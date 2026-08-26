#import "OpenConnectSession.h"
#import "CiscoTunnel-Swift.h"
#import <openconnect.h>
#import <arpa/inet.h>
#import <sys/socket.h>
#import <unistd.h>

@interface OpenConnectSession ()
@property(nonatomic) struct openconnect_info *vpn;
@property(nonatomic) int packetSocket;
@property(nonatomic) dispatch_source_t packetPump;
@property(nonatomic, copy) void (^configureNetwork)(NEPacketTunnelNetworkSettings *, void (^)(NSError *));
@property(nonatomic, copy) void (^failed)(NSError *);
@property(nonatomic) TunnelConfiguration *configuration;
@end

static int process_auth_form(void *privdata, struct oc_auth_form *form) {
    OpenConnectSession *session = (__bridge OpenConnectSession *)privdata;
    NSString *formID = [NSString stringWithUTF8String:form->auth_id ?: ""];
    for (struct oc_form_opt *option = form->opts; option; option = option->next) {
        NSString *name = [NSString stringWithUTF8String:option->name ?: ""];
        NSString *value = nil;
        if ([formID isEqualToString:@"main"] && [name isEqualToString:@"username"]) value = session.configuration.username;
        if ([formID isEqualToString:@"main"] && [name isEqualToString:@"password"]) value = session.configuration.password;
        if ([formID isEqualToString:@"challenge"] && [name isEqualToString:@"answer"]) value = session.configuration.otp;
        if (value.length > 0) openconnect_set_option_value(option, value.UTF8String);
    }
    if (form->authgroup_opt && session.configuration.group.length > 0) {
        openconnect_set_option_value(&form->authgroup_opt->form, session.configuration.group.UTF8String);
    }
    return OC_FORM_RESULT_OK;
}

static int validate_peer_certificate(void *privdata, const char *reason) {
    // Trust is never weakened automatically. A future UI flow may pin an explicit hash.
    return -1;
}

static void report_progress(void *privdata, int level, const char *fmt, ...) {
    // Do not forward raw OpenConnect logs: they can contain server-controlled data.
}

@implementation OpenConnectSession

- (instancetype)initWithConfiguration:(TunnelConfiguration *)configuration {
    self = [super init];
    if (self) {
        _configuration = configuration;
        _packetSocket = -1;
    }
    return self;
}

- (void)startWithPacketFlow:(NEPacketTunnelFlow *)packetFlow
            configureNetwork:(void (^)(NEPacketTunnelNetworkSettings *, void (^)(NSError *)))configureNetwork
                      failed:(void (^)(NSError *))failed {
    self.configureNetwork = configureNetwork;
    self.failed = failed;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self connectAndPump:packetFlow];
    });
}

- (void)connectAndPump:(NEPacketTunnelFlow *)packetFlow {
    if (openconnect_init_ssl() != 0) return [self fail:@"Unable to initialize OpenConnect TLS."];
    self.vpn = openconnect_vpninfo_new("AnyConnect", validate_peer_certificate, NULL, process_auth_form, report_progress, (__bridge void *)self);
    if (!self.vpn) return [self fail:@"Unable to create an OpenConnect session."];
    if (openconnect_set_protocol(self.vpn, "anyconnect") || openconnect_parse_url(self.vpn, self.configuration.gateway.UTF8String)) return [self fail:@"The Cisco gateway is invalid."];
    openconnect_set_xmlpost(self.vpn, 1);
    openconnect_set_pfs(self.vpn, 0);
    openconnect_set_reported_os(self.vpn, "mac-intel");
    if (openconnect_obtain_cookie(self.vpn) != 0) return [self fail:@"Cisco gateway rejected the credentials or OTP."];
    if (openconnect_make_cstp_connection(self.vpn) != 0) return [self fail:@"Unable to establish the Cisco tunnel."];

    const struct oc_ip_info *ipInfo = NULL;
    if (openconnect_get_ip_info(self.vpn, &ipInfo, NULL, NULL) != 0 || !ipInfo) return [self fail:@"Cisco gateway did not provide network settings."];
    NEPacketTunnelNetworkSettings *settings = [self networkSettingsFromIPInfo:ipInfo];
    dispatch_semaphore_t networkSettingsReady = dispatch_semaphore_create(0);
    __block NSError *settingsError = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.configureNetwork(settings, ^(NSError *error) {
            settingsError = error;
            dispatch_semaphore_signal(networkSettingsReady);
        });
    });
    dispatch_semaphore_wait(networkSettingsReady, DISPATCH_TIME_FOREVER);
    if (settingsError) return [self fail:settingsError.localizedDescription];

    int sockets[2];
    if (socketpair(AF_UNIX, SOCK_DGRAM, 0, sockets) != 0) return [self fail:@"Unable to create the packet bridge."];
    self.packetSocket = sockets[0];
    if (openconnect_setup_tun_fd(self.vpn, sockets[1]) != 0) return [self fail:@"OpenConnect could not attach the packet bridge."];
    if (openconnect_setup_dtls(self.vpn, 60) != 0) return [self fail:@"OpenConnect could not enable DTLS."];
    [self readPacketsFrom:packetFlow];
    openconnect_mainloop(self.vpn, RECONNECT_INTERVAL_MIN, RECONNECT_INTERVAL_MIN);
}

- (NEPacketTunnelNetworkSettings *)networkSettingsFromIPInfo:(const struct oc_ip_info *)info {
    NSURLComponents *components = [NSURLComponents componentsWithString:self.configuration.gateway];
    NSString *remoteAddress = components.host ?: self.configuration.gateway;
    NEPacketTunnelNetworkSettings *settings = [[NEPacketTunnelNetworkSettings alloc] initWithTunnelRemoteAddress:remoteAddress];
    if (info->addr && info->netmask) {
        NEIPv4Settings *ipv4 = [[NEIPv4Settings alloc] initWithAddresses:@[[NSString stringWithUTF8String:info->addr]] subnetMasks:@[[NSString stringWithUTF8String:info->netmask]]];
        NSMutableArray<NEIPv4Route *> *routes = [NSMutableArray array];
        for (struct oc_split_include *route = info->split_includes; route; route = route->next) {
            NEIPv4Route *parsed = [self ipv4RouteFromCString:route->route];
            if (parsed) [routes addObject:parsed];
        }
        // A gateway that provides no split routes is treated as full-tunnel.
        ipv4.includedRoutes = routes.count ? routes : @[[NEIPv4Route defaultRoute]];
        settings.IPv4Settings = ipv4;
    }
    NSMutableArray *dns = [NSMutableArray array];
    for (int index = 0; index < 3; index++) if (info->dns[index]) [dns addObject:[NSString stringWithUTF8String:info->dns[index]]];
    if (dns.count) settings.DNSSettings = [[NEDNSSettings alloc] initWithServers:dns];
    return settings;
}

- (NEIPv4Route *)ipv4RouteFromCString:(const char *)routeCString {
    if (!routeCString) return nil;
    NSString *route = [NSString stringWithUTF8String:routeCString];
    NSArray<NSString *> *parts = [route componentsSeparatedByString:@"/"];
    if (parts.count != 2 || parts[0].length == 0) return nil;
    NSString *mask = parts[1];
    if (![mask containsString:@"."]) {
        NSInteger prefix = mask.integerValue;
        if (prefix < 0 || prefix > 32) return nil;
        uint32_t numericMask = prefix == 0 ? 0 : htonl(0xFFFFFFFF << (32 - prefix));
        struct in_addr address = { .s_addr = numericMask };
        char buffer[INET_ADDRSTRLEN];
        mask = [NSString stringWithUTF8String:inet_ntop(AF_INET, &address, buffer, sizeof(buffer))];
    }
    return [[NEIPv4Route alloc] initWithDestinationAddress:parts[0] subnetMask:mask];
}

- (void)readPacketsFrom:(NEPacketTunnelFlow *)packetFlow {
    __weak typeof(self) weakSelf = self;
    [packetFlow readPacketsWithCompletionHandler:^(NSArray<NSData *> *packets, NSArray<NSNumber *> *protocols) {
        OpenConnectSession *strongSelf = weakSelf;
        if (!strongSelf || strongSelf.packetSocket < 0) return;
        for (NSData *packet in packets) {
            send(strongSelf.packetSocket, packet.bytes, packet.length, 0);
        }
        [strongSelf readPacketsFrom:packetFlow];
    }];

    int socketFD = self.packetSocket;
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)socketFD, 0, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
    self.packetPump = source;
    dispatch_source_set_event_handler(source, ^{
        OpenConnectSession *strongSelf = weakSelf;
        if (!strongSelf || strongSelf.packetSocket < 0) return;
        uint8_t buffer[65536];
        ssize_t size = recv(socketFD, buffer, sizeof(buffer), 0);
        if (size <= 0) return;
        NSData *packet = [NSData dataWithBytes:buffer length:(NSUInteger)size];
        sa_family_t family = ((buffer[0] >> 4) == 6) ? AF_INET6 : AF_INET;
        [packetFlow writePackets:@[packet] withProtocols:@[@(family)]];
    });
    dispatch_resume(source);
}

- (void)stop {
    if (self.packetPump) {
        dispatch_source_cancel(self.packetPump);
        self.packetPump = nil;
    }
    if (self.vpn) {
        int commandFD = openconnect_setup_cmd_pipe(self.vpn);
        if (commandFD >= 0) write(commandFD, "x", 1);
    }
    if (self.packetSocket >= 0) { close(self.packetSocket); self.packetSocket = -1; }
}

- (void)fail:(NSString *)message {
    NSError *error = [NSError errorWithDomain:@"CiscoConnect.OpenConnect" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
    dispatch_async(dispatch_get_main_queue(), ^{ self.failed(error); });
}

- (void)dealloc {
    [self stop];
    if (self.vpn) openconnect_vpninfo_free(self.vpn);
}
@end

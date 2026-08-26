#import <Foundation/Foundation.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <openconnect.h>
#import <errno.h>
#import <fcntl.h>
#import <signal.h>
#import <stdatomic.h>
#import <sys/stat.h>
#import <unistd.h>
#import <xpc/xpc.h>

typedef NS_ENUM(NSInteger, HelperMode) { HelperModeDiscover, HelperModeConnect };

@interface HelperSession : NSObject
@property struct openconnect_info *vpn;
@property HelperMode mode;
@property NSDictionary *request;
@property NSString *statusPath;
@property NSString *otpPath;
@property BOOL passwordSubmitted;
@property BOOL otpSubmitted;
@property BOOL groupApplied;
@property BOOL authenticationRejected;
@property BOOL timedOut;
@property BOOL authenticationComplete;
@property BOOL disconnectRequested;
@property NSTimeInterval deadline;
@property int commandFD;
@property NSDictionary *networkInfo;
- (int)processForm:(struct oc_auth_form *)form;
- (void)writeState:(NSString *)state message:(NSString *)message groups:(NSArray *)groups;
- (BOOL)systemConfigurationIsReady;
@end

static HelperSession *activeSession;
static dispatch_queue_t sessionQueue;
static atomic_bool sessionReserved = false;

static NSString *stringValue(const char *value) {
    return value ? [NSString stringWithUTF8String:value] : @"";
}

static int process_auth_form(void *data, struct oc_auth_form *form) {
    return [(__bridge HelperSession *)data processForm:form];
}

static int validate_peer_certificate(void *data, const char *reason) {
    HelperSession *session = (__bridge HelperSession *)data;
    const char *hash = openconnect_get_peer_cert_hash(session.vpn);
    NSString *message = [NSString stringWithFormat:@"Server certificate validation failed (%s). Fingerprint: %s", reason ?: "unknown", hash ?: "unavailable"];
    [session writeState:@"failed" message:message groups:@[]];
    return -1;
}

static void progress_callback(void *data, int level, const char *format, ...) {
    (void)data; (void)level; (void)format;
}

@implementation HelperSession

- (void)writeState:(NSString *)state message:(NSString *)message groups:(NSArray *)groups {
    NSDictionary *payload = @{
        @"state": state, @"message": message, @"groups": groups,
        @"networkInfo": self.networkInfo ?: @{}
    };
    NSString *temporary = [self.statusPath stringByAppendingString:@".new"];
    [payload writeToFile:temporary atomically:YES];
    chmod(temporary.fileSystemRepresentation, 0644);
    rename(temporary.fileSystemRepresentation, self.statusPath.fileSystemRepresentation);
}

- (NSArray *)valuesFromSplitList:(const struct oc_split_include *)item {
    NSMutableArray *values = [NSMutableArray array];
    for (; item; item = item->next) {
        NSString *value = stringValue(item->route);
        if (value.length && ![values containsObject:value]) [values addObject:value];
    }
    return values;
}

- (NSDictionary *)networkInfoFromVPN {
    const struct oc_ip_info *info = NULL;
    const struct oc_vpn_option *cstpOptions = NULL;
    const struct oc_vpn_option *dtlsOptions = NULL;
    if (openconnect_get_ip_info(self.vpn, &info, &cstpOptions, &dtlsOptions) || !info) return @{};
    NSMutableArray *domains = [[self valuesFromSplitList:info->split_dns] mutableCopy];
    NSString *defaultDomain = stringValue(info->domain);
    if (defaultDomain.length && ![domains containsObject:defaultDomain]) [domains addObject:defaultDomain];
    NSMutableArray *dnsServers = [NSMutableArray array];
    for (int index = 0; index < 3; index++) {
        NSString *server = stringValue(info->dns[index]);
        if (server.length && ![dnsServers containsObject:server]) [dnsServers addObject:server];
    }
    NSMutableArray *vpnAddresses = [NSMutableArray array];
    NSString *ipv4 = stringValue(info->addr);
    NSString *ipv6 = stringValue(info->addr6);
    if (ipv4.length) [vpnAddresses addObject:ipv4];
    if (ipv6.length) [vpnAddresses addObject:ipv6];
    return @{
        @"available": @YES,
        @"includedRoutes": [self valuesFromSplitList:info->split_includes],
        @"excludedRoutes": [self valuesFromSplitList:info->split_excludes],
        @"domains": domains, @"dnsServers": dnsServers, @"vpnAddresses": vpnAddresses
    };
}

- (BOOL)systemConfigurationIsReady {
    NSString *interfaceName = stringValue(openconnect_get_ifname(self.vpn));
    if (!interfaceName.length) return NO;

    NSString *dnsKey = [NSString stringWithFormat:@"State:/Network/Service/%@/DNS", interfaceName];
    NSString *ipv4Key = [NSString stringWithFormat:@"State:/Network/Service/%@/IPv4", interfaceName];
    NSDictionary *dnsState = CFBridgingRelease(SCDynamicStoreCopyValue(NULL, (__bridge CFStringRef)dnsKey));
    NSDictionary *ipv4State = CFBridgingRelease(SCDynamicStoreCopyValue(NULL, (__bridge CFStringRef)ipv4Key));
    NSArray *activeDNS = [dnsState[@"ServerAddresses"] isKindOfClass:NSArray.class] ? dnsState[@"ServerAddresses"] : @[];
    NSArray *activeAddresses = [ipv4State[@"Addresses"] isKindOfClass:NSArray.class] ? ipv4State[@"Addresses"] : @[];
    NSArray *expectedDNS = self.networkInfo[@"dnsServers"] ?: @[];
    NSArray *expectedAddresses = self.networkInfo[@"vpnAddresses"] ?: @[];

    for (NSString *server in expectedDNS) if (![activeDNS containsObject:server]) return NO;
    for (NSString *address in expectedAddresses) if (![activeAddresses containsObject:address]) return NO;
    return expectedDNS.count == 0 || activeDNS.count > 0;
}

- (NSArray *)groupsFromForm:(struct oc_auth_form *)form {
    NSMutableArray *groups = [NSMutableArray array];
    struct oc_form_opt_select *select = form->authgroup_opt;
    if (!select) return groups;
    for (int index = 0; index < select->nr_choices; index++) {
        struct oc_choice *choice = select->choices[index];
        if (!choice) continue;
        NSString *name = stringValue(choice->name);
        NSString *label = stringValue(choice->label);
        if (name.length) [groups addObject:@{ @"id": name, @"label": label.length ? label : name }];
    }
    return groups;
}

- (BOOL)isOTPOption:(struct oc_form_opt *)option form:(struct oc_auth_form *)form {
    NSString *formID = stringValue(form->auth_id).lowercaseString;
    NSString *name = stringValue(option->name).lowercaseString;
    NSString *label = stringValue(option->label).lowercaseString;
    if ([formID isEqualToString:@"challenge"] && [name isEqualToString:@"answer"]) return YES;
    NSString *hint = [NSString stringWithFormat:@"%@ %@", name, label];
    for (NSString *word in @[@"otp", @"token", @"passcode", @"code", @"answer", @"secondary"]) {
        if ([hint containsString:word]) return YES;
    }
    return option->type == OC_FORM_OPT_TOKEN || (self.passwordSubmitted && option->type == OC_FORM_OPT_PASSWORD);
}

- (BOOL)isUsernameOption:(struct oc_form_opt *)option form:(struct oc_auth_form *)form {
    NSString *formID = stringValue(form->auth_id).lowercaseString;
    NSString *name = stringValue(option->name).lowercaseString;
    if ([formID isEqualToString:@"main"] && [name isEqualToString:@"username"]) return YES;
    if (option->type != OC_FORM_OPT_TEXT) return NO;
    NSString *hint = [NSString stringWithFormat:@"%@ %@", name, stringValue(option->label).lowercaseString];
    for (NSString *word in @[@"user", @"login", @"логин", @"пользователь"]) {
        if ([hint containsString:word]) return YES;
    }
    return NO;
}

- (BOOL)isPasswordOption:(struct oc_form_opt *)option form:(struct oc_auth_form *)form {
    NSString *formID = stringValue(form->auth_id).lowercaseString;
    NSString *name = stringValue(option->name).lowercaseString;
    if ([formID isEqualToString:@"main"] && [name isEqualToString:@"password"]) return YES;
    return option->type == OC_FORM_OPT_PASSWORD && !self.passwordSubmitted;
}

- (NSString *)waitForOTP {
    if (self.otpSubmitted) return nil;
    self.deadline = NSDate.date.timeIntervalSince1970 + 60;
    [self writeState:@"otpRequired" message:@"Enter the one-time code" groups:@[]];
    while (NSDate.date.timeIntervalSince1970 < self.deadline) {
        NSData *data = [NSData dataWithContentsOfFile:self.otpPath];
        if (data.length) {
            unlink(self.otpPath.fileSystemRepresentation);
            NSString *otp = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            otp = [otp stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (otp.length) {
                self.otpSubmitted = YES;
                self.deadline = NSDate.date.timeIntervalSince1970 + 45;
                return otp;
            }
        }
        usleep(200000);
    }
    self.timedOut = YES;
    return nil;
}

- (int)processForm:(struct oc_auth_form *)form {
    NSArray *groups = [self groupsFromForm:form];
    if (self.mode == HelperModeDiscover) {
        [self writeState:@"groupsAvailable" message:groups.count ? @"Choose a VPN group" : @"No group selection is required" groups:groups];
        return OC_FORM_RESULT_CANCELLED;
    }
    if (form->error && (self.passwordSubmitted || self.otpSubmitted)) {
        self.authenticationRejected = YES;
        return OC_FORM_RESULT_ERR;
    }
    NSString *configuredGroup = self.request[@"group"] ?: @"";
    if (form->authgroup_opt && configuredGroup.length) {
        struct oc_choice *match = NULL;
        for (int index = 0; index < form->authgroup_opt->nr_choices; index++) {
            struct oc_choice *choice = form->authgroup_opt->choices[index];
            if ([stringValue(choice->name) caseInsensitiveCompare:configuredGroup] == NSOrderedSame ||
                [stringValue(choice->label) caseInsensitiveCompare:configuredGroup] == NSOrderedSame) {
                match = choice; break;
            }
        }
        if (!match) {
            [self writeState:@"failed" message:@"The saved VPN group is no longer offered by the gateway" groups:groups];
            return OC_FORM_RESULT_ERR;
        }
        openconnect_set_option_value(&form->authgroup_opt->form, match->name);
        if (!self.groupApplied) {
            self.groupApplied = YES;
            struct oc_choice *current = form->authgroup_selection >= 0 && form->authgroup_selection < form->authgroup_opt->nr_choices ? form->authgroup_opt->choices[form->authgroup_selection] : NULL;
            if (!current || strcmp(current->name, match->name)) return OC_FORM_RESULT_NEWGROUP;
        }
    }
    for (struct oc_form_opt *option = form->opts; option; option = option->next) {
        BOOL otpOption = [self isOTPOption:option form:form];
        if (!otpOption && ((option->flags & OC_FORM_OPT_IGNORE) || option->type == OC_FORM_OPT_HIDDEN)) continue;
        NSString *value = nil;
        if ([self isUsernameOption:option form:form]) {
            value = self.request[@"username"];
        } else if (otpOption) {
            value = [self waitForOTP];
            if (!value) { self.authenticationRejected = self.otpSubmitted; return OC_FORM_RESULT_ERR; }
        } else if ([self isPasswordOption:option form:form]) {
            if (self.passwordSubmitted) { self.authenticationRejected = YES; return OC_FORM_RESULT_ERR; }
            value = self.request[@"password"];
            self.passwordSubmitted = YES;
            self.deadline = NSDate.date.timeIntervalSince1970 + 45;
        } else if (option->type == OC_FORM_OPT_SELECT && !option->_value) {
            struct oc_form_opt_select *select = (struct oc_form_opt_select *)option;
            if (select->nr_choices) openconnect_set_option_value(option, select->choices[0]->name);
            continue;
        }
        if (value.length) openconnect_set_option_value(option, value.UTF8String);
        else if (option->type != OC_FORM_OPT_SELECT) {
            [self writeState:@"failed" message:@"The gateway requested an unsupported authentication field" groups:@[]];
            return OC_FORM_RESULT_ERR;
        }
    }
    [self writeState:@"authenticating" message:self.otpSubmitted ? @"Checking the one-time code" : @"Checking credentials" groups:@[]];
    return OC_FORM_RESULT_OK;
}
@end

static void stop_signal(int signalNumber) {
    (void)signalNumber;
    HelperSession *session = activeSession;
    if (session) session.disconnectRequested = YES;
    if (session && session.commandFD >= 0) write(session.commandFD, "x", 1);
}

static NSString *installedRuntimeRoot(void) {
    NSString *executable = NSProcessInfo.processInfo.arguments.firstObject.stringByStandardizingPath;
    return [[executable stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
}

static NSString *installedContainerRoot(void) {
    NSString *root = installedRuntimeRoot();
    for (int index = 0; index < 3; index++) root = root.stringByDeletingLastPathComponent;
    return root;
}

static void scheduleTimeout(HelperSession *session) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        while (session.vpn && !session.authenticationComplete && NSDate.date.timeIntervalSince1970 < session.deadline) usleep(200000);
        if (session.vpn && !session.authenticationComplete && NSDate.date.timeIntervalSince1970 >= session.deadline) {
            session.timedOut = YES;
            if (session.commandFD >= 0) write(session.commandFD, "x", 1);
        }
    });
}

static int runRequest(NSDictionary *originalRequest) {
    NSMutableDictionary *request = [originalRequest mutableCopy];
    if (!request[@"vpncScript"]) request[@"vpncScript"] = [installedRuntimeRoot() stringByAppendingPathComponent:@"vpnc-script"];
    HelperSession *session = [HelperSession new];
    activeSession = session;
    session.request = request;
    session.statusPath = request[@"statusPath"];
    session.otpPath = request[@"otpPath"];
    session.mode = [request[@"mode"] isEqualToString:@"discover"] ? HelperModeDiscover : HelperModeConnect;
    session.commandFD = -1;
    session.deadline = NSDate.date.timeIntervalSince1970 + 45;
    [[NSString stringWithFormat:@"%d\n", getpid()] writeToFile:request[@"pidPath"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [session writeState:@"authenticating" message:session.mode == HelperModeDiscover ? @"Loading VPN groups" : @"Contacting VPN gateway" groups:@[]];

    int result = 0;
    if (openconnect_init_ssl()) { result = 70; goto finished; }
    session.vpn = openconnect_vpninfo_new("AnyConnect", validate_peer_certificate, NULL, process_auth_form, progress_callback, (__bridge void *)session);
    if (!session.vpn) { result = 71; goto finished; }
    session.commandFD = openconnect_setup_cmd_pipe(session.vpn);
    scheduleTimeout(session);
    openconnect_set_protocol(session.vpn, "anyconnect");
    openconnect_set_xmlpost(session.vpn, 1);
    openconnect_set_pfs(session.vpn, 0);
    openconnect_set_reported_os(session.vpn, "mac-intel");
    if (openconnect_parse_url(session.vpn, [request[@"gateway"] UTF8String])) { result = 72; goto finished; }
    int auth = openconnect_obtain_cookie(session.vpn);
    session.authenticationComplete = auth == 0;
    if (session.mode == HelperModeDiscover) goto finished;
    if (auth) {
        if (session.passwordSubmitted && !session.timedOut) session.authenticationRejected = YES;
        NSString *message = session.timedOut ? @"Authentication timed out" : (session.authenticationRejected ? @"The gateway rejected the credentials or one-time code; automatic retry is disabled" : @"Authentication could not be completed");
        [session writeState:session.authenticationRejected ? @"authenticationFailed" : @"failed" message:message groups:@[]];
        result = 73; goto finished;
    }
    if (openconnect_make_cstp_connection(session.vpn)) {
        [session writeState:@"failed" message:@"Could not establish the encrypted VPN channel" groups:@[]];
        result = 74; goto finished;
    }
    session.networkInfo = [session networkInfoFromVPN];
    if (openconnect_setup_tun_device(session.vpn, [request[@"vpncScript"] UTF8String], NULL)) {
        [session writeState:@"failed" message:@"Could not create the macOS VPN interface" groups:@[]];
        result = 75; goto finished;
    }
    BOOL configurationReady = NO;
    for (int check = 0; check < 20 && !configurationReady; check++) {
        configurationReady = [session systemConfigurationIsReady];
        if (!configurationReady) usleep(100000);
    }
    if (!configurationReady) {
        [session writeState:@"failed" message:@"macOS не применила VPN-адрес или корпоративные DNS" groups:@[]];
        result = 76; goto finished;
    }
    openconnect_setup_dtls(session.vpn, 60);
    [session writeState:@"connected" message:@"VPN connected" groups:@[]];
    int mainloopResult = openconnect_mainloop(session.vpn, 300, RECONNECT_INTERVAL_MIN);
    if (session.disconnectRequested) {
        [session writeState:@"disconnected" message:@"VPN отключён пользователем" groups:@[]];
    } else {
        NSString *message = [NSString stringWithFormat:@"VPN-соединение прервано; автоматическое восстановление не удалось (код OpenConnect: %d)", mainloopResult];
        [session writeState:@"failed" message:message groups:@[]];
        result = mainloopResult ?: 77;
    }

finished:
    if (session.vpn) openconnect_vpninfo_free(session.vpn);
    session.vpn = NULL;
    activeSession = nil;
    NSNumber *peerUID = request[@"peerUID"];
    if (peerUID) {
        NSString *directory = [request[@"statusPath"] stringByDeletingLastPathComponent];
        chmod(directory.fileSystemRepresentation, 0700);
        chown(directory.fileSystemRepresentation, peerUID.unsignedIntValue, (gid_t)-1);
    }
    return result;
}

static BOOL matchesSessionPath(NSString *path, NSString *directory, NSString *filename) {
    if (![path isKindOfClass:NSString.class]) return NO;
    NSString *expected = [directory stringByAppendingPathComponent:filename].stringByStandardizingPath;
    return [path.stringByStandardizingPath isEqualToString:expected];
}

static BOOL validateRequest(NSDictionary *request, uid_t peerUID, NSString **errorMessage) {
    NSString *statusPath = request[@"statusPath"];
    if (![statusPath isKindOfClass:NSString.class]) return NO;
    NSString *directory = statusPath.stringByDeletingLastPathComponent.stringByStandardizingPath;
    struct stat info;
    if (!directory.length || lstat(directory.fileSystemRepresentation, &info) || !S_ISDIR(info.st_mode) || info.st_uid != peerUID || (info.st_mode & 0077)) {
        if (errorMessage) *errorMessage = @"Недопустимая папка VPN-сеанса";
        return NO;
    }
    if (!matchesSessionPath(statusPath, directory, @"status.plist") ||
        !matchesSessionPath(request[@"otpPath"], directory, @"otp") ||
        !matchesSessionPath(request[@"pidPath"], directory, @"pid")) {
        if (errorMessage) *errorMessage = @"Недопустимые пути VPN-сеанса";
        return NO;
    }
    struct stat otpInfo;
    NSString *otpPath = request[@"otpPath"];
    if (lstat(otpPath.fileSystemRepresentation, &otpInfo) || !S_ISREG(otpInfo.st_mode) || otpInfo.st_uid != peerUID || (otpInfo.st_mode & 0077) ||
        lstat(statusPath.fileSystemRepresentation, &otpInfo) == 0 || errno != ENOENT ||
        lstat([request[@"pidPath"] fileSystemRepresentation], &otpInfo) == 0 || errno != ENOENT) {
        if (errorMessage) *errorMessage = @"Недопустимые файлы VPN-сеанса";
        return NO;
    }
    NSString *mode = request[@"mode"];
    NSString *gateway = request[@"gateway"];
    if ((!([mode isEqualToString:@"connect"] || [mode isEqualToString:@"discover"])) || ![gateway isKindOfClass:NSString.class] || !gateway.length) {
        if (errorMessage) *errorMessage = @"Недопустимый запрос VPN";
        return NO;
    }
    return YES;
}

static BOOL protectSessionDirectory(NSDictionary *request, uid_t peerUID) {
    NSString *directory = [request[@"statusPath"] stringByDeletingLastPathComponent].stringByStandardizingPath;
    int descriptor = open(directory.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    if (descriptor < 0) return NO;
    struct stat info;
    BOOL valid = fstat(descriptor, &info) == 0 && S_ISDIR(info.st_mode) && info.st_uid == peerUID && !(info.st_mode & 0077);
    if (valid) valid = fchown(descriptor, 0, 0) == 0 && fchmod(descriptor, 0711) == 0;
    close(descriptor);
    return valid;
}

static void sendReply(xpc_object_t event, BOOL accepted, NSString *message) {
    xpc_object_t reply = xpc_dictionary_create_reply(event);
    if (!reply) return;
    xpc_dictionary_set_bool(reply, "accepted", accepted);
    xpc_dictionary_set_string(reply, "message", message.UTF8String ?: "");
    xpc_connection_send_message(xpc_dictionary_get_remote_connection(event), reply);
}

static void handleMessage(xpc_connection_t peer, xpc_object_t event) {
    if (xpc_get_type(event) != XPC_TYPE_DICTIONARY) return;
    const char *rawCommand = xpc_dictionary_get_string(event, "command");
    NSString *command = rawCommand ? [NSString stringWithUTF8String:rawCommand] : @"";
    if ([command isEqualToString:@"ping"]) { sendReply(event, YES, @""); return; }
    if ([command isEqualToString:@"disconnect"]) {
        HelperSession *session = activeSession;
        if (session) session.disconnectRequested = YES;
        if (session && session.commandFD >= 0) write(session.commandFD, "x", 1);
        sendReply(event, YES, @"");
        return;
    }
    if (![command isEqualToString:@"connect"]) { sendReply(event, NO, @"Неизвестная команда"); return; }
    size_t length = 0;
    const void *bytes = xpc_dictionary_get_data(event, "payload", &length);
    NSData *data = bytes && length ? [NSData dataWithBytes:bytes length:length] : nil;
    id decoded = data ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:nil error:nil] : nil;
    NSDictionary *request = [decoded isKindOfClass:NSDictionary.class] ? decoded : nil;
    NSString *validationError = nil;
    if (!request || !validateRequest(request, xpc_connection_get_euid(peer), &validationError)) {
        sendReply(event, NO, validationError ?: @"Повреждённый запрос VPN");
        return;
    }
    if (atomic_exchange(&sessionReserved, true)) { sendReply(event, NO, @"VPN-сеанс уже запущен"); return; }
    uid_t peerUID = xpc_connection_get_euid(peer);
    if (!protectSessionDirectory(request, peerUID)) {
        atomic_store(&sessionReserved, false);
        sendReply(event, NO, @"Не удалось защитить папку VPN-сеанса");
        return;
    }
    NSMutableDictionary *safeRequest = [request mutableCopy];
    safeRequest[@"vpncScript"] = [installedRuntimeRoot() stringByAppendingPathComponent:@"vpnc-script"];
    safeRequest[@"peerUID"] = @(peerUID);
    sendReply(event, YES, @"");
    dispatch_async(sessionQueue, ^{
        runRequest(safeRequest);
        atomic_store(&sessionReserved, false);
    });
}

static int runDaemon(void) {
    NSString *requirementPath = [installedContainerRoot() stringByAppendingPathComponent:@"client-requirement.txt"];
    NSString *requirement = [NSString stringWithContentsOfFile:requirementPath encoding:NSUTF8StringEncoding error:nil];
    requirement = [requirement stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!requirement.length) return 76;
    sessionQueue = dispatch_queue_create("com.max.openconnectnative.helper.session", DISPATCH_QUEUE_SERIAL);
    xpc_connection_t listener = xpc_connection_create_mach_service("com.max.openconnectnative.helper", dispatch_get_main_queue(), XPC_CONNECTION_MACH_SERVICE_LISTENER);
    if (!listener) return 77;
    if (xpc_connection_set_peer_code_signing_requirement(listener, requirement.UTF8String)) return 78;
    xpc_connection_set_event_handler(listener, ^(xpc_object_t peerObject) {
        if (xpc_get_type(peerObject) != XPC_TYPE_CONNECTION) return;
        xpc_connection_t peer = (xpc_connection_t)peerObject;
        xpc_connection_set_event_handler(peer, ^(xpc_object_t event) { handleMessage(peer, event); });
        xpc_connection_activate(peer);
    });
    xpc_connection_activate(listener);
    dispatch_main();
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        signal(SIGINT, stop_signal);
        signal(SIGTERM, stop_signal);
        if (argc == 1) return runDaemon();
        if (argc != 2) return 64;
        NSString *requestPath = [NSString stringWithUTF8String:argv[1]];
        NSDictionary *request = [NSDictionary dictionaryWithContentsOfFile:requestPath];
        unlink(requestPath.fileSystemRepresentation);
        if (!request) return 65;
        return runRequest(request);
    }
}

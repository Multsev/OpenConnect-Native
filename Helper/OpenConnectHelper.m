#import <Foundation/Foundation.h>
#import <openconnect.h>
#import <signal.h>
#import <sys/stat.h>
#import <unistd.h>

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
@property NSTimeInterval deadline;
@property int commandFD;
@property NSDictionary *networkInfo;
- (int)processForm:(struct oc_auth_form *)form;
- (void)writeState:(NSString *)state message:(NSString *)message groups:(NSArray *)groups;
@end

static HelperSession *activeSession;

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
    // Raw server-controlled diagnostics are intentionally not persisted.
}

static NSString *stringValue(const char *value) {
    return value ? [NSString stringWithUTF8String:value] : @"";
}

@implementation HelperSession

- (void)writeState:(NSString *)state message:(NSString *)message groups:(NSArray *)groups {
    NSDictionary *payload = @{
        @"state": state,
        @"message": message,
        @"groups": groups,
        @"networkInfo": self.networkInfo ?: @{}
    };
    NSString *temporary = [self.statusPath stringByAppendingString:@".new"];
    [payload writeToFile:temporary atomically:YES];
    // The elevated helper owns this file, while the GUI must read it. The
    // parent session directory is user-owned 0700, so 0644 does not expose the
    // state outside that private directory.
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
        @"domains": domains,
        @"dnsServers": dnsServers,
        @"vpnAddresses": vpnAddresses
    };
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
            if (otp.length) { self.otpSubmitted = YES; self.deadline = NSDate.date.timeIntervalSince1970 + 45; return otp; }
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
            if ([stringValue(choice->name) caseInsensitiveCompare:configuredGroup] == NSOrderedSame || [stringValue(choice->label) caseInsensitiveCompare:configuredGroup] == NSOrderedSame) { match = choice; break; }
        }
        if (!match) { [self writeState:@"failed" message:@"The saved VPN group is no longer offered by the gateway" groups:groups]; return OC_FORM_RESULT_ERR; }
        openconnect_set_option_value(&form->authgroup_opt->form, match->name);
        if (!self.groupApplied) {
            self.groupApplied = YES;
            struct oc_choice *current = form->authgroup_selection >= 0 && form->authgroup_selection < form->authgroup_opt->nr_choices ? form->authgroup_opt->choices[form->authgroup_selection] : NULL;
            if (!current || strcmp(current->name, match->name)) return OC_FORM_RESULT_NEWGROUP;
        }
    }
    NSString *formID = stringValue(form->auth_id).lowercaseString;
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
            value = self.request[@"password"]; self.passwordSubmitted = YES; self.deadline = NSDate.date.timeIntervalSince1970 + 45;
        } else if (option->type == OC_FORM_OPT_SELECT && !option->_value) {
            struct oc_form_opt_select *select = (struct oc_form_opt_select *)option;
            if (select->nr_choices) openconnect_set_option_value(option, select->choices[0]->name);
            continue;
        }
        if (value.length) openconnect_set_option_value(option, value.UTF8String);
        else if (option->type != OC_FORM_OPT_SELECT) { [self writeState:@"failed" message:@"The gateway requested an unsupported authentication field" groups:@[]]; return OC_FORM_RESULT_ERR; }
    }
    [self writeState:@"authenticating" message:self.otpSubmitted ? @"Checking the one-time code" : @"Checking credentials" groups:@[]];
    return OC_FORM_RESULT_OK;
}
@end

static void stop_signal(int signalNumber) {
    (void)signalNumber;
    if (activeSession.commandFD >= 0) write(activeSession.commandFD, "x", 1);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) return 64;
        NSString *requestPath = [NSString stringWithUTF8String:argv[1]];
        NSDictionary *request = [NSDictionary dictionaryWithContentsOfFile:requestPath];
        unlink(requestPath.fileSystemRepresentation);
        if (!request) return 65;
        HelperSession *session = [HelperSession new]; activeSession = session;
        session.request = request;
        session.statusPath = request[@"statusPath"];
        session.otpPath = request[@"otpPath"];
        session.mode = [request[@"mode"] isEqualToString:@"discover"] ? HelperModeDiscover : HelperModeConnect;
        session.commandFD = -1;
        session.deadline = NSDate.date.timeIntervalSince1970 + 45;
        [[NSString stringWithFormat:@"%d\n", getpid()] writeToFile:request[@"pidPath"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        signal(SIGINT, stop_signal); signal(SIGTERM, stop_signal);
        [session writeState:@"authenticating" message:session.mode == HelperModeDiscover ? @"Loading VPN groups" : @"Contacting VPN gateway" groups:@[]];

        if (openconnect_init_ssl()) return 70;
        session.vpn = openconnect_vpninfo_new("AnyConnect", validate_peer_certificate, NULL, process_auth_form, progress_callback, (__bridge void *)session);
        if (!session.vpn) return 71;
        session.commandFD = openconnect_setup_cmd_pipe(session.vpn);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            while (session.vpn && NSDate.date.timeIntervalSince1970 < session.deadline) usleep(200000);
            if (session.vpn && NSDate.date.timeIntervalSince1970 >= session.deadline) {
                session.timedOut = YES;
                if (session.commandFD >= 0) write(session.commandFD, "x", 1);
            }
        });
        openconnect_set_protocol(session.vpn, "anyconnect");
        openconnect_set_xmlpost(session.vpn, 1); openconnect_set_pfs(session.vpn, 0);
        openconnect_set_reported_os(session.vpn, "mac-intel");
        if (openconnect_parse_url(session.vpn, [request[@"gateway"] UTF8String])) return 72;
        int auth = openconnect_obtain_cookie(session.vpn);
        if (session.mode == HelperModeDiscover) { openconnect_vpninfo_free(session.vpn); session.vpn = NULL; return 0; }
        if (auth) {
            if (session.passwordSubmitted && !session.timedOut) session.authenticationRejected = YES;
            NSString *message = session.timedOut ? @"Authentication timed out" : (session.authenticationRejected ? @"The gateway rejected the credentials or one-time code; automatic retry is disabled" : @"Authentication could not be completed");
            [session writeState:session.authenticationRejected ? @"authenticationFailed" : @"failed" message:message groups:@[]];
            openconnect_vpninfo_free(session.vpn); session.vpn = NULL; return 73;
        }
        if (openconnect_make_cstp_connection(session.vpn)) { [session writeState:@"failed" message:@"Could not establish the encrypted VPN channel" groups:@[]]; return 74; }
        session.networkInfo = [session networkInfoFromVPN];
        if (openconnect_setup_tun_device(session.vpn, [request[@"vpncScript"] UTF8String], NULL)) { [session writeState:@"failed" message:@"Could not create the macOS VPN interface" groups:@[]]; return 75; }
        openconnect_setup_dtls(session.vpn, 60);
        [session writeState:@"connected" message:@"VPN connected" groups:@[]];
        openconnect_mainloop(session.vpn, RECONNECT_INTERVAL_MIN, RECONNECT_INTERVAL_MIN);
        [session writeState:@"disconnected" message:@"VPN disconnected" groups:@[]];
        openconnect_vpninfo_free(session.vpn);
        session.vpn = NULL;
        return 0;
    }
}

// Bounded route inspection. Arguments are passed directly, never through a shell.
static BOOL validCorporateIPv4Route(NSString *route) {
    NSArray *parts = [route componentsSeparatedByString:@"/"];
    if (parts.count != 2) return NO;
    struct in_addr address;
    if (inet_pton(AF_INET, [parts[0] UTF8String], &address) != 1) return NO;
    NSScanner *scanner = [NSScanner scannerWithString:parts[1]];
    int prefix = 0;
    return [scanner scanInt:&prefix] && scanner.isAtEnd && prefix > 0 && prefix <= 32;
}

static NSString *runRouteCommand(NSArray<NSString *> *arguments) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/sbin/route"];
    task.arguments = arguments;
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    if (![task launchAndReturnError:nil]) return @"";
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1];
    while (task.running && deadline.timeIntervalSinceNow > 0) usleep(10000);
    if (task.running) { kill(task.processIdentifier, SIGKILL); [task waitUntilExit]; return @""; }
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
}

static NSString *routeInterface(NSString *address) {
    NSString *output = runRouteCommand(@[@"-n", @"get", address]);
    for (NSString *line in [output componentsSeparatedByString:@"\n"]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([trimmed hasPrefix:@"interface:"]) return [[trimmed substringFromIndex:10]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    }
    return @"";
}

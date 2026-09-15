// Exercise the real helper's cancellation branches without a VPN or credentials.
#define main openconnect_helper_main
#import "../Helper/OpenConnectHelper.m"
#undef main
#import <sys/wait.h>

int main(void) {
    @autoreleasepool {
        // Reproduce the actual terminating signal with a closed reader, then
        // verify the production signal policy turns it into a handled error.
        for (int protected = 0; protected < 2; protected++) {
            pid_t child = fork();
            assert(child >= 0);
            if (child == 0) {
                signal(SIGPIPE, SIG_DFL);
                if (protected) ignoreBrokenPipe();
                int pipeFD[2];
                assert(pipe(pipeFD) == 0);
                close(pipeFD[0]);
                HelperSession *broken = [HelperSession new];
                broken.commandFD = pipeFD[1];
                BOOL accepted = sendSessionCommand(broken, OC_CMD_CANCEL);
                _exit(!accepted && errno == EPIPE ? 0 : 1);
            }
            int status = 0;
            assert(waitpid(child, &status, 0) == child);
            if (protected) assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
            else assert(WIFSIGNALED(status) && WTERMSIG(status) == SIGPIPE);
        }
        ignoreBrokenPipe();
        puts("SIGPIPE reproduced; protected helper survives EPIPE.");
        NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:NO attributes:nil error:nil];
        NSDictionary *request = @{
            @"mode": @"connect", @"gateway": @"https://invalid.example",
            @"statusPath": [directory stringByAppendingPathComponent:@"status.plist"],
            @"otpPath": [directory stringByAppendingPathComponent:@"otp"],
            @"pidPath": [directory stringByAppendingPathComponent:@"pid"]
        };
        // A stop received after reservation but before session startup must
        // prevent all authentication/network work.
        atomic_store(&cancellationRequested, true);
        assert(runRequest(request) == 0);
        NSDictionary *snapshot = [NSDictionary dictionaryWithContentsOfFile:request[@"statusPath"]];
        assert([snapshot[@"state"] isEqualToString:@"disconnected"]);

        HelperSession *session = [HelperSession new];
        session.statusPath = request[@"statusPath"];
        session.otpPath = request[@"otpPath"];
        session.commandFD = -1;
        atomic_store(&cancellationRequested, false);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            atomic_store(&cancellationRequested, true);
        });
        NSTimeInterval started = NSDate.date.timeIntervalSince1970;
        assert([session waitForOTP] == nil);
        assert(NSDate.date.timeIntervalSince1970 - started < 2);
        assert(!session.timedOut);
        assert(!session.authenticationRejected);
        // Cancellation must be checked before even dereferencing an auth form.
        assert([session processForm:NULL] == OC_FORM_RESULT_CANCELLED);
        [session setConnectionStage:@"checkingOTP"];
        [session setConnectionStage:@"tlsTunnel"];
        [session writeState:@"connecting" message:@"TLS" groups:@[]];
        NSDictionary *diagnostics = [NSDictionary dictionaryWithContentsOfFile:session.statusPath][@"progress"];
        assert([diagnostics[@"stage"] isEqualToString:@"tlsTunnel"]);
        assert([diagnostics[@"events"] count] >= 2);
        NSSet *allowedKeys = [NSSet setWithArray:@[@"stage", @"stageStartedAt", @"events"]];
        assert([[NSSet setWithArray:[diagnostics allKeys]] isEqual:allowedKeys]);
        [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
        puts("Helper cancellation verified: startup, OTP, authentication form.");
    }
    return 0;
}

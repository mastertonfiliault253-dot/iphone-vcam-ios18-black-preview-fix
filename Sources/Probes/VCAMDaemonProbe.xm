#import <Foundation/Foundation.h>
#import <os/log.h>
#include <unistd.h>
#include <stdlib.h>

%ctor {
    @autoreleasepool {
        NSString *content = [NSString stringWithFormat:@"pid=%d name=%@ bundle=%@ exe=%@ tmp=%@\n",
                             getpid(),
                             NSProcessInfo.processInfo.processName ?: @"(nil)",
                             NSBundle.mainBundle.bundleIdentifier ?: @"(nil)",
                             NSProcessInfo.processInfo.arguments.firstObject ?: @"(nil)",
                             NSTemporaryDirectory() ?: @"(nil)"];
        NSArray<NSString *> *paths = @[
            @"/tmp/vcam-daemon-probe.txt",
            @"/var/mobile/Media/VCAM/vcam-daemon-probe.txt",
            @"/var/mobile/Library/Application Support/VCAM/vcam-daemon-probe.txt",
            @"/var/mobile/Library/Preferences/vcam-daemon-probe.txt",
        ];
        if (NSTemporaryDirectory().length > 0) {
            paths = [paths arrayByAddingObject:[NSTemporaryDirectory() stringByAppendingPathComponent:@"vcam-daemon-probe.txt"]];
        }
        for (NSString *path in paths) {
            [content writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
        os_log(OS_LOG_DEFAULT, "VCAMDaemonProbe loaded in pid=%d name=%@", getpid(), NSProcessInfo.processInfo.processName ?: @"(nil)");
        NSString *name = NSProcessInfo.processInfo.processName.lowercaseString ?: @"";
        if ([name isEqualToString:@"mediaserverd"] || [name isEqualToString:@"cfprefsd"]) {
            // Diagnostic probe: only abort the daemon when the explicit flag is
            // present. On real rootless setups the injection works, so an
            // unconditional abort() crash-loops mediaserverd.
            if ([NSFileManager.defaultManager fileExistsAtPath:@"/var/mobile/Media/VCAM/probe-abort.flag"]) {
                sleep(1);
                abort();
            }
        }
    }
}
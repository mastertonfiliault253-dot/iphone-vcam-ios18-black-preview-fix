#import <Foundation/Foundation.h>
#include <unistd.h>

__attribute__((constructor))
static void VCAMDaemonProbeInit(void) {
    @autoreleasepool {
        NSString *content = [NSString stringWithFormat:@"pid=%d name=%@ bundle=%@ exe=%@\n",
                             getpid(),
                             NSProcessInfo.processInfo.processName ?: @"(nil)",
                             NSBundle.mainBundle.bundleIdentifier ?: @"(nil)",
                             NSProcessInfo.processInfo.arguments.firstObject ?: @"(nil)"];
        NSArray<NSString *> *paths = @[
            @"/tmp/vcam-daemon-probe.txt",
            @"/var/mobile/Media/VCAM/vcam-daemon-probe.txt",
            @"/var/mobile/Library/Application Support/VCAM/vcam-daemon-probe.txt",
        ];
        for (NSString *path in paths) {
            [content writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
    }
}
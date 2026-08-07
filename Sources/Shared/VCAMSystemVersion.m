#import "VCAMSystemVersion.h"

BOOL VCAMSystemVersionAtLeast(NSInteger majorVersion, NSInteger minorVersion) {
    NSOperatingSystemVersion version = NSProcessInfo.processInfo.operatingSystemVersion;
    if (version.majorVersion != majorVersion) {
        return version.majorVersion > majorVersion;
    }
    return version.minorVersion >= minorVersion;
}

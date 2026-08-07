#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runtime OS-version check that avoids compiler-generated
/// `___isOSVersionAtLeast` calls, which the Linux Theos toolchain cannot link.
BOOL VCAMSystemVersionAtLeast(NSInteger majorVersion, NSInteger minorVersion);

NS_ASSUME_NONNULL_END

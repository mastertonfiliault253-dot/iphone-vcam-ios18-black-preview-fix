#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Deep module used by vcamd. Callers choose only output size; source
/// selection, decoding, reconnect and rendering remain implementation details.
@interface VCAMFrameProducer : NSObject

- (void)reload;
- (BOOL)isEnabled;
- (NSInteger)preferredFramesPerSecond;
- (BOOL)usesNativeSurfaceTransport;
- (nullable CVPixelBufferRef)copyNativePixelBufferForSharedCanvas CF_RETURNS_RETAINED;
- (nullable CMSampleBufferRef)copyFrameForSize:(CGSize)size CF_RETURNS_RETAINED;

@end

NS_ASSUME_NONNULL_END

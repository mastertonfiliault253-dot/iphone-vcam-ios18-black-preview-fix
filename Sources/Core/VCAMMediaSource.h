#import <AVFoundation/AVFoundation.h>
#import "VCAMConfiguration.h"

NS_ASSUME_NONNULL_BEGIN

/// A media source owns decoding and timing. Returned sample buffers are retained;
/// the caller must release them. Returning NULL means "use the real camera/mic".
@protocol VCAMMediaSource <NSObject>

- (BOOL)start:(NSError **)error;
- (void)stop;
- (nullable CMSampleBufferRef)copyVideoSampleForTemplate:(CMSampleBufferRef)templateBuffer
    CF_RETURNS_RETAINED;
- (nullable CMSampleBufferRef)copyAudioSampleForTemplate:(CMSampleBufferRef)templateBuffer
    CF_RETURNS_RETAINED;

@end

NS_ASSUME_NONNULL_END

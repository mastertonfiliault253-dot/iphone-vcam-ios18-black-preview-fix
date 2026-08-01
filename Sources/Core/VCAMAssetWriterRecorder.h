#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Records the already-normalized replacement video samples used by OBS mode.
/// The caller starts once, appends samples, then atomically finishes to a file.
@interface VCAMAssetWriterRecorder : NSObject
- (void)start;
- (void)appendVideoSample:(CMSampleBufferRef)sample;
- (nullable NSURL *)finishAndWait:(NSTimeInterval)timeout;
@end

NS_ASSUME_NONNULL_END

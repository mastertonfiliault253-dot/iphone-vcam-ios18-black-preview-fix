#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The only interface used by capture hooks. Source selection, decoding,
/// reconnection and fail-open behavior are implementation details.
@interface VCAMFramePipeline : NSObject

+ (instancetype)sharedPipeline;
- (void)reloadConfiguration;
- (BOOL)isEnabled;
- (NSInteger)preferredFramesPerSecond;
- (nullable AVPlayer *)localPreviewPlayer;
- (nullable CMSampleBufferRef)copyReplacementVideoForSample:(CMSampleBufferRef)sample
    CF_RETURNS_RETAINED;
- (nullable CMSampleBufferRef)copyReplacementAudioForSample:(CMSampleBufferRef)sample
    CF_RETURNS_RETAINED;
- (nullable CMSampleBufferRef)copyPreviewVideoForSize:(CGSize)size
    CF_RETURNS_RETAINED;
- (nullable AVDepthData *)replacementDepthData;
- (NSDictionary<NSString *, id> *)replacementPhotoMetadataForOriginal:(NSDictionary<NSString *, id> *)original;
- (nullable NSData *)pairedLivePhotoStillData;
- (nullable NSString *)pairedLivePhotoMoviePath;
- (nullable NSString *)localRecordingReplacementPath;
- (void)startReplacementRecording;
- (nullable NSURL *)finishReplacementRecording;

@end

NS_ASSUME_NONNULL_END

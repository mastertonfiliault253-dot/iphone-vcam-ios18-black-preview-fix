#import <Foundation/Foundation.h>
#import "../Core/VCAMMediaSource.h"
#import "../Core/VCAMFrameRenderer.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSDictionary<NSString *, id> *VCAMRTSPPerformanceSnapshot(void);

/// Direct RTSP/HLS receiver. FFmpeg owns network demuxing and VideoToolbox returns
/// native CVPixelBuffer frames; only the newest frame is retained for low latency.
@interface VCAMRTSPStreamSource : NSObject <VCAMMediaSource>
- (instancetype)initWithConfiguration:(VCAMConfiguration *)configuration
                              renderer:(VCAMFrameRenderer *)renderer;
- (nullable CMSampleBufferRef)copyDirectPreviewSample CF_RETURNS_RETAINED;
- (nullable CVPixelBufferRef)copyNativePixelBufferForSurface CF_RETURNS_RETAINED;
@end

NS_ASSUME_NONNULL_END

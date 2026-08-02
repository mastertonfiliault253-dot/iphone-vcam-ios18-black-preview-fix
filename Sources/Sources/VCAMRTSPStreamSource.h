#import <Foundation/Foundation.h>
#import "../Core/VCAMMediaSource.h"
#import "../Core/VCAMFrameRenderer.h"

NS_ASSUME_NONNULL_BEGIN

/// Direct RTSP receiver. FFmpeg owns RTSP/RTP demuxing and VideoToolbox returns
/// native CVPixelBuffer frames; only the newest frame is retained for low latency.
@interface VCAMRTSPStreamSource : NSObject <VCAMMediaSource>
- (instancetype)initWithConfiguration:(VCAMConfiguration *)configuration
                              renderer:(VCAMFrameRenderer *)renderer;
@end

NS_ASSUME_NONNULL_END

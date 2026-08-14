#import <Foundation/Foundation.h>
#import "../Core/VCAMMediaSource.h"
#import "../Core/VCAMFrameRenderer.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSDictionary<NSString *, id> *VCAMRTSPPerformanceSnapshot(void);

/// FFmpeg software receiver for RTSP and the explicit legacy HLS rollback.
/// Network demuxing, decode, and latest-frame retention stay inside vcamd.
@interface VCAMRTSPStreamSource : NSObject <VCAMMediaSource>
- (instancetype)initWithConfiguration:(VCAMConfiguration *)configuration
                              renderer:(VCAMFrameRenderer *)renderer;
- (nullable CMSampleBufferRef)copyDirectPreviewSample CF_RETURNS_RETAINED;
@end

NS_ASSUME_NONNULL_END

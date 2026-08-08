#import "../Core/VCAMMediaSource.h"
#import "../Core/VCAMFrameRenderer.h"

NS_ASSUME_NONNULL_BEGIN

// HTTP/HLS stream source backed by AVPlayer + AVPlayerItemVideoOutput.
// AVFoundation uses the system hardware decoder for H.264/HEVC, so this is
// the recommended hardware-decode path for network video on iOS 16-16.5
// (VideoToolbox in a bare daemon can be unavailable; AVPlayer is not).
@interface VCAMHLSStreamSource : NSObject <VCAMMediaSource>

- (instancetype)initWithConfiguration:(VCAMConfiguration *)configuration
                             renderer:(VCAMFrameRenderer *)renderer;

@end

NS_ASSUME_NONNULL_END

#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^VCAMSpringBoardRTSPFrameHandler)(CVPixelBufferRef buffer,
                                                CMTime presentationTime,
                                                uint32_t width,
                                                uint32_t height);

/// SpringBoard-process RTSP reader + direct VideoToolbox decoder.
///
/// vcamd cannot run VTDecompressionSession successfully in its environment;
/// SpringBoard (a regular app process) can, and it already owns the shared
/// frame transport (IOSurface pool + mmap) that mediaserverd consumes. This
/// class demuxes the RTSP stream on a background queue, decodes it with
/// VCAMHardwareVideoDecoder (direct VT), and hands each frame to the media
/// bridge through a main-queue-safe handler.
@interface VCAMSpringBoardRTSPSource : NSObject

- (instancetype)initWithURL:(NSURL *)url;

/// Starts the reader/decoder loop. Frames are delivered on the main queue.
- (void)startWithFrameHandler:(VCAMSpringBoardRTSPFrameHandler)handler;
- (void)stop;

@property(nonatomic, readonly) BOOL running;
@property(nonatomic, readonly) NSUInteger decodedFrames;
@property(nonatomic, readonly) NSUInteger transportFailures;
@property(nonatomic, readonly, nullable) NSString *lastError;

@end

NS_ASSUME_NONNULL_END

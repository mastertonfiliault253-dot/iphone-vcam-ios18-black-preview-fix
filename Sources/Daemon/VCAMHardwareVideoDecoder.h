#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct AVCodecParameters AVCodecParameters;

/// Decodes H.264/HEVC Annex-B-free (AVCC/HVCC) packets with a direct
/// VTDecompressionSession instead of FFmpeg's videotoolbox hwaccel wrapper.
/// vcamd-only; never linked into injected clients.
@interface VCAMHardwareVideoDecoder : NSObject

- (nullable instancetype)initWithCodecParameters:(AVCodecParameters *)parameters;
- (BOOL)start:(NSError **)error;
- (BOOL)decodePacket:(const uint8_t *)bytes
               length:(size_t)length
       presentationTime:(CMTime)presentationTime
             decodeTime:(CMTime)decodeTime
               duration:(CMTime)duration
             isKeyFrame:(BOOL)isKeyFrame;
/// Pops the oldest decoded frame (retained). Returns NULL when none is ready.
- (nullable CVPixelBufferRef)copyNextOutputFrame:(CMTime *)presentationTimeOut;
- (void)flush;
- (void)stop;

@property(nonatomic, readonly) BOOL active;

@end

NS_ASSUME_NONNULL_END

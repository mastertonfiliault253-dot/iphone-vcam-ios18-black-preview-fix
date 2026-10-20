#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, VCAMVideoCodecType) {
    VCAMVideoCodecTypeH264,
    VCAMVideoCodecTypeHEVC,
};

/// Decodes H.264/HEVC Annex-B-free (AVCC/HVCC) packets with a direct
/// VTDecompressionSession instead of FFmpeg's videotoolbox hwaccel wrapper.
/// Linked into vcamd (legacy rollback) and the injected SpringBoard client
/// (production RTSP path: VT hardware decode runs in an app process; the
/// E9 case shows the decode service is unreachable from the daemon
/// context). The initializer is deliberately FFmpeg-free so the class can
/// link into targets that never touch FFmpeg; callers unpack their own
/// codec parameters.
@interface VCAMHardwareVideoDecoder : NSObject

- (nullable instancetype)initWithCodecType:(VCAMVideoCodecType)type
                            parameterData:(const uint8_t *)parameterData
                                   length:(size_t)length
                                    width:(int)width
                                   height:(int)height;
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

/// Cumulative output-callback failures (recoverable reference-missing errors
/// included). A failed callback consumes its input access unit but never
/// yields a published frame, so the remote-decode owner compares this counter
/// between packets and reclaims the flow-control credit each AU owes; without
/// that the vcamd window gate parks at max outstanding while the RTSP
/// publisher is still running (2026-10-21 field deadlock).
@property(nonatomic, readonly) NSUInteger callbackFailureCount;

@end

NS_ASSUME_NONNULL_END

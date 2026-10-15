#import "VCAMSpringBoardRemoteDecoder.h"

#import "../Core/VCAMConfiguration.h"
#import "../Daemon/VCAMHardwareVideoDecoder.h"
#import "../Shared/VCAMSurfaceBroker.h"

// Consecutive failed submissions end the session so a stuck decoder cannot
// spin the RTSP pipeline; vcamd then falls back to its software decoder.
enum { VCAMRemoteDecodeMaxFailures = 8 };

@interface VCAMSpringBoardRemoteDecoder () {
    BOOL _started;
    // All fields below are touched only on the broker's serial connection
    // queue, so no additional lock is needed.
    VCAMHardwareVideoDecoder *decoder;
    uint64_t activeEpoch;
    NSUInteger failureCount;
    NSUInteger loggedFrames;
}
@end

@implementation VCAMSpringBoardRemoteDecoder

+ (instancetype)sharedDecoder {
    static VCAMSpringBoardRemoteDecoder *shared;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[VCAMSpringBoardRemoteDecoder alloc] init];
    });
    return shared;
}

- (void)stopActiveSession:(const char *)reason {
    if (decoder != nil) {
        [decoder stop];
        decoder = nil;
    }
    if (activeEpoch != 0) {
        [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
            @"springboard remote decoder stopped epoch=%llu reason=%s",
            (unsigned long long)activeEpoch, reason ?: "close"]];
        activeEpoch = 0;
    }
    failureCount = 0;
}

- (void)start {
    if (_started ||
        ![NSProcessInfo.processInfo.processName isEqualToString:@"SpringBoard"]) {
        return;
    }
    _started = YES;
    __weak typeof(self) weakSelf = self;
    VCAMSurfaceBrokerStartRemoteDecoderClient(
        ^(uint64_t epoch, const char *codec, int width, int height,
          const void *parameterData, size_t length) {
            VCAMSpringBoardRemoteDecoder *target = weakSelf;
            if (target == nil || epoch == 0) return;
            [target openEpoch:epoch codec:codec width:width height:height
                parameterData:parameterData length:length];
        },
        ^(uint64_t epoch, const void *bytes, size_t length,
          double presentationSeconds, BOOL isKeyFrame) {
            VCAMSpringBoardRemoteDecoder *target = weakSelf;
            if (target == nil) return;
            [target decodeEpoch:epoch bytes:bytes length:length
             presentationSeconds:presentationSeconds isKeyFrame:isKeyFrame];
        },
        ^(uint64_t epoch) {
            VCAMSpringBoardRemoteDecoder *target = weakSelf;
            if (target == nil) return;
            if (target->activeEpoch == epoch) {
                [target stopActiveSession:"close"];
            }
        });
}

- (void)openEpoch:(uint64_t)epoch
            codec:(const char *)codec
            width:(int)width
           height:(int)height
    parameterData:(const void *)parameterData
           length:(size_t)length {
    [self stopActiveSession:"replace"];
    VCAMVideoCodecType type = strcmp(codec, "hevc") == 0
        ? VCAMVideoCodecTypeHEVC : VCAMVideoCodecTypeH264;
    VCAMHardwareVideoDecoder *created = [[VCAMHardwareVideoDecoder alloc]
        initWithCodecType:type
           parameterData:(const uint8_t *)parameterData
                  length:length
                   width:width
                  height:height];
    NSError *error = nil;
    if (created == nil || ![created start:&error]) {
        [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
            @"springboard remote decoder open failed epoch=%llu code=%d error=%@",
            (unsigned long long)epoch, (int)error.code,
            error.localizedDescription ?: @"(init failed)"]];
        VCAMSurfaceBrokerSendRemoteDecoderOpenAck(epoch, NO);
        return;
    }
    decoder = created;
    activeEpoch = epoch;
    failureCount = 0;
    loggedFrames = 0;
    [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
        @"springboard remote decoder open accepted epoch=%llu codec=%s %dx%d",
        (unsigned long long)epoch, codec, width, height]];
    VCAMSurfaceBrokerSendRemoteDecoderOpenAck(epoch, YES);
}

- (void)decodeEpoch:(uint64_t)epoch
              bytes:(const void *)bytes
             length:(size_t)length
 presentationSeconds:(double)presentationSeconds
         isKeyFrame:(BOOL)isKeyFrame {
    if (decoder == nil || epoch != activeEpoch) return;
    CMTime presentationTime = presentationSeconds > 0
        ? CMTimeMakeWithSeconds(presentationSeconds, 600) : kCMTimeZero;
    if (![decoder decodePacket:(const uint8_t *)bytes
                        length:length
              presentationTime:presentationTime
                    decodeTime:kCMTimeInvalid
                      duration:kCMTimeInvalid
                    isKeyFrame:isKeyFrame]) {
        failureCount += 1;
    }
    CVPixelBufferRef frame = NULL;
    CMTime outputTime = kCMTimeInvalid;
    while ((frame = [decoder copyNextOutputFrame:&outputTime]) != NULL) {
        IOSurfaceRef surface = CVPixelBufferGetIOSurface(frame);
        if (surface != NULL && loggedFrames < 4) {
            loggedFrames += 1;
            [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
                @"springboard remote decoder frame epoch=%llu %zux%zu",
                (unsigned long long)epoch,
                (size_t)CVPixelBufferGetWidth(frame),
                (size_t)CVPixelBufferGetHeight(frame)]];
        }
        if (surface != NULL) {
            VCAMSurfaceBrokerSendRemoteDecoderFrame(activeEpoch, surface);
        }
        CVPixelBufferRelease(frame);
    }
    if (failureCount >= VCAMRemoteDecodeMaxFailures) {
        VCAMSurfaceBrokerSendRemoteDecoderError(
            activeEpoch, "submission failures");
        [self stopActiveSession:"failures"];
    }
}

@end

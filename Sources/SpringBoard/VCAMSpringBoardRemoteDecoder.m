#import "VCAMSpringBoardRemoteDecoder.h"

#import "../Core/VCAMConfiguration.h"
#import "../Daemon/VCAMHardwareVideoDecoder.h"
#import "../Shared/VCAMSurfaceBroker.h"

#import <IOSurface/IOSurfaceRef.h>
#include <mach/mach.h>

// Same conditional-headers pattern as the shared broker sources: the Linux
// iPhoneOS 16.5 SDK has no <xpc/xpc.h> for tweak targets, so declare only
// what this self-test needs.
#if __has_include(<xpc/xpc.h>)
#import <xpc/xpc.h>
// Same release policy as the shared broker sources: with the system XPC
// headers the object is ARC-managed; only the header-less toolchain needs
// the explicit C call.
#if defined(OS_OBJECT_USE_OBJC) && OS_OBJECT_USE_OBJC
#define VCAMSelfTestXPCRelease(object) ((void)(object))
#else
#define VCAMSelfTestXPCRelease(object) xpc_release(object)
#endif
#else
typedef void *xpc_object_t;
typedef const void *xpc_type_t;
extern xpc_type_t xpc_get_type(xpc_object_t object);
void xpc_release(xpc_object_t object);
#define VCAMSelfTestXPCRelease(object) xpc_release(object)
#endif

extern xpc_object_t IOSurfaceCreateXPCObject(IOSurfaceRef surface);
extern IOSurfaceRef _Nullable IOSurfaceLookupFromXPCObject(xpc_object_t object)
    CF_RETURNS_RETAINED;
// Present in libSystem but undeclared in this SDK's XPC headers.
extern const char *xpc_type_get_name(xpc_type_t type);
extern mach_port_t xpc_mach_send_get_right(xpc_object_t object);

// Mirror of the vcamd-side probe: round-trip a private surface through the
// exact IOSurface<->XPC pair used for remote frames. The vcamd import of
// SB-created decoder surfaces returns NULL, so this establishes the pair is
// healthy in the SpringBoard context and isolates the failure to the
// cross-process import.
static void VCAMSpringBoardSurfaceSelfTest(void) {
    static BOOL tested;
    if (tested) return;
    tested = YES;
    NSDictionary *properties = @{
        (id)kIOSurfaceWidth: @64,
        (id)kIOSurfaceHeight: @64,
        (id)kIOSurfaceBytesPerElement: @4,
    };
    IOSurfaceRef probe =
        IOSurfaceCreate((__bridge CFDictionaryRef)properties);
    xpc_object_t encoded =
        probe != NULL ? IOSurfaceCreateXPCObject(probe) : NULL;
    mach_port_t right = encoded != NULL ? xpc_mach_send_get_right(encoded)
                                        : MACH_PORT_NULL;
    IOSurfaceRef decoded = encoded != NULL
        ? IOSurfaceLookupFromXPCObject(encoded) : NULL;
    const char *typeC = encoded != NULL
        ? xpc_type_get_name(xpc_get_type(encoded)) : "(none)";
    [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
        @"springboard surface selftest created=%d xpcType=%s machRight=%d "
        @"imported=%d",
        probe != NULL, typeC, right != MACH_PORT_NULL, decoded != NULL]];
    if (decoded != NULL) CFRelease(decoded);
    if (encoded != NULL) VCAMSelfTestXPCRelease(encoded);
    if (probe != NULL) CFRelease(probe);
}

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
    VCAMSpringBoardSurfaceSelfTest();
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
        OSType format = CVPixelBufferGetPixelFormatType(frame);
        size_t planes = CVPixelBufferGetPlaneCount(frame);
        if (format != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
            format != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
            VCAMSurfaceBrokerSendRemoteDecoderError(
                activeEpoch, "unsupported pixel format");
            CVPixelBufferRelease(frame);
            [self stopActiveSession:"pixel format"];
            return;
        }
        if (planes != 2) {
            VCAMSurfaceBrokerSendRemoteDecoderError(
                activeEpoch, "unsupported plane count");
            CVPixelBufferRelease(frame);
            [self stopActiveSession:"pixel format"];
            return;
        }
        CVPixelBufferLockBaseAddress(frame, kCVPixelBufferLock_ReadOnly);
        const void *plane0 = CVPixelBufferGetBaseAddressOfPlane(frame, 0);
        const void *plane1 = CVPixelBufferGetBaseAddressOfPlane(frame, 1);
        uint32_t rowBytes0 =
            (uint32_t)CVPixelBufferGetBytesPerRowOfPlane(frame, 0);
        uint32_t rowBytes1 =
            (uint32_t)CVPixelBufferGetBytesPerRowOfPlane(frame, 1);
        uint32_t height = (uint32_t)CVPixelBufferGetHeight(frame);
        if (plane0 != NULL && plane1 != NULL && loggedFrames < 4) {
            loggedFrames += 1;
            [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
                @"springboard remote decoder frame epoch=%llu rows=%u,%u h=%u",
                (unsigned long long)epoch, rowBytes0, rowBytes1, height]];
        }
        VCAMSurfaceBrokerSendRemoteDecoderFrameData(activeEpoch, plane0,
                                                    rowBytes0, plane1,
                                                    rowBytes1, height);
        CVPixelBufferUnlockBaseAddress(frame, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferRelease(frame);
    }
    if (failureCount >= VCAMRemoteDecodeMaxFailures) {
        VCAMSurfaceBrokerSendRemoteDecoderError(
            activeEpoch, "submission failures");
        [self stopActiveSession:"failures"];
    }
}

@end

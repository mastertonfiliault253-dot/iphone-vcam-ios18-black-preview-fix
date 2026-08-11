#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>
#import <errno.h>
#import <stdio.h>
#import <string.h>
#import <unistd.h>

#import "VCAMFrameProducer.h"
#import "../Core/VCAMConfiguration.h"
#import "../Shared/VCAMSharedFrame.h"
#import "../Shared/VCAMSurfaceBroker.h"

static VCAMFrameProducer *VCAMProducer;
static VCAMSharedFrameWriter *VCAMWriter;
static VCAMSharedSurfaceWriter *VCAMSurfaceWriter;
static OSType VCAMSurfacePixelFormat;
static uint32_t VCAMSurfaceWidth;
static uint32_t VCAMSurfaceHeight;
static uint32_t VCAMSurfaceSlotCount;
static BOOL VCAMStaticSurfacePublished;
static dispatch_source_t VCAMTimer;
static BOOL VCAMLoggedNativeSurfaceReady;
static BOOL VCAMLoggedNativeTransportReceived;
static BOOL VCAMLoggedNativeSurfaceCreateFailed;
static BOOL VCAMLoggedNativeSurfacePublished;
static BOOL VCAMLoggedNativeSurfaceConsumed;
static BOOL VCAMLoggedLegacyFallback;

static void VCAMDestroySurfaceWriter(void) {
    if (VCAMSurfaceWriter != NULL) {
        VCAMSharedSurfaceWriterDestroy(VCAMSurfaceWriter);
        VCAMSurfaceWriter = NULL;
    }
    VCAMSurfacePixelFormat = 0;
    VCAMSurfaceWidth = 0;
    VCAMSurfaceHeight = 0;
    VCAMSurfaceSlotCount = 0;
    VCAMStaticSurfacePublished = NO;
}

enum {
    MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES = 7,
    MEMORYSTATUS_CMD_GET_MEMLIMIT_PROPERTIES = 8,
    VCAMWorkerMemoryLimitMB = 256,
};

typedef struct {
    int32_t memlimit_active;
    uint32_t memlimit_active_attr;
    int32_t memlimit_inactive;
    uint32_t memlimit_inactive_attr;
} VCAMMemorystatusMemlimitProperties;

extern int memorystatus_control(uint32_t command, int32_t pid, uint32_t flags,
                                void *buffer, size_t bufferSize);

static BOOL VCAMRunMemorystatusStep(uint32_t command, pid_t pid, uint32_t flags,
                                   void *buffer, size_t bufferSize,
                                   const char *step) {
    errno = 0;
    int result = memorystatus_control(command, pid, flags, buffer, bufferSize);
    int savedErrno = errno;
    fprintf(stderr, "vcamd jetsam step=%s result=%d errno=%d (%s)\n",
            step, result, savedErrno, savedErrno == 0 ? "none" : strerror(savedErrno));
    return result == 0;
}

static BOOL VCAMRaiseJetsamMemoryLimit(void) {
    pid_t pid = getpid();
    VCAMMemorystatusMemlimitProperties properties = {0};
    properties.memlimit_active = VCAMWorkerMemoryLimitMB;
    properties.memlimit_inactive = VCAMWorkerMemoryLimitMB;
    BOOL success = VCAMRunMemorystatusStep(MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES,
                                           pid, 0, &properties, sizeof(properties),
                                           "bounded-memlimit");

    VCAMMemorystatusMemlimitProperties effective = {0};
    int queryResult = memorystatus_control(MEMORYSTATUS_CMD_GET_MEMLIMIT_PROPERTIES,
                                           pid, 0, &effective, sizeof(effective));
    if (queryResult == 0) {
        fprintf(stderr,
                "vcamd jetsam policy ready=%d effective active=%d attr=%u inactive=%d attr=%u MB\n",
                success, effective.memlimit_active, effective.memlimit_active_attr,
                effective.memlimit_inactive, effective.memlimit_inactive_attr);
    } else {
        fprintf(stderr, "vcamd jetsam policy ready=0 query failed: %s\n", strerror(errno));
        success = NO;
    }
    fflush(stderr);
    return success;
}

static BOOL VCAMCopyPixelBufferPlanes(CVPixelBufferRef source,
                                      CVPixelBufferRef destination) {
    if (source == NULL || destination == NULL ||
        CVPixelBufferGetPixelFormatType(source) !=
            CVPixelBufferGetPixelFormatType(destination) ||
        CVPixelBufferGetWidth(source) != CVPixelBufferGetWidth(destination) ||
        CVPixelBufferGetHeight(source) != CVPixelBufferGetHeight(destination) ||
        CVPixelBufferIsPlanar(source) != CVPixelBufferIsPlanar(destination)) return NO;
    if (CVPixelBufferLockBaseAddress(source, kCVPixelBufferLock_ReadOnly) !=
        kCVReturnSuccess) return NO;
    if (CVPixelBufferLockBaseAddress(destination, 0) != kCVReturnSuccess) {
        CVPixelBufferUnlockBaseAddress(source, kCVPixelBufferLock_ReadOnly);
        return NO;
    }
    size_t planeCount = CVPixelBufferIsPlanar(source)
        ? CVPixelBufferGetPlaneCount(source) : 1;
    BOOL copied = planeCount == (CVPixelBufferIsPlanar(destination)
        ? CVPixelBufferGetPlaneCount(destination) : 1);
    for (size_t plane = 0; copied && plane < planeCount; plane++) {
        uint8_t *sourceBase = planeCount == 1
            ? CVPixelBufferGetBaseAddress(source)
            : CVPixelBufferGetBaseAddressOfPlane(source, plane);
        uint8_t *destinationBase = planeCount == 1
            ? CVPixelBufferGetBaseAddress(destination)
            : CVPixelBufferGetBaseAddressOfPlane(destination, plane);
        size_t sourceStride = planeCount == 1
            ? CVPixelBufferGetBytesPerRow(source)
            : CVPixelBufferGetBytesPerRowOfPlane(source, plane);
        size_t destinationStride = planeCount == 1
            ? CVPixelBufferGetBytesPerRow(destination)
            : CVPixelBufferGetBytesPerRowOfPlane(destination, plane);
        size_t height = planeCount == 1
            ? CVPixelBufferGetHeight(source)
            : CVPixelBufferGetHeightOfPlane(source, plane);
        size_t rowBytes = MIN(sourceStride, destinationStride);
        copied = sourceBase != NULL && destinationBase != NULL && rowBytes > 0;
        for (size_t row = 0; copied && row < height; row++) {
            memcpy(destinationBase + row * destinationStride,
                   sourceBase + row * sourceStride, rowBytes);
        }
    }
    CVPixelBufferUnlockBaseAddress(destination, 0);
    CVPixelBufferUnlockBaseAddress(source, kCVPixelBufferLock_ReadOnly);
    if (copied) CVBufferPropagateAttachments(source, destination);
    return copied;
}

static void VCAMPublishTick(void) {
    @autoreleasepool {
        if (![VCAMProducer isEnabled]) {
            VCAMDestroySurfaceWriter();
            return;
        }
        BOOL nativeTransport = [VCAMProducer usesNativeSurfaceTransport];
        if (VCAMSurfaceWriter != NULL &&
            !VCAMSharedSurfaceWriterIsCurrent(VCAMSurfaceWriter)) {
            VCAMDestroySurfaceWriter();
        }
        if (!nativeTransport && VCAMSurfaceWriter != NULL) {
            VCAMDestroySurfaceWriter();
        }
        uint32_t nativeSlotCount = nativeTransport
            ? [VCAMProducer nativeSurfaceSlotCount] : VCAMSharedFrameSlotCount;
        BOOL refreshedStaticSurface = nativeSlotCount == 1 &&
            VCAMStaticSurfacePublished &&
            VCAMSharedSurfaceWriterRefreshLatest(VCAMSurfaceWriter);
        BOOL nativeConsumed = refreshedStaticSurface &&
            VCAMSharedSurfaceWriterHasConsumer(VCAMSurfaceWriter);
        if (nativeConsumed) return;
        CVPixelBufferRef native = nativeTransport && !refreshedStaticSurface
            ? [VCAMProducer copyNativePixelBufferForSurface] : NULL;
        if (native != NULL) {
            OSType pixelFormat = CVPixelBufferGetPixelFormatType(native);
            uint32_t width = (uint32_t)CVPixelBufferGetWidth(native);
            uint32_t height = (uint32_t)CVPixelBufferGetHeight(native);
            uint32_t slotCount = nativeSlotCount;
            if (!VCAMLoggedNativeTransportReceived) {
                [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
                    @"vcamd native transport received size=%ux%u pixel=%08x slots=%u",
                    width, height, pixelFormat, slotCount]];
                VCAMLoggedNativeTransportReceived = YES;
            }
            if (VCAMSurfaceWriter == NULL || VCAMSurfacePixelFormat != pixelFormat ||
                VCAMSurfaceWidth != width || VCAMSurfaceHeight != height ||
                VCAMSurfaceSlotCount != slotCount) {
                VCAMDestroySurfaceWriter();
                VCAMSurfaceWriter = VCAMSharedSurfaceWriterCreateConfigured(
                    width, height, pixelFormat, slotCount);
                VCAMSurfacePixelFormat = VCAMSurfaceWriter == NULL ? 0 : pixelFormat;
                VCAMSurfaceWidth = VCAMSurfaceWriter == NULL ? 0 : width;
                VCAMSurfaceHeight = VCAMSurfaceWriter == NULL ? 0 : height;
                VCAMSurfaceSlotCount = VCAMSurfaceWriter == NULL ? 0 : slotCount;
                if (VCAMSurfaceWriter == NULL &&
                    !VCAMLoggedNativeSurfaceCreateFailed) {
                    [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
                        @"vcamd native IOSurface create failed size=%ux%u pixel=%08x slots=%u",
                        width, height, pixelFormat, slotCount]];
                    VCAMLoggedNativeSurfaceCreateFailed = YES;
                }
                if (VCAMSurfaceWriter != NULL && !VCAMLoggedNativeSurfaceReady) {
                    [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
                        @"vcamd native IOSurface ready size=%ux%u pixel=%08x slots=%u",
                        width, height, pixelFormat, slotCount]];
                    VCAMLoggedNativeSurfaceReady = YES;
                }
            }
            BOOL immutableFrame = slotCount == 1;
            CVPixelBufferRef destination = NULL;
            BOOL published = immutableFrame && VCAMStaticSurfacePublished
                ? VCAMSharedSurfaceWriterRefreshLatest(VCAMSurfaceWriter) : NO;
            if (!published) {
                destination = VCAMSurfaceWriter == NULL ? NULL
                    : VCAMSharedSurfaceWriterCopyNextPixelBuffer(VCAMSurfaceWriter);
                published = destination != NULL &&
                    VCAMCopyPixelBufferPlanes(native, destination) &&
                    VCAMSharedSurfaceWriterPublish(VCAMSurfaceWriter, destination);
                if (published && immutableFrame) VCAMStaticSurfacePublished = YES;
            }
            if (published && !VCAMLoggedNativeSurfacePublished) {
                [VCAMConfiguration appendProcessLog:@"vcamd native IOSurface published"];
                VCAMLoggedNativeSurfacePublished = YES;
            }
            if (destination != NULL) CVPixelBufferRelease(destination);
            nativeConsumed = published &&
                VCAMSharedSurfaceWriterHasConsumer(VCAMSurfaceWriter);
            if (nativeConsumed && !VCAMLoggedNativeSurfaceConsumed) {
                [VCAMConfiguration appendProcessLog:@"vcamd native IOSurface consumer accepted"];
                VCAMLoggedNativeSurfaceConsumed = YES;
            }
            CVPixelBufferRelease(native);
        }
        if (nativeConsumed) return;
        if (nativeTransport && !VCAMLoggedLegacyFallback) {
            [VCAMConfiguration appendProcessLog:@"vcamd native IOSurface awaiting consumer; BGRA fallback active"];
            VCAMLoggedLegacyFallback = YES;
        }
        CMSampleBufferRef sample = [VCAMProducer copyFrameForSize:
            CGSizeMake(VCAMSharedFrameWidth, VCAMSharedFrameHeight)];
        CVPixelBufferRef pixelBuffer = sample == NULL ? NULL : CMSampleBufferGetImageBuffer(sample);
        if (pixelBuffer != NULL) {
            uint64_t surfaceGeneration =
                VCAMSharedSurfaceWriterGeneration(VCAMSurfaceWriter);
            if (surfaceGeneration != 0) {
                VCAMSharedFrameWriterPublishForSurfaceGeneration(
                    VCAMWriter, pixelBuffer, surfaceGeneration);
            } else {
                VCAMSharedFrameWriterPublish(VCAMWriter, pixelBuffer);
            }
        }
        if (sample != NULL) CFRelease(sample);
    }
}

static void VCAMScheduleTimer(void) {
    NSInteger fps = [VCAMProducer preferredFramesPerSecond];
    uint64_t interval = NSEC_PER_SEC / (uint64_t)MAX(1, MIN(60, fps));
    if (VCAMTimer == nil) {
        VCAMTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                           dispatch_get_main_queue());
        dispatch_source_set_event_handler(VCAMTimer, ^{ VCAMPublishTick(); });
        dispatch_resume(VCAMTimer);
    }
    dispatch_source_set_timer(VCAMTimer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              interval, interval / 10);
}

static void VCAMConfigurationChanged(CFNotificationCenterRef center, void *observer,
                                     CFStringRef name, const void *object,
                                     CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    dispatch_async(dispatch_get_main_queue(), ^{
        // A same-dimension media replacement still needs a fresh immutable
        // surface; recreating here keeps the one-slot path honest.
        VCAMDestroySurfaceWriter();
        [VCAMProducer reload];
        VCAMScheduleTimer();
    });
}

int main(int argc, char *argv[]) {
    (void)argc; (void)argv;
    VCAMRaiseJetsamMemoryLimit();
    @autoreleasepool {
        VCAMSurfaceBrokerStartServer();
        VCAMWriter = VCAMSharedFrameWriterCreate();
        if (VCAMWriter == NULL) return 2;
        VCAMProducer = [VCAMFrameProducer new];
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL, VCAMConfigurationChanged,
                                        CFSTR("com.codex.vcam/preferences.changed"),
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        VCAMScheduleTimer();
        [VCAMConfiguration appendProcessLog:@"vcamd started"];
        CFRunLoopRun();
        VCAMDestroySurfaceWriter();
        VCAMSharedFrameWriterDestroy(VCAMWriter);
    }
    return 0;
}

#import "VCAMMediaServerRefImageUtils.h"

#import <CoreImage/CoreImage.h>
#import <CoreVideo/CVPixelFormatDescription.h>
#import <Metal/Metal.h>
#import "../Shared/VCAMSharedFrame.h"

#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

static VCAMSharedFrameReader *VCAMReader;
static CVPixelBufferPoolRef VCAMScratchPool;
static CVPixelBufferRef VCAMLastVirtualFrame;
static CIContext *VCAMContext;
static NSLock *VCAMReaderLock;
static volatile int VCAMConsecutiveSlowRenders;
// -1 means no valid configuration has been read yet. Treat that state as
// enabled/fail-closed until an explicit valid false is observed.
static volatile int VCAMConfiguredMode = -1;

static int VCAMCompareRenderMilliseconds(const void *left, const void *right) {
    double a = *(const double *)left;
    double b = *(const double *)right;
    return (a > b) - (a < b);
}

static void VCAMReloadConfiguredMode(void) {
    @autoreleasepool {
        NSDictionary *values = [NSDictionary dictionaryWithContentsOfFile:
            @"/var/mobile/Media/VCAM/com.codex.vcam.plist"];
        id enabledValue = values[@"enabled"];
        if ([enabledValue isKindOfClass:NSNumber.class]) {
            (void)__sync_lock_test_and_set(
                &VCAMConfiguredMode,
                [enabledValue boolValue] ? 1 : 0);
        } else {
            static dispatch_once_t invalidConfigurationToken;
            dispatch_once(&invalidConfigurationToken, ^{
                VCAMRefLog("configuration unreadable; retaining last virtual-camera mode");
            });
        }
    }
}

static void VCAMPreferencesChanged(__unused CFNotificationCenterRef center,
                                   __unused void *observer,
                                   __unused CFStringRef name,
                                   __unused const void *object,
                                   __unused CFDictionaryRef userInfo) {
    VCAMReloadConfiguredMode();
}

void VCAMRefLog(const char *message) {
    struct timeval value = {0};
    gettimeofday(&value, NULL);
    time_t now = value.tv_sec;
    struct tm brokenDown = {0};
    localtime_r(&now, &brokenDown);
    char stamp[32] = {0};
    strftime(stamp, sizeof(stamp), "%H:%M:%S", &brokenDown);
    char line[768] = {0};
    snprintf(line, sizeof(line), "[%d][%s.%03d] %s\n", getpid(), stamp,
             (int)(value.tv_usec / 1000), message != NULL ? message : "(null)");
    int descriptor = open("/var/tmp/vcam-ref-msd.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (descriptor >= 0) {
        (void)write(descriptor, line, strlen(line));
        close(descriptor);
    }
}

void loadReplacementMedia(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        VCAMReader = VCAMSharedFrameReaderCreate();
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        VCAMContext = device != nil
            ? [CIContext contextWithMTLDevice:device options:@{kCIContextUseSoftwareRenderer: @NO}]
            : [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @YES}];
        VCAMReaderLock = [NSLock new];
        NSDictionary *poolAttributes = @{(id)kCVPixelBufferPoolMinimumBufferCountKey: @2};
        NSDictionary *pixelAttributes = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferWidthKey: @(VCAMSharedFrameWidth),
            (id)kCVPixelBufferHeightKey: @(VCAMSharedFrameHeight),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
            (id)kCVPixelBufferMetalCompatibilityKey: @YES,
        };
        CVReturn result = CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                                   (__bridge CFDictionaryRef)poolAttributes,
                                                   (__bridge CFDictionaryRef)pixelAttributes,
                                                   &VCAMScratchPool);
        VCAMReloadConfiguredMode();
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            VCAMPreferencesChanged, CFSTR("com.codex.vcam/preferences.changed"),
            NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        VCAMRefLog(result == kCVReturnSuccess
            ? "shared-frame reader initialized"
            : "shared-frame scratch pool initialization failed");
    });
}

BOOL VCAMVirtualModeIsEnabled(void) {
    return VCAMConfiguredMode != 0;
}

BOOL VCAMTargetBufferIsSupported(CVPixelBufferRef targetBuffer) {
    if (targetBuffer == NULL) return NO;
    size_t width = CVPixelBufferGetWidth(targetBuffer);
    size_t height = CVPixelBufferGetHeight(targetBuffer);
    size_t shortEdge = MIN(width, height);
    size_t longEdge = MAX(width, height);
    // The terminal still-photo output on the test device is 4224x3024. Keep a
    // bounded ceiling that also covers 4K video without accepting arbitrary
    // IOSurfaces inside mediaserverd.
    if (shortEdge < 120 || longEdge < 160 || longEdge > 4608 ||
        width > SIZE_MAX / height || width * height > (size_t)4608 * 3456 ||
        CVPixelBufferGetIOSurface(targetBuffer) == NULL) return NO;

    OSType format = CVPixelBufferGetPixelFormatType(targetBuffer);
    if (format == kCVPixelFormatType_32BGRA) {
        return !CVPixelBufferIsPlanar(targetBuffer) &&
            CVPixelBufferGetPlaneCount(targetBuffer) == 0 &&
            CVPixelBufferGetBytesPerRow(targetBuffer) >= width * 4;
    }
    BOOL compressedVideoRange =
        format == kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange ||
        format == kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarVideoRange ||
        format == (OSType)0x5b387630 || // observed private compressed '[8v0'
        format == (OSType)0x7d387630;   // observed private compressed '}8v0'
    if (format != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
        format != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange &&
        !compressedVideoRange) return NO;
    if ((width & 1) != 0 || (height & 1) != 0 ||
        !CVPixelBufferIsPlanar(targetBuffer) ||
        CVPixelBufferGetPlaneCount(targetBuffer) != 2) return NO;
    if (compressedVideoRange) {
        // Apple explicitly forbids CPU interpretation of compressed planes.
        // Core Image/Metal owns the write; the IOSurface and device capability
        // checks are the only safe validation available here.
        return CVIsCompressedPixelFormatAvailable(format) ||
            format == (OSType)0x5b387630 || format == (OSType)0x7d387630;
    }
    return CVPixelBufferGetWidthOfPlane(targetBuffer, 0) == width &&
        CVPixelBufferGetHeightOfPlane(targetBuffer, 0) == height &&
        CVPixelBufferGetBytesPerRowOfPlane(targetBuffer, 0) >= width &&
        CVPixelBufferGetWidthOfPlane(targetBuffer, 1) == width / 2 &&
        CVPixelBufferGetHeightOfPlane(targetBuffer, 1) == height / 2 &&
        CVPixelBufferGetBytesPerRowOfPlane(targetBuffer, 1) >= width;
}

static BOOL VCAMFillBlackSharedFrame(CVPixelBufferRef pixelBuffer) {
    if (pixelBuffer == NULL ||
        CVPixelBufferLockBaseAddress(pixelBuffer, 0) != kCVReturnSuccess) return NO;
    size_t width = CVPixelBufferGetWidth(pixelBuffer);
    size_t height = CVPixelBufferGetHeight(pixelBuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
    uint8_t *base = CVPixelBufferGetBaseAddress(pixelBuffer);
    for (size_t row = 0; row < height; row++) {
        uint8_t *line = base + row * bytesPerRow;
        memset(line, 0, width * 4);
        for (size_t column = 0; column < width; column++) line[column * 4 + 3] = 255;
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    return YES;
}

BOOL drawReplacementOntoBuffer(CVPixelBufferRef targetBuffer, BOOL realtimeBudget) {
    if (!VCAMTargetBufferIsSupported(targetBuffer) || VCAMReader == NULL || VCAMContext == nil ||
        VCAMScratchPool == NULL) return NO;

    size_t targetWidth = CVPixelBufferGetWidth(targetBuffer);
    size_t targetHeight = CVPixelBufferGetHeight(targetBuffer);
    CVPixelBufferRef scratch = NULL;
    VCAMSharedFrameMetadata metadata = {0};
    BOOL readerLocked = NO;
    BOOL rendered = NO;
    CFAbsoluteTime elapsed = 0;
    @try {
        [VCAMReaderLock lock];
        readerLocked = YES;
        if (VCAMConfiguredMode == 0) {
            if (VCAMLastVirtualFrame != NULL) {
                CVPixelBufferRelease(VCAMLastVirtualFrame);
                VCAMLastVirtualFrame = NULL;
            }
            return NO;
        }
        if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, VCAMScratchPool,
                                               &scratch) != kCVReturnSuccess) return NO;
        BOOL copied = VCAMSharedFrameReaderCopyLatest(VCAMReader, scratch,
                                                      1000000000ULL, &metadata);
        if (!copied) {
            // An enabled virtual camera must never expose a real frame merely
            // because the producer paused. A stale shared virtual frame is a
            // safer fallback than black and is still immutable while copied.
            copied = VCAMSharedFrameReaderCopyLatest(VCAMReader, scratch, 0, &metadata);
        }
        if (copied) {
            if (VCAMLastVirtualFrame != NULL) CVPixelBufferRelease(VCAMLastVirtualFrame);
            VCAMLastVirtualFrame = CVPixelBufferRetain(scratch);
        } else if (VCAMLastVirtualFrame != NULL) {
            CVPixelBufferRelease(scratch);
            scratch = CVPixelBufferRetain(VCAMLastVirtualFrame);
        } else if (VCAMFillBlackSharedFrame(scratch)) {
            VCAMLastVirtualFrame = CVPixelBufferRetain(scratch);
            VCAMRefLog("virtual mode pending: rendering black instead of real camera");
        } else {
            return NO;
        }
        [VCAMReaderLock unlock];
        readerLocked = NO;

        CIImage *image = [CIImage imageWithCVPixelBuffer:scratch];
        CGFloat scale = MIN((CGFloat)targetWidth / CGRectGetWidth(image.extent),
                            (CGFloat)targetHeight / CGRectGetHeight(image.extent));
        image = [image imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
        CGFloat x = ((CGFloat)targetWidth - CGRectGetWidth(image.extent)) * 0.5 -
            CGRectGetMinX(image.extent);
        CGFloat y = ((CGFloat)targetHeight - CGRectGetHeight(image.extent)) * 0.5 -
            CGRectGetMinY(image.extent);
        image = [image imageByApplyingTransform:CGAffineTransformMakeTranslation(x, y)];
        CIImage *background = [[CIImage imageWithColor:CIColor.blackColor]
            imageByCroppingToRect:CGRectMake(0, 0, targetWidth, targetHeight)];
        image = [[image imageByCompositingOverImage:background]
            imageByCroppingToRect:CGRectMake(0, 0, targetWidth, targetHeight)];

        CIRenderDestination *destination = [[CIRenderDestination alloc]
            initWithPixelBuffer:targetBuffer];
        NSError *startError = nil;
        CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
        CIRenderTask *task = [VCAMContext startTaskToRender:image
                                                  fromRect:image.extent
                                             toDestination:destination
                                                   atPoint:CGPointZero
                                                     error:&startError];
        NSError *completionError = nil;
        CIRenderInfo *renderInfo = task == nil ? nil
            : [task waitUntilCompletedAndReturnError:&completionError];
        elapsed = CFAbsoluteTimeGetCurrent() - started;
        rendered = task != nil && renderInfo != nil &&
            startError == nil && completionError == nil;
        if (!rendered) {
            static dispatch_once_t renderFailureToken;
            dispatch_once(&renderFailureToken, ^{
                NSString *message = [NSString stringWithFormat:
                    @"replacement render failed start=%@ completion=%@",
                    startError.localizedDescription ?: @"none",
                    completionError.localizedDescription ?: @"none"];
                VCAMRefLog(message.UTF8String);
            });
        }
    } @catch (NSException *exception) {
        static dispatch_once_t exceptionToken;
        dispatch_once(&exceptionToken, ^{
            NSString *message = [NSString stringWithFormat:
                @"replacement render exception %@", exception.name ?: @"unknown"];
            VCAMRefLog(message.UTF8String);
        });
        rendered = NO;
    } @finally {
        if (readerLocked) [VCAMReaderLock unlock];
        if (scratch != NULL) CVPixelBufferRelease(scratch);
    }

    if (rendered) {
        if (realtimeBudget && elapsed > 0.050) {
            int slowCount = __sync_add_and_fetch(&VCAMConsecutiveSlowRenders, 1);
            if (slowCount <= 4 || slowCount % 120 == 0) {
                char message[192] = {0};
                snprintf(message, sizeof(message),
                         "replacement render slow count=%d elapsedMs=%.2f",
                         slowCount, elapsed * 1000.0);
                VCAMRefLog(message);
            }
        } else if (realtimeBudget) {
            (void)__sync_lock_test_and_set(&VCAMConsecutiveSlowRenders, 0);
        }

        if (!realtimeBudget) {
            static volatile int highResolutionRenders = 0;
            int highResolutionCount = __sync_add_and_fetch(&highResolutionRenders, 1);
            if (highResolutionCount <= 4) {
                char message[224] = {0};
                snprintf(message, sizeof(message),
                         "high-resolution replacement render count=%d size=%zux%zu elapsedMs=%.2f",
                         highResolutionCount, targetWidth, targetHeight,
                         elapsed * 1000.0);
                VCAMRefLog(message);
            }
        }

        static double renderMilliseconds[120] = {0};
        static NSUInteger renderMillisecondsCount = 0;
        BOOL reportWindow = NO;
        double p50 = 0;
        double p95 = 0;
        double maximum = 0;
        @synchronized (VCAMContext) {
            renderMilliseconds[renderMillisecondsCount++] = elapsed * 1000.0;
            if (renderMillisecondsCount == 120) {
                qsort(renderMilliseconds, renderMillisecondsCount,
                      sizeof(renderMilliseconds[0]), VCAMCompareRenderMilliseconds);
                p50 = renderMilliseconds[59];
                p95 = renderMilliseconds[113];
                maximum = renderMilliseconds[119];
                renderMillisecondsCount = 0;
                reportWindow = YES;
            }
        }
        if (reportWindow) {
            char metrics[192] = {0};
            snprintf(metrics, sizeof(metrics),
                     "replacement render window count=120 p50Ms=%.2f p95Ms=%.2f maxMs=%.2f",
                     p50, p95, maximum);
            VCAMRefLog(metrics);
        }

        static volatile int renderedFrames = 0;
        int frameCount = __sync_add_and_fetch(&renderedFrames, 1);
        if (frameCount <= 3) {
            char message[200] = {0};
            snprintf(message, sizeof(message),
                     "rendered shared frame sequence=%llu format=%08x elapsedMs=%.2f",
                     (unsigned long long)metadata.sequence,
                     CVPixelBufferGetPixelFormatType(targetBuffer), elapsed * 1000.0);
            VCAMRefLog(message);
        }
    }
    return rendered;
}

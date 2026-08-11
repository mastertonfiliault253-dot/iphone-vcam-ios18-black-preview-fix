#import "VCAMMediaServerRefImageUtils.h"

#import <CoreImage/CoreImage.h>
#import <CoreVideo/CVPixelFormatDescription.h>
#import <ImageIO/CGImageProperties.h>
#import <Metal/Metal.h>
#import <VideoToolbox/VideoToolbox.h>
#import "../Shared/VCAMSharedFrame.h"
#import "../Shared/VCAMSurfaceBroker.h"

#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

static VCAMSharedFrameReader *VCAMReader;
static VCAMSharedSurfaceReader *VCAMSurfaceReader;
static VCAMSharedSurfaceFrame VCAMLastSurfaceFrame;
/// Once a surface writer generation is consumed, its old mmap bootstrap must
/// never become a live source again. All three video slots carry the same
/// generation; only a new writer reopens bootstrap while XPC rights arrive.
static uint64_t VCAMAdoptedSurfaceGeneration;
/// When an adopted surface writer disappears, a generation-zero legacy
/// daemon may take over only with a frame published after this observation.
static uint64_t VCAMLegacyMmapCutoffNanoseconds;
static CVPixelBufferPoolRef VCAMScratchPool;
static CVPixelBufferPoolRef VCAMCompressedStagingPool;
static size_t VCAMCompressedStagingWidth;
static size_t VCAMCompressedStagingHeight;
static CVPixelBufferPoolRef VCAMCompressedTargetPool;
static OSType VCAMCompressedTargetFormat;
static size_t VCAMCompressedTargetWidth;
static size_t VCAMCompressedTargetHeight;
static CFDictionaryRef VCAMCompressedTargetCreationAttributes;
static CVPixelBufferRef VCAMLastCompressedVirtualFrame;
static CFDictionaryRef VCAMLastCompressedVirtualFrameCreationAttributes;
static CVPixelBufferRef VCAMLastVirtualFrame;
static CFAbsoluteTime VCAMLastVirtualFrameHostTime;
static CIContext *VCAMContext;
static CGColorSpaceRef VCAMStandardColorSpace;
static NSLock *VCAMReaderLock;
static NSLock *VCAMPixelTransferLock;
// Keep the process-lifetime session in an availability-neutral CF slot. The
// concrete VTPixelTransferSessionRef type is iOS 16+, while the package keeps
// an iOS 15 deployment target so unsupported systems can fail closed.
static CFTypeRef VCAMPixelTransferSession;
static volatile int VCAMConsecutiveSlowRenders;
// -1 means no valid configuration has been read yet. Treat that state as
// enabled/fail-closed until an explicit valid false is observed.
static volatile int VCAMConfiguredMode = -1;

static int VCAMCompareRenderMilliseconds(const void *left, const void *right) {
    double a = *(const double *)left;
    double b = *(const double *)right;
    return (a > b) - (a < b);
}

static BOOL VCAMFormatIsCompressedVideoRange(OSType format) {
    return format == kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange ||
        format == kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarVideoRange ||
        format == kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarVideoRange ||
        format == kCVPixelFormatType_Lossy_420YpCbCr10PackedBiPlanarVideoRange ||
        format == (OSType)0x70343230 || // iOS 16.1 Camera preview 'p420'
        format == (OSType)0x5b387630 || // observed private compressed '[8v0'
        format == (OSType)0x7d387630 || // observed private compressed '}8v0'
        format == (OSType)0x26386630 || // observed private bi-planar '&8f0'
        format == (OSType)0x26786630;   // iOS 16.1 deferred photo '&xf0'
}

static CVReturn VCAMCreateStagingPool(OSType format, size_t width, size_t height,
                                     CVPixelBufferPoolRef *poolOut) {
    NSDictionary *poolAttributes = @{(id)kCVPixelBufferPoolMinimumBufferCountKey: @2};
    NSDictionary *pixelAttributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(format),
        (id)kCVPixelBufferWidthKey: @(width),
        (id)kCVPixelBufferHeightKey: @(height),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
    };
    return CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                   (__bridge CFDictionaryRef)poolAttributes,
                                   (__bridge CFDictionaryRef)pixelAttributes,
                                   poolOut);
}

static CVReturn VCAMCreateCompressedStagingBuffer(size_t width, size_t height,
                                                  CVPixelBufferRef *bufferOut) {
    if (bufferOut == NULL || VCAMPixelTransferLock == nil) return kCVReturnInvalidArgument;
    *bufferOut = NULL;
    [VCAMPixelTransferLock lock];
    if (VCAMCompressedStagingPool == NULL ||
        VCAMCompressedStagingWidth != width ||
        VCAMCompressedStagingHeight != height) {
        CVPixelBufferPoolRef replacementPool = NULL;
        CVReturn poolStatus = VCAMCreateStagingPool(
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            width, height, &replacementPool);
        if (poolStatus != kCVReturnSuccess) {
            [VCAMPixelTransferLock unlock];
            return poolStatus;
        }
        if (VCAMCompressedStagingPool != NULL) {
            CVPixelBufferPoolRelease(VCAMCompressedStagingPool);
        }
        VCAMCompressedStagingPool = replacementPool;
        VCAMCompressedStagingWidth = width;
        VCAMCompressedStagingHeight = height;
    }
    CVReturn bufferStatus = CVPixelBufferPoolCreatePixelBuffer(
        kCFAllocatorDefault, VCAMCompressedStagingPool, bufferOut);
    [VCAMPixelTransferLock unlock];
    return bufferStatus;
}

static CVReturn VCAMCreateCompressedTargetBuffer(CVPixelBufferRef targetBuffer,
                                                 CVPixelBufferRef *bufferOut) {
    if (targetBuffer == NULL || bufferOut == NULL ||
        VCAMPixelTransferLock == nil) return kCVReturnInvalidArgument;
    *bufferOut = NULL;
    size_t width = CVPixelBufferGetWidth(targetBuffer);
    size_t height = CVPixelBufferGetHeight(targetBuffer);
    OSType format = CVPixelBufferGetPixelFormatType(targetBuffer);
    CFDictionaryRef creationAttributes =
        CVPixelBufferCopyCreationAttributes(targetBuffer);
    if (creationAttributes == NULL) return kCVReturnInvalidPixelBufferAttributes;

    [VCAMPixelTransferLock lock];
    if (VCAMCompressedTargetPool == NULL ||
        VCAMCompressedTargetFormat != format ||
        VCAMCompressedTargetWidth != width ||
        VCAMCompressedTargetHeight != height ||
        VCAMCompressedTargetCreationAttributes == NULL ||
        !CFEqual(VCAMCompressedTargetCreationAttributes, creationAttributes)) {
        NSDictionary *poolAttributes = @{
            (id)kCVPixelBufferPoolMinimumBufferCountKey: @3,
        };
        CVPixelBufferPoolRef replacementPool = NULL;
        CVReturn poolStatus = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            (__bridge CFDictionaryRef)poolAttributes,
            creationAttributes,
            &replacementPool);
        if (poolStatus != kCVReturnSuccess) {
            [VCAMPixelTransferLock unlock];
            CFRelease(creationAttributes);
            return poolStatus;
        }
        if (VCAMCompressedTargetPool != NULL) {
            CVPixelBufferPoolRelease(VCAMCompressedTargetPool);
        }
        if (VCAMCompressedTargetCreationAttributes != NULL) {
            CFRelease(VCAMCompressedTargetCreationAttributes);
        }
        if (VCAMLastCompressedVirtualFrame != NULL) {
            CVPixelBufferRelease(VCAMLastCompressedVirtualFrame);
            VCAMLastCompressedVirtualFrame = NULL;
        }
        if (VCAMLastCompressedVirtualFrameCreationAttributes != NULL) {
            CFRelease(VCAMLastCompressedVirtualFrameCreationAttributes);
            VCAMLastCompressedVirtualFrameCreationAttributes = NULL;
        }
        VCAMCompressedTargetPool = replacementPool;
        VCAMCompressedTargetFormat = format;
        VCAMCompressedTargetWidth = width;
        VCAMCompressedTargetHeight = height;
        VCAMCompressedTargetCreationAttributes =
            (CFDictionaryRef)CFRetain(creationAttributes);
    }
    CVReturn bufferStatus = CVPixelBufferPoolCreatePixelBuffer(
        kCFAllocatorDefault, VCAMCompressedTargetPool, bufferOut);
    [VCAMPixelTransferLock unlock];
    CFRelease(creationAttributes);
    return bufferStatus;
}

static void VCAMRememberCompressedVirtualFrame(CVPixelBufferRef pixelBuffer,
                                               CVPixelBufferRef targetBuffer) {
    if (pixelBuffer == NULL || targetBuffer == NULL ||
        VCAMPixelTransferLock == nil) return;
    CFDictionaryRef creationAttributes =
        CVPixelBufferCopyCreationAttributes(targetBuffer);
    if (creationAttributes == NULL) return;
    [VCAMPixelTransferLock lock];
    if (VCAMLastCompressedVirtualFrame != NULL) {
        CVPixelBufferRelease(VCAMLastCompressedVirtualFrame);
    }
    if (VCAMLastCompressedVirtualFrameCreationAttributes != NULL) {
        CFRelease(VCAMLastCompressedVirtualFrameCreationAttributes);
    }
    VCAMLastCompressedVirtualFrame = CVPixelBufferRetain(pixelBuffer);
    VCAMLastCompressedVirtualFrameCreationAttributes = creationAttributes;
    [VCAMPixelTransferLock unlock];
}

static BOOL VCAMCopyLastCompressedVirtualFrame(CVPixelBufferRef targetBuffer,
                                               CVPixelBufferRef *bufferOut) {
    if (targetBuffer == NULL || bufferOut == NULL ||
        VCAMPixelTransferLock == nil) return NO;
    CFDictionaryRef creationAttributes =
        CVPixelBufferCopyCreationAttributes(targetBuffer);
    if (creationAttributes == NULL) return NO;
    size_t width = CVPixelBufferGetWidth(targetBuffer);
    size_t height = CVPixelBufferGetHeight(targetBuffer);
    OSType format = CVPixelBufferGetPixelFormatType(targetBuffer);
    BOOL copied = NO;
    [VCAMPixelTransferLock lock];
    if (VCAMLastCompressedVirtualFrame != NULL &&
        VCAMLastCompressedVirtualFrameCreationAttributes != NULL &&
        CFEqual(VCAMLastCompressedVirtualFrameCreationAttributes,
                creationAttributes) &&
        CVPixelBufferGetWidth(VCAMLastCompressedVirtualFrame) == width &&
        CVPixelBufferGetHeight(VCAMLastCompressedVirtualFrame) == height &&
        CVPixelBufferGetPixelFormatType(VCAMLastCompressedVirtualFrame) == format) {
        *bufferOut = CVPixelBufferRetain(VCAMLastCompressedVirtualFrame);
        copied = YES;
    }
    [VCAMPixelTransferLock unlock];
    CFRelease(creationAttributes);
    if (copied) {
        static volatile int staleCompressedFrames = 0;
        int staleCount = __sync_add_and_fetch(&staleCompressedFrames, 1);
        if (staleCount <= 8 || staleCount % 300 == 0) {
            char message[192] = {0};
            snprintf(message, sizeof(message),
                     "using last virtual compressed frame count=%d format=%08x",
                     staleCount, format);
            VCAMRefLog(message);
        }
    }
    return copied;
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
        VCAMSurfaceReader = VCAMSharedSurfaceReaderCreate();
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        VCAMContext = device != nil
            ? [CIContext contextWithMTLDevice:device options:@{kCIContextUseSoftwareRenderer: @NO}]
            : [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @YES}];
        VCAMStandardColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        VCAMReaderLock = [NSLock new];
        VCAMPixelTransferLock = [NSLock new];
        CVReturn result = VCAMCreateStagingPool(
            kCVPixelFormatType_32BGRA,
            VCAMSharedFrameWidth, VCAMSharedFrameHeight, &VCAMScratchPool);
        OSStatus transferCreateResult = kCVReturnUnsupported;
        OSStatus scalingResult = transferCreateResult;
        OSStatus realtimeResult = transferCreateResult;
        if (@available(iOS 16.0, *)) {
            VTPixelTransferSessionRef transferSession = NULL;
            transferCreateResult = VTPixelTransferSessionCreate(
                kCFAllocatorDefault, &transferSession);
            if (transferCreateResult == noErr) {
                VCAMPixelTransferSession = transferSession;
                scalingResult = VTSessionSetProperty(
                    transferSession, kVTPixelTransferPropertyKey_ScalingMode,
                    kVTScalingMode_Normal);
                realtimeResult = VTSessionSetProperty(
                    transferSession, kVTPixelTransferPropertyKey_RealTime,
                    kCFBooleanTrue);
            }
        }
        VCAMReloadConfiguredMode();
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            VCAMPreferencesChanged, CFSTR("com.codex.vcam/preferences.changed"),
            NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        VCAMRefLog(result == kCVReturnSuccess
            ? "shared-frame reader initialized"
            : "shared-frame scratch pool initialization failed");
        VCAMRefLog(VCAMSurfaceReader != NULL
            ? "shared IOSurface reader initialized"
            : "shared IOSurface reader unavailable; mmap fallback retained");
        if (transferCreateResult == noErr && scalingResult == noErr &&
            realtimeResult == noErr) {
            VCAMRefLog("compressed pixel transfer initialized");
        } else {
            char message[224] = {0};
            snprintf(message, sizeof(message),
                     "compressed pixel transfer initialization failed create=%d scaling=%d realtime=%d",
                     (int)transferCreateResult,
                     (int)scalingResult, (int)realtimeResult);
            VCAMRefLog(message);
        }
    });
}

static BOOL VCAMEffectiveVirtualModeIsEnabledLocked(void) {
    bool sharedActive = false;
    BOOL sharedAvailable = VCAMSharedFrameReaderGetActiveState(
        VCAMReader, &sharedActive);
    return sharedAvailable ? sharedActive : VCAMConfiguredMode != 0;
}

BOOL VCAMVirtualModeIsEnabled(void) {
    loadReplacementMedia();
    [VCAMReaderLock lock];
    BOOL enabled = VCAMEffectiveVirtualModeIsEnabledLocked();
    [VCAMReaderLock unlock];
    return enabled;
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
    BOOL compressedVideoRange = VCAMFormatIsCompressedVideoRange(format);
    if (format != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
        format != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange &&
        !compressedVideoRange) return NO;
    if ((width & 1) != 0 || (height & 1) != 0 ||
        !CVPixelBufferIsPlanar(targetBuffer) ||
        CVPixelBufferGetPlaneCount(targetBuffer) != 2) return NO;
    if (compressedVideoRange) {
        // Apple explicitly forbids CPU interpretation of compressed planes.
        // VideoToolbox owns the write; the IOSurface and device capability
        // checks are the only safe validation available here.
        return CVIsCompressedPixelFormatAvailable(format) ||
            format == (OSType)0x70343230 || // iOS 16.1 Camera preview 'p420'
            format == (OSType)0x5b387630 || format == (OSType)0x7d387630 ||
            format == (OSType)0x26786630;
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

static void VCAMSetStandardColorAttachments(CVPixelBufferRef buffer) {
    if (buffer == NULL) return;
    CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
                          kCVImageBufferColorPrimaries_ITU_R_709_2,
                          kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
                          kCVImageBufferTransferFunction_ITU_R_709_2,
                          kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                          kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                          kCVAttachmentMode_ShouldPropagate);
}

static void VCAMMergeGraphAttachments(CVPixelBufferRef sourceBuffer,
                                      CVPixelBufferRef destinationBuffer) {
    // Keep VideoToolbox's content-description attachments authoritative. Only
    // fill missing, public graph-contract keys whose values remain valid for a
    // same-sized clone; never copy opaque camera/private metadata wholesale.
    const CFStringRef keys[] = {
        kCVImageBufferCleanApertureKey,
        kCVImageBufferPixelAspectRatioKey,
        kCVImageBufferFieldCountKey,
        kCVImageBufferFieldDetailKey,
        kCVImageBufferChromaLocationTopFieldKey,
        kCVImageBufferChromaLocationBottomFieldKey,
        kCVImageBufferColorPrimariesKey,
        kCVImageBufferTransferFunctionKey,
        kCVImageBufferYCbCrMatrixKey,
        kCVImageBufferGammaLevelKey,
    };
    for (NSUInteger index = 0; index < sizeof(keys) / sizeof(keys[0]); index++) {
        if (CVBufferGetAttachment(destinationBuffer, keys[index], NULL) != NULL) {
            continue;
        }
        CVAttachmentMode mode = kCVAttachmentMode_ShouldNotPropagate;
        CFTypeRef value = CVBufferGetAttachment(sourceBuffer, keys[index], &mode);
        if (value != NULL) CVBufferSetAttachment(destinationBuffer, keys[index], value, mode);
    }
}

static BOOL VCAMTransferIntoCompressedTarget(CVPixelBufferRef stagingBuffer,
                                             CVPixelBufferRef originalTargetBuffer,
                                             CVPixelBufferRef replacementTargetBuffer) {
    if (stagingBuffer == NULL || originalTargetBuffer == NULL ||
        replacementTargetBuffer == NULL ||
        VCAMPixelTransferSession == NULL || VCAMPixelTransferLock == nil) return NO;

    CVBufferRemoveAllAttachments(stagingBuffer);
    // The shared canvas is standard-range sRGB/Rec.709 content. Reusing the
    // physical camera's HDR/headroom tags makes saved virtual photos visibly
    // darker and over-contrasted.
    VCAMSetStandardColorAttachments(stagingBuffer);

    OSStatus transferStatus = kCVReturnUnsupported;
    if (@available(iOS 16.0, *)) {
        [VCAMPixelTransferLock lock];
        transferStatus = VTPixelTransferSessionTransferImage(
            (VTPixelTransferSessionRef)VCAMPixelTransferSession,
            stagingBuffer, replacementTargetBuffer);
        [VCAMPixelTransferLock unlock];
    }

    if (transferStatus != noErr) {
        static volatile int transferFailures = 0;
        int failureCount = __sync_add_and_fetch(&transferFailures, 1);
        if (failureCount <= 8 || failureCount % 300 == 0) {
            char message[224] = {0};
            snprintf(message, sizeof(message),
                     "compressed pixel transfer failed count=%d status=%d format=%08x",
                     failureCount, (int)transferStatus,
                     CVPixelBufferGetPixelFormatType(originalTargetBuffer));
            VCAMRefLog(message);
        }
        return NO;
    }
    VCAMMergeGraphAttachments(originalTargetBuffer, replacementTargetBuffer);
    VCAMSetStandardColorAttachments(replacementTargetBuffer);
    return YES;
}

BOOL drawReplacementOntoBuffer(CVPixelBufferRef targetBuffer,
                               VCAMFramePresentation presentation,
                               CVPixelBufferRef *replacementBufferOut,
                               BOOL *stillPhotoRequiresRightOrientationOut) {
    if (replacementBufferOut != NULL) *replacementBufferOut = NULL;
    if (stillPhotoRequiresRightOrientationOut != NULL) {
        *stillPhotoRequiresRightOrientationOut = NO;
    }
    if (!VCAMTargetBufferIsSupported(targetBuffer) || VCAMReader == NULL || VCAMContext == nil ||
        VCAMScratchPool == NULL) return NO;

    size_t targetWidth = CVPixelBufferGetWidth(targetBuffer);
    size_t targetHeight = CVPixelBufferGetHeight(targetBuffer);
    OSType targetFormat = CVPixelBufferGetPixelFormatType(targetBuffer);
    BOOL realtimeCompensation =
        presentation != VCAMFramePresentationStillPhotoFill;
    BOOL aspectFit =
        presentation == VCAMFramePresentationCameraPreviewFit;
    BOOL webKitLandscapeStorage =
        presentation == VCAMFramePresentationWebKitFill;
    BOOL compressedTarget = VCAMFormatIsCompressedVideoRange(targetFormat);
    if (compressedTarget && replacementBufferOut == NULL) return NO;
    CVPixelBufferRef scratch = NULL;
    CVPixelBufferRef stagingBuffer = NULL;
    CVPixelBufferRef compressedReplacementBuffer = NULL;
    VCAMSharedFrameMetadata metadata = {0};
    VCAMSharedSurfaceFrame surfaceFrame = {0};
    BOOL readerLocked = NO;
    BOOL rendered = NO;
    CFAbsoluteTime elapsed = 0;
    @try {
        [VCAMReaderLock lock];
        readerLocked = YES;
        BOOL virtualModeEnabled = VCAMEffectiveVirtualModeIsEnabledLocked();
        if (!virtualModeEnabled) {
            if (VCAMLastVirtualFrame != NULL) {
                CVPixelBufferRelease(VCAMLastVirtualFrame);
                VCAMLastVirtualFrame = NULL;
            }
            VCAMSharedSurfaceFrameRelease(&VCAMLastSurfaceFrame);
            VCAMAdoptedSurfaceGeneration = 0;
            VCAMLegacyMmapCutoffNanoseconds = 0;
            return NO;
        }
        BOOL surfaceCopied = VCAMSharedSurfaceReaderCopyLatest(
            VCAMSurfaceReader, 1000000000ULL, &surfaceFrame);
        BOOL copied = surfaceCopied;
        if (surfaceCopied) {
            scratch = CVPixelBufferRetain(surfaceFrame.pixelBuffer);
            metadata = surfaceFrame.metadata;
            VCAMAdoptedSurfaceGeneration = metadata.surfaceGeneration;
            VCAMLegacyMmapCutoffNanoseconds = 0;
            static volatile int sharedSurfaceFrames = 0;
            int surfaceCount = __sync_add_and_fetch(&sharedSurfaceFrames, 1);
            if (surfaceCount <= 3) {
                char message[192] = {0};
                snprintf(message, sizeof(message),
                         "shared IOSurface frame count=%d sequence=%llu size=%ux%u",
                         surfaceCount, (unsigned long long)metadata.sequence,
                         metadata.width, metadata.height);
                VCAMRefLog(message);
            }
        } else {
            static VCAMSharedSurfaceReaderFailure lastSurfaceFailure =
                VCAMSharedSurfaceReaderFailureNone;
            static int surfaceFailureLogs = 0;
            VCAMSharedSurfaceReaderFailure failure =
                VCAMSharedSurfaceReaderLastFailure(VCAMSurfaceReader);
            if (failure != VCAMSharedSurfaceReaderFailureOpen &&
                failure != VCAMSharedSurfaceReaderFailureStale &&
                (failure != lastSurfaceFailure || surfaceFailureLogs < 3)) {
                char message[128] = {0};
                snprintf(message, sizeof(message),
                         "shared IOSurface unavailable failure=%d broker=%s",
                         failure, VCAMSurfaceBrokerSubscriberStatus());
                VCAMRefLog(message);
                lastSurfaceFailure = failure;
                surfaceFailureLogs += 1;
            }
            VCAMSharedFrameMetadata currentSurface = {0};
            BOOL hasCurrentSurface = VCAMSharedSurfaceReaderGetLatestMetadata(
                VCAMSurfaceReader, 0, &currentSurface);
            if (!hasCurrentSurface && VCAMAdoptedSurfaceGeneration != 0 &&
                VCAMLegacyMmapCutoffNanoseconds == 0) {
                VCAMLegacyMmapCutoffNanoseconds =
                    VCAMSharedFrameMonotonicNanoseconds();
            }
            BOOL allowMmapBootstrap = VCAMAdoptedSurfaceGeneration == 0 ||
                (hasCurrentSurface && currentSurface.surfaceGeneration != 0 &&
                 currentSurface.surfaceGeneration !=
                    VCAMAdoptedSurfaceGeneration) ||
                (!hasCurrentSurface &&
                 VCAMLegacyMmapCutoffNanoseconds != 0);
            if (CVPixelBufferPoolCreatePixelBuffer(
                    kCFAllocatorDefault, VCAMScratchPool,
                    &scratch) != kCVReturnSuccess) {
                if (compressedTarget && VCAMCopyLastCompressedVirtualFrame(
                        targetBuffer, replacementBufferOut)) return YES;
                return NO;
            }
            copied = allowMmapBootstrap && VCAMSharedFrameReaderCopyLatest(
                VCAMReader, scratch, 1000000000ULL, &metadata);
            if (copied) {
                if (metadata.surfaceGeneration != 0) {
                    copied = hasCurrentSurface &&
                        currentSurface.surfaceGeneration ==
                            metadata.surfaceGeneration;
                } else if (hasCurrentSurface) {
                    copied = NO;
                } else if (VCAMAdoptedSurfaceGeneration != 0) {
                    // A direct marker rollback is allowed only after vcamd
                    // publishes a new legacy frame following disappearance
                    // of the adopted surface writer. Never revive its old
                    // generation-bound bootstrap.
                    copied = VCAMLegacyMmapCutoffNanoseconds != 0 &&
                        metadata.monotonicTimestampNanoseconds >=
                            VCAMLegacyMmapCutoffNanoseconds;
                    if (copied) {
                        VCAMAdoptedSurfaceGeneration = 0;
                        VCAMLegacyMmapCutoffNanoseconds = 0;
                    }
                }
            }
        }
        if (copied) {
            if (VCAMLastVirtualFrame != NULL) CVPixelBufferRelease(VCAMLastVirtualFrame);
            VCAMSharedSurfaceFrameRelease(&VCAMLastSurfaceFrame);
            if (surfaceCopied) {
                VCAMLastSurfaceFrame = surfaceFrame;
                memset(&surfaceFrame, 0, sizeof(surfaceFrame));
            }
            VCAMLastVirtualFrame = CVPixelBufferRetain(scratch);
            VCAMLastVirtualFrameHostTime = CFAbsoluteTimeGetCurrent();
        } else if (VCAMLastVirtualFrame != NULL &&
                   CFAbsoluteTimeGetCurrent() - VCAMLastVirtualFrameHostTime <= 2.5) {
            // Short stalls reuse the last good frame so the picture does not
            // blink on every producer hiccup.
            CVPixelBufferRelease(scratch);
            scratch = CVPixelBufferRetain(VCAMLastVirtualFrame);
        } else if (VCAMFillBlackSharedFrame(scratch)) {
            // The stream has been gone long enough that a frozen frame would
            // be mistaken for the live picture. Fail closed to black instead.
            if (VCAMLastVirtualFrame != NULL) CVPixelBufferRelease(VCAMLastVirtualFrame);
            VCAMSharedSurfaceFrameRelease(&VCAMLastSurfaceFrame);
            VCAMLastVirtualFrame = CVPixelBufferRetain(scratch);
            VCAMLastVirtualFrameHostTime = CFAbsoluteTimeGetCurrent();
            static volatile int staleBlackFrames = 0;
            int staleCount = __sync_add_and_fetch(&staleBlackFrames, 1);
            if (staleCount <= 4 || staleCount % 300 == 0) {
                VCAMRefLog("virtual frame stale; rendering black instead of frozen frame");
            }
        } else {
            if (compressedTarget && VCAMCopyLastCompressedVirtualFrame(
                    targetBuffer, replacementBufferOut)) return YES;
            return NO;
        }
        [VCAMReaderLock unlock];
        readerLocked = NO;

        CVPixelBufferRef renderBuffer = targetBuffer;
        size_t renderWidth = targetWidth;
        size_t renderHeight = targetHeight;
        if (compressedTarget) {
            CVReturn stagingStatus = VCAMPixelTransferSession == NULL
                ? kCVReturnInvalidArgument
                : VCAMCreateCompressedStagingBuffer(
                    targetWidth, targetHeight, &stagingBuffer);
            CVReturn targetStatus = stagingStatus == kCVReturnSuccess
                ? VCAMCreateCompressedTargetBuffer(
                    targetBuffer, &compressedReplacementBuffer)
                : kCVReturnInvalidArgument;
            if (stagingStatus != kCVReturnSuccess ||
                targetStatus != kCVReturnSuccess) {
                static volatile int allocationFailures = 0;
                int failureCount = __sync_add_and_fetch(&allocationFailures, 1);
                if (failureCount <= 8 || failureCount % 300 == 0) {
                    char message[224] = {0};
                    snprintf(message, sizeof(message),
                             "compressed replacement buffer allocation failed count=%d staging=%d target=%d format=%08x",
                             failureCount, stagingStatus, targetStatus, targetFormat);
                    VCAMRefLog(message);
                }
                if (VCAMCopyLastCompressedVirtualFrame(
                        targetBuffer, replacementBufferOut)) return YES;
                return NO;
            }
            renderBuffer = stagingBuffer;
            renderWidth = CVPixelBufferGetWidth(stagingBuffer);
            renderHeight = CVPixelBufferGetHeight(stagingBuffer);
        }

        CIImage *image = [CIImage imageWithCVPixelBuffer:scratch];
        BOOL sourceIsPortrait = CGRectGetHeight(image.extent) >
            CGRectGetWidth(image.extent);
        // Safari's iOS 16 getUserMedia terminal consumes a landscape 640x480
        // pixel basis and then applies the camera graph's portrait display
        // transform. Device A/B showed that canonical portrait pixels which
        // are already upright in Camera therefore appear 90 degrees clockwise
        // in WebKit. Pre-rotate only that explicit terminal route; target
        // dimensions alone are never used to identify a browser consumer.
        if (webKitLandscapeStorage && sourceIsPortrait &&
            targetWidth > targetHeight) {
            image = [image imageByApplyingOrientation:kCGImagePropertyOrientationLeft];
        }
        // iOS still-photo buffers use the sensor's landscape storage basis.
        // Only a canonical portrait source is turned into that basis; the
        // caller then marks the final sample Orientation=Right so Photos shows
        // a portrait 3:4 image. Realtime consumers and landscape sources keep
        // their canonical basis unchanged.
        if (!realtimeCompensation && sourceIsPortrait &&
            targetWidth > targetHeight) {
            image = [image imageByApplyingOrientation:kCGImagePropertyOrientationLeft];
            if (stillPhotoRequiresRightOrientationOut != NULL) {
                *stillPhotoRequiresRightOrientationOut = YES;
            }
        }
        // The producer publishes canonical visual orientation. The real
        // camera graph remains the negotiation shell: target dimensions,
        // pixel format, timing and graph attachments are left untouched.
        // WebKit, recording and still-photo terminals use the camera graph's
        // full-bleed center crop. Camera preview alone retains whole-frame fit.
        // This is the only scale operation: the negotiated target dimensions,
        // format, timing and attachments remain unchanged downstream.
        CGFloat scale = aspectFit
            ? MIN((CGFloat)renderWidth / CGRectGetWidth(image.extent),
                  (CGFloat)renderHeight / CGRectGetHeight(image.extent))
            : MAX((CGFloat)renderWidth / CGRectGetWidth(image.extent),
                  (CGFloat)renderHeight / CGRectGetHeight(image.extent));
        image = [image imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
        CGFloat x = ((CGFloat)renderWidth - CGRectGetWidth(image.extent)) * 0.5 -
            CGRectGetMinX(image.extent);
        CGFloat y = ((CGFloat)renderHeight - CGRectGetHeight(image.extent)) * 0.5 -
            CGRectGetMinY(image.extent);
        image = [image imageByApplyingTransform:CGAffineTransformMakeTranslation(x, y)];
        CIImage *background = [[CIImage imageWithColor:CIColor.blackColor]
            imageByCroppingToRect:CGRectMake(0, 0, renderWidth, renderHeight)];
        image = [[image imageByCompositingOverImage:background]
            imageByCroppingToRect:CGRectMake(0, 0, renderWidth, renderHeight)];

        CIRenderDestination *destination = [[CIRenderDestination alloc]
            initWithPixelBuffer:renderBuffer];
        VCAMSetStandardColorAttachments(renderBuffer);
        destination.colorSpace = VCAMStandardColorSpace;
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
        BOOL coreImageRendered = task != nil && renderInfo != nil &&
            startError == nil && completionError == nil;
        rendered = coreImageRendered && (!compressedTarget ||
            VCAMTransferIntoCompressedTarget(stagingBuffer, targetBuffer,
                                             compressedReplacementBuffer));
        if (rendered && compressedTarget) {
            VCAMRememberCompressedVirtualFrame(compressedReplacementBuffer,
                                               targetBuffer);
            *replacementBufferOut = CVPixelBufferRetain(compressedReplacementBuffer);
        }
        elapsed = CFAbsoluteTimeGetCurrent() - started;
        if (!coreImageRendered) {
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
        if (compressedReplacementBuffer != NULL) {
            CVPixelBufferRelease(compressedReplacementBuffer);
        }
        if (stagingBuffer != NULL) CVPixelBufferRelease(stagingBuffer);
        if (scratch != NULL) CVPixelBufferRelease(scratch);
        VCAMSharedSurfaceFrameRelease(&surfaceFrame);
    }

    if (!rendered && compressedTarget && replacementBufferOut != NULL &&
        *replacementBufferOut == NULL) {
        rendered = VCAMCopyLastCompressedVirtualFrame(
            targetBuffer, replacementBufferOut);
    }

    if (rendered) {
        if (compressedTarget) {
            static volatile int compressedRenders = 0;
            int compressedRenderCount = __sync_add_and_fetch(&compressedRenders, 1);
            if (compressedRenderCount <= 4) {
                char message[224] = {0};
                snprintf(message, sizeof(message),
                         "compressed replacement rendered count=%d size=%zux%zu format=%08x elapsedMs=%.2f",
                         compressedRenderCount, targetWidth, targetHeight,
                         targetFormat, elapsed * 1000.0);
                VCAMRefLog(message);
            }
        }
        if (realtimeCompensation && elapsed > 0.050) {
            int slowCount = __sync_add_and_fetch(&VCAMConsecutiveSlowRenders, 1);
            if (slowCount <= 4 || slowCount % 120 == 0) {
                char message[192] = {0};
                snprintf(message, sizeof(message),
                         "replacement render slow count=%d elapsedMs=%.2f",
                         slowCount, elapsed * 1000.0);
                VCAMRefLog(message);
            }
        } else if (realtimeCompensation) {
            (void)__sync_lock_test_and_set(&VCAMConsecutiveSlowRenders, 0);
        }

        if (!realtimeCompensation) {
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

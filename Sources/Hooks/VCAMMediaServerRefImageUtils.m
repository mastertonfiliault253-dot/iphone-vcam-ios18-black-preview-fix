#import "VCAMMediaServerRefImageUtils.h"
#import "../Shared/VCAMProcessIdentity.h"

#import <CoreImage/CoreImage.h>
#import <CoreVideo/CVPixelBufferIOSurface.h>
#import <CoreVideo/CVPixelFormatDescription.h>
#import <ImageIO/CGImageProperties.h>
#import <Metal/Metal.h>
#import <VideoToolbox/VideoToolbox.h>
#import "../Shared/VCAMSharedFrame.h"
#import "../Shared/VCAMSurfaceBroker.h"

#include <fcntl.h>
#include <errno.h>
#include <notify.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
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
static CVPixelBufferPoolRef VCAMNV12ScratchPool;
static CVPixelBufferPoolRef VCAMPlanarRenderPool;
static size_t VCAMPlanarRenderWidth;
static size_t VCAMPlanarRenderHeight;
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
static int VCAMVirtualModeStateToken = -1;
static int VCAMVirtualModeStateReadyToken = -1;
// VTPixelTransferSession is available throughout the supported iOS 16.0-16.5
// range. Keep the process-lifetime object in a narrow CF slot so this hook does
// not depend on SDK-specific public typedef details.
static CFTypeRef VCAMPixelTransferSession;
static volatile int VCAMConsecutiveSlowRenders;
// Fresh installs start on the real camera. After a valid value is observed,
// transient read failures retain that last value in VCAMReloadConfiguredMode.
static volatile int VCAMConfiguredMode = 0;

// Bounded pixel telemetry for the iOS 18 black-preview investigation. The
// values are scalar Darwin-notify state so a root probe can read them without
// dereferencing objects in cameracaptured. A signature is taken from a small,
// evenly-spaced sample of each plane; it is not a frame dump.
static int VCAMPixelDiagnosticSequenceToken = -1;
static int VCAMPixelDiagnosticSourceToken = -1;
static int VCAMPixelDiagnosticStagingToken = -1;
static int VCAMPixelDiagnosticTargetToken = -1;
static int VCAMPixelDiagnosticSourceSummaryToken = -1;
static int VCAMPixelDiagnosticStagingSummaryToken = -1;
static int VCAMPixelDiagnosticTargetSummaryToken = -1;

static uint64_t VCAMPixelDiagnosticSignature(
    CVPixelBufferRef pixelBuffer, uint64_t *summaryOut) {
    if (summaryOut != NULL) *summaryOut = 0;
    if (pixelBuffer == NULL) return 0;
    if (CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly) !=
        kCVReturnSuccess) return 0;

    uint64_t hash = 1469598103934665603ULL;
    uint64_t sum = 0;
    uint64_t sampleCount = 0;
    uint64_t nonzero = 0;
    uint8_t minimum = 255;
    uint8_t maximum = 0;
    size_t planeCount = CVPixelBufferIsPlanar(pixelBuffer)
        ? CVPixelBufferGetPlaneCount(pixelBuffer) : 1;
    for (size_t plane = 0; plane < planeCount; plane++) {
        uint8_t *base = CVPixelBufferIsPlanar(pixelBuffer)
            ? CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane)
            : CVPixelBufferGetBaseAddress(pixelBuffer);
        size_t rows = CVPixelBufferIsPlanar(pixelBuffer)
            ? CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
            : CVPixelBufferGetHeight(pixelBuffer);
        size_t rowBytes = CVPixelBufferIsPlanar(pixelBuffer)
            ? CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
            : CVPixelBufferGetBytesPerRow(pixelBuffer);
        size_t usefulBytes = CVPixelBufferIsPlanar(pixelBuffer)
            ? CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
            : CVPixelBufferGetWidth(pixelBuffer) * 4;
        if (base == NULL || rows == 0 || rowBytes == 0 || usefulBytes == 0) {
            continue;
        }
        if (usefulBytes > rowBytes) usefulBytes = rowBytes;
        for (size_t rowSample = 0; rowSample < 8; rowSample++) {
            size_t row = rows == 1 ? 0 : (rowSample * (rows - 1)) / 7;
            const uint8_t *line = base + row * rowBytes;
            for (size_t byteSample = 0; byteSample < 32; byteSample++) {
                size_t offset = usefulBytes == 1 ? 0
                    : (byteSample * (usefulBytes - 1)) / 31;
                uint8_t value = line[offset];
                hash ^= value;
                hash *= 1099511628211ULL;
                sum += value;
                if (value != 0) nonzero++;
                if (value < minimum) minimum = value;
                if (value > maximum) maximum = value;
                sampleCount++;
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    if (summaryOut != NULL && sampleCount != 0) {
        // low 16 bits: sampled mean; next bytes: min/max; high 32 bits:
        // sampled nonzero count. Video-range black (Y=16, UV=128) is thus
        // distinguishable from an all-zero or unwritten surface.
        uint64_t mean = sum / sampleCount;
        *summaryOut = (mean & 0xffffULL) |
            ((uint64_t)minimum << 16) |
            ((uint64_t)maximum << 24) |
            ((nonzero & 0xffffffffULL) << 32);
    }
    return hash;
}

static void VCAMPixelDiagnosticSetState(int *token, const char *name,
                                         uint64_t value) {
    if (*token < 0) notify_register_check(name, token);
    if (*token >= 0) notify_set_state(*token, value);
}

static void VCAMPublishPixelDiagnostics(CVPixelBufferRef sourceBuffer,
                                        CVPixelBufferRef stagingBuffer,
                                        CVPixelBufferRef targetBuffer) {
    uint64_t sourceSummary = 0;
    uint64_t stagingSummary = 0;
    uint64_t targetSummary = 0;
    uint64_t sourceSignature = VCAMPixelDiagnosticSignature(
        sourceBuffer, &sourceSummary);
    uint64_t stagingSignature = VCAMPixelDiagnosticSignature(
        stagingBuffer, &stagingSummary);
    uint64_t targetSignature = VCAMPixelDiagnosticSignature(
        targetBuffer, &targetSummary);
    static volatile uint64_t sequence = 0;
    uint64_t next = __sync_add_and_fetch(&sequence, 1);
    VCAMPixelDiagnosticSetState(&VCAMPixelDiagnosticSourceToken,
        "com.codex.vcam.ios18.production.source-sig.state", sourceSignature);
    VCAMPixelDiagnosticSetState(&VCAMPixelDiagnosticStagingToken,
        "com.codex.vcam.ios18.production.staging-sig.state", stagingSignature);
    VCAMPixelDiagnosticSetState(&VCAMPixelDiagnosticTargetToken,
        "com.codex.vcam.ios18.production.target-sig.state", targetSignature);
    VCAMPixelDiagnosticSetState(&VCAMPixelDiagnosticSourceSummaryToken,
        "com.codex.vcam.ios18.production.source-summary.state", sourceSummary);
    VCAMPixelDiagnosticSetState(&VCAMPixelDiagnosticStagingSummaryToken,
        "com.codex.vcam.ios18.production.staging-summary.state", stagingSummary);
    VCAMPixelDiagnosticSetState(&VCAMPixelDiagnosticTargetSummaryToken,
        "com.codex.vcam.ios18.production.target-summary.state", targetSummary);
    VCAMPixelDiagnosticSetState(&VCAMPixelDiagnosticSequenceToken,
        "com.codex.vcam.ios18.production.pixel-seq.state", next);
    notify_post("com.codex.vcam.ios18.production.pixels");
}

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

// Core Image can report a completed render while a software context cannot
// reliably write a graph-owned planar 420f/420v IOSurface on iOS 18. Render
// the replacement into a normal BGRA IOSurface first, then convert it into the
// original graph-owned target without replacing the graph's buffer contract.
static CVReturn VCAMCreatePlanarRenderBuffer(size_t width, size_t height,
                                             CVPixelBufferRef *bufferOut) {
    if (bufferOut == NULL || VCAMPixelTransferLock == nil) {
        return kCVReturnInvalidArgument;
    }
    *bufferOut = NULL;
    [VCAMPixelTransferLock lock];
    if (VCAMPlanarRenderPool == NULL ||
        VCAMPlanarRenderWidth != width ||
        VCAMPlanarRenderHeight != height) {
        CVPixelBufferPoolRef replacementPool = NULL;
        CVReturn poolStatus = VCAMCreateStagingPool(
            kCVPixelFormatType_32BGRA, width, height, &replacementPool);
        if (poolStatus != kCVReturnSuccess) {
            [VCAMPixelTransferLock unlock];
            return poolStatus;
        }
        if (VCAMPlanarRenderPool != NULL) {
            CVPixelBufferPoolRelease(VCAMPlanarRenderPool);
        }
        VCAMPlanarRenderPool = replacementPool;
        VCAMPlanarRenderWidth = width;
        VCAMPlanarRenderHeight = height;
    }
    CVReturn bufferStatus = CVPixelBufferPoolCreatePixelBuffer(
        kCFAllocatorDefault, VCAMPlanarRenderPool, bufferOut);
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

static BOOL VCAMReadConfiguredModeFromFile(BOOL *enabledOut) {
    if (enabledOut == NULL) return NO;
    int descriptor = open("/var/mobile/Media/VCAM/com.codex.vcam.plist", O_RDONLY);
    if (descriptor < 0) return NO;
    struct stat metadata = {0};
    if (fstat(descriptor, &metadata) != 0 || metadata.st_size <= 0 ||
        metadata.st_size > 1024 * 1024) {
        close(descriptor);
        return NO;
    }
    size_t capacity = (size_t)metadata.st_size;
    char *contents = calloc(capacity + 1, 1);
    if (contents == NULL) {
        close(descriptor);
        return NO;
    }
    size_t bytesRead = 0;
    while (bytesRead < capacity) {
        ssize_t result = read(descriptor, contents + bytesRead,
                              capacity - bytesRead);
        if (result < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (result == 0) break;
        bytesRead += (size_t)result;
    }
    close(descriptor);
    if (bytesRead != capacity) {
        free(contents);
        return NO;
    }

    // The configuration writer uses atomic XML plist writes. Parse only the
    // one scalar needed by mediaserverd so Foundation never parses a possibly
    // concurrent plist in the camera daemon.
    const char *key = strstr(contents, "<key>enabled</key>");
    const char *nextKey = key != NULL ? strstr(key + 1, "<key>") : NULL;
    const char *trueTag = key != NULL ? strstr(key, "<true") : NULL;
    const char *falseTag = key != NULL ? strstr(key, "<false") : NULL;
    const char *selected = NULL;
    BOOL enabled = NO;
    if (trueTag != NULL && (nextKey == NULL || trueTag < nextKey) &&
        (strncmp(trueTag, "<true/>", 7) == 0 ||
         strncmp(trueTag, "<true />", 8) == 0)) {
        selected = trueTag;
        enabled = YES;
    } else if (falseTag != NULL && (nextKey == NULL || falseTag < nextKey) &&
               (strncmp(falseTag, "<false/>", 8) == 0 ||
                strncmp(falseTag, "<false />", 9) == 0)) {
        selected = falseTag;
    }
    free(contents);
    if (selected == NULL) return NO;
    *enabledOut = enabled;
    return YES;
}

static void VCAMReloadConfiguredMode(void) {
    BOOL enabled = NO;
    if (VCAMReadConfiguredModeFromFile(&enabled)) {
        (void)__sync_lock_test_and_set(&VCAMConfiguredMode, enabled ? 1 : 0);
    } else {
        static dispatch_once_t invalidConfigurationToken;
        dispatch_once(&invalidConfigurationToken, ^{
            VCAMRefLog("configuration unreadable; retaining last virtual-camera mode");
        });
    }
}

static void VCAMPreferencesChanged(__unused CFNotificationCenterRef center,
                                   __unused void *observer,
                                   __unused CFStringRef name,
                                   __unused const void *object,
                                   __unused CFDictionaryRef userInfo) {
    VCAMReloadConfiguredMode();
}

// Darwin notification registration hashes the observer identity inside
// CoreFoundation. The iOS 18 arm64e implementation expects that identity to
// be a real CF/ObjC object; NULL and an address of arbitrary static storage
// both trigger a pointer-authentication trap while cameracaptured initializes.
// A CFSTR has process lifetime and is never released, which makes it a stable
// observer identity without adding an Objective-C allocation to this hook.
static CFStringRef VCAMPreferencesObserverToken =
    CFSTR("com.codex.vcam.preferences.observer");

static BOOL VCAMReadPublishedRequestedMode(BOOL *enabledOut) {
    if (enabledOut == NULL) return NO;
    if (VCAMVirtualModeStateToken < 0 &&
        notify_register_check("com.codex.vcam.ios18.virtual-mode.state",
                              &VCAMVirtualModeStateToken) != NOTIFY_STATUS_OK) {
        return NO;
    }
    if (VCAMVirtualModeStateReadyToken < 0 &&
        notify_register_check("com.codex.vcam.ios18.virtual-mode.ready.state",
                              &VCAMVirtualModeStateReadyToken) != NOTIFY_STATUS_OK) {
        return NO;
    }
    uint64_t ready = 0;
    uint64_t state = 0;
    if (VCAMVirtualModeStateReadyToken < 0 ||
        notify_get_state(VCAMVirtualModeStateReadyToken, &ready) != NOTIFY_STATUS_OK ||
        ready == 0 || VCAMVirtualModeStateToken < 0 ||
        notify_get_state(VCAMVirtualModeStateToken, &state) != NOTIFY_STATUS_OK) {
        return NO;
    }
    *enabledOut = state != 0;
    return YES;
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
    static uint64_t processStartToken;
    if (processStartToken == 0) {
        processStartToken = VCAMProcessStartToken(getpid());
    }
    snprintf(line, sizeof(line), "[%d][start=%llu][%s.%03d] %s\n", getpid(),
             (unsigned long long)processStartToken, stamp,
             (int)(value.tv_usec / 1000), message != NULL ? message : "(null)");
    // cameracaptured sandbox blocks /var/tmp; try several writable candidates
    // in order so the iOS18 daemon can emit its signature/proof log.
    static const char *candidatePaths[] = {
        "/var/mobile/Media/VCAM/vcam-ref.log",
        "/var/mobile/Library/Caches/vcam-ref.log",
        "/var/log/vcam-ref.log",
        "/tmp/vcam-ref.log",
        "/var/tmp/vcam-ref-msd.log",
        NULL,
    };
    for (int index = 0; candidatePaths[index] != NULL; index++) {
        int descriptor = open(candidatePaths[index], O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (descriptor < 0) continue;
        if (flock(descriptor, LOCK_EX) == 0) {
            struct stat metadata = {0};
            if (fstat(descriptor, &metadata) == 0 &&
                metadata.st_size > 4 * 1024 * 1024) {
                (void)ftruncate(descriptor, 0);
            }
            (void)write(descriptor, line, strlen(line));
            (void)flock(descriptor, LOCK_UN);
        }
        close(descriptor);
        break;
    }
}

void loadReplacementMedia(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        VCAMReader = VCAMSharedFrameReaderCreate();
        VCAMSurfaceReader = VCAMSharedSurfaceReaderCreate();
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        notify_post(device != nil
            ? "com.codex.vcam.ios18.metal"
            : "com.codex.vcam.ios18.metalnil");
        // ponytail: cameracaptured Metal render hangs; force software renderer.
        VCAMContext = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @YES}];
        VCAMStandardColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        VCAMReaderLock = [NSLock new];
        VCAMPixelTransferLock = [NSLock new];
        CVReturn result = VCAMCreateStagingPool(
            kCVPixelFormatType_32BGRA,
            VCAMSharedFrameWidth, VCAMSharedFrameHeight, &VCAMScratchPool);
        (void)VCAMCreateStagingPool(
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            VCAMSharedFrameWidth, VCAMSharedFrameHeight, &VCAMNV12ScratchPool);
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
            CFNotificationCenterGetDarwinNotifyCenter(),
            VCAMPreferencesObserverToken,
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
    BOOL publishedActive = NO;
    if (VCAMReadPublishedRequestedMode(&publishedActive)) {
        return publishedActive;
    }
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
    // The compositor explicitly converts shared content to Rec.709. Reusing the
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

static uint8_t VCAMClampByte(int value) {
    if (value < 0) return 0;
    if (value > 255) return 255;
    return (uint8_t)value;
}

static void VCAMConvertBGRARec709(const uint8_t *pixel, BOOL fullRange,
                                  uint8_t *yOut, int *uOut, int *vOut) {
    int red = pixel[2];
    int green = pixel[1];
    int blue = pixel[0];
    if (fullRange) {
        *yOut = VCAMClampByte((54 * red + 183 * green + 19 * blue + 128) >> 8);
        *uOut = ((-29 * red - 99 * green + 128 * blue + 128) >> 8) + 128;
        *vOut = ((128 * red - 116 * green - 12 * blue + 128) >> 8) + 128;
    } else {
        *yOut = VCAMClampByte(
            ((47 * red + 157 * green + 16 * blue + 128) >> 8) + 16);
        *uOut = ((-26 * red - 87 * green + 112 * blue + 128) >> 8) + 128;
        *vOut = ((112 * red - 102 * green - 10 * blue + 128) >> 8) + 128;
    }
}

static BOOL VCAMCopyBGRAToPlanarTarget(CVPixelBufferRef stagingBuffer,
                                       CVPixelBufferRef targetBuffer) {
    if (stagingBuffer == NULL || targetBuffer == NULL ||
        CVPixelBufferGetPixelFormatType(stagingBuffer) != kCVPixelFormatType_32BGRA ||
        !CVPixelBufferIsPlanar(targetBuffer) ||
        CVPixelBufferGetPlaneCount(targetBuffer) != 2 ||
        (CVPixelBufferGetPixelFormatType(targetBuffer) !=
             kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
         CVPixelBufferGetPixelFormatType(targetBuffer) !=
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) ||
        CVPixelBufferGetWidth(stagingBuffer) != CVPixelBufferGetWidth(targetBuffer) ||
        CVPixelBufferGetHeight(stagingBuffer) != CVPixelBufferGetHeight(targetBuffer)) {
        return NO;
    }

    size_t width = CVPixelBufferGetWidth(targetBuffer);
    size_t height = CVPixelBufferGetHeight(targetBuffer);
    if ((width & 1) != 0 || (height & 1) != 0 ||
        CVPixelBufferGetBytesPerRow(stagingBuffer) < width * 4 ||
        CVPixelBufferGetBytesPerRowOfPlane(targetBuffer, 0) < width ||
        CVPixelBufferGetBytesPerRowOfPlane(targetBuffer, 1) < width) {
        return NO;
    }

    CVReturn sourceLockStatus = CVPixelBufferLockBaseAddress(
        stagingBuffer, kCVPixelBufferLock_ReadOnly);
    if (sourceLockStatus != kCVReturnSuccess) return NO;
    IOSurfaceRef targetSurface = CVPixelBufferGetIOSurface(targetBuffer);
    BOOL targetSurfaceLocked = targetSurface != NULL &&
        IOSurfaceLock(targetSurface, 0, NULL) == 0;
    CVReturn targetLockStatus = targetSurfaceLocked
        ? kCVReturnSuccess : CVPixelBufferLockBaseAddress(targetBuffer, 0);
    if (targetLockStatus != kCVReturnSuccess) {
        CVPixelBufferUnlockBaseAddress(stagingBuffer, kCVPixelBufferLock_ReadOnly);
        return NO;
    }

    uint8_t *sourceBase = CVPixelBufferGetBaseAddress(stagingBuffer);
    uint8_t *lumaBase = targetSurfaceLocked
        ? IOSurfaceGetBaseAddressOfPlane(targetSurface, 0)
        : CVPixelBufferGetBaseAddressOfPlane(targetBuffer, 0);
    uint8_t *chromaBase = targetSurfaceLocked
        ? IOSurfaceGetBaseAddressOfPlane(targetSurface, 1)
        : CVPixelBufferGetBaseAddressOfPlane(targetBuffer, 1);
    BOOL copied = sourceBase != NULL && lumaBase != NULL && chromaBase != NULL;
    BOOL fullRange = CVPixelBufferGetPixelFormatType(targetBuffer) ==
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    if (copied) {
        size_t sourceBytesPerRow = CVPixelBufferGetBytesPerRow(stagingBuffer);
        size_t lumaBytesPerRow = targetSurfaceLocked
            ? IOSurfaceGetBytesPerRowOfPlane(targetSurface, 0)
            : CVPixelBufferGetBytesPerRowOfPlane(targetBuffer, 0);
        size_t chromaBytesPerRow = targetSurfaceLocked
            ? IOSurfaceGetBytesPerRowOfPlane(targetSurface, 1)
            : CVPixelBufferGetBytesPerRowOfPlane(targetBuffer, 1);
        for (size_t row = 0; row < height; row++) {
            const uint8_t *sourceLine = sourceBase + row * sourceBytesPerRow;
            uint8_t *lumaLine = lumaBase + row * lumaBytesPerRow;
            for (size_t column = 0; column < width; column++) {
                uint8_t luma = 0;
                int unusedU = 0;
                int unusedV = 0;
                VCAMConvertBGRARec709(sourceLine + column * 4, fullRange,
                                      &luma, &unusedU, &unusedV);
                lumaLine[column] = luma;
            }
        }
        for (size_t row = 0; row < height; row += 2) {
            const uint8_t *sourceLine0 = sourceBase + row * sourceBytesPerRow;
            const uint8_t *sourceLine1 = sourceBase + (row + 1) * sourceBytesPerRow;
            uint8_t *chromaLine = chromaBase + (row / 2) * chromaBytesPerRow;
            for (size_t column = 0; column < width; column += 2) {
                int uSum = 0;
                int vSum = 0;
                for (size_t offset = 0; offset < 2; offset++) {
                    uint8_t unusedY = 0;
                    int u = 0;
                    int v = 0;
                    VCAMConvertBGRARec709(
                        sourceLine0 + (column + offset) * 4, fullRange,
                        &unusedY, &u, &v);
                    uSum += u;
                    vSum += v;
                    VCAMConvertBGRARec709(
                        sourceLine1 + (column + offset) * 4, fullRange,
                        &unusedY, &u, &v);
                    uSum += u;
                    vSum += v;
                }
                chromaLine[column] = VCAMClampByte((uSum + 2) / 4);
                chromaLine[column + 1] = VCAMClampByte((vSum + 2) / 4);
            }
        }
    }
    if (targetSurfaceLocked) {
        IOSurfaceUnlock(targetSurface, 0, NULL);
    } else {
        CVPixelBufferUnlockBaseAddress(targetBuffer, 0);
    }
    CVPixelBufferUnlockBaseAddress(stagingBuffer, kCVPixelBufferLock_ReadOnly);
    if (copied) VCAMSetStandardColorAttachments(targetBuffer);
    return copied;
}

static BOOL VCAMTransferBGRAIntoPlanarTarget(CVPixelBufferRef stagingBuffer,
                                              CVPixelBufferRef targetBuffer) {
    if (stagingBuffer == NULL || targetBuffer == NULL ||
        VCAMPixelTransferLock == nil) {
        return NO;
    }

    // On iOS 18, the graph-owned 420f/420v IOSurface can accept a successful
    // VideoToolbox transfer without exposing the written planes to the next
    // graph stage. Write the public two-plane formats directly first; retain
    // VideoToolbox only as a compatibility fallback for targets whose base
    // addresses are not CPU-accessible.
    if (VCAMCopyBGRAToPlanarTarget(stagingBuffer, targetBuffer)) {
        return YES;
    }
    if (VCAMPixelTransferSession == NULL) return NO;

    CVBufferRemoveAllAttachments(stagingBuffer);
    VCAMSetStandardColorAttachments(stagingBuffer);
    OSStatus transferStatus = kCVReturnUnsupported;
    if (@available(iOS 16.0, *)) {
        [VCAMPixelTransferLock lock];
        transferStatus = VTPixelTransferSessionTransferImage(
            (VTPixelTransferSessionRef)VCAMPixelTransferSession,
            stagingBuffer, targetBuffer);
        [VCAMPixelTransferLock unlock];
    }
    if (transferStatus != noErr) {
        static volatile int transferFailures = 0;
        int failureCount = __sync_add_and_fetch(&transferFailures, 1);
        if (failureCount <= 8 || failureCount % 300 == 0) {
            char message[224] = {0};
            snprintf(message, sizeof(message),
                     "planar BGRA pixel transfer failed count=%d status=%d format=%08x",
                     failureCount, (int)transferStatus,
                     CVPixelBufferGetPixelFormatType(targetBuffer));
            VCAMRefLog(message);
        }
        return NO;
    }
    VCAMSetStandardColorAttachments(targetBuffer);
    return YES;
}

BOOL VCAMCopyReplacementBufferIntoTarget(CVPixelBufferRef replacementBuffer,
                                         CVPixelBufferRef targetBuffer) {
    if (replacementBuffer == NULL || targetBuffer == NULL ||
        VCAMPixelTransferSession == NULL || VCAMPixelTransferLock == nil) {
        return NO;
    }
    if (CVPixelBufferGetWidth(replacementBuffer) != CVPixelBufferGetWidth(targetBuffer) ||
        CVPixelBufferGetHeight(replacementBuffer) != CVPixelBufferGetHeight(targetBuffer) ||
        CVPixelBufferGetPixelFormatType(replacementBuffer) !=
            CVPixelBufferGetPixelFormatType(targetBuffer)) {
        return NO;
    }

    [VCAMPixelTransferLock lock];
    OSStatus status = kCVReturnUnsupported;
    if (@available(iOS 16.0, *)) {
        // Keep the graph-owned target buffer and its attachments. Only the
        // pixels are transferred; no new CMSampleBuffer crosses the hook.
        status = VTPixelTransferSessionTransferImage(
            (VTPixelTransferSessionRef)VCAMPixelTransferSession,
            replacementBuffer, targetBuffer);
    }
    [VCAMPixelTransferLock unlock];
    if (status == noErr) return YES;

    static volatile int failures = 0;
    int failureCount = __sync_add_and_fetch(&failures, 1);
    if (failureCount <= 8 || failureCount % 300 == 0) {
        char message[224] = {0};
        snprintf(message, sizeof(message),
                 "in-place replacement transfer failed count=%d status=%d format=%08x",
                 failureCount, (int)status,
                 CVPixelBufferGetPixelFormatType(targetBuffer));
        VCAMRefLog(message);
    }
    return NO;
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
    BOOL planarTarget = !compressedTarget && CVPixelBufferIsPlanar(targetBuffer) &&
        (targetFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
         targetFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);
    if (compressedTarget && replacementBufferOut == NULL) return NO;
    CVPixelBufferRef scratch = NULL;
    CVPixelBufferRef stagingBuffer = NULL;
    CVPixelBufferRef compressedReplacementBuffer = NULL;
    VCAMSharedFrameMetadata metadata = {0};
    VCAMSharedSurfaceFrame surfaceFrame = {0};
    BOOL readerLocked = NO;
    BOOL rendered = NO;
    CFAbsoluteTime elapsed = 0;
    static volatile int pixelDiagnosticFrames = 0;
    int pixelDiagnosticCount = __sync_add_and_fetch(&pixelDiagnosticFrames, 1);
    BOOL publishPixelDiagnostics = pixelDiagnosticCount <= 3 ||
        pixelDiagnosticCount % 30 == 0;
    @try {
        [VCAMReaderLock lock];
        readerLocked = YES;
        BOOL virtualModeEnabled = VCAMEffectiveVirtualModeIsEnabledLocked();
        if (!virtualModeEnabled) {
            static volatile int disabledLogs = 0;
            int disabledCount = __sync_add_and_fetch(&disabledLogs, 1);
            if (disabledCount <= 6) {
                VCAMRefLog("virtual mode disabled; passing real frame");
            }
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
            VCAMSharedFrameMetadata mmapFormatMetadata = {0};
            BOOL hasMmapFormat = VCAMSharedFrameReaderGetLatestMetadata(
                VCAMReader, 0, &mmapFormatMetadata);
            CVPixelBufferPoolRef scratchPool = VCAMScratchPool;
            if (hasMmapFormat &&
                (mmapFormatMetadata.pixelFormat ==
                     kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                 mmapFormatMetadata.pixelFormat ==
                     kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)) {
                scratchPool = VCAMNV12ScratchPool;
            }
            if (CVPixelBufferPoolCreatePixelBuffer(
                    kCFAllocatorDefault, scratchPool,
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
        } else if (planarTarget) {
            CVReturn stagingStatus = VCAMCreatePlanarRenderBuffer(
                targetWidth, targetHeight, &stagingBuffer);
            if (stagingStatus != kCVReturnSuccess || stagingBuffer == NULL) {
                static volatile int allocationFailures = 0;
                int failureCount = __sync_add_and_fetch(&allocationFailures, 1);
                if (failureCount <= 8 || failureCount % 300 == 0) {
                    char message[224] = {0};
                    snprintf(message, sizeof(message),
                             "planar BGRA render buffer allocation failed count=%d status=%d format=%08x",
                             failureCount, stagingStatus, targetFormat);
                    VCAMRefLog(message);
                }
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
        // Still-photo fill renders the landscape camera basis with canonical
        // portrait pixels: rotate left in place and let the caller mark the
        // final sample Orientation=Right so Photos shows a portrait 3:4 image.
        if (!realtimeCompensation && /* sourceIsPortrait always YES */ YES &&
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
        rendered = coreImageRendered &&
            (compressedTarget
                ? VCAMTransferIntoCompressedTarget(
                    stagingBuffer, targetBuffer, compressedReplacementBuffer)
                : (!planarTarget || VCAMTransferBGRAIntoPlanarTarget(
                    stagingBuffer, targetBuffer)));
        if (rendered && publishPixelDiagnostics) {
            VCAMPublishPixelDiagnostics(
                scratch, renderBuffer,
                compressedTarget ? compressedReplacementBuffer : targetBuffer);
        }
        // This notification is the production success boundary: it is emitted
        // only after the final planar/compressed target write has succeeded.
        notify_post(rendered
            ? "com.codex.vcam.ios18.rendered"
            : "com.codex.vcam.ios18.renderfail");
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

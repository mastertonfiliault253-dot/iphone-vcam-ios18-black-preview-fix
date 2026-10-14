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
#include <math.h>
#include <notify.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

// The iPhoneOS 16.5 SDK exposes IOSurface-backed CVPixelBuffers through
// CoreVideo but does not ship the IOSurface framework header. Keep the small
// byte-surface ABI local, as the shared-surface implementation does.
extern int32_t IOSurfaceLock(IOSurfaceRef surface, uint32_t options,
                             uint32_t *seed);
extern int32_t IOSurfaceUnlock(IOSurfaceRef surface, uint32_t options,
                               uint32_t *seed);
extern void *IOSurfaceGetBaseAddress(IOSurfaceRef surface);
extern size_t IOSurfaceGetBytesPerRow(IOSurfaceRef surface);

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
static CVPixelBufferPoolRef VCAMCPUBGRAScratchPool;
static size_t VCAMCPUBGRAScratchWidth;
static size_t VCAMCPUBGRAScratchHeight;
static CVPixelBufferPoolRef VCAMLocalSourcePool;
static size_t VCAMLocalSourceWidth;
static size_t VCAMLocalSourceHeight;
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
// metalRenderer 配置生效且探针渲染通过时才为 1；任何真实帧失败即永久回退 0。
static volatile int32_t VCAMMetalContextActive = 0;
static CGColorSpaceRef VCAMStandardColorSpace;
static NSLock *VCAMReaderLock;
static NSLock *VCAMPixelTransferLock;
static NSLock *VCAMPreviewCacheLock;
static CVPixelBufferRef VCAMPreviewCacheBuffer;
static uint64_t VCAMPreviewCacheSequence;
static uint64_t VCAMPreviewCacheGeneration;
static size_t VCAMPreviewCacheWidth;
static size_t VCAMPreviewCacheHeight;
static OSType VCAMPreviewCacheFormat;
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
// The physical source node is emitted before its converter fan-out. Keep only
// its lens position so the explicit WebKit presentation can cancel the
// consumer's front-camera mirror without changing routing or graph contracts.
static volatile int VCAMCurrentCameraIsFront = 0;

// 前/后摄像头切换=物理设备切换：AE/torch 观测与基线必须作废（前置无硬件
// torch、前后曝光量程不同，跨设备复用基线会产生错误增益）。实现见 AE 观测段。

void VCAMSetLastCameraIsFront(BOOL isFront) {
    int value = isFront ? 1 : 0;
    int previous = __sync_lock_test_and_set(&VCAMCurrentCameraIsFront, value);
    if (previous != value) VCAMResetObservedPhysicalState();
}

BOOL VCAMLastCameraIsFront(void) {
    return __sync_fetch_and_add(&VCAMCurrentCameraIsFront, 0) != 0;
}

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
static int VCAMPixelDiagnosticDirectStatusToken = -1;
static int VCAMPixelDiagnosticDirectBeforeToken = -1;
static int VCAMPixelDiagnosticDirectAfterToken = -1;
static int VCAMPixelDiagnosticDirectRelockToken = -1;
static int VCAMPixelDiagnosticDirectSurfaceToken = -1;
static int VCAMPixelDiagnosticDirectLumaAddressToken = -1;
static int VCAMPixelDiagnosticDirectChromaAddressToken = -1;
static int VCAMDebug6F2CFallbackStateToken = -1;
static int VCAMDebug6F2CSurfaceRGBToken = -1;
static int VCAMDebug6F2CMmapRGBToken = -1;
static int VCAMDebug6F2CSurfaceGenerationToken = -1;
static int VCAMDebug6F2CMmapGenerationToken = -1;
static int VCAMDebug6F2CSourceStateToken = -1;

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

static BOOL VCAMPixelBufferHasRGBContent(CVPixelBufferRef pixelBuffer) {
    if (pixelBuffer == NULL || CVPixelBufferIsPlanar(pixelBuffer) ||
        CVPixelBufferGetPixelFormatType(pixelBuffer) !=
            kCVPixelFormatType_32BGRA ||
        CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly) !=
            kCVReturnSuccess) return NO;
    const uint8_t *base = (const uint8_t *)CVPixelBufferGetBaseAddress(pixelBuffer);
    size_t width = CVPixelBufferGetWidth(pixelBuffer);
    size_t height = CVPixelBufferGetHeight(pixelBuffer);
    size_t rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer);
    BOOL hasContent = NO;
    if (base != NULL && width > 0 && height > 0 && rowBytes >= width * 4) {
        for (size_t rowSample = 0; rowSample < 8 && !hasContent; rowSample++) {
            size_t row = height == 1 ? 0 : (rowSample * (height - 1)) / 7;
            const uint8_t *line = base + row * rowBytes;
            for (size_t pixelSample = 0; pixelSample < 32; pixelSample++) {
                size_t pixel = width == 1 ? 0
                    : (pixelSample * (width - 1)) / 31;
                const uint8_t *rgba = line + pixel * 4;
                if (rgba[0] != 0 || rgba[1] != 0 || rgba[2] != 0) {
                    hasContent = YES;
                    break;
                }
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    return hasContent;
}

// [DEBUG-6f2c] Pack an aligned 8x32 BGRA sample without exporting pixels.
// low16=nonzero RGB pixels, next16=RGB max >= 16, next16=mean RGB max,
// next8=min RGB max, high8=max RGB max. The boolean return distinguishes an
// unreadable buffer from a valid all-black summary of zero.
static BOOL VCAMDebug6F2CRGBCoverageSummary(CVPixelBufferRef pixelBuffer,
                                            uint64_t *summaryOut) {
    if (summaryOut == NULL) return NO;
    *summaryOut = 0;
    if (pixelBuffer == NULL || CVPixelBufferIsPlanar(pixelBuffer) ||
        CVPixelBufferGetPixelFormatType(pixelBuffer) !=
            kCVPixelFormatType_32BGRA ||
        CVPixelBufferLockBaseAddress(pixelBuffer,
                                     kCVPixelBufferLock_ReadOnly) !=
            kCVReturnSuccess) return NO;
    const uint8_t *base =
        (const uint8_t *)CVPixelBufferGetBaseAddress(pixelBuffer);
    size_t width = CVPixelBufferGetWidth(pixelBuffer);
    size_t height = CVPixelBufferGetHeight(pixelBuffer);
    size_t rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer);
    uint64_t active = 0;
    uint64_t strong = 0;
    uint64_t intensitySum = 0;
    uint64_t sampleCount = 0;
    uint8_t minimum = 255;
    uint8_t maximum = 0;
    BOOL valid = base != NULL && width > 0 && height > 0 &&
        rowBytes >= width * 4;
    if (valid) {
        for (size_t rowSample = 0; rowSample < 8; rowSample++) {
            size_t row = height == 1 ? 0
                : (rowSample * (height - 1)) / 7;
            const uint8_t *line = base + row * rowBytes;
            for (size_t pixelSample = 0; pixelSample < 32; pixelSample++) {
                size_t pixel = width == 1 ? 0
                    : (pixelSample * (width - 1)) / 31;
                const uint8_t *bgra = line + pixel * 4;
                uint8_t intensity = MAX(bgra[0], MAX(bgra[1], bgra[2]));
                if (intensity != 0) active++;
                if (intensity >= 16) strong++;
                intensitySum += intensity;
                if (intensity < minimum) minimum = intensity;
                if (intensity > maximum) maximum = intensity;
                sampleCount++;
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer,
                                   kCVPixelBufferLock_ReadOnly);
    if (!valid || sampleCount == 0) return NO;
    uint64_t mean = intensitySum / sampleCount;
    *summaryOut = (active & 0xffffULL) |
        ((strong & 0xffffULL) << 16) |
        ((mean & 0xffffULL) << 32) |
        ((uint64_t)minimum << 48) |
        ((uint64_t)maximum << 56);
    return YES;
}

static void VCAMPixelDiagnosticSetState(int *token, const char *name,
                                         uint64_t value) {
    if (*token < 0) notify_register_check(name, token);
    if (*token >= 0) notify_set_state(*token, value);
}

static void VCAMDebug6F2CPublishRGBGateDiagnostics(
    uint64_t fallbackState, uint64_t surfaceRGB, uint64_t mmapRGB,
    uint64_t surfaceGeneration, uint64_t mmapGeneration,
    uint64_t sourceState) {
    VCAMPixelDiagnosticSetState(&VCAMDebug6F2CFallbackStateToken,
        "com.codex.vcam.ios18.debug-6f2c.fallback-state", fallbackState);
    VCAMPixelDiagnosticSetState(&VCAMDebug6F2CSurfaceRGBToken,
        "com.codex.vcam.ios18.debug-6f2c.surface-rgb", surfaceRGB);
    VCAMPixelDiagnosticSetState(&VCAMDebug6F2CMmapRGBToken,
        "com.codex.vcam.ios18.debug-6f2c.mmap-rgb", mmapRGB);
    VCAMPixelDiagnosticSetState(&VCAMDebug6F2CSurfaceGenerationToken,
        "com.codex.vcam.ios18.debug-6f2c.surface-generation",
        surfaceGeneration);
    VCAMPixelDiagnosticSetState(&VCAMDebug6F2CMmapGenerationToken,
        "com.codex.vcam.ios18.debug-6f2c.mmap-generation",
        mmapGeneration);
    VCAMPixelDiagnosticSetState(&VCAMDebug6F2CSourceStateToken,
        "com.codex.vcam.ios18.debug-6f2c.source-state", sourceState);
}

// Four bytes are enough to compare the same two planes at the top-left and
// center samples without copying image data out of cameracaptured:
// y(0,0), y(center), uv(0,0), uv(center). The values are deliberately kept as
// separate notify states so the listener can report the exact transition.
static uint64_t VCAMPackDirectSamples(uint8_t topLuma, uint8_t centerLuma,
                                      uint8_t topChroma, uint8_t centerChroma) {
    return (uint64_t)topLuma |
        ((uint64_t)centerLuma << 8) |
        ((uint64_t)topChroma << 16) |
        ((uint64_t)centerChroma << 24);
}

static void VCAMPublishDirectWriteDiagnostics(
    BOOL copied, BOOL targetSurfaceLocked, uint8_t beforeTopLuma,
    uint8_t beforeCenterLuma, uint8_t beforeTopChroma,
    uint8_t beforeCenterChroma, uint8_t afterTopLuma,
    uint8_t afterCenterLuma, uint8_t afterTopChroma,
    uint8_t afterCenterChroma, uint8_t relockTopLuma,
    uint8_t relockCenterLuma, uint8_t relockTopChroma,
    uint8_t relockCenterChroma, IOSurfaceRef targetSurface,
    uint8_t *lumaBase, uint8_t *chromaBase) {
    uint64_t status = (copied ? 1ULL : 0ULL) |
        (targetSurfaceLocked ? 2ULL : 0ULL);
    VCAMPixelDiagnosticSetState(
        &VCAMPixelDiagnosticDirectStatusToken,
        "com.codex.vcam.ios18.production.direct-write-status.state", status);
    VCAMPixelDiagnosticSetState(
        &VCAMPixelDiagnosticDirectBeforeToken,
        "com.codex.vcam.ios18.production.direct-write-before.state",
        VCAMPackDirectSamples(beforeTopLuma, beforeCenterLuma,
                              beforeTopChroma, beforeCenterChroma));
    VCAMPixelDiagnosticSetState(
        &VCAMPixelDiagnosticDirectAfterToken,
        "com.codex.vcam.ios18.production.direct-write-after.state",
        VCAMPackDirectSamples(afterTopLuma, afterCenterLuma,
                              afterTopChroma, afterCenterChroma));
    VCAMPixelDiagnosticSetState(
        &VCAMPixelDiagnosticDirectRelockToken,
        "com.codex.vcam.ios18.production.direct-write-relock.state",
        VCAMPackDirectSamples(relockTopLuma, relockCenterLuma,
                              relockTopChroma, relockCenterChroma));
    VCAMPixelDiagnosticSetState(
        &VCAMPixelDiagnosticDirectSurfaceToken,
        "com.codex.vcam.ios18.production.direct-write-surface.state",
        targetSurface == NULL ? 0 : (uint64_t)IOSurfaceGetID(targetSurface));
    VCAMPixelDiagnosticSetState(
        &VCAMPixelDiagnosticDirectLumaAddressToken,
        "com.codex.vcam.ios18.production.direct-write-luma-addr.state",
        (uint64_t)(uintptr_t)lumaBase);
    VCAMPixelDiagnosticSetState(
        &VCAMPixelDiagnosticDirectChromaAddressToken,
        "com.codex.vcam.ios18.production.direct-write-chroma-addr.state",
        (uint64_t)(uintptr_t)chromaBase);
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
        format == (OSType)0x26786630 || // iOS 16.1 deferred photo '&xf0'
        format == (OSType)0x70663230;   // iOS 18.3.1 still photo 'pf20'
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

static void VCAMRecordPreviewPerformance(BOOL cacheHit, BOOL fullRender,
                                         double elapsedMilliseconds) {
    static double durations[120] = {0};
    static NSUInteger count = 0;
    static NSUInteger cacheHits = 0;
    static NSUInteger renders = 0;
    BOOL report = NO;
    double p50 = 0;
    double p95 = 0;
    double maximum = 0;
    NSUInteger reportHits = 0;
    NSUInteger reportRenders = 0;
    @synchronized (VCAMContext) {
        durations[count++] = elapsedMilliseconds;
        if (cacheHit) cacheHits++;
        if (fullRender) renders++;
        if (count == 120) {
            qsort(durations, count, sizeof(durations[0]),
                  VCAMCompareRenderMilliseconds);
            p50 = durations[59];
            p95 = durations[113];
            maximum = durations[119];
            reportHits = cacheHits;
            reportRenders = renders;
            count = 0;
            cacheHits = 0;
            renders = 0;
            report = YES;
        }
    }
    if (report) {
        char metrics[256] = {0};
        snprintf(metrics, sizeof(metrics),
                 "preview replacement performance window count=120 cacheHits=%lu renders=%lu p50Ms=%.2f p95Ms=%.2f maxMs=%.2f",
                 (unsigned long)reportHits, (unsigned long)reportRenders,
                 p50, p95, maximum);
        VCAMRefLog(metrics);
    }
}

// 设备没有 top/ps CPU（实测该 ps 的 TIME 列恒 0、无 top/pmset），getrusage
// 自测是唯一可靠的 CPU 来源。60s 窗口自报：替换链 CPU 成本=本进程 CPU 时间
// 增量/窗长。每帧一次 syscall（微秒级），只在虚拟模式开启的渲染路径调用。
// 用于渲染路径改动（如 metalRenderer）前后对比；日志行以 "self-cpu window" 开头。
static void VCAMSampleSelfCPUWindow(void) {
    static int64_t windowStartMs = 0;
    static double windowStartCPUSeconds = 0.0;
    struct rusage usage;
    if (getrusage(RUSAGE_SELF, &usage) != 0) return;
    double cpuSeconds = (double)usage.ru_utime.tv_sec + (double)usage.ru_utime.tv_usec / 1e6 +
                        (double)usage.ru_stime.tv_sec + (double)usage.ru_stime.tv_usec / 1e6;
    int64_t nowMs = (int64_t)(CFAbsoluteTimeGetCurrent() * 1000.0);
    if (windowStartMs == 0) {
        windowStartMs = nowMs;
        windowStartCPUSeconds = cpuSeconds;
        return;
    }
    if (nowMs - windowStartMs < 60000) return;
    double elapsedSeconds = (double)(nowMs - windowStartMs) / 1000.0;
    double cpuDelta = cpuSeconds - windowStartCPUSeconds;
    char metrics[192];
    snprintf(metrics, sizeof(metrics),
             "self-cpu window elapsedS=%.0f cpuS=%.1f pct=%.1f",
             elapsedSeconds, cpuDelta, elapsedSeconds > 0 ? 100.0 * cpuDelta / elapsedSeconds : 0.0);
    VCAMRefLog(metrics);
    windowStartMs = nowMs;
    windowStartCPUSeconds = cpuSeconds;
}

// A same-generation mmap bootstrap is already process-local data. Do not put
// it back into an IOSurface-backed pool: on iOS 18 that can re-enter the same
// stale/black CPU mapping that made the imported surface unusable. Omitting
// IOSurfaceProperties keeps this hand-off in ordinary CoreVideo-owned memory.
static CVReturn VCAMCreateCPUReadableBGRABuffer(
    size_t width, size_t height, CVPixelBufferRef *bufferOut) {
    if (bufferOut == NULL || VCAMPixelTransferLock == nil ||
        width == 0 || height == 0) return kCVReturnInvalidArgument;
    *bufferOut = NULL;
    [VCAMPixelTransferLock lock];
    if (VCAMCPUBGRAScratchPool == NULL ||
        VCAMCPUBGRAScratchWidth != width ||
        VCAMCPUBGRAScratchHeight != height) {
        NSDictionary *poolAttributes = @{
            (id)kCVPixelBufferPoolMinimumBufferCountKey: @2,
        };
        NSDictionary *pixelAttributes = @{
            (id)kCVPixelBufferPixelFormatTypeKey:
                @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferWidthKey: @(width),
            (id)kCVPixelBufferHeightKey: @(height),
        };
        CVPixelBufferPoolRef replacementPool = NULL;
        CVReturn poolStatus = CVPixelBufferPoolCreate(
            kCFAllocatorDefault, (__bridge CFDictionaryRef)poolAttributes,
            (__bridge CFDictionaryRef)pixelAttributes, &replacementPool);
        if (poolStatus != kCVReturnSuccess || replacementPool == NULL) {
            [VCAMPixelTransferLock unlock];
            return poolStatus;
        }
        if (VCAMCPUBGRAScratchPool != NULL) {
            CVPixelBufferPoolRelease(VCAMCPUBGRAScratchPool);
        }
        VCAMCPUBGRAScratchPool = replacementPool;
        VCAMCPUBGRAScratchWidth = width;
        VCAMCPUBGRAScratchHeight = height;
    }
    CVReturn bufferStatus = CVPixelBufferPoolCreatePixelBuffer(
        kCFAllocatorDefault, VCAMCPUBGRAScratchPool, bufferOut);
    [VCAMPixelTransferLock unlock];
    return bufferStatus;
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

// —— photoreal exposure coupling（检测点 #5：torch/AE ↔ 画面亮度一致性）——
// 三家真实 KYC SDK 都会打 torch 脉冲（docs/kyc/VCAM-DETECTION-POINTS-CHECKLIST-ZH.md），
// 真相机画面亮度会随之变化；替换画面必须做同方向响应，否则"闪光活体"直接穿帮。
// 状态源现阶段来自配置注入（探针定量回路先行校准幅度），BW 图设备节点 hook
// 接入后由真实观测值覆盖（见 probe-app/cli_main.m bw 模式的符号发现）。
static volatile int32_t VCAMPhotorealEnabled = 1;      // photorealisticExposure
static volatile double VCAMPhotorealTorchLevel = 0.0;  // 0..1 注入/观测 torch 电平
static volatile int32_t VCAMMetadataBranchReplace = 0; // metadataBranch=replace
static volatile int32_t VCAMScreenTintEnabled = 0;     // screenTintEnabled（三色调光，缺省关）

// 与 VCAMReadConfiguredModeFromFile 相同的裸文本策略：只在偏好变化时低频调用，
// 不引入 Foundation 并发解析。返回 malloc 的文件全文（NUL 结尾），失败 NULL。
// 注意：cameracaptured 的沙箱不能读 /var/mobile/Media/VCAM（既有
// "configuration unreadable" 行为即为此），所以配置源是偏好写入方镜像到
// cameracaptured 已获授权的 /var/mobile/Library/VirtualCaptureCard/VCAM/ 的副本
// （见 VCAMConfiguration 写盘后的镜像步骤）。
static char *VCAMCopyConfigFileContents(void) {
    int descriptor = open("/var/mobile/Library/VirtualCaptureCard/VCAM/com.codex.vcam.plist",
                          O_RDONLY);
    if (descriptor < 0) return NULL;
    struct stat metadata = {0};
    if (fstat(descriptor, &metadata) != 0 || metadata.st_size <= 0 ||
        metadata.st_size > 1024 * 1024) {
        close(descriptor);
        return NULL;
    }
    size_t capacity = (size_t)metadata.st_size;
    char *contents = calloc(capacity + 1, 1);
    if (contents == NULL) {
        close(descriptor);
        return NULL;
    }
    size_t bytesRead = 0;
    while (bytesRead < capacity) {
        ssize_t result = read(descriptor, contents + bytesRead, capacity - bytesRead);
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
        return NULL;
    }
    return contents;
}

// 返回该 key 的值段（下一个 <key> 之前），找不到返回 NULL。
static const char *VCAMConfigValueSegment(const char *contents, const char *key,
                                          const char **endOut) {
    char keyTag[192];
    snprintf(keyTag, sizeof(keyTag), "<key>%s</key>", key);
    const char *start = strstr(contents, keyTag);
    if (start == NULL) return NULL;
    start += strlen(keyTag);
    const char *end = strstr(start, "<key>");
    *endOut = end != NULL ? end : contents + strlen(contents);
    return start;
}

// 路线 A 的真实 torch 观测：BWFigVideoCaptureDevice setTorchLevel: hook 注入。
// 观测值带新鲜度窗口（5s）：窗口内以真实观测驱动增益，窗口外回落到
// photorealTorchLevel 配置注入值（测试/校准回路）。
static volatile double VCAMObservedTorchLevel = -1.0;  // -1 = 从未观测
static volatile int64_t VCAMObservedTorchTimeMs = 0;

// 把 photoreal 状态发布到 notifyd：App 沙箱读不到任何文件通道，探针靠它
// 对表（VCAMDetectProbe observedPhotoreal）。编码 state = round(level*1000)<<1 | enabled。
static void VCAMPublishPhotorealState(void) {
    static int stateToken = -1;
    if (stateToken < 0 &&
        notify_register_check("com.codex.vcam.ios18.photoreal.state", &stateToken) !=
            NOTIFY_STATUS_OK) {
        return;
    }
    double effective = VCAMPhotorealTorchLevel;
    double observed = VCAMObservedTorchLevel;
    int64_t nowMs = (int64_t)(CFAbsoluteTimeGetCurrent() * 1000.0);
    if (observed >= 0 && nowMs - VCAMObservedTorchTimeMs <= 5000) {
        effective = observed;
    }
    uint64_t encoded = ((uint64_t)(effective * 1000.0 + 0.5) << 1) |
                       (uint64_t)(VCAMPhotorealEnabled != 0);
    notify_set_state(stateToken, encoded);
}

void VCAMSetObservedTorchLevel(double level) {
    if (level < 0) level = 0;
    if (level > 1) level = 1;
    VCAMObservedTorchLevel = level;
    VCAMObservedTorchTimeMs = (int64_t)(CFAbsoluteTimeGetCurrent() * 1000.0);
    VCAMPublishPhotorealState();
}

// —— 路线 A-2：真实 AE 观测（P0 遗留项补齐：AE 元数据↔亮度全耦合）——
// 模型：传感器曝光量 = 曝光时长 × ISO，对最终成像亮度是乘性因子。
// 观测来源两条通道（Entry .xm）：显式控制路径（setExposureModeCustom...ISO:
// setter，KYC App 常用固定曝光时直接命中）与数据路径（输出 sample buffer
// 的 attachment，auto-AE 内部环路不经过 setter，只有 attachment 携带终值）。
// 增益侧用 20s EMA 基线归一：缓慢的 AE 漂移按同速率复现，避免阶跃。
static volatile double VCAMObservedExposureDurationS = -1.0; // -1 = 从未观测
static volatile double VCAMObservedExposureISO = -1.0;
static volatile int64_t VCAMObservedExposureTimeMs = 0;
static volatile double VCAMObservedExposureBiasEV = 0.0;

void VCAMSetObservedExposure(double durationSeconds, double iso) {
    // 数值防御：时长合理区间 (0,1]s、ISO>0；异常值直接丢弃不污染基线。
    if (!(durationSeconds > 0.0 && durationSeconds <= 1.0) || !(iso > 0.0)) return;
    VCAMObservedExposureDurationS = durationSeconds;
    VCAMObservedExposureISO = iso;
    VCAMObservedExposureTimeMs = (int64_t)(CFAbsoluteTimeGetCurrent() * 1000.0);
}

void VCAMSetObservedExposureBias(double biasEV) {
    if (!(biasEV >= -8.0 && biasEV <= 8.0)) return;
    VCAMObservedExposureBiasEV = biasEV;
}

// 曝光增益的 EMA 基线（文件级：前后面切换/设备实例切换时需要作废）。
static volatile double VCAMExposureBaselineIndex = 0.0;  // 0 = 未初始化
static volatile int64_t VCAMExposureBaselineLastApplyMs = 0;

// 观测状态作废：物理设备变了（前后摄像头切换、或 BW 设备实例更换）。
// torch 观测同样作废——前置的"闪光"活体是屏幕闪光，走屏幕采样通道，
// 不应把后置 torch 状态带进前置会话（反之亦然）。
void VCAMResetObservedPhysicalState(void) {
    VCAMObservedExposureDurationS = -1.0;
    VCAMObservedExposureISO = -1.0;
    VCAMObservedExposureTimeMs = 0;
    VCAMObservedExposureBiasEV = 0.0;
    VCAMExposureBaselineIndex = 0.0;
    VCAMExposureBaselineLastApplyMs = 0;
    VCAMObservedTorchLevel = -1.0;
    VCAMObservedTorchTimeMs = 0;
}

static void VCAMReloadPhotorealAndBranchConfig(void) {
    int32_t enabled = 1;      // 缺省开启：目标就是画面跟随真实相机物理状态
    double level = 0.0;
    int32_t branch = 0;       // metadataBranch 缺省 passthrough（保持既有 QR 行为）
    int32_t tint = 0;         // screenTintEnabled 缺省关：新特性先经真机验证再开
    char *contents = VCAMCopyConfigFileContents();
    if (contents != NULL) {
        const char *end = NULL;
        const char *segment = VCAMConfigValueSegment(contents, "photorealisticExposure", &end);
        if (segment != NULL) {
            enabled = strstr(segment, "<true") != NULL ? 1 : 0;
        }
        segment = VCAMConfigValueSegment(contents, "photorealTorchLevel", &end);
        if (segment != NULL) {
            const char *realTag = strstr(segment, "<real");
            if (realTag != NULL) {
                const char *valueStart = strchr(realTag, '>');
                if (valueStart != NULL && valueStart < end) {
                    level = strtod(valueStart + 1, NULL);
                    if (level < 0) level = 0;
                    if (level > 1) level = 1;
                }
            }
        }
        segment = VCAMConfigValueSegment(contents, "metadataBranch", &end);
        if (segment != NULL && strstr(segment, "<string>replace") != NULL) {
            branch = 1;
        }
        segment = VCAMConfigValueSegment(contents, "screenTintEnabled", &end);
        if (segment != NULL) {
            tint = strstr(segment, "<true") != NULL ? 1 : 0;
        }
        free(contents);
    }
    (void)__sync_lock_test_and_set(&VCAMPhotorealEnabled, enabled);
    VCAMPhotorealTorchLevel = level;
    (void)__sync_lock_test_and_set(&VCAMMetadataBranchReplace, branch);
    (void)__sync_lock_test_and_set(&VCAMScreenTintEnabled, tint);
    char message[160];
    snprintf(message, sizeof(message),
             "photoreal config photoreal=%d torch_level=%.2f metadata_replace=%d screen_tint=%d",
             (int)enabled, level, (int)branch, (int)tint);
    VCAMRefLog(message);
    VCAMPublishPhotorealState();
}

int VCAMMetadataBranchReplaceEnabled(void) {
    return VCAMMetadataBranchReplace != 0;
}

BOOL VCAMPhotorealCouplingEnabled(void) {
    return VCAMPhotorealEnabled != 0;
}

// —— metalRenderer 配置（性能实验开关，缺省 0=软件渲染保持既有行为）——
// 只在进程初始化时读一次（CIContext 生命周期=进程）；改动需重启
// cameracaptured 生效。与 photoreal 同一镜像配置通道、同一裸文本解析策略。
static int VCAMConfiguredMetalRendererRequested(void) {
    int requested = 0;
    char *contents = VCAMCopyConfigFileContents();
    if (contents != NULL) {
        const char *end = NULL;
        const char *segment = VCAMConfigValueSegment(contents, "metalRenderer", &end);
        if (segment != NULL) {
            const char *integerTag = strstr(segment, "<integer>");
            if (integerTag != NULL && integerTag < end) {
                requested = atoi(integerTag + strlen("<integer>")) != 0 ? 1 : 0;
            }
        }
        free(contents);
    }
    return requested;
}

// Metal 上下文探针验证：8x8 小图渲染在独立队列等待，2.5s 封顶（16.5 SDK 无
// CIContext contextWithMetalDevice: 选择器，用 UseSoftwareRenderer=NO 表达 GPU
// 上下文；CIRenderTask 无 cancel，超时即弃用该上下文——探针线程滞留一次无碍，
// 进程级不采用即可）。通过才返回可用上下文，帧路径不会遇到未验证的 Metal
// 上下文（ponytail 挂起事故的正确性边界）。
static CIContext *VCAMCreateProbedMetalContext(id<MTLDevice> device) {
    (void)device;
    CIContext *candidate =
        [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}];
    if (candidate == nil) return nil;
    CVPixelBufferRef probeBuffer = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, 8, 8, kCVPixelFormatType_32BGRA,
                            NULL, &probeBuffer) != kCVReturnSuccess) {
        return nil;
    }
    __block CIRenderTask *task = nil;
    @try {
        CIImage *probeImage = [[CIImage imageWithColor:CIColor.whiteColor]
            imageByCroppingToRect:CGRectMake(0, 0, 8, 8)];
        CIRenderDestination *destination =
            [[CIRenderDestination alloc] initWithPixelBuffer:probeBuffer];
        task = [candidate startTaskToRender:probeImage fromRect:probeImage.extent
                              toDestination:destination atPoint:CGPointZero error:NULL];
    } @catch (NSException *exception) {
        CVPixelBufferRelease(probeBuffer);
        return nil;
    }
    __block BOOL completed = NO;
    if (task != nil) {
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSError *waitError = nil;
            BOOL ok = [task waitUntilCompletedAndReturnError:&waitError] != nil;
            dispatch_semaphore_signal(semaphore);
            if (ok) completed = YES;   // 写后 signal，读在 wait 返回之后，无竞争
        });
        if (dispatch_semaphore_wait(
                semaphore, dispatch_time(DISPATCH_TIME_NOW,
                                        (int64_t)(2.5 * NSEC_PER_SEC))) == 0 && completed) {
            completed = YES;
        }
    }
    CVPixelBufferRelease(probeBuffer);
    return completed ? candidate : nil;
}

// 状态快照低频导出：探针 native_probe 报告读它做 torch↔亮度一致性对表。
static void VCAMEmitPhotorealStateSnapshot(double torch) {
    static CFAbsoluteTime lastEmit = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (lastEmit != 0 && now - lastEmit < 2.0) return;
    lastEmit = now;
    FILE *file = fopen("/var/mobile/Library/VirtualCaptureCard/VCAM/photoreal_state.log", "a");
    if (file != NULL) {
        // obs_exp/obs_iso/obs_bias=真实 AE 观测值，与探针 exposureSamples 对表。
        fprintf(file, "t=%.2f photoreal=%d torch_level=%.3f obs_exp_s=%.6f obs_iso=%.1f obs_bias=%.2f\n",
                now, (int)VCAMPhotorealEnabled, torch,
                VCAMObservedExposureDurationS, VCAMObservedExposureISO,
                VCAMObservedExposureBiasEV);
        fclose(file);
    }
    VCAMPublishPhotorealState();
}

// 合成链上的物理增益：真相机在 torch 开启时被补光照亮，画面亮度出现正相关脉冲。
// CIColorControls.inputBrightness 是加性偏移（与补光物理同型），挂在既有 CoreImage
// render task 里，零额外拷贝；幅度先取 0.45*level（真机基线采样后校准）。
// 现阶段状态源=配置注入（photorealTorchLevel），BW 设备节点 hook 落地后覆盖。
// 加性增益与对角增益（VCAMComputeCombinedChannelFactors）拆开：只有加性激活时
// 必须走 CoreImage 滤镜；对角增益在直通快速路径里用等价的逐像素乘法执行。
static BOOL VCAMCurrentPhotorealBrightness(double *outBrightness) {
    if (!VCAMPhotorealCouplingEnabled()) return NO;
    double level = VCAMPhotorealTorchLevel;
    double observed = VCAMObservedTorchLevel;
    int64_t nowMs = (int64_t)(CFAbsoluteTimeGetCurrent() * 1000.0);
    if (observed >= 0 && nowMs - VCAMObservedTorchTimeMs <= 5000) {
        level = observed;  // 真实观测优先于配置注入（路线 A）
    }
    if (level <= 0.001) return NO;
    VCAMEmitPhotorealStateSnapshot(level);
    double brightness = level * 0.45;
    if (brightness > 1.0) brightness = 1.0;
    *outBrightness = brightness;
    return YES;
}

// —— 路线 2：屏幕色染色（三色活体，docs/kyc 检测点补全）——
// SpringBoard 进程采屏器（VCAMMediaPickerController.m）经 notifyd 发布屏幕平均色：
// state = (tick<<32)|(valid<<31)|(r<<16)|(g<<8)|b。物理模型：屏幕发出的光改变被照
// 面的反射光通道分布，颜色切换在 ~1s 内让真实场景"染色"。这里做"相对基线的偏差"
// 通道增益：基线=时间常数 20s 的慢滑均（EMA），跟随普通 UI 内容的慢漂移（含人脸
// 预览自身的肤色自污染）；活体挑战的色脉冲（每档 0.5–2s）相对基线大幅偏离才触发，
// 普通界面因此不会误染色。tick 2s 未推进=采样器已停（开关/模式关闭、熄屏），不染色。
static int VCAMScreenTintReadToken = -1;
static uint64_t VCAMScreenTintLastTick = 0;
static int64_t VCAMScreenTintTickTimeMs = 0;
static double VCAMScreenTintBaseline[3] = {0, 0, 0};  // 全 0 = 未初始化（首样即基线）
static int64_t VCAMScreenTintLastApplyMs = 0;

// 计算本帧的屏幕色染色因子：门控条件不满足时返回 0（不染色）；
// 通过时写入 outFactor[3] 返回 1。门控逻辑与原 VCAMApplyScreenTint 完全一致。
static int VCAMComputeScreenTintFactors(double outFactor[3]) {
    outFactor[0] = outFactor[1] = outFactor[2] = 1.0;
    if (!VCAMScreenTintEnabled) return 0;
    if (VCAMScreenTintReadToken < 0 &&
        notify_register_check("com.codex.vcam.ios18.screen-tint.state",
                              &VCAMScreenTintReadToken) != NOTIFY_STATUS_OK) {
        return 0;
    }
    uint64_t state = 0;
    if (notify_get_state(VCAMScreenTintReadToken, &state) != NOTIFY_STATUS_OK ||
        ((state >> 31) & 1ull) == 0) {
        return 0;
    }
    uint64_t tick = state >> 32;
    int64_t nowMs = (int64_t)(CFAbsoluteTimeGetCurrent() * 1000.0);
    if (tick != VCAMScreenTintLastTick) {
        // 采样器重启（此前停摆 >2s）：丢弃旧基线，避免跨场景误判。
        if (VCAMScreenTintTickTimeMs != 0 && nowMs - VCAMScreenTintTickTimeMs > 2000) {
            VCAMScreenTintBaseline[0] = VCAMScreenTintBaseline[1] = VCAMScreenTintBaseline[2] = 0;
        }
        VCAMScreenTintLastTick = tick;
        VCAMScreenTintTickTimeMs = nowMs;
    }
    if (nowMs - VCAMScreenTintTickTimeMs > 2000) return 0;
    double rgb[3] = {(double)((state >> 16) & 0xFF), (double)((state >> 8) & 0xFF),
                     (double)(state & 0xFF)};
    if (rgb[0] + rgb[1] + rgb[2] < 24.0) return 0;  // 黑屏/熄屏不算颜色
    if (VCAMScreenTintBaseline[0] == 0) {
        VCAMScreenTintBaseline[0] = rgb[0];
        VCAMScreenTintBaseline[1] = rgb[1];
        VCAMScreenTintBaseline[2] = rgb[2];
        VCAMScreenTintLastApplyMs = nowMs;
        return 0;
    }
    double dt = VCAMScreenTintLastApplyMs == 0
        ? 0.033
        : (double)(nowMs - VCAMScreenTintLastApplyMs) / 1000.0;
    VCAMScreenTintLastApplyMs = nowMs;
    if (dt < 0.0) dt = 0.0;
    if (dt > 5.0) dt = 5.0;
    double alpha = 1.0 - exp(-dt / 20.0);
    double factor[3];
    double maxDeviation = 0.0;
    for (int i = 0; i < 3; i++) {
        VCAMScreenTintBaseline[i] += alpha * (rgb[i] - VCAMScreenTintBaseline[i]);
        if (VCAMScreenTintBaseline[i] < 1.0) VCAMScreenTintBaseline[i] = 1.0;
        factor[i] = rgb[i] / VCAMScreenTintBaseline[i];
        if (factor[i] < 0.5) factor[i] = 0.5;
        if (factor[i] > 2.0) factor[i] = 2.0;
        double deviation = factor[i] > 1.0 ? factor[i] - 1.0 : 1.0 - factor[i];
        if (deviation > maxDeviation) maxDeviation = deviation;
    }
    if (maxDeviation < 0.10) return 0;  // 中性屏幕：不染色
    double strength = (maxDeviation - 0.10) / 0.35;
    if (strength > 1.0) strength = 1.0;
    static CFAbsoluteTime lastTintLog = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - lastTintLog >= 2.0) {
        lastTintLog = now;
        FILE *file = fopen("/var/mobile/Library/VirtualCaptureCard/VCAM/screen_tint.log", "a");
        if (file != NULL) {
            fprintf(file,
                    "t=%.2f rgb=%.0f,%.0f,%.0f baseline=%.0f,%.0f,%.0f strength=%.2f "
                    "factors=%.2f,%.2f,%.2f\n",
                    now, rgb[0], rgb[1], rgb[2],
                    VCAMScreenTintBaseline[0], VCAMScreenTintBaseline[1],
                    VCAMScreenTintBaseline[2], strength, factor[0], factor[1], factor[2]);
            fclose(file);
        }
    }
    for (int i = 0; i < 3; i++) {
        outFactor[i] = 1.0 + strength * (factor[i] - 1.0);
    }
    return 1;
}

// —— A-2 + 路线 2 合并：对角通道增益的唯一计算入口（factor[0]=R,1=G,2=B）——
// AE 曝光增益=乘性中性系数（(E*ISO)/EMA 基线），屏幕色染色=通道因子；两者
// 相乘后消费侧只走一种执行：CIColorMatrix filter pass（全链），或直通快速路径
// 里语义等价的逐像素定点乘法（不透明图像 premultiplied==straight，8-bit
// 量化顺序与 CI 相同）。torch 补光是加性偏移，保持在 CIColorControls
//（VCAMCurrentPhotorealBrightness），物理同型不混用。
// 注意：增益只来自真实相机实时曝光变化（相对调制），替换内容自身的亮度
// 差异完全保留——换更亮/更暗的视频，输出仍保持该亮度差，叠加的只是真实
// 环境曝光变化的同向曲线。
static BOOL VCAMComputeCombinedChannelFactors(double outFactor[3]) {
    double factor[3] = {1.0, 1.0, 1.0};
    BOOL active = NO;
    // —— AE 曝光增益（缓变，相对基线）——
    if (VCAMPhotorealCouplingEnabled()) {
        double duration = VCAMObservedExposureDurationS;
        double iso = VCAMObservedExposureISO;
        int64_t nowMs = (int64_t)(CFAbsoluteTimeGetCurrent() * 1000.0);
        if (duration > 0.0 && iso > 0.0 && nowMs - VCAMObservedExposureTimeMs <= 10000) {
            double exposureIndex = duration * iso;
            if (VCAMExposureBaselineIndex == 0.0) {
                VCAMExposureBaselineIndex = exposureIndex;
            } else {
                double dt = (double)(nowMs - VCAMExposureBaselineLastApplyMs) / 1000.0;
                if (dt < 0.0) dt = 0.0;
                if (dt > 5.0) dt = 5.0;
                // 时间常数 20s：慢于 AE 响应但快于场景常态漂移。
                VCAMExposureBaselineIndex +=
                    (1.0 - exp(-dt / 20.0)) * (exposureIndex - VCAMExposureBaselineIndex);
            }
            VCAMExposureBaselineLastApplyMs = nowMs;
            double gain = exposureIndex / VCAMExposureBaselineIndex;
            if (gain < 0.5) gain = 0.5;
            if (gain > 2.0) gain = 2.0;
            if (fabs(gain - 1.0) >= 0.05) {
                factor[0] *= gain;
                factor[1] *= gain;
                factor[2] *= gain;
                active = YES;
                static CFAbsoluteTime lastExposureLog = 0;
                CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
                if (now - lastExposureLog >= 2.0) {
                    lastExposureLog = now;
                    FILE *file = fopen("/var/mobile/Library/VirtualCaptureCard/VCAM/screen_tint.log", "a");
                    if (file != NULL) {
                        fprintf(file, "t=%.2f ae_gain=%.3f exposure_index=%.6f baseline=%.6f\n",
                                now, gain, exposureIndex, VCAMExposureBaselineIndex);
                        fclose(file);
                    }
                }
            }
        }
    }
    double tintFactor[3];
    if (VCAMComputeScreenTintFactors(tintFactor)) {
        for (int i = 0; i < 3; i++) factor[i] *= tintFactor[i];
        active = YES;
    }
    if (!active) return NO;
    outFactor[0] = factor[0];
    outFactor[1] = factor[1];
    outFactor[2] = factor[2];
    return YES;
}

// 对角增益的逐像素等价执行（与 CIColorMatrix 对角节点同语义）：不透明图像
// premultiplied==straight，输入已是 8-bit 量化，factor 区间 [0.25,4] 定点
// ×1024 不溢出；round-to-nearest 与 CoreImage 写 8-bit 目的地的取整一致。
static void VCAMApplyBGRAChannelFactorsInPlace(CVPixelBufferRef buffer,
                                               const double factor[3]) {
    if (buffer == NULL ||
        CVPixelBufferLockBaseAddress(buffer, 0) != kCVReturnSuccess) return;
    uint8_t *base = CVPixelBufferGetBaseAddress(buffer);
    if (base != NULL) {
        size_t bytesPerRow = CVPixelBufferGetBytesPerRow(buffer);
        size_t width = CVPixelBufferGetWidth(buffer);
        size_t height = CVPixelBufferGetHeight(buffer);
        int fb = (int)(factor[2] * 1024.0);
        int fg = (int)(factor[1] * 1024.0);
        int fr = (int)(factor[0] * 1024.0);
        for (size_t row = 0; row < height; row++) {
            uint8_t *line = base + row * bytesPerRow;
            for (size_t column = 0; column < width; column++) {
                uint8_t *pixel = line + column * 4;
                int b = (pixel[0] * fb + 512) >> 10;
                int g = (pixel[1] * fg + 512) >> 10;
                int r = (pixel[2] * fr + 512) >> 10;
                pixel[0] = (uint8_t)(b > 255 ? 255 : b);
                pixel[1] = (uint8_t)(g > 255 ? 255 : g);
                pixel[2] = (uint8_t)(r > 255 ? 255 : r);
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, 0);
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
    VCAMReloadPhotorealAndBranchConfig();
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
    // iOS 18 cameracaptured explicitly grants its home-relative
    // /Library/VirtualCaptureCard directory. Prefer the package-owned child
    // there so signature/proof logs survive the daemon sandbox.
    static const char *candidatePaths[] = {
        "/var/mobile/Library/VirtualCaptureCard/VCAM/vcam-ref.log",
        "/var/mobile/Media/VCAM/vcam-ref.log",
        "/var/mobile/Library/Caches/vcam-ref.log",
        "/var/log/vcam-ref.log",
        "/tmp/vcam-ref.log",
        "/var/tmp/vcam-ref-msd.log",
        NULL,
    };
    // Hot path: remember the first path that worked and start there. The full
    // probe still runs whenever the cached path stops opening (file deleted,
    // sandbox change), so recovery needs no invalidation hook.
    static int preferredIndex = 0;
    for (int step = 0; ; step++) {
        int index = step == 0 ? preferredIndex : step - 1;
        if (candidatePaths[index] == NULL) break;
        int descriptor = open(candidatePaths[index], O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (descriptor < 0) {
            if (step == 0) preferredIndex = 0;
            continue;
        }
        preferredIndex = index;
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
        VCAMStandardColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        // 历史决策（原 ponytail 注释）：初版 Metal 渲染在 cameracaptured 内挂起，
        // 整体切到软件渲染。软件渲染 1080p 每帧数十 ms CPU——这是发热与丢帧的
        // 首要嫌疑。现在改为"配置驱动 + 探针验证"：metalRenderer=1 才尝试，
        // 小图探针通过 watchdog 验证后才采用；帧路径永远不会遇到未验证的上下文。
        VCAMContext = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @YES}];
        if (VCAMConfiguredMetalRendererRequested() && device != nil) {
            CIContext *candidate = VCAMCreateProbedMetalContext(device);
            if (candidate != nil) {
                VCAMContext = candidate;
                (void)__sync_lock_test_and_set(&VCAMMetalContextActive, 1);
                VCAMRefLog("coreimage context=metal probe=ok");
            } else {
                VCAMRefLog("coreimage context=software probe=failed");
            }
        } else {
            VCAMRefLog("coreimage context=software metal=off");
        }
        VCAMReaderLock = [NSLock new];
        VCAMPixelTransferLock = [NSLock new];
        VCAMPreviewCacheLock = [NSLock new];
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
        // VideoToolbox owns the write; the IOSurface check above plus
        // membership in the observed-format table (already proven by
        // compressedVideoRange, whose render pools are created from the very
        // same list) is the only safe validation available here. Do not
        // re-enumerate the formats below that table: it previously drifted
        // and silently rejected the '&8f0' bi-planar format.
        return YES;
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

static BOOL VCAMRuntimeIsAtLeastIOS18(void) {
    static dispatch_once_t onceToken;
    static BOOL supported = NO;
    dispatch_once(&onceToken, ^{
        supported = NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 18;
    });
    return supported;
}

static BOOL VCAMCopyPlanarPixels(CVPixelBufferRef sourceBuffer,
                                 CVPixelBufferRef destinationBuffer) {
    if (sourceBuffer == NULL || destinationBuffer == NULL ||
        !CVPixelBufferIsPlanar(sourceBuffer) ||
        !CVPixelBufferIsPlanar(destinationBuffer) ||
        CVPixelBufferGetPlaneCount(sourceBuffer) != 2 ||
        CVPixelBufferGetPlaneCount(destinationBuffer) != 2 ||
        CVPixelBufferGetWidth(sourceBuffer) !=
            CVPixelBufferGetWidth(destinationBuffer) ||
        CVPixelBufferGetHeight(sourceBuffer) !=
            CVPixelBufferGetHeight(destinationBuffer) ||
        CVPixelBufferGetPixelFormatType(sourceBuffer) !=
            CVPixelBufferGetPixelFormatType(destinationBuffer)) return NO;

    size_t width = CVPixelBufferGetWidth(sourceBuffer);
    OSType format = CVPixelBufferGetPixelFormatType(sourceBuffer);
    if (format != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
        format != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) return NO;

    IOSurfaceRef sourceSurface = CVPixelBufferGetIOSurface(sourceBuffer);
    IOSurfaceRef destinationSurface =
        CVPixelBufferGetIOSurface(destinationBuffer);
    BOOL sourceSurfaceLocked = sourceSurface != NULL &&
        IOSurfaceLock(sourceSurface, 1, NULL) == 0;
    CVReturn sourceStatus = sourceSurfaceLocked ? kCVReturnSuccess
        : CVPixelBufferLockBaseAddress(
            sourceBuffer, kCVPixelBufferLock_ReadOnly);
    if (sourceStatus != kCVReturnSuccess) return NO;

    BOOL destinationSurfaceLocked = destinationSurface != NULL &&
        IOSurfaceLock(destinationSurface, 0, NULL) == 0;
    CVReturn destinationStatus = destinationSurfaceLocked ? kCVReturnSuccess
        : CVPixelBufferLockBaseAddress(destinationBuffer, 0);
    if (destinationStatus != kCVReturnSuccess) {
        if (sourceSurfaceLocked) IOSurfaceUnlock(sourceSurface, 1, NULL);
        else CVPixelBufferUnlockBaseAddress(
            sourceBuffer, kCVPixelBufferLock_ReadOnly);
        return NO;
    }

    BOOL copied = YES;
    for (size_t plane = 0; plane < 2; plane++) {
        const uint8_t *sourceBase = sourceSurfaceLocked
            ? IOSurfaceGetBaseAddressOfPlane(sourceSurface, plane)
            : CVPixelBufferGetBaseAddressOfPlane(sourceBuffer, plane);
        uint8_t *destinationBase = destinationSurfaceLocked
            ? IOSurfaceGetBaseAddressOfPlane(destinationSurface, plane)
            : CVPixelBufferGetBaseAddressOfPlane(destinationBuffer, plane);
        size_t sourceStride = sourceSurfaceLocked
            ? IOSurfaceGetBytesPerRowOfPlane(sourceSurface, plane)
            : CVPixelBufferGetBytesPerRowOfPlane(sourceBuffer, plane);
        size_t destinationStride = destinationSurfaceLocked
            ? IOSurfaceGetBytesPerRowOfPlane(destinationSurface, plane)
            : CVPixelBufferGetBytesPerRowOfPlane(destinationBuffer, plane);
        size_t rows = CVPixelBufferGetHeightOfPlane(sourceBuffer, plane);
        size_t destinationRows =
            CVPixelBufferGetHeightOfPlane(destinationBuffer, plane);
        if (sourceBase == NULL || destinationBase == NULL ||
            rows != destinationRows || sourceStride < width ||
            destinationStride < width) {
            copied = NO;
            break;
        }
        for (size_t row = 0; row < rows; row++) {
            memcpy(destinationBase + row * destinationStride,
                   sourceBase + row * sourceStride, width);
        }
    }

    if (destinationSurfaceLocked) {
        IOSurfaceUnlock(destinationSurface, 0, NULL);
    } else {
        CVPixelBufferUnlockBaseAddress(destinationBuffer, 0);
    }
    if (sourceSurfaceLocked) {
        IOSurfaceUnlock(sourceSurface, 1, NULL);
    } else {
        CVPixelBufferUnlockBaseAddress(
            sourceBuffer, kCVPixelBufferLock_ReadOnly);
    }
    if (copied) VCAMSetStandardColorAttachments(destinationBuffer);
    return copied;
}

static void VCAMInvalidatePreviewCache(void) {
    if (VCAMPreviewCacheLock == nil) return;
    [VCAMPreviewCacheLock lock];
    if (VCAMPreviewCacheBuffer != NULL) {
        CVPixelBufferRelease(VCAMPreviewCacheBuffer);
        VCAMPreviewCacheBuffer = NULL;
    }
    VCAMPreviewCacheSequence = 0;
    VCAMPreviewCacheGeneration = 0;
    VCAMPreviewCacheWidth = 0;
    VCAMPreviewCacheHeight = 0;
    VCAMPreviewCacheFormat = 0;
    [VCAMPreviewCacheLock unlock];
}

static BOOL VCAMPreviewCacheCanReuse(
    VCAMFramePresentation presentation, BOOL planarTarget,
    VCAMSharedFrameMetadata metadata, size_t targetWidth,
    size_t targetHeight, OSType targetFormat) {
    return VCAMRuntimeIsAtLeastIOS18() &&
        presentation == VCAMFramePresentationCameraPreviewFit &&
        planarTarget && metadata.sequence != 0 &&
        metadata.surfaceGeneration != 0 &&
        metadata.surfaceSlotCount <= 1 &&
        VCAMPreviewCacheBuffer != NULL &&
        VCAMPreviewCacheSequence == metadata.sequence &&
        VCAMPreviewCacheGeneration == metadata.surfaceGeneration &&
        VCAMPreviewCacheWidth == targetWidth &&
        VCAMPreviewCacheHeight == targetHeight &&
        VCAMPreviewCacheFormat == targetFormat;
}

static BOOL VCAMCopyPreviewCacheIntoTarget(
    CVPixelBufferRef targetBuffer, VCAMFramePresentation presentation,
    BOOL planarTarget, VCAMSharedFrameMetadata metadata, size_t targetWidth,
    size_t targetHeight, OSType targetFormat) {
    if (VCAMPreviewCacheLock == nil) return NO;
    [VCAMPreviewCacheLock lock];
    BOOL copied = VCAMPreviewCacheCanReuse(
        presentation, planarTarget, metadata, targetWidth, targetHeight,
        targetFormat) &&
        VCAMCopyPlanarPixels(VCAMPreviewCacheBuffer, targetBuffer);
    [VCAMPreviewCacheLock unlock];
    return copied;
}

static void VCAMRememberPreviewTarget(
    CVPixelBufferRef targetBuffer, VCAMFramePresentation presentation,
    BOOL planarTarget, VCAMSharedFrameMetadata metadata, size_t targetWidth,
    size_t targetHeight, OSType targetFormat) {
    if (!VCAMRuntimeIsAtLeastIOS18() ||
        presentation != VCAMFramePresentationCameraPreviewFit ||
        !planarTarget || metadata.sequence == 0 ||
        metadata.surfaceGeneration == 0 || metadata.surfaceSlotCount > 1 ||
        VCAMPreviewCacheLock == nil) return;

    CVPixelBufferRef candidate = NULL;
    CVReturn status = CVPixelBufferCreate(
        kCFAllocatorDefault, targetWidth, targetHeight, targetFormat,
        NULL, &candidate);
    if (status != kCVReturnSuccess || candidate == NULL ||
        !VCAMCopyPlanarPixels(targetBuffer, candidate)) {
        if (candidate != NULL) CVPixelBufferRelease(candidate);
        return;
    }

    [VCAMPreviewCacheLock lock];
    if (VCAMPreviewCacheBuffer != NULL) {
        CVPixelBufferRelease(VCAMPreviewCacheBuffer);
    }
    VCAMPreviewCacheBuffer = candidate;
    VCAMPreviewCacheSequence = metadata.sequence;
    VCAMPreviewCacheGeneration = metadata.surfaceGeneration;
    VCAMPreviewCacheWidth = targetWidth;
    VCAMPreviewCacheHeight = targetHeight;
    VCAMPreviewCacheFormat = targetFormat;
    [VCAMPreviewCacheLock unlock];
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

// A cameracaptured software Core Image context can complete a render while
// reading an externally-created BGRA IOSurface as black. Copy the readable
// bytes into a pool-owned buffer before constructing the CIImage so Core Image
// consumes a process-local source surface.
static CVReturn VCAMCreateLocalBGRASourceBuffer(size_t width, size_t height,
                                                CVPixelBufferRef *bufferOut) {
    if (bufferOut == NULL || VCAMPixelTransferLock == nil) {
        return kCVReturnInvalidArgument;
    }
    *bufferOut = NULL;
    [VCAMPixelTransferLock lock];
    if (VCAMLocalSourcePool == NULL ||
        VCAMLocalSourceWidth != width || VCAMLocalSourceHeight != height) {
        CVPixelBufferPoolRef replacementPool = NULL;
        CVReturn poolStatus = VCAMCreateStagingPool(
            kCVPixelFormatType_32BGRA, width, height, &replacementPool);
        if (poolStatus != kCVReturnSuccess) {
            [VCAMPixelTransferLock unlock];
            return poolStatus;
        }
        if (VCAMLocalSourcePool != NULL) {
            CVPixelBufferPoolRelease(VCAMLocalSourcePool);
        }
        VCAMLocalSourcePool = replacementPool;
        VCAMLocalSourceWidth = width;
        VCAMLocalSourceHeight = height;
    }
    CVReturn bufferStatus = CVPixelBufferPoolCreatePixelBuffer(
        kCFAllocatorDefault, VCAMLocalSourcePool, bufferOut);
    [VCAMPixelTransferLock unlock];
    return bufferStatus;
}

static BOOL VCAMCopyBGRASourceToLocal(CVPixelBufferRef sourceBuffer,
                                      CVPixelBufferRef localBuffer) {
    if (sourceBuffer == NULL || localBuffer == NULL ||
        VCAMPixelTransferLock == nil ||
        CVPixelBufferGetPixelFormatType(sourceBuffer) !=
            kCVPixelFormatType_32BGRA ||
        CVPixelBufferGetPixelFormatType(localBuffer) !=
            kCVPixelFormatType_32BGRA ||
        CVPixelBufferIsPlanar(sourceBuffer) ||
        CVPixelBufferIsPlanar(localBuffer) ||
        CVPixelBufferGetPlaneCount(sourceBuffer) != 0 ||
        CVPixelBufferGetPlaneCount(localBuffer) != 0 ||
        CVPixelBufferGetWidth(sourceBuffer) != CVPixelBufferGetWidth(localBuffer) ||
        CVPixelBufferGetHeight(sourceBuffer) != CVPixelBufferGetHeight(localBuffer)) {
        return NO;
    }

    size_t width = CVPixelBufferGetWidth(sourceBuffer);
    size_t height = CVPixelBufferGetHeight(sourceBuffer);
    size_t rowBytes = width * 4;
    if (CVPixelBufferGetBytesPerRow(sourceBuffer) < rowBytes ||
        CVPixelBufferGetBytesPerRow(localBuffer) < rowBytes) {
        return NO;
    }

    [VCAMPixelTransferLock lock];
    // On iOS 18, a CVPixelBuffer created around an IOSurface imported through
    // XPC can expose a stale/black CPU mapping unless the IOSurface itself is
    // explicitly locked. Read the shared surface bytes while holding its
    // read-only lock; retain the CoreVideo lock path for non-IOSurface buffers.
    IOSurfaceRef sourceSurface = CVPixelBufferGetIOSurface(sourceBuffer);
    BOOL sourceSurfaceLocked = sourceSurface != NULL &&
        IOSurfaceLock(sourceSurface, 1, NULL) == 0; // kIOSurfaceLockReadOnly
    CVReturn sourceLockStatus = sourceSurfaceLocked
        ? kCVReturnSuccess
        : CVPixelBufferLockBaseAddress(sourceBuffer,
                                       kCVPixelBufferLock_ReadOnly);
    if (sourceLockStatus != kCVReturnSuccess) {
        [VCAMPixelTransferLock unlock];
        return NO;
    }
    CVReturn localLockStatus = CVPixelBufferLockBaseAddress(localBuffer, 0);
    if (localLockStatus != kCVReturnSuccess) {
        if (sourceSurfaceLocked) {
            IOSurfaceUnlock(sourceSurface, 1, NULL);
        } else {
            CVPixelBufferUnlockBaseAddress(sourceBuffer,
                                           kCVPixelBufferLock_ReadOnly);
        }
        [VCAMPixelTransferLock unlock];
        return NO;
    }

    uint8_t *sourceBase = sourceSurfaceLocked
        ? (uint8_t *)IOSurfaceGetBaseAddress(sourceSurface)
        : CVPixelBufferGetBaseAddress(sourceBuffer);
    uint8_t *localBase = CVPixelBufferGetBaseAddress(localBuffer);
    BOOL copied = sourceBase != NULL && localBase != NULL;
    size_t sourceBytesPerRow = sourceSurfaceLocked
        ? IOSurfaceGetBytesPerRow(sourceSurface)
        : CVPixelBufferGetBytesPerRow(sourceBuffer);
    size_t localBytesPerRow = CVPixelBufferGetBytesPerRow(localBuffer);
    if (copied) {
        for (size_t row = 0; row < height; row++) {
            memcpy(localBase + row * localBytesPerRow,
                   sourceBase + row * sourceBytesPerRow, rowBytes);
        }
    }
    CVPixelBufferUnlockBaseAddress(localBuffer, 0);
    if (sourceSurfaceLocked) {
        IOSurfaceUnlock(sourceSurface, 1, NULL);
    } else {
        CVPixelBufferUnlockBaseAddress(sourceBuffer,
                                       kCVPixelBufferLock_ReadOnly);
    }
    [VCAMPixelTransferLock unlock];

    if (copied) {
        CVBufferRemoveAllAttachments(localBuffer);
        VCAMMergeGraphAttachments(sourceBuffer, localBuffer);
    }
    return copied;
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

// cameracaptured 的 CoreImage 上下文被强制走软件渲染（Metal 渲染在该进程会挂起），
// 1080p/4K 全尺寸软渲染单帧实测 90–135ms，超过 30fps 帧预算后 graph 复用旧帧，
// 表现为"时间戳正常 + 内容刷新 ~9Hz"的冻结。源细节本来就只有 VCAMSharedFrame
// 尺寸，实时路径把合成尺寸钳制到源细节以内，放大在直写阶段一次双线性完成。
static void VCAMClampRealtimeCompositionSize(size_t *width, size_t *height) {
    size_t longerTarget = MAX(*width, *height);
    size_t sourceDetail = (size_t)MAX(VCAMSharedFrameWidth, VCAMSharedFrameHeight);
    if (longerTarget <= sourceDetail) {
        return;
    }
    CGFloat scale = (CGFloat)sourceDetail * 0.85 / (CGFloat)longerTarget;
    size_t composedWidth = ((size_t)((CGFloat)*width * scale)) & ~(size_t)1;
    size_t composedHeight = ((size_t)((CGFloat)*height * scale)) & ~(size_t)1;
    if (composedWidth < 16 || composedHeight < 16) {
        return;
    }
    *width = composedWidth;
    *height = composedHeight;
}

// 把 BGRA 暂存左上角 (0,0,contentWidth,contentHeight) 的内容双线性放大写入
// 同格式全尺寸缓冲区；仅用于合成尺寸已被钳制小于目标尺寸的实时路径。
static void VCAMUpscaleBGRAContent(const uint8_t *sourceBase, size_t sourceBytesPerRow,
                                   size_t contentWidth, size_t contentHeight,
                                   uint8_t *targetBase, size_t targetBytesPerRow,
                                   size_t targetWidth, size_t targetHeight) {
    CGFloat scaleX = (CGFloat)contentWidth / (CGFloat)targetWidth;
    CGFloat scaleY = (CGFloat)contentHeight / (CGFloat)targetHeight;
    for (size_t row = 0; row < targetHeight; row++) {
        CGFloat sourceY = ((CGFloat)row + 0.5) * scaleY - 0.5;
        if (sourceY < 0.0) sourceY = 0.0;
        if (sourceY > (CGFloat)(contentHeight - 1)) sourceY = (CGFloat)(contentHeight - 1);
        size_t y0 = (size_t)sourceY;
        size_t y1 = MIN(y0 + 1, contentHeight - 1);
        uint32_t weightY = (uint32_t)((sourceY - (CGFloat)y0) * 256.0);
        uint32_t weightYInv = 256u - weightY;
        const uint8_t *row0 = sourceBase + y0 * sourceBytesPerRow;
        const uint8_t *row1 = sourceBase + y1 * sourceBytesPerRow;
        uint8_t *outputLine = targetBase + row * targetBytesPerRow;
        for (size_t column = 0; column < targetWidth; column++) {
            CGFloat sourceX = ((CGFloat)column + 0.5) * scaleX - 0.5;
            if (sourceX < 0.0) sourceX = 0.0;
            if (sourceX > (CGFloat)(contentWidth - 1)) sourceX = (CGFloat)(contentWidth - 1);
            size_t x0 = (size_t)sourceX;
            size_t x1 = MIN(x0 + 1, contentWidth - 1);
            uint32_t weightX = (uint32_t)((sourceX - (CGFloat)x0) * 256.0);
            uint32_t weightXInv = 256u - weightX;
            uint8_t *output = outputLine + column * 4;
            for (int channel = 0; channel < 4; channel++) {
                uint32_t top = row0[x0 * 4 + channel] * weightXInv + row0[x1 * 4 + channel] * weightX;
                uint32_t bottom = row1[x0 * 4 + channel] * weightXInv + row1[x1 * 4 + channel] * weightX;
                output[channel] = (uint8_t)((top * weightYInv + bottom * weightY) >> 16);
            }
        }
    }
}

// 合成尺寸小于目标尺寸时的 planar 写回：先把内容放大到全尺寸 BGRA（池化缓冲），
// 再走与相同尺寸路径完全一致的直写副本路径——保持"优先直写、VideoToolbox 仅作
// 兜底"的 iOS 18 语义，不让 graph 的 IOSurface 依赖 transfer 可见性。
static CVPixelBufferPoolRef VCAMUpscaleScratchPool = NULL;
static size_t VCAMUpscaleScratchWidth = 0;
static size_t VCAMUpscaleScratchHeight = 0;

static BOOL VCAMCopyBGRAToPlanarTarget(CVPixelBufferRef stagingBuffer,
                                       CVPixelBufferRef targetBuffer);

static BOOL VCAMCopyScaledBGRAToPlanarTarget(CVPixelBufferRef stagingBuffer,
                                             size_t contentWidth, size_t contentHeight,
                                             CVPixelBufferRef targetBuffer) {
    if (stagingBuffer == NULL || targetBuffer == NULL ||
        CVPixelBufferGetPixelFormatType(stagingBuffer) != kCVPixelFormatType_32BGRA ||
        CVPixelBufferGetWidth(stagingBuffer) < contentWidth ||
        CVPixelBufferGetHeight(stagingBuffer) < contentHeight) {
        return NO;
    }
    size_t targetWidth = CVPixelBufferGetWidth(targetBuffer);
    size_t targetHeight = CVPixelBufferGetHeight(targetBuffer);
    if (contentWidth == targetWidth && contentHeight == targetHeight) {
        return VCAMCopyBGRAToPlanarTarget(stagingBuffer, targetBuffer);
    }
    CVPixelBufferRef fullBuffer = NULL;
    [VCAMPixelTransferLock lock];
    if (VCAMUpscaleScratchPool == NULL ||
        VCAMUpscaleScratchWidth != targetWidth ||
        VCAMUpscaleScratchHeight != targetHeight) {
        CVPixelBufferPoolRef replacementPool = NULL;
        CVReturn poolStatus = VCAMCreateStagingPool(
            kCVPixelFormatType_32BGRA, targetWidth, targetHeight, &replacementPool);
        if (poolStatus == kCVReturnSuccess) {
            if (VCAMUpscaleScratchPool != NULL) {
                CVPixelBufferPoolRelease(VCAMUpscaleScratchPool);
            }
            VCAMUpscaleScratchPool = replacementPool;
            VCAMUpscaleScratchWidth = targetWidth;
            VCAMUpscaleScratchHeight = targetHeight;
        }
    }
    BOOL poolReady = VCAMUpscaleScratchPool != NULL &&
        VCAMUpscaleScratchWidth == targetWidth &&
        VCAMUpscaleScratchHeight == targetHeight;
    if (poolReady) {
        (void)CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault,
                                                VCAMUpscaleScratchPool, &fullBuffer);
    }
    [VCAMPixelTransferLock unlock];
    if (fullBuffer == NULL) {
        return NO;
    }
    CVReturn stagingLock = CVPixelBufferLockBaseAddress(
        stagingBuffer, kCVPixelBufferLock_ReadOnly);
    CVReturn fullLock = stagingLock == kCVReturnSuccess
        ? CVPixelBufferLockBaseAddress(fullBuffer, 0) : kCVReturnInvalidArgument;
    BOOL upscaled = NO;
    if (stagingLock == kCVReturnSuccess && fullLock == kCVReturnSuccess) {
        const uint8_t *stagingBase = CVPixelBufferGetBaseAddress(stagingBuffer);
        uint8_t *fullBase = CVPixelBufferGetBaseAddress(fullBuffer);
        upscaled = stagingBase != NULL && fullBase != NULL;
        if (upscaled) {
            VCAMUpscaleBGRAContent(
                stagingBase, CVPixelBufferGetBytesPerRow(stagingBuffer),
                contentWidth, contentHeight,
                fullBase, CVPixelBufferGetBytesPerRow(fullBuffer),
                targetWidth, targetHeight);
        }
    }
    if (fullLock == kCVReturnSuccess) {
        CVPixelBufferUnlockBaseAddress(fullBuffer, 0);
    }
    if (stagingLock == kCVReturnSuccess) {
        CVPixelBufferUnlockBaseAddress(stagingBuffer, kCVPixelBufferLock_ReadOnly);
    }
    if (!upscaled) {
        CVPixelBufferRelease(fullBuffer);
        return NO;
    }
    BOOL copied = VCAMCopyBGRAToPlanarTarget(fullBuffer, targetBuffer);
    CVPixelBufferRelease(fullBuffer);
    return copied;
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
    size_t sourceBytesPerRow = CVPixelBufferGetBytesPerRow(stagingBuffer);
    size_t lumaBytesPerRow = targetSurfaceLocked
        ? IOSurfaceGetBytesPerRowOfPlane(targetSurface, 0)
        : CVPixelBufferGetBytesPerRowOfPlane(targetBuffer, 0);
    size_t chromaBytesPerRow = targetSurfaceLocked
        ? IOSurfaceGetBytesPerRowOfPlane(targetSurface, 1)
        : CVPixelBufferGetBytesPerRowOfPlane(targetBuffer, 1);
    copied = copied && lumaBytesPerRow >= width && chromaBytesPerRow >= width;
    BOOL fullRange = CVPixelBufferGetPixelFormatType(targetBuffer) ==
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;

    uint8_t beforeTopLuma = 0;
    uint8_t beforeCenterLuma = 0;
    uint8_t beforeTopChroma = 0;
    uint8_t beforeCenterChroma = 0;
    uint8_t afterTopLuma = 0;
    uint8_t afterCenterLuma = 0;
    uint8_t afterTopChroma = 0;
    uint8_t afterCenterChroma = 0;
    uint8_t relockTopLuma = 0;
    uint8_t relockCenterLuma = 0;
    uint8_t relockTopChroma = 0;
    uint8_t relockCenterChroma = 0;
    size_t centerRow = (height / 2) & ~(size_t)1;
    size_t centerColumn = (width / 2) & ~(size_t)1;
    if (copied) {
        beforeTopLuma = lumaBase[0];
        beforeCenterLuma = lumaBase[centerRow * lumaBytesPerRow + centerColumn];
        beforeTopChroma = chromaBase[0];
        beforeCenterChroma = chromaBase[(centerRow / 2) * chromaBytesPerRow + centerColumn];
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
        afterTopLuma = lumaBase[0];
        afterCenterLuma = lumaBase[centerRow * lumaBytesPerRow + centerColumn];
        afterTopChroma = chromaBase[0];
        afterCenterChroma = chromaBase[(centerRow / 2) * chromaBytesPerRow + centerColumn];
    }
    if (targetSurfaceLocked) {
        IOSurfaceUnlock(targetSurface, 0, NULL);
    } else {
        CVPixelBufferUnlockBaseAddress(targetBuffer, 0);
    }
    CVPixelBufferUnlockBaseAddress(stagingBuffer, kCVPixelBufferLock_ReadOnly);
    if (targetSurfaceLocked && IOSurfaceLock(targetSurface, 0, NULL) == 0) {
        uint8_t *relockLuma = IOSurfaceGetBaseAddressOfPlane(targetSurface, 0);
        uint8_t *relockChroma = IOSurfaceGetBaseAddressOfPlane(targetSurface, 1);
        size_t relockLumaBytesPerRow = IOSurfaceGetBytesPerRowOfPlane(targetSurface, 0);
        size_t relockChromaBytesPerRow = IOSurfaceGetBytesPerRowOfPlane(targetSurface, 1);
        if (relockLuma != NULL && relockChroma != NULL &&
            relockLumaBytesPerRow >= width && relockChromaBytesPerRow >= width) {
            relockTopLuma = relockLuma[0];
            relockCenterLuma = relockLuma[centerRow * relockLumaBytesPerRow + centerColumn];
            relockTopChroma = relockChroma[0];
            relockCenterChroma = relockChroma[(centerRow / 2) * relockChromaBytesPerRow + centerColumn];
        }
        IOSurfaceUnlock(targetSurface, 0, NULL);
    } else if (!targetSurfaceLocked &&
               CVPixelBufferLockBaseAddress(targetBuffer, kCVPixelBufferLock_ReadOnly) ==
                   kCVReturnSuccess) {
        uint8_t *relockLuma = CVPixelBufferGetBaseAddressOfPlane(targetBuffer, 0);
        uint8_t *relockChroma = CVPixelBufferGetBaseAddressOfPlane(targetBuffer, 1);
        size_t relockLumaBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(targetBuffer, 0);
        size_t relockChromaBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(targetBuffer, 1);
        if (relockLuma != NULL && relockChroma != NULL &&
            relockLumaBytesPerRow >= width && relockChromaBytesPerRow >= width) {
            relockTopLuma = relockLuma[0];
            relockCenterLuma = relockLuma[centerRow * relockLumaBytesPerRow + centerColumn];
            relockTopChroma = relockChroma[0];
            relockCenterChroma = relockChroma[(centerRow / 2) * relockChromaBytesPerRow + centerColumn];
        }
        CVPixelBufferUnlockBaseAddress(targetBuffer, kCVPixelBufferLock_ReadOnly);
    }
    VCAMPublishDirectWriteDiagnostics(
        copied, targetSurfaceLocked, beforeTopLuma, beforeCenterLuma,
        beforeTopChroma, beforeCenterChroma, afterTopLuma, afterCenterLuma,
        afterTopChroma, afterCenterChroma, relockTopLuma, relockCenterLuma,
        relockTopChroma, relockCenterChroma, targetSurface, lumaBase,
        chromaBase);
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
    CVPixelBufferRef localSourceBuffer = NULL;
    CVPixelBufferRef stagingBuffer = NULL;
    CVPixelBufferRef compressedReplacementBuffer = NULL;
    VCAMSharedFrameMetadata metadata = {0};
    VCAMSharedSurfaceFrame surfaceFrame = {0};
    BOOL readerLocked = NO;
    BOOL usingMmapBootstrap = NO;
    BOOL rendered = NO;
    BOOL previewCacheEligible = NO;
    CFAbsoluteTime previewCallStarted = CFAbsoluteTimeGetCurrent();
    uint64_t debug6F2CFallbackState = 0;
    uint64_t debug6F2CSurfaceRGB = 0;
    uint64_t debug6F2CMmapRGB = 0;
    uint64_t debug6F2CSurfaceGeneration = 0;
    uint64_t debug6F2CMmapGeneration = 0;
    // [DEBUG-6f2c] sourceState packs the source-selection path without pixels:
    // low4=surface failure; b4=surface copied; b5=current surface metadata;
    // b6=mmap allowed; b7=mmap metadata; b8=BGRA; b9=NV12; b10=scratch;
    // b11=direct mmap attempted; b12=raw copy; b13=RGB summary valid;
    // b14=legacy any-RGB; b15=copy accepted; b16=surface selected;
    // b17=direct mmap selected; b18=cached frame; b19=fail-closed black;
    // b20=adopted generation; b21=current/adopted match;
    // b22=mmap generation bound; b23=mmap/current generation match.
    uint64_t debug6F2CSourceState = 0;
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
            VCAMInvalidatePreviewCache();
            return NO;
        }
        // 虚拟模式实际工作期间的 CPU 自测窗（见函数注释：设备侧无其它 CPU 来源）。
        VCAMSampleSelfCPUWindow();
        BOOL surfaceCopied = VCAMSharedSurfaceReaderCopyLatest(
            VCAMSurfaceReader, 1000000000ULL, &surfaceFrame);
        VCAMSharedSurfaceReaderFailure surfaceFailure =
            VCAMSharedSurfaceReaderLastFailure(VCAMSurfaceReader);
        debug6F2CSourceState |= ((uint64_t)surfaceFailure & 0xfULL);
        if (surfaceCopied) debug6F2CSourceState |= 1ULL << 4;
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
            if (hasCurrentSurface) {
                debug6F2CSourceState |= 1ULL << 5;
                debug6F2CSurfaceGeneration = currentSurface.surfaceGeneration;
            }
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
            if (allowMmapBootstrap) debug6F2CSourceState |= 1ULL << 6;
            if (VCAMAdoptedSurfaceGeneration != 0) {
                debug6F2CSourceState |= 1ULL << 20;
                if (hasCurrentSurface && currentSurface.surfaceGeneration ==
                        VCAMAdoptedSurfaceGeneration) {
                    debug6F2CSourceState |= 1ULL << 21;
                }
            }
            VCAMSharedFrameMetadata mmapFormatMetadata = {0};
            BOOL hasMmapFormat = VCAMSharedFrameReaderGetLatestMetadata(
                VCAMReader, 0, &mmapFormatMetadata);
            if (hasMmapFormat) debug6F2CSourceState |= 1ULL << 7;
            if (hasMmapFormat && mmapFormatMetadata.pixelFormat ==
                    kCVPixelFormatType_32BGRA) {
                debug6F2CSourceState |= 1ULL << 8;
            }
            if (hasMmapFormat &&
                (mmapFormatMetadata.pixelFormat ==
                     kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                 mmapFormatMetadata.pixelFormat ==
                     kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)) {
                debug6F2CSourceState |= 1ULL << 9;
            }
            CVPixelBufferPoolRef scratchPool = VCAMScratchPool;
            if (hasMmapFormat &&
                (mmapFormatMetadata.pixelFormat ==
                     kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                 mmapFormatMetadata.pixelFormat ==
                     kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)) {
                scratchPool = VCAMNV12ScratchPool;
            }
            BOOL scratchCreated = CVPixelBufferPoolCreatePixelBuffer(
                kCFAllocatorDefault, scratchPool,
                &scratch) == kCVReturnSuccess;
            if (scratchCreated) debug6F2CSourceState |= 1ULL << 10;
            if (!scratchCreated) {
                if (compressedTarget && VCAMCopyLastCompressedVirtualFrame(
                        targetBuffer, replacementBufferOut)) return YES;
                return NO;
            }
            BOOL directMmapAttempted = allowMmapBootstrap;
            if (directMmapAttempted) debug6F2CSourceState |= 1ULL << 11;
            BOOL directMmapCopied = directMmapAttempted &&
                VCAMSharedFrameReaderCopyLatest(
                    VCAMReader, scratch, 1000000000ULL, &metadata);
            if (directMmapCopied) {
                debug6F2CSourceState |= 1ULL << 12;
                debug6F2CMmapGeneration = metadata.surfaceGeneration;
                if (metadata.surfaceGeneration != 0) {
                    debug6F2CSourceState |= 1ULL << 22;
                }
                if (hasCurrentSurface && metadata.surfaceGeneration != 0 &&
                    metadata.surfaceGeneration ==
                        currentSurface.surfaceGeneration) {
                    debug6F2CSourceState |= 1ULL << 23;
                }
                if (publishPixelDiagnostics &&
                    CVPixelBufferGetPixelFormatType(scratch) ==
                        kCVPixelFormatType_32BGRA) {
                    if (VCAMDebug6F2CRGBCoverageSummary(
                            scratch, &debug6F2CMmapRGB)) {
                        debug6F2CSourceState |= 1ULL << 13;
                    }
                    if (VCAMPixelBufferHasRGBContent(scratch)) {
                        debug6F2CSourceState |= 1ULL << 14;
                    }
                }
            }
            copied = directMmapCopied;
            if (directMmapCopied) {
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
            if (copied) debug6F2CSourceState |= 1ULL << 15;
        }
        if (surfaceCopied) debug6F2CFallbackState |= 1ULL << 0;
        BOOL surfaceIsBGRA = surfaceCopied &&
            CVPixelBufferGetPixelFormatType(scratch) ==
                kCVPixelFormatType_32BGRA;
        if (surfaceIsBGRA) debug6F2CFallbackState |= 1ULL << 1;
        BOOL surfaceHasRGB = surfaceIsBGRA &&
            VCAMPixelBufferHasRGBContent(scratch);
        if (surfaceHasRGB) debug6F2CFallbackState |= 1ULL << 3;
        if (surfaceIsBGRA && publishPixelDiagnostics &&
            VCAMDebug6F2CRGBCoverageSummary(
                scratch, &debug6F2CSurfaceRGB)) {
            debug6F2CFallbackState |= 1ULL << 2;
        }
        if (surfaceCopied) {
            debug6F2CSurfaceGeneration = metadata.surfaceGeneration;
        }
        if (surfaceIsBGRA && (!surfaceHasRGB || publishPixelDiagnostics)) {
            debug6F2CFallbackState |= 1ULL << 4;
            VCAMSharedFrameMetadata mmapMetadata = {0};
            CVPixelBufferRef mmapScratch = NULL;
            BOOL mmapBufferCreated = VCAMCreateCPUReadableBGRABuffer(
                VCAMSharedFrameWidth, VCAMSharedFrameHeight,
                &mmapScratch) == kCVReturnSuccess;
            if (mmapBufferCreated) debug6F2CFallbackState |= 1ULL << 5;
            BOOL mmapCopied = mmapBufferCreated &&
                VCAMSharedFrameReaderCopyLatest(
                    VCAMReader, mmapScratch, 1000000000ULL, &mmapMetadata);
            if (mmapCopied) debug6F2CFallbackState |= 1ULL << 6;
            BOOL mmapIsBGRA = mmapCopied &&
                mmapMetadata.pixelFormat == kCVPixelFormatType_32BGRA;
            if (mmapIsBGRA) debug6F2CFallbackState |= 1ULL << 7;
            BOOL mmapGenerationIsBound = mmapCopied &&
                mmapMetadata.surfaceGeneration != 0;
            if (mmapGenerationIsBound) debug6F2CFallbackState |= 1ULL << 8;
            BOOL generationsMatch = mmapGenerationIsBound &&
                mmapMetadata.surfaceGeneration == metadata.surfaceGeneration;
            if (generationsMatch) debug6F2CFallbackState |= 1ULL << 9;
            if (mmapCopied) {
                debug6F2CMmapGeneration = mmapMetadata.surfaceGeneration;
            }
            BOOL mmapSummaryValid = mmapIsBGRA &&
                VCAMDebug6F2CRGBCoverageSummary(
                    mmapScratch, &debug6F2CMmapRGB);
            if (mmapSummaryValid) debug6F2CFallbackState |= 1ULL << 10;
            BOOL mmapHasRGB = mmapIsBGRA &&
                VCAMPixelBufferHasRGBContent(mmapScratch);
            if (mmapHasRGB) debug6F2CFallbackState |= 1ULL << 11;
            if (!surfaceHasRGB && mmapCopied && mmapIsBGRA &&
                mmapGenerationIsBound && generationsMatch && mmapHasRGB) {
                VCAMSharedSurfaceFrameRelease(&surfaceFrame);
                CVPixelBufferRelease(scratch);
                scratch = mmapScratch;
                mmapScratch = NULL;
                metadata = mmapMetadata;
                surfaceCopied = NO;
                usingMmapBootstrap = YES;
                copied = YES;
                debug6F2CFallbackState |= 1ULL << 12;
                static dispatch_once_t surfaceFallbackLogToken;
                dispatch_once(&surfaceFallbackLogToken, ^{
                    VCAMRefLog("[DEBUG-ios18-surface-fallback] surface transport black; using same-generation mmap bootstrap");
                });
            }
            if (mmapScratch != NULL) CVPixelBufferRelease(mmapScratch);
        }
        if (copied) {
            debug6F2CSourceState |= surfaceCopied
                ? 1ULL << 16 : 1ULL << 17;
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
            debug6F2CSourceState |= 1ULL << 18;
            // Short stalls reuse the last good frame so the picture does not
            // blink on every producer hiccup.
            CVPixelBufferRelease(scratch);
            scratch = CVPixelBufferRetain(VCAMLastVirtualFrame);
        } else if (VCAMFillBlackSharedFrame(scratch)) {
            debug6F2CSourceState |= 1ULL << 19;
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

        previewCacheEligible = copied && VCAMRuntimeIsAtLeastIOS18() &&
            presentation == VCAMFramePresentationCameraPreviewFit &&
            planarTarget && metadata.sequence != 0 &&
            metadata.surfaceGeneration != 0 && metadata.surfaceSlotCount <= 1;
        if (previewCacheEligible && VCAMCopyPreviewCacheIntoTarget(
                targetBuffer, presentation, planarTarget, metadata,
                targetWidth, targetHeight, targetFormat)) {
            elapsed = CFAbsoluteTimeGetCurrent() - previewCallStarted;
            if (publishPixelDiagnostics) {
                VCAMDebug6F2CPublishRGBGateDiagnostics(
                    debug6F2CFallbackState, debug6F2CSurfaceRGB,
                    debug6F2CMmapRGB, debug6F2CSurfaceGeneration,
                    debug6F2CMmapGeneration, debug6F2CSourceState);
                VCAMPublishPixelDiagnostics(scratch, targetBuffer, targetBuffer);
            }
            notify_post("com.codex.vcam.ios18.rendered");
            VCAMRecordPreviewPerformance(YES, NO, elapsed * 1000.0);
            return YES;
        }

        CVPixelBufferRef renderBuffer = targetBuffer;
        size_t renderWidth = targetWidth;
        size_t renderHeight = targetHeight;
        size_t planarComposedWidth = targetWidth;
        size_t planarComposedHeight = targetHeight;
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
            // 实时路径把合成尺寸钳制到源细节以内，写回阶段一次双线性放大补齐；
            // 静态照片仍按目标全尺寸合成以保留细节。
            size_t compositionWidth = targetWidth;
            size_t compositionHeight = targetHeight;
            if (realtimeCompensation) {
                VCAMClampRealtimeCompositionSize(&compositionWidth, &compositionHeight);
            }
            if (compositionWidth != targetWidth || compositionHeight != targetHeight) {
                static dispatch_once_t compositionClampToken;
                dispatch_once(&compositionClampToken, ^{
                    char message[192] = {0};
                    snprintf(message, sizeof(message),
                             "realtime composition clamped for large target=%zux%zu composed=%zux%zu; scaled direct-write enabled",
                             targetWidth, targetHeight, compositionWidth, compositionHeight);
                    VCAMRefLog(message);
                });
            }
            CVReturn stagingStatus = VCAMCreatePlanarRenderBuffer(
                compositionWidth, compositionHeight, &stagingBuffer);
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
            planarComposedWidth = renderWidth;
            planarComposedHeight = renderHeight;
        }

        CVPixelBufferRef ciSourceBuffer = scratch;
        if (!usingMmapBootstrap && !CVPixelBufferIsPlanar(scratch) &&
            CVPixelBufferGetPixelFormatType(scratch) == kCVPixelFormatType_32BGRA) {
            if (VCAMCreateLocalBGRASourceBuffer(
                    CVPixelBufferGetWidth(scratch), CVPixelBufferGetHeight(scratch),
                    &localSourceBuffer) == kCVReturnSuccess &&
                VCAMCopyBGRASourceToLocal(scratch, localSourceBuffer)) {
                ciSourceBuffer = localSourceBuffer;
            }
        }
        CIImage *image = [CIImage imageWithCVPixelBuffer:ciSourceBuffer];
        CGFloat sourceWidth = CGRectGetWidth(image.extent);
        CGFloat sourceHeight = CGRectGetHeight(image.extent);
        BOOL sourceIsPortrait = CGRectGetHeight(image.extent) >
            CGRectGetWidth(image.extent);
        // WebKit can renegotiate its converter basis when the lens changes:
        // the observed iOS 18 rear target is portrait while the front target
        // is landscape. Adapt to the actual target dimensions instead of an OS
        // version or fixed profile. Lens state only chooses the system camera's
        // storage rotation direction; it never identifies the consumer route.
        BOOL currentCameraIsFront = VCAMLastCameraIsFront();
        BOOL webKitRotatedForStorage = webKitLandscapeStorage &&
            sourceIsPortrait && targetWidth > targetHeight;
        if (webKitRotatedForStorage) {
            CGImagePropertyOrientation storageOrientation =
                currentCameraIsFront
                    ? kCGImagePropertyOrientationRight
                    : kCGImagePropertyOrientationLeft;
            image = [image imageByApplyingOrientation:storageOrientation];
        }
        BOOL webKitFrontPresentation =
            webKitLandscapeStorage && currentCameraIsFront;
        // Still-photo fill renders the landscape camera basis with canonical
        // portrait pixels: rotate left in place and let the caller mark the
        // final sample Orientation=Right so Photos shows a portrait 3:4 image.
        if (!realtimeCompensation && targetWidth > targetHeight) {
            image = [image imageByApplyingOrientation:kCGImagePropertyOrientationLeft];
            if (stillPhotoRequiresRightOrientationOut != NULL) {
                *stillPhotoRequiresRightOrientationOut = YES;
            }
        }
        // The front WebKit graph applies its user-facing mirror after this
        // converter. The shared VCAM frame is canonical/unmirrored, so cancel
        // that downstream transform here and nowhere else. This must not affect
        // Camera preview, still-photo, recording, or rear-camera consumers.
        if (webKitFrontPresentation) {
            CGRect extent = image.extent;
            CGFloat mirrorTranslation = CGRectGetMinX(extent) * 2.0 +
                CGRectGetWidth(extent);
            image = [image imageByApplyingTransform:
                CGAffineTransformMakeTranslation(mirrorTranslation, 0.0)];
            image = [image imageByApplyingTransform:
                CGAffineTransformMakeScale(-1.0, 1.0)];
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
        if (webKitLandscapeStorage || !realtimeCompensation) {
            static volatile int webKitCompositionCount = 0;
            static volatile int stillCompositionCount = 0;
            int compositionCount = webKitLandscapeStorage
                ? __sync_add_and_fetch(&webKitCompositionCount, 1)
                : __sync_add_and_fetch(&stillCompositionCount, 1);
            int logInterval = webKitLandscapeStorage ? 300 : 8;
            if (compositionCount <= 8 || compositionCount % logInterval == 0) {
                char message[384] = {0};
                snprintf(message, sizeof(message),
                         "composition diagnostic presentation=%s count=%d source=%.0fx%.0f oriented=%.0fx%.0f target=%zux%zu front=%d rotate=%d mirror=%d fit=%d scale=%.6f coverage=%.1fx%.1f",
                         webKitLandscapeStorage ? "webkit" : "still",
                         compositionCount, (double)sourceWidth,
                         (double)sourceHeight,
                         (double)CGRectGetWidth(image.extent),
                         (double)CGRectGetHeight(image.extent),
                         renderWidth, renderHeight, currentCameraIsFront,
                         webKitRotatedForStorage, webKitFrontPresentation,
                         aspectFit, (double)scale,
                         (double)(CGRectGetWidth(image.extent) * scale),
                         (double)(CGRectGetHeight(image.extent) * scale));
                VCAMRefLog(message);
            }
        }
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
        // 增益按物理形态分两类：加性（torch 补光→CIColorControls）必须走 CoreImage
        // 滤镜；对角（AE 曝光增益 × 屏幕色染色）是逐通道乘法，快速路径里可用等价
        // 的逐像素定点乘法执行（见 VCAMApplyBGRAChannelFactorsInPlace）。
        double diagFactor[3] = {1.0, 1.0, 1.0};
        BOOL diagonalActive = VCAMComputeCombinedChannelFactors(diagFactor);
        double additiveBrightness = 0.0;
        BOOL additiveActive = VCAMCurrentPhotorealBrightness(&additiveBrightness);
        if (additiveActive) {
            image = [image imageByApplyingFilter:@"CIColorControls" withInputParameters:
                @{kCIInputImageKey: image, kCIInputBrightnessKey: @(additiveBrightness)}];
        }
        if (diagonalActive) {
            image = [image imageByApplyingFilter:@"CIColorMatrix" withInputParameters:@{
                kCIInputImageKey: image,
                @"inputRVector": [CIVector vectorWithX:diagFactor[0] Y:0 Z:0 W:0],
                @"inputGVector": [CIVector vectorWithX:0 Y:diagFactor[1] Z:0 W:0],
                @"inputBVector": [CIVector vectorWithX:0 Y:diagFactor[2] Z:0 W:0],
                @"inputAVector": [CIVector vectorWithX:0 Y:0 Z:0 W:1],
                @"inputBiasVector": [CIVector vectorWithX:0 Y:0 Z:0 W:0],
            }];
        }

        // 实时同尺寸快速路径（无加性增益时）：源=目标尺寸的 BGRA、scale=1.0、
        // 无旋转/镜像，CI 图在像素上等价"源（×对角因子）→目标直通"。跳过
        // CIRenderTask，用合成链最后一级同一写回函数直接转源缓冲——真机
        // rear 1080p 全幅软渲染 p50 ~32ms 是丢帧/发热主成本（Metal 对照
        // p50 35.3ms 更差，已回滚），此场景只保留一次格式转换。对角因子先
        // 作用在私有 localSourceBuffer 拷贝上（共享 IOSurface 不可原地改），
        // 复制失败的罕见情形回全链；输出质量不变。
        BOOL passthroughFastPath = !additiveActive &&
            realtimeCompensation && planarTarget && !compressedTarget &&
            !webKitRotatedForStorage && !webKitFrontPresentation &&
            fabs((double)scale - 1.0) < 0.001 &&
            renderWidth == targetWidth && renderHeight == targetHeight &&
            !CVPixelBufferIsPlanar(ciSourceBuffer) &&
            CVPixelBufferGetPixelFormatType(ciSourceBuffer) == kCVPixelFormatType_32BGRA &&
            CVPixelBufferGetWidth(ciSourceBuffer) == targetWidth &&
            CVPixelBufferGetHeight(ciSourceBuffer) == targetHeight &&
            (!diagonalActive || localSourceBuffer != NULL);
        if (passthroughFastPath && diagonalActive) {
            VCAMApplyBGRAChannelFactorsInPlace(localSourceBuffer, diagFactor);
        }

        CIRenderDestination *destination = [[CIRenderDestination alloc]
            initWithPixelBuffer:renderBuffer];
        VCAMSetStandardColorAttachments(renderBuffer);
        destination.colorSpace = VCAMStandardColorSpace;
        NSError *startError = nil;
        CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
        CIRenderTask *task = passthroughFastPath ? nil
            : [VCAMContext startTaskToRender:image
                                                  fromRect:image.extent
                                             toDestination:destination
                                                   atPoint:CGPointZero
                                                     error:&startError];
        NSError *completionError = nil;
        CIRenderInfo *renderInfo = nil;
        if (task != nil) {
            if (__sync_fetch_and_add(&VCAMMetalContextActive, 0) != 0) {
                // Metal 帧路径有界等待：CIRenderTask 没有 cancel，把阻塞等待放到
                // 独立串行渲染队列，主路径 1.5s 超时即返回（超时=本帧失败，触发
                // 下方永久回退软件；滞留队列至多一个、其持有的像素缓冲一次性
                // 泄漏 ~8MB，远小于每帧被挂起阻塞的风险）。
                static dispatch_queue_t metalRenderQueue;
                static dispatch_once_t metalQueueToken;
                dispatch_once(&metalQueueToken, ^{
                    metalRenderQueue = dispatch_queue_create("com.codex.vcam.metal-render",
                                                             DISPATCH_QUEUE_SERIAL);
                });
                dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
                __block CIRenderInfo *completedInfo = nil;
                __block NSError *waitError = nil;
                dispatch_async(metalRenderQueue, ^{
                    completedInfo = [task waitUntilCompletedAndReturnError:&waitError];
                    dispatch_semaphore_signal(semaphore);
                });
                if (dispatch_semaphore_wait(
                        semaphore, dispatch_time(DISPATCH_TIME_NOW,
                                                (int64_t)(1.5 * NSEC_PER_SEC))) == 0) {
                    renderInfo = completedInfo;
                    completionError = waitError;
                }
                // 超时保持 renderInfo=NULL：本帧按失败处理，下一帧起走软件上下文。
            } else {
                renderInfo = [task waitUntilCompletedAndReturnError:&completionError];
            }
        }
        BOOL coreImageRendered = task != nil && renderInfo != nil &&
            startError == nil && completionError == nil;
        if (passthroughFastPath) {
            static volatile int passthroughFastPathLogs = 0;
            int fastCount = __sync_add_and_fetch(&passthroughFastPathLogs, 1);
            if (fastCount <= 3 || fastCount % 300 == 0) {
                char message[160] = {0};
                snprintf(message, sizeof(message),
                         "bgra passthrough fast path count=%d target=%zux%zu",
                         fastCount, targetWidth, targetHeight);
                VCAMRefLog(message);
            }
            rendered = VCAMTransferBGRAIntoPlanarTarget(ciSourceBuffer, targetBuffer);
        } else {
            rendered = coreImageRendered &&
                (compressedTarget
                    ? VCAMTransferIntoCompressedTarget(
                        stagingBuffer, targetBuffer, compressedReplacementBuffer)
                    : (!planarTarget ||
                       (planarComposedWidth != targetWidth ||
                        planarComposedHeight != targetHeight
                           ? VCAMCopyScaledBGRAToPlanarTarget(
                               stagingBuffer, planarComposedWidth, planarComposedHeight,
                               targetBuffer)
                           : VCAMTransferBGRAIntoPlanarTarget(
                               stagingBuffer, targetBuffer))));
        }
        if (rendered && previewCacheEligible) {
            VCAMRememberPreviewTarget(
                targetBuffer, presentation, planarTarget, metadata,
                targetWidth, targetHeight, targetFormat);
        }
        if (rendered && publishPixelDiagnostics) {
            VCAMDebug6F2CPublishRGBGateDiagnostics(
                debug6F2CFallbackState, debug6F2CSurfaceRGB,
                debug6F2CMmapRGB, debug6F2CSurfaceGeneration,
                debug6F2CMmapGeneration, debug6F2CSourceState);
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
        if (!coreImageRendered && !passthroughFastPath &&
            __sync_fetch_and_add(&VCAMMetalContextActive, 0) != 0) {
            // Metal 真实帧首次失败（含 watchdog 取消）：永久回退软件上下文。
            // 本帧不重试——单帧失败远小于"每帧都可能挂起"的风险；下一帧起走软件。
            (void)__sync_lock_test_and_set(&VCAMMetalContextActive, 0);
            VCAMContext = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @YES}];
            VCAMRefLog("metal render failed; permanently falling back to software context");
        }
        if (!coreImageRendered && !passthroughFastPath) {
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
        if (localSourceBuffer != NULL) CVPixelBufferRelease(localSourceBuffer);
        if (scratch != NULL) CVPixelBufferRelease(scratch);
        VCAMSharedSurfaceFrameRelease(&surfaceFrame);
    }

    if (!rendered && compressedTarget && replacementBufferOut != NULL &&
        *replacementBufferOut == NULL) {
        rendered = VCAMCopyLastCompressedVirtualFrame(
            targetBuffer, replacementBufferOut);
    }

    if (previewCacheEligible) {
        VCAMRecordPreviewPerformance(
            NO, rendered,
            (CFAbsoluteTimeGetCurrent() - previewCallStarted) * 1000.0);
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

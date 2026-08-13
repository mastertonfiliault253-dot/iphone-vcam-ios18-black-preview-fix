#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import "VCAMSurfaceBroker.h"

#include <stdbool.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

enum {
    VCAMSharedFrameWidth = 1080,
    VCAMSharedFrameHeight = 1920,
    /// Maximum IOSurface ring depth. Static images use one slot; moving
    /// sources use all three. The legacy mmap fallback remains fixed at three.
    VCAMSharedFrameSlotCount = VCAMSurfaceBrokerVideoSlotCount,
};

typedef struct VCAMSharedFrameWriter VCAMSharedFrameWriter;
typedef struct VCAMSharedFrameReader VCAMSharedFrameReader;
typedef struct VCAMSharedSurfaceWriter VCAMSharedSurfaceWriter;
typedef struct VCAMSharedSurfaceReader VCAMSharedSurfaceReader;

typedef NS_ENUM(int32_t, VCAMSharedSurfaceReaderFailure) {
    VCAMSharedSurfaceReaderFailureNone = 0,
    VCAMSharedSurfaceReaderFailureOpen = 1,
    VCAMSharedSurfaceReaderFailureHeader = 2,
    VCAMSharedSurfaceReaderFailureStale = 3,
    VCAMSharedSurfaceReaderFailureLookup = 4,
    VCAMSharedSurfaceReaderFailurePixelBuffer = 5,
    VCAMSharedSurfaceReaderFailureChanged = 6,
};

typedef struct {
    uint64_t sequence;
    uint64_t monotonicTimestampNanoseconds;
    uint32_t width;
    uint32_t height;
    OSType pixelFormat;
    /// Zero for mmap; the IOSurface ID for surface-backed frames.
    uint32_t surfaceID;
    /// Zero for mmap; stable across every slot owned by one surface writer.
    uint64_t surfaceGeneration;
    /// Compact CoreVideo color attachment identifiers. Zero means the source
    /// did not provide that attachment.
    uint32_t colorPrimaries;
    /// High 8 bits carry the decoder class (1 = VideoToolbox hardware,
    /// 0 = software). CoreVideo transfer IDs are < 256, so the low 24 bits
    /// stay the real transfer function. See VCAMSharedFrameDecodeHardware.
    uint32_t transferFunction;
    uint32_t yCbCrMatrix;
} VCAMSharedFrameMetadata;

/// A retained, cross-process IOSurface frame. Release it with
/// VCAMSharedSurfaceFrameRelease so the producer can safely reuse its slot.
typedef struct {
    CVPixelBufferRef _Nullable pixelBuffer;
    void *_Nullable surface;
    void *_Nullable useCounter;
    uint32_t surfaceID;
    VCAMSharedFrameMetadata metadata;
} VCAMSharedSurfaceFrame;

/// Producer interface. The implementation owns file creation, mmap layout,
/// slot selection, publication ordering and permissions.
VCAMSharedFrameWriter *_Nullable VCAMSharedFrameWriterCreate(void);
void VCAMSharedFrameWriterDestroy(VCAMSharedFrameWriter *_Nullable writer);
bool VCAMSharedFrameWriterPublish(VCAMSharedFrameWriter *writer,
                                  CVPixelBufferRef pixelBuffer);
bool VCAMSharedFrameWriterPublishForSurfaceGeneration(
    VCAMSharedFrameWriter *writer, CVPixelBufferRef pixelBuffer,
    uint64_t surfaceGeneration);

/// Updates only the requested virtual-camera state in an existing shared
/// transport. SpringBoard is the sole control-plane writer and uses this after
/// an atomic configuration write so mediaserverd observes enable/restore
/// without reading mobile's sandbox. The media worker must never call it.
bool VCAMSharedFrameSetRequestedActive(bool active);

/// Consumer interface. Copying is non-blocking and fails when the producer is
/// absent, a frame is stale, or a slot changes while it is being copied.
VCAMSharedFrameReader *VCAMSharedFrameReaderCreate(void);
void VCAMSharedFrameReaderDestroy(VCAMSharedFrameReader *_Nullable reader);
bool VCAMSharedFrameReaderGetActiveState(VCAMSharedFrameReader *reader,
                                         bool *active);
bool VCAMSharedFrameReaderGetLatestMetadata(
    VCAMSharedFrameReader *reader,
    uint64_t maximumAgeNanoseconds,
    VCAMSharedFrameMetadata *_Nullable metadata);
bool VCAMSharedFrameReaderCopyLatest(VCAMSharedFrameReader *reader,
                                     CVPixelBufferRef destination,
                                     uint64_t maximumAgeNanoseconds,
                                     VCAMSharedFrameMetadata *_Nullable metadata);

/// Zero-copy IOSurface producer. The writable buffers form a bounded ring; a
/// slot held by a consumer is never selected for rendering.
VCAMSharedSurfaceWriter *_Nullable VCAMSharedSurfaceWriterCreate(void);
VCAMSharedSurfaceWriter *_Nullable VCAMSharedSurfaceWriterCreateWithPixelFormat(
    OSType pixelFormat);
VCAMSharedSurfaceWriter *_Nullable VCAMSharedSurfaceWriterCreateConfigured(
    uint32_t width, uint32_t height, OSType pixelFormat, uint32_t slotCount);
bool VCAMSharedSurfaceWriterIsCurrent(VCAMSharedSurfaceWriter *_Nullable writer);
uint64_t VCAMSharedSurfaceWriterGeneration(
    VCAMSharedSurfaceWriter *_Nullable writer);
void VCAMSharedSurfaceWriterDestroy(VCAMSharedSurfaceWriter *_Nullable writer);
CVPixelBufferRef _Nullable VCAMSharedSurfaceWriterCopyNextPixelBuffer(
    VCAMSharedSurfaceWriter *writer) CF_RETURNS_RETAINED;
bool VCAMSharedSurfaceWriterPublish(VCAMSharedSurfaceWriter *writer,
                                    CVPixelBufferRef pixelBuffer);
/// Refreshes the age of an immutable one-slot frame without copying pixels.
bool VCAMSharedSurfaceWriterRefreshLatest(VCAMSharedSurfaceWriter *writer);
bool VCAMSharedSurfaceWriterHasConsumer(VCAMSharedSurfaceWriter *writer);

/// Zero-copy IOSurface consumer. Failure is expected while a new producer's
/// XPC right is arriving; callers may use only its fresh mmap bootstrap until
/// that surface generation has been adopted.
VCAMSharedSurfaceReader *_Nullable VCAMSharedSurfaceReaderCreate(void);
void VCAMSharedSurfaceReaderDestroy(VCAMSharedSurfaceReader *_Nullable reader);
bool VCAMSharedSurfaceReaderGetLatestMetadata(
    VCAMSharedSurfaceReader *reader,
    uint64_t maximumAgeNanoseconds,
    VCAMSharedFrameMetadata *_Nullable metadata);
bool VCAMSharedSurfaceReaderCopyLatest(VCAMSharedSurfaceReader *reader,
                                       uint64_t maximumAgeNanoseconds,
                                       VCAMSharedSurfaceFrame *frame);
/// Observer copy that participates in per-slot exclusion without claiming the
/// primary consumer heartbeat. Intended for passive control-panel preview UI.
bool VCAMSharedSurfaceReaderCopyLatestPassive(
    VCAMSharedSurfaceReader *reader,
    uint64_t maximumAgeNanoseconds,
    VCAMSharedSurfaceFrame *frame);
VCAMSharedSurfaceReaderFailure VCAMSharedSurfaceReaderLastFailure(
    VCAMSharedSurfaceReader *reader);
void VCAMSharedSurfaceFrameRelease(VCAMSharedSurfaceFrame *frame);

const char *VCAMSharedFrameFileSystemPath(void);
const char *VCAMSharedSurfaceFileSystemPath(void);
/// Decoder-class mask stored in the high 8 bits of
/// VCAMSharedFrameMetadata.transferFunction.
#define VCAMSharedFrameDecodeHardwareShift 24
#define VCAMSharedFrameDecodeHardwareMask 0xFF000000U
#define VCAMSharedFrameTransferFunctionMask 0x00FFFFFFU

uint64_t VCAMSharedFrameMonotonicNanoseconds(void);

NS_ASSUME_NONNULL_END

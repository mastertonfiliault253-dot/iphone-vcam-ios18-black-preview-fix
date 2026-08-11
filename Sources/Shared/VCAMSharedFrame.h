#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

#include <stdbool.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

enum {
    VCAMSharedFrameWidth = 1080,
    VCAMSharedFrameHeight = 1920,
    VCAMSharedFrameSlotCount = 3,
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
} VCAMSharedFrameMetadata;

/// A retained, cross-process IOSurface frame. Release it with
/// VCAMSharedSurfaceFrameRelease so the producer can safely reuse its slot.
typedef struct {
    CVPixelBufferRef _Nullable pixelBuffer;
    void *_Nullable surface;
    void *_Nullable useCounter;
    VCAMSharedFrameMetadata metadata;
} VCAMSharedSurfaceFrame;

/// Producer interface. The implementation owns file creation, mmap layout,
/// slot selection, publication ordering and permissions.
VCAMSharedFrameWriter *_Nullable VCAMSharedFrameWriterCreate(void);
void VCAMSharedFrameWriterDestroy(VCAMSharedFrameWriter *_Nullable writer);
bool VCAMSharedFrameWriterPublish(VCAMSharedFrameWriter *writer,
                                  CVPixelBufferRef pixelBuffer);

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

/// Zero-copy IOSurface producer. The writable buffers form a bounded
/// three-slot ring; a slot held by a consumer is never selected for rendering.
VCAMSharedSurfaceWriter *_Nullable VCAMSharedSurfaceWriterCreate(void);
VCAMSharedSurfaceWriter *_Nullable VCAMSharedSurfaceWriterCreateWithPixelFormat(
    OSType pixelFormat);
bool VCAMSharedSurfaceWriterIsCurrent(VCAMSharedSurfaceWriter *_Nullable writer);
void VCAMSharedSurfaceWriterDestroy(VCAMSharedSurfaceWriter *_Nullable writer);
CVPixelBufferRef _Nullable VCAMSharedSurfaceWriterCopyNextPixelBuffer(
    VCAMSharedSurfaceWriter *writer) CF_RETURNS_RETAINED;
bool VCAMSharedSurfaceWriterPublish(VCAMSharedSurfaceWriter *writer,
                                    CVPixelBufferRef pixelBuffer);
bool VCAMSharedSurfaceWriterHasConsumer(VCAMSharedSurfaceWriter *writer);

/// Zero-copy IOSurface consumer. Failure is expected when the platform blocks
/// global IOSurface lookup; callers must retain the legacy mmap fallback.
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
/// primary consumer heartbeat. Intended for SpringBoard preview UI.
bool VCAMSharedSurfaceReaderCopyLatestPassive(
    VCAMSharedSurfaceReader *reader,
    uint64_t maximumAgeNanoseconds,
    VCAMSharedSurfaceFrame *frame);
VCAMSharedSurfaceReaderFailure VCAMSharedSurfaceReaderLastFailure(
    VCAMSharedSurfaceReader *reader);
void VCAMSharedSurfaceFrameRelease(VCAMSharedSurfaceFrame *frame);

const char *VCAMSharedFrameFileSystemPath(void);
const char *VCAMSharedSurfaceFileSystemPath(void);
uint64_t VCAMSharedFrameMonotonicNanoseconds(void);

NS_ASSUME_NONNULL_END

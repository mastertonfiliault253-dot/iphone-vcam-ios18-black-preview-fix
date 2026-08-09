#import "VCAMSharedFrame.h"

#include <errno.h>
#include <fcntl.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

// The iPhoneOS 16.5 SDK exposes IOSurface-backed CVPixelBuffers through
// CoreVideo but does not ship IOSurface framework headers. Keep the narrow
// cross-process ABI local instead of copying the private framework header.
extern uint32_t IOSurfaceGetID(IOSurfaceRef surface);
extern IOSurfaceRef _Nullable IOSurfaceLookup(uint32_t surfaceID)
    CF_RETURNS_RETAINED;
extern void IOSurfaceIncrementUseCount(IOSurfaceRef surface);
extern void IOSurfaceDecrementUseCount(IOSurfaceRef surface);

static const uint32_t VCAMSharedFrameMagic = 0x5643414d;
static const uint32_t VCAMSharedFrameVersion = 2;
static const char *const VCAMSharedFramePath = "/var/tmp/com.codex.vcam.frames";
static const uint32_t VCAMSharedSurfaceMagic = 0x56435346;
static const uint32_t VCAMSharedSurfaceVersion = 2;
static const char *const VCAMSharedSurfacePath = "/var/tmp/com.codex.vcam.surfaces";
static const size_t VCAMSharedFrameBytesPerRow = VCAMSharedFrameWidth * 4;
static const size_t VCAMSharedFrameSlotBytes = VCAMSharedFrameBytesPerRow * VCAMSharedFrameHeight;

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t headerBytes;
    uint32_t slotCount;
    uint32_t width;
    uint32_t height;
    uint32_t bytesPerRow;
    uint32_t pixelFormat;
    uint64_t slotBytes;
    // Low bit is the requested enabled state; upper bits are a monotonically
    // increasing generation. One atomic word prevents torn mode/generation
    // reads and makes concurrent SpringBoard/vcamd writers orderable.
    _Atomic(uint64_t) requestedState;
    _Atomic(uint32_t) publishedSlot;
    _Atomic(uint64_t) publishedSequence;
    _Atomic(uint64_t) publishedTimestampNanoseconds;
    _Atomic(uint64_t) slotSequence[VCAMSharedFrameSlotCount];
} VCAMSharedFrameHeader;

struct VCAMSharedFrameWriter {
    int descriptor;
    size_t mappedBytes;
    void *mapping;
    VCAMSharedFrameHeader *header;
};

struct VCAMSharedFrameReader {
    int descriptor;
    size_t mappedBytes;
    void *mapping;
    const VCAMSharedFrameHeader *header;
};

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t headerBytes;
    uint32_t slotCount;
    uint32_t width;
    uint32_t height;
    uint32_t pixelFormat;
    uint32_t surfaceIDs[VCAMSharedFrameSlotCount];
    _Atomic(uint32_t) publishedSlot;
    _Atomic(uint64_t) publishedSequence;
    _Atomic(uint64_t) publishedTimestampNanoseconds;
    _Atomic(uint64_t) slotSequence[VCAMSharedFrameSlotCount];
    _Atomic(uint32_t) consumerUseCount[VCAMSharedFrameSlotCount];
} VCAMSharedSurfaceHeader;

struct VCAMSharedSurfaceWriter {
    int descriptor;
    void *mapping;
    VCAMSharedSurfaceHeader *header;
    IOSurfaceRef surfaces[VCAMSharedFrameSlotCount];
    CVPixelBufferRef pixelBuffers[VCAMSharedFrameSlotCount];
    uint32_t pendingSlot;
    uint64_t pendingSequence;
};

struct VCAMSharedSurfaceReader {
    int descriptor;
    void *mapping;
    const VCAMSharedSurfaceHeader *header;
};

static size_t VCAMSharedFrameMappedBytes(void) {
    return sizeof(VCAMSharedFrameHeader) + VCAMSharedFrameSlotCount * VCAMSharedFrameSlotBytes;
}

static uint8_t *VCAMSharedFrameMutableSlot(void *mapping, uint32_t slot) {
    return (uint8_t *)mapping + sizeof(VCAMSharedFrameHeader) + slot * VCAMSharedFrameSlotBytes;
}

static const uint8_t *VCAMSharedFrameSlot(const void *mapping, uint32_t slot) {
    return (const uint8_t *)mapping + sizeof(VCAMSharedFrameHeader) + slot * VCAMSharedFrameSlotBytes;
}

static bool VCAMSharedFrameHeaderIsValid(const VCAMSharedFrameHeader *header) {
    return header != NULL &&
        header->magic == VCAMSharedFrameMagic &&
        header->version == VCAMSharedFrameVersion &&
        header->headerBytes == sizeof(VCAMSharedFrameHeader) &&
        header->slotCount == VCAMSharedFrameSlotCount &&
        header->width == VCAMSharedFrameWidth &&
        header->height == VCAMSharedFrameHeight &&
        header->bytesPerRow == VCAMSharedFrameBytesPerRow &&
        header->pixelFormat == kCVPixelFormatType_32BGRA &&
        header->slotBytes == VCAMSharedFrameSlotBytes;
}

static void VCAMSharedFrameInitializeHeader(VCAMSharedFrameHeader *header,
                                            bool active) {
    if (header == NULL) return;
    memset(header, 0, sizeof(*header));
    header->version = VCAMSharedFrameVersion;
    header->headerBytes = sizeof(VCAMSharedFrameHeader);
    header->slotCount = VCAMSharedFrameSlotCount;
    header->width = VCAMSharedFrameWidth;
    header->height = VCAMSharedFrameHeight;
    header->bytesPerRow = (uint32_t)VCAMSharedFrameBytesPerRow;
    header->pixelFormat = kCVPixelFormatType_32BGRA;
    header->slotBytes = VCAMSharedFrameSlotBytes;
    atomic_store_explicit(&header->requestedState, active ? 1 : 0,
                          memory_order_release);
    atomic_thread_fence(memory_order_release);
    // Publish the magic last so readers never accept a partial header.
    header->magic = VCAMSharedFrameMagic;
}

static bool VCAMSharedFrameHeaderSetRequestedActive(VCAMSharedFrameHeader *header,
                                                    bool active) {
    if (header == NULL || !VCAMSharedFrameHeaderIsValid(header)) return false;
    uint64_t current = atomic_load_explicit(&header->requestedState,
                                            memory_order_acquire);
    for (NSUInteger attempt = 0; attempt < 64; attempt++) {
        uint64_t next = ((current + 2ULL) & ~1ULL) | (active ? 1ULL : 0ULL);
        if (atomic_compare_exchange_weak_explicit(
                &header->requestedState, &current, next,
                memory_order_acq_rel, memory_order_acquire)) return true;
    }
    return false;
}

static bool VCAMSharedFrameLockExclusive(int descriptor) {
    int result = 0;
    do {
        result = flock(descriptor, LOCK_EX);
    } while (result != 0 && errno == EINTR);
    return result == 0;
}

static void VCAMSharedFrameUnlock(int descriptor) {
    while (flock(descriptor, LOCK_UN) != 0 && errno == EINTR) {}
}

const char *VCAMSharedFrameFileSystemPath(void) {
    return VCAMSharedFramePath;
}

const char *VCAMSharedSurfaceFileSystemPath(void) {
    return VCAMSharedSurfacePath;
}

uint64_t VCAMSharedFrameMonotonicNanoseconds(void) {
    struct timespec value = {0};
    if (clock_gettime(CLOCK_MONOTONIC, &value) != 0) return 0;
    return (uint64_t)value.tv_sec * 1000000000ULL + (uint64_t)value.tv_nsec;
}

VCAMSharedFrameWriter *VCAMSharedFrameWriterCreate(void) {
    VCAMSharedFrameWriter *writer = calloc(1, sizeof(*writer));
    if (writer == NULL) return NULL;
    writer->descriptor = open(VCAMSharedFramePath, O_RDWR | O_CREAT, 0644);
    writer->mappedBytes = VCAMSharedFrameMappedBytes();
    if (writer->descriptor < 0 || ftruncate(writer->descriptor, (off_t)writer->mappedBytes) != 0) {
        VCAMSharedFrameWriterDestroy(writer);
        return NULL;
    }
    fchmod(writer->descriptor, 0644);
    writer->mapping = mmap(NULL, writer->mappedBytes, PROT_READ | PROT_WRITE,
                           MAP_SHARED, writer->descriptor, 0);
    if (writer->mapping == MAP_FAILED) {
        writer->mapping = NULL;
        VCAMSharedFrameWriterDestroy(writer);
        return NULL;
    }
    writer->header = writer->mapping;
    if (!VCAMSharedFrameLockExclusive(writer->descriptor)) {
        VCAMSharedFrameWriterDestroy(writer);
        return NULL;
    }
    if (!VCAMSharedFrameHeaderIsValid(writer->header)) {
        memset(writer->mapping, 0, writer->mappedBytes);
        // Unknown/new transport state is fail-closed until SpringBoard
        // publishes the canonical persisted state.
        VCAMSharedFrameInitializeHeader(writer->header, true);
    }
    VCAMSharedFrameUnlock(writer->descriptor);
    return writer;
}

void VCAMSharedFrameWriterDestroy(VCAMSharedFrameWriter *writer) {
    if (writer == NULL) return;
    // Preserve both the requested mode and last published virtual frame across
    // worker restarts. A decoder/worker exit must freeze virtual output rather
    // than expose the real camera.
    if (writer->mapping != NULL) munmap(writer->mapping, writer->mappedBytes);
    if (writer->descriptor >= 0) close(writer->descriptor);
    free(writer);
}

bool VCAMSharedFrameWriterPublish(VCAMSharedFrameWriter *writer,
                                  CVPixelBufferRef pixelBuffer) {
    if (writer == NULL || writer->header == NULL || pixelBuffer == NULL ||
        CVPixelBufferGetWidth(pixelBuffer) != VCAMSharedFrameWidth ||
        CVPixelBufferGetHeight(pixelBuffer) != VCAMSharedFrameHeight ||
        CVPixelBufferGetPixelFormatType(pixelBuffer) != kCVPixelFormatType_32BGRA) {
        return false;
    }
    if (CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
        return false;
    }
    uint64_t sequence = atomic_load_explicit(&writer->header->publishedSequence,
                                             memory_order_relaxed) + 1;
    uint32_t slot = (uint32_t)(sequence % VCAMSharedFrameSlotCount);
    // Invalidate the slot before overwriting it. A reader that started copying
    // the same slot will reject the result on its post-copy sequence check.
    atomic_store_explicit(&writer->header->slotSequence[slot], 0, memory_order_release);
    uint8_t *destination = VCAMSharedFrameMutableSlot(writer->mapping, slot);
    const uint8_t *source = (const uint8_t *)CVPixelBufferGetBaseAddress(pixelBuffer);
    size_t sourceBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
    for (size_t row = 0; row < VCAMSharedFrameHeight; row++) {
        memcpy(destination + row * VCAMSharedFrameBytesPerRow,
               source + row * sourceBytesPerRow,
               VCAMSharedFrameBytesPerRow);
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

    uint64_t timestamp = VCAMSharedFrameMonotonicNanoseconds();
    atomic_store_explicit(&writer->header->slotSequence[slot], sequence, memory_order_release);
    atomic_store_explicit(&writer->header->publishedTimestampNanoseconds, timestamp,
                          memory_order_relaxed);
    atomic_store_explicit(&writer->header->publishedSlot, slot, memory_order_relaxed);
    atomic_store_explicit(&writer->header->publishedSequence, sequence, memory_order_release);
    return true;
}

bool VCAMSharedFrameSetRequestedActive(bool active) {
    int descriptor = open(VCAMSharedFramePath, O_RDWR | O_CREAT, 0644);
    if (descriptor < 0) return false;
    struct stat metadata = {0};
    if (fstat(descriptor, &metadata) != 0) {
        close(descriptor);
        return false;
    }
    if ((size_t)metadata.st_size < VCAMSharedFrameMappedBytes() &&
        ftruncate(descriptor, (off_t)VCAMSharedFrameMappedBytes()) != 0) {
        close(descriptor);
        return false;
    }
    fchmod(descriptor, 0644);
    void *mapping = mmap(NULL, sizeof(VCAMSharedFrameHeader),
                         PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0);
    if (mapping == MAP_FAILED) {
        close(descriptor);
        return false;
    }
    if (!VCAMSharedFrameLockExclusive(descriptor)) {
        munmap(mapping, sizeof(VCAMSharedFrameHeader));
        close(descriptor);
        return false;
    }
    VCAMSharedFrameHeader *header = mapping;
    bool valid = VCAMSharedFrameHeaderIsValid(header);
    if (!valid) {
        VCAMSharedFrameInitializeHeader(header, active);
        valid = true;
    } else {
        valid = VCAMSharedFrameHeaderSetRequestedActive(header, active);
    }
    VCAMSharedFrameUnlock(descriptor);
    munmap(mapping, sizeof(VCAMSharedFrameHeader));
    close(descriptor);
    return valid;
}

VCAMSharedFrameReader *VCAMSharedFrameReaderCreate(void) {
    VCAMSharedFrameReader *reader = calloc(1, sizeof(*reader));
    if (reader != NULL) reader->descriptor = -1;
    return reader;
}

static void VCAMSharedFrameReaderUnmap(VCAMSharedFrameReader *reader) {
    if (reader->mapping != NULL) munmap(reader->mapping, reader->mappedBytes);
    if (reader->descriptor >= 0) close(reader->descriptor);
    reader->descriptor = -1;
    reader->mapping = NULL;
    reader->mappedBytes = 0;
    reader->header = NULL;
}

static bool VCAMSharedFrameReaderEnsureMapped(VCAMSharedFrameReader *reader) {
    if (reader->header != NULL && VCAMSharedFrameHeaderIsValid(reader->header)) return true;
    VCAMSharedFrameReaderUnmap(reader);
    reader->descriptor = open(VCAMSharedFramePath, O_RDONLY);
    reader->mappedBytes = VCAMSharedFrameMappedBytes();
    if (reader->descriptor < 0) return false;
    struct stat metadata = {0};
    if (fstat(reader->descriptor, &metadata) != 0 ||
        (size_t)metadata.st_size < reader->mappedBytes) {
        VCAMSharedFrameReaderUnmap(reader);
        return false;
    }
    reader->mapping = mmap(NULL, reader->mappedBytes, PROT_READ, MAP_SHARED,
                           reader->descriptor, 0);
    if (reader->mapping == MAP_FAILED) {
        reader->mapping = NULL;
        VCAMSharedFrameReaderUnmap(reader);
        return false;
    }
    reader->header = reader->mapping;
    if (!VCAMSharedFrameHeaderIsValid(reader->header)) {
        VCAMSharedFrameReaderUnmap(reader);
        return false;
    }
    return true;
}

void VCAMSharedFrameReaderDestroy(VCAMSharedFrameReader *reader) {
    if (reader == NULL) return;
    VCAMSharedFrameReaderUnmap(reader);
    free(reader);
}

bool VCAMSharedFrameReaderGetActiveState(VCAMSharedFrameReader *reader,
                                         bool *active) {
    if (reader == NULL || active == NULL ||
        !VCAMSharedFrameReaderEnsureMapped(reader)) return false;
    uint64_t requestedState = atomic_load_explicit(
        &reader->header->requestedState, memory_order_acquire);
    *active = (requestedState & 1ULL) != 0;
    return true;
}

bool VCAMSharedFrameReaderCopyLatest(VCAMSharedFrameReader *reader,
                                     CVPixelBufferRef destination,
                                     uint64_t maximumAgeNanoseconds,
                                     VCAMSharedFrameMetadata *metadata) {
    if (reader == NULL || destination == NULL ||
        !VCAMSharedFrameReaderEnsureMapped(reader) ||
        CVPixelBufferGetWidth(destination) != VCAMSharedFrameWidth ||
        CVPixelBufferGetHeight(destination) != VCAMSharedFrameHeight ||
        CVPixelBufferGetPixelFormatType(destination) != kCVPixelFormatType_32BGRA ||
        (atomic_load_explicit(&reader->header->requestedState,
                              memory_order_acquire) & 1ULL) == 0) {
        return false;
    }

    uint64_t sequence = atomic_load_explicit(&reader->header->publishedSequence,
                                             memory_order_acquire);
    uint32_t slot = atomic_load_explicit(&reader->header->publishedSlot,
                                         memory_order_relaxed);
    uint64_t timestamp = atomic_load_explicit(&reader->header->publishedTimestampNanoseconds,
                                              memory_order_relaxed);
    uint64_t now = VCAMSharedFrameMonotonicNanoseconds();
    if (sequence == 0 || slot >= VCAMSharedFrameSlotCount || timestamp == 0 ||
        (maximumAgeNanoseconds > 0 && (now < timestamp || now - timestamp > maximumAgeNanoseconds)) ||
        atomic_load_explicit(&reader->header->slotSequence[slot], memory_order_acquire) != sequence) {
        return false;
    }

    if (CVPixelBufferLockBaseAddress(destination, 0) != kCVReturnSuccess) return false;
    uint8_t *target = (uint8_t *)CVPixelBufferGetBaseAddress(destination);
    size_t targetBytesPerRow = CVPixelBufferGetBytesPerRow(destination);
    const uint8_t *source = VCAMSharedFrameSlot(reader->mapping, slot);
    for (size_t row = 0; row < VCAMSharedFrameHeight; row++) {
        memcpy(target + row * targetBytesPerRow,
               source + row * VCAMSharedFrameBytesPerRow,
               VCAMSharedFrameBytesPerRow);
    }
    CVPixelBufferUnlockBaseAddress(destination, 0);

    if (atomic_load_explicit(&reader->header->slotSequence[slot], memory_order_acquire) != sequence ||
        atomic_load_explicit(&reader->header->publishedSequence, memory_order_acquire) < sequence) {
        return false;
    }
    if (metadata != NULL) {
        metadata->sequence = sequence;
        metadata->monotonicTimestampNanoseconds = timestamp;
        metadata->width = VCAMSharedFrameWidth;
        metadata->height = VCAMSharedFrameHeight;
        metadata->pixelFormat = kCVPixelFormatType_32BGRA;
    }
    return true;
}

static bool VCAMSharedSurfaceHeaderIsValid(const VCAMSharedSurfaceHeader *header) {
    if (header == NULL || header->magic != VCAMSharedSurfaceMagic ||
        header->version != VCAMSharedSurfaceVersion ||
        header->headerBytes != sizeof(VCAMSharedSurfaceHeader) ||
        header->slotCount != VCAMSharedFrameSlotCount ||
        header->width != VCAMSharedFrameWidth ||
        header->height != VCAMSharedFrameHeight ||
        header->pixelFormat != kCVPixelFormatType_32BGRA) return false;
    for (uint32_t slot = 0; slot < VCAMSharedFrameSlotCount; slot++) {
        if (header->surfaceIDs[slot] == 0) return false;
    }
    return true;
}

static CVPixelBufferRef VCAMSharedSurfaceCreatePixelBuffer(void) {
    CVPixelBufferRef pixelBuffer = NULL;
    NSDictionary *attributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey: @(VCAMSharedFrameWidth),
        (id)kCVPixelBufferHeightKey: @(VCAMSharedFrameHeight),
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{
            @"IOSurfaceIsGlobal": @YES,
        },
    };
    CVReturn status = CVPixelBufferCreate(
        kCFAllocatorDefault, VCAMSharedFrameWidth, VCAMSharedFrameHeight,
        kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attributes,
        &pixelBuffer);
    return status == kCVReturnSuccess ? pixelBuffer : NULL;
}

VCAMSharedSurfaceWriter *VCAMSharedSurfaceWriterCreate(void) {
    VCAMSharedSurfaceWriter *writer = calloc(1, sizeof(*writer));
    if (writer == NULL) return NULL;
    writer->descriptor = -1;
    writer->pendingSlot = UINT32_MAX;
    writer->descriptor = open(VCAMSharedSurfacePath, O_RDWR | O_CREAT, 0644);
    if (writer->descriptor < 0 ||
        ftruncate(writer->descriptor, sizeof(VCAMSharedSurfaceHeader)) != 0) {
        VCAMSharedSurfaceWriterDestroy(writer);
        return NULL;
    }
    fchmod(writer->descriptor, 0644);
    writer->mapping = mmap(NULL, sizeof(VCAMSharedSurfaceHeader),
                           PROT_READ | PROT_WRITE, MAP_SHARED,
                           writer->descriptor, 0);
    if (writer->mapping == MAP_FAILED) {
        writer->mapping = NULL;
        VCAMSharedSurfaceWriterDestroy(writer);
        return NULL;
    }
    writer->header = writer->mapping;

    uint32_t surfaceIDs[VCAMSharedFrameSlotCount] = {0};
    for (uint32_t slot = 0; slot < VCAMSharedFrameSlotCount; slot++) {
        writer->pixelBuffers[slot] = VCAMSharedSurfaceCreatePixelBuffer();
        writer->surfaces[slot] = writer->pixelBuffers[slot] == NULL ? NULL
            : CVPixelBufferGetIOSurface(writer->pixelBuffers[slot]);
        if (writer->pixelBuffers[slot] == NULL || writer->surfaces[slot] == NULL) {
            VCAMSharedSurfaceWriterDestroy(writer);
            return NULL;
        }
        CFRetain(writer->surfaces[slot]);
        surfaceIDs[slot] = IOSurfaceGetID(writer->surfaces[slot]);
        if (surfaceIDs[slot] == 0) {
            VCAMSharedSurfaceWriterDestroy(writer);
            return NULL;
        }
    }
    if (!VCAMSharedFrameLockExclusive(writer->descriptor)) {
        VCAMSharedSurfaceWriterDestroy(writer);
        return NULL;
    }
    memset(writer->header, 0, sizeof(*writer->header));
    writer->header->version = VCAMSharedSurfaceVersion;
    writer->header->headerBytes = sizeof(*writer->header);
    writer->header->slotCount = VCAMSharedFrameSlotCount;
    writer->header->width = VCAMSharedFrameWidth;
    writer->header->height = VCAMSharedFrameHeight;
    writer->header->pixelFormat = kCVPixelFormatType_32BGRA;
    memcpy(writer->header->surfaceIDs, surfaceIDs, sizeof(surfaceIDs));
    atomic_thread_fence(memory_order_release);
    writer->header->magic = VCAMSharedSurfaceMagic;
    VCAMSharedFrameUnlock(writer->descriptor);
    return writer;
}

void VCAMSharedSurfaceWriterDestroy(VCAMSharedSurfaceWriter *writer) {
    if (writer == NULL) return;
    if (writer->header != NULL && writer->descriptor >= 0 &&
        VCAMSharedFrameLockExclusive(writer->descriptor)) {
        bool ownsHeader = VCAMSharedSurfaceHeaderIsValid(writer->header);
        for (uint32_t slot = 0; ownsHeader && slot < VCAMSharedFrameSlotCount; slot++) {
            ownsHeader = writer->surfaces[slot] != NULL &&
                writer->header->surfaceIDs[slot] == IOSurfaceGetID(writer->surfaces[slot]);
        }
        if (ownsHeader) writer->header->magic = 0;
        VCAMSharedFrameUnlock(writer->descriptor);
    }
    for (uint32_t slot = 0; slot < VCAMSharedFrameSlotCount; slot++) {
        if (writer->pixelBuffers[slot] != NULL) {
            CVPixelBufferRelease(writer->pixelBuffers[slot]);
        }
        if (writer->surfaces[slot] != NULL) CFRelease(writer->surfaces[slot]);
    }
    if (writer->mapping != NULL) {
        munmap(writer->mapping, sizeof(VCAMSharedSurfaceHeader));
    }
    if (writer->descriptor >= 0) close(writer->descriptor);
    free(writer);
}

CVPixelBufferRef VCAMSharedSurfaceWriterCopyNextPixelBuffer(
    VCAMSharedSurfaceWriter *writer) {
    if (writer == NULL || writer->header == NULL ||
        !VCAMSharedSurfaceHeaderIsValid(writer->header)) return NULL;
    // A render that threw or was abandoned must drop one frame, not wedge the
    // bounded transport forever.
    writer->pendingSlot = UINT32_MAX;
    writer->pendingSequence = 0;
    uint64_t sequence = atomic_load_explicit(
        &writer->header->publishedSequence, memory_order_relaxed) + 1;
    for (uint32_t offset = 0; offset < VCAMSharedFrameSlotCount; offset++) {
        uint32_t slot = (uint32_t)((sequence + offset) % VCAMSharedFrameSlotCount);
        if (atomic_load_explicit(&writer->header->consumerUseCount[slot],
                                 memory_order_acquire) != 0) continue;
        atomic_store_explicit(&writer->header->slotSequence[slot], 0,
                              memory_order_release);
        writer->pendingSlot = slot;
        writer->pendingSequence = sequence;
        return CVPixelBufferRetain(writer->pixelBuffers[slot]);
    }
    return NULL;
}

bool VCAMSharedSurfaceWriterPublish(VCAMSharedSurfaceWriter *writer,
                                    CVPixelBufferRef pixelBuffer) {
    if (writer == NULL || pixelBuffer == NULL || writer->pendingSlot >=
        VCAMSharedFrameSlotCount ||
        writer->pixelBuffers[writer->pendingSlot] != pixelBuffer) return false;
    uint32_t slot = writer->pendingSlot;
    uint64_t sequence = writer->pendingSequence;
    uint64_t timestamp = VCAMSharedFrameMonotonicNanoseconds();
    atomic_store_explicit(&writer->header->slotSequence[slot], sequence,
                          memory_order_release);
    atomic_store_explicit(&writer->header->publishedTimestampNanoseconds,
                          timestamp, memory_order_relaxed);
    atomic_store_explicit(&writer->header->publishedSlot, slot,
                          memory_order_relaxed);
    atomic_store_explicit(&writer->header->publishedSequence, sequence,
                          memory_order_release);
    writer->pendingSlot = UINT32_MAX;
    writer->pendingSequence = 0;
    return true;
}

VCAMSharedSurfaceReader *VCAMSharedSurfaceReaderCreate(void) {
    VCAMSharedSurfaceReader *reader = calloc(1, sizeof(*reader));
    if (reader != NULL) reader->descriptor = -1;
    return reader;
}

static void VCAMSharedSurfaceReaderUnmap(VCAMSharedSurfaceReader *reader) {
    if (reader->mapping != NULL) {
        munmap(reader->mapping, sizeof(VCAMSharedSurfaceHeader));
    }
    if (reader->descriptor >= 0) close(reader->descriptor);
    reader->descriptor = -1;
    reader->mapping = NULL;
    reader->header = NULL;
}

static bool VCAMSharedSurfaceReaderEnsureMapped(VCAMSharedSurfaceReader *reader) {
    if (reader == NULL) return false;
    if (reader->header != NULL && VCAMSharedSurfaceHeaderIsValid(reader->header)) {
        return true;
    }
    VCAMSharedSurfaceReaderUnmap(reader);
    reader->descriptor = open(VCAMSharedSurfacePath, O_RDWR);
    if (reader->descriptor < 0) return false;
    struct stat metadata = {0};
    if (fstat(reader->descriptor, &metadata) != 0 ||
        metadata.st_size < (off_t)sizeof(VCAMSharedSurfaceHeader)) {
        VCAMSharedSurfaceReaderUnmap(reader);
        return false;
    }
    reader->mapping = mmap(NULL, sizeof(VCAMSharedSurfaceHeader),
                           PROT_READ | PROT_WRITE,
                           MAP_SHARED, reader->descriptor, 0);
    if (reader->mapping == MAP_FAILED) {
        reader->mapping = NULL;
        VCAMSharedSurfaceReaderUnmap(reader);
        return false;
    }
    reader->header = reader->mapping;
    if (!VCAMSharedSurfaceHeaderIsValid(reader->header)) {
        VCAMSharedSurfaceReaderUnmap(reader);
        return false;
    }
    return true;
}

void VCAMSharedSurfaceReaderDestroy(VCAMSharedSurfaceReader *reader) {
    if (reader == NULL) return;
    VCAMSharedSurfaceReaderUnmap(reader);
    free(reader);
}

bool VCAMSharedSurfaceReaderCopyLatest(VCAMSharedSurfaceReader *reader,
                                       uint64_t maximumAgeNanoseconds,
                                       VCAMSharedSurfaceFrame *frame) {
    if (frame == NULL) return false;
    memset(frame, 0, sizeof(*frame));
    if (!VCAMSharedSurfaceReaderEnsureMapped(reader)) return false;
    uint64_t sequence = atomic_load_explicit(
        &reader->header->publishedSequence, memory_order_acquire);
    uint32_t slot = atomic_load_explicit(
        &reader->header->publishedSlot, memory_order_relaxed);
    uint64_t timestamp = atomic_load_explicit(
        &reader->header->publishedTimestampNanoseconds, memory_order_relaxed);
    uint64_t now = VCAMSharedFrameMonotonicNanoseconds();
    if (sequence == 0 || slot >= VCAMSharedFrameSlotCount || timestamp == 0 ||
        (maximumAgeNanoseconds > 0 &&
         (now < timestamp || now - timestamp > maximumAgeNanoseconds)) ||
        atomic_load_explicit(&reader->header->slotSequence[slot],
                             memory_order_acquire) != sequence) return false;
    _Atomic(uint32_t) *useCounter =
        (_Atomic(uint32_t) *)&reader->header->consumerUseCount[slot];
    atomic_fetch_add_explicit(useCounter, 1, memory_order_acq_rel);
    IOSurfaceRef surface = IOSurfaceLookup(reader->header->surfaceIDs[slot]);
    if (surface == NULL) {
        atomic_fetch_sub_explicit(useCounter, 1, memory_order_acq_rel);
        return false;
    }
    IOSurfaceIncrementUseCount(surface);
    CVPixelBufferRef pixelBuffer = NULL;
    NSDictionary *attributes = @{
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
    };
    CVReturn status = CVPixelBufferCreateWithIOSurface(
        kCFAllocatorDefault, surface, (__bridge CFDictionaryRef)attributes,
        &pixelBuffer);
    bool unchanged = status == kCVReturnSuccess && pixelBuffer != NULL &&
        atomic_load_explicit(&reader->header->slotSequence[slot],
                             memory_order_acquire) == sequence &&
        atomic_load_explicit(&reader->header->publishedSequence,
                             memory_order_acquire) >= sequence;
    if (!unchanged) {
        if (pixelBuffer != NULL) CVPixelBufferRelease(pixelBuffer);
        IOSurfaceDecrementUseCount(surface);
        CFRelease(surface);
        atomic_fetch_sub_explicit(useCounter, 1, memory_order_acq_rel);
        return false;
    }
    frame->pixelBuffer = pixelBuffer;
    frame->surface = surface;
    frame->useCounter = useCounter;
    frame->metadata.sequence = sequence;
    frame->metadata.monotonicTimestampNanoseconds = timestamp;
    frame->metadata.width = VCAMSharedFrameWidth;
    frame->metadata.height = VCAMSharedFrameHeight;
    frame->metadata.pixelFormat = kCVPixelFormatType_32BGRA;
    return true;
}

void VCAMSharedSurfaceFrameRelease(VCAMSharedSurfaceFrame *frame) {
    if (frame == NULL) return;
    if (frame->pixelBuffer != NULL) CVPixelBufferRelease(frame->pixelBuffer);
    if (frame->surface != NULL) {
        IOSurfaceRef surface = (IOSurfaceRef)frame->surface;
        IOSurfaceDecrementUseCount(surface);
        CFRelease(surface);
    }
    if (frame->useCounter != NULL) {
        _Atomic(uint32_t) *useCounter = frame->useCounter;
        uint32_t current = atomic_load_explicit(useCounter, memory_order_acquire);
        while (current > 0 && !atomic_compare_exchange_weak_explicit(
                   useCounter, &current, current - 1,
                   memory_order_acq_rel, memory_order_acquire)) {}
    }
    memset(frame, 0, sizeof(*frame));
}

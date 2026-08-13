#import "VCAMSharedFrame.h"
#import "VCAMProcessIdentity.h"
#import "VCAMSurfaceBroker.h"

#include <errno.h>
#include <fcntl.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <stdio.h>
#include <sys/file.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

// The iPhoneOS 16.5 SDK exposes IOSurface-backed CVPixelBuffers through
// CoreVideo but does not ship IOSurface framework headers. Keep the narrow
// cross-process ABI local instead of copying the private framework header.
extern uint32_t IOSurfaceGetID(IOSurfaceRef surface);
extern IOSurfaceRef _Nullable IOSurfaceCreate(CFDictionaryRef properties)
    CF_RETURNS_RETAINED;
extern IOSurfaceRef _Nullable IOSurfaceLookup(uint32_t surfaceID)
    CF_RETURNS_RETAINED;
extern void IOSurfaceIncrementUseCount(IOSurfaceRef surface);
extern void IOSurfaceDecrementUseCount(IOSurfaceRef surface);
extern const CFStringRef kIOSurfaceWidth;
extern const CFStringRef kIOSurfaceHeight;
extern const CFStringRef kIOSurfaceBytesPerElement;
extern const CFStringRef kIOSurfacePixelFormat;

static const uint32_t VCAMSharedFrameMagic = 0x5643414d;
static const uint32_t VCAMSharedFrameVersion = 3;
static const char *const VCAMSharedFramePath = "/var/tmp/com.codex.vcam.frames";
static const uint32_t VCAMSharedSurfaceMagic = 0x56435346;
static const uint32_t VCAMSharedSurfaceVersion = 8;
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
    /// Zero for legacy-only publication; otherwise binds a bootstrap frame to
    /// exactly one IOSurface writer generation.
    _Atomic(uint64_t) slotSurfaceGeneration[VCAMSharedFrameSlotCount];
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
    _Atomic(int32_t) producerPID;
    _Atomic(uint64_t) producerStartToken;
    _Atomic(uint64_t) producerGeneration;
    _Atomic(uint32_t) surfaceIDs[VCAMSharedFrameSlotCount];
    _Atomic(uint32_t) publishedSlot;
    _Atomic(uint64_t) publishedSequence;
    _Atomic(uint64_t) publishedTimestampNanoseconds;
    _Atomic(uint64_t) slotSequence[VCAMSharedFrameSlotCount];
    _Atomic(uint32_t) slotColorPrimaries[VCAMSharedFrameSlotCount];
    _Atomic(uint32_t) slotTransferFunction[VCAMSharedFrameSlotCount];
    _Atomic(uint32_t) slotYCbCrMatrix[VCAMSharedFrameSlotCount];
    // High 32 bits identify the IOSurface generation; low 32 bits are the
    // active reader count. One CAS word prevents an old reader from releasing
    // a newly-created surface that reused the same header slot.
    _Atomic(uint64_t) consumerUseState[VCAMSharedFrameSlotCount];
    _Atomic(int32_t) consumerPID;
    _Atomic(uint64_t) consumerStartToken;
    _Atomic(uint64_t) consumerHeartbeatNanoseconds;
    _Atomic(uint32_t) consumerReady;
} VCAMSharedSurfaceHeader;

enum {
    VCAMColorUnknown = 0,
    VCAMColor709 = 1,
    VCAMColorEBU3213 = 2,
    VCAMColorSMPTEC = 3,
    VCAMColorP22 = 4,
    VCAMColorDCIP3 = 5,
    VCAMColorP3D65 = 6,
    VCAMColor2020 = 7,
    VCAMTransferSMPTE240M = 8,
    VCAMTransferSRGB = 9,
    VCAMTransferST428 = 10,
    VCAMTransferPQ = 11,
    VCAMTransferHLG = 12,
    VCAMTransferLinear = 13,
    VCAMMatrix601 = 14,
    VCAMMatrixSMPTE240M = 15,
};

static uint32_t VCAMColorPrimariesCode(CFTypeRef value) {
    if (value == NULL) return VCAMColorUnknown;
    if (CFEqual(value, kCVImageBufferColorPrimaries_ITU_R_709_2)) return VCAMColor709;
    if (CFEqual(value, kCVImageBufferColorPrimaries_EBU_3213)) return VCAMColorEBU3213;
    if (CFEqual(value, kCVImageBufferColorPrimaries_SMPTE_C)) return VCAMColorSMPTEC;
    if (CFEqual(value, kCVImageBufferColorPrimaries_P22)) return VCAMColorP22;
    if (CFEqual(value, kCVImageBufferColorPrimaries_DCI_P3)) return VCAMColorDCIP3;
    if (CFEqual(value, kCVImageBufferColorPrimaries_P3_D65)) return VCAMColorP3D65;
    if (CFEqual(value, kCVImageBufferColorPrimaries_ITU_R_2020)) return VCAMColor2020;
    return VCAMColorUnknown;
}

static uint32_t VCAMTransferFunctionCode(CFTypeRef value) {
    if (value == NULL) return VCAMColorUnknown;
    if (CFEqual(value, kCVImageBufferTransferFunction_ITU_R_709_2)) return VCAMColor709;
    if (CFEqual(value, kCVImageBufferTransferFunction_ITU_R_2020)) return VCAMColor2020;
    if (CFEqual(value, kCVImageBufferTransferFunction_SMPTE_240M_1995)) return VCAMTransferSMPTE240M;
    if (CFEqual(value, kCVImageBufferTransferFunction_sRGB)) return VCAMTransferSRGB;
    if (CFEqual(value, kCVImageBufferTransferFunction_SMPTE_ST_428_1)) return VCAMTransferST428;
    if (CFEqual(value, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)) return VCAMTransferPQ;
    if (CFEqual(value, kCVImageBufferTransferFunction_ITU_R_2100_HLG)) return VCAMTransferHLG;
    if (CFEqual(value, kCVImageBufferTransferFunction_Linear)) return VCAMTransferLinear;
    return VCAMColorUnknown;
}

static uint32_t VCAMYCbCrMatrixCode(CFTypeRef value) {
    if (value == NULL) return VCAMColorUnknown;
    if (CFEqual(value, kCVImageBufferYCbCrMatrix_ITU_R_709_2)) return VCAMColor709;
    if (CFEqual(value, kCVImageBufferYCbCrMatrix_ITU_R_2020)) return VCAMColor2020;
    if (CFEqual(value, kCVImageBufferYCbCrMatrix_ITU_R_601_4)) return VCAMMatrix601;
    if (CFEqual(value, kCVImageBufferYCbCrMatrix_SMPTE_240M_1995)) return VCAMMatrixSMPTE240M;
    return VCAMColorUnknown;
}

static CFStringRef VCAMColorPrimariesValue(uint32_t code) {
    switch (code) {
        case VCAMColor709: return kCVImageBufferColorPrimaries_ITU_R_709_2;
        case VCAMColorEBU3213: return kCVImageBufferColorPrimaries_EBU_3213;
        case VCAMColorSMPTEC: return kCVImageBufferColorPrimaries_SMPTE_C;
        case VCAMColorP22: return kCVImageBufferColorPrimaries_P22;
        case VCAMColorDCIP3: return kCVImageBufferColorPrimaries_DCI_P3;
        case VCAMColorP3D65: return kCVImageBufferColorPrimaries_P3_D65;
        case VCAMColor2020: return kCVImageBufferColorPrimaries_ITU_R_2020;
        default: return NULL;
    }
}

static CFStringRef VCAMTransferFunctionValue(uint32_t code) {
    switch (code) {
        case VCAMColor709: return kCVImageBufferTransferFunction_ITU_R_709_2;
        case VCAMColor2020: return kCVImageBufferTransferFunction_ITU_R_2020;
        case VCAMTransferSMPTE240M: return kCVImageBufferTransferFunction_SMPTE_240M_1995;
        case VCAMTransferSRGB: return kCVImageBufferTransferFunction_sRGB;
        case VCAMTransferST428: return kCVImageBufferTransferFunction_SMPTE_ST_428_1;
        case VCAMTransferPQ: return kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ;
        case VCAMTransferHLG: return kCVImageBufferTransferFunction_ITU_R_2100_HLG;
        case VCAMTransferLinear: return kCVImageBufferTransferFunction_Linear;
        default: return NULL;
    }
}

static CFStringRef VCAMYCbCrMatrixValue(uint32_t code) {
    switch (code) {
        case VCAMColor709: return kCVImageBufferYCbCrMatrix_ITU_R_709_2;
        case VCAMColor2020: return kCVImageBufferYCbCrMatrix_ITU_R_2020;
        case VCAMMatrix601: return kCVImageBufferYCbCrMatrix_ITU_R_601_4;
        case VCAMMatrixSMPTE240M: return kCVImageBufferYCbCrMatrix_SMPTE_240M_1995;
        default: return NULL;
    }
}

static void VCAMApplyColorMetadata(CVPixelBufferRef pixelBuffer,
                                   const VCAMSharedFrameMetadata *metadata) {
    if (pixelBuffer == NULL || metadata == NULL) return;
    CFStringRef primaries = VCAMColorPrimariesValue(metadata->colorPrimaries);
    CFStringRef transfer = VCAMTransferFunctionValue(metadata->transferFunction);
    CFStringRef matrix = VCAMYCbCrMatrixValue(metadata->yCbCrMatrix);
    if (primaries != NULL) CVBufferSetAttachment(pixelBuffer,
        kCVImageBufferColorPrimariesKey, primaries, kCVAttachmentMode_ShouldPropagate);
    if (transfer != NULL) CVBufferSetAttachment(pixelBuffer,
        kCVImageBufferTransferFunctionKey, transfer, kCVAttachmentMode_ShouldPropagate);
    if (matrix != NULL) CVBufferSetAttachment(pixelBuffer,
        kCVImageBufferYCbCrMatrixKey, matrix, kCVAttachmentMode_ShouldPropagate);
}

struct VCAMSharedSurfaceWriter {
    int descriptor;
    void *mapping;
    VCAMSharedSurfaceHeader *header;
    IOSurfaceRef surfaces[VCAMSharedFrameSlotCount];
    CVPixelBufferRef pixelBuffers[VCAMSharedFrameSlotCount];
    uint32_t pendingSlot;
    uint64_t pendingSequence;
    uint64_t lastBrokerPublishNanoseconds;
};

struct VCAMSharedSurfaceReader {
    int descriptor;
    void *mapping;
    const VCAMSharedSurfaceHeader *header;
    VCAMSharedSurfaceReaderFailure lastFailure;
    bool ownsConsumerLease;
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
        // Pixel producers do not own requestedState. SpringBoard initializes
        // invalid/new transport state from the persisted configuration; until
        // that happens the worker exits/retries instead of silently enabling
        // virtual mode.
        VCAMSharedFrameUnlock(writer->descriptor);
        VCAMSharedFrameWriterDestroy(writer);
        return NULL;
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

bool VCAMSharedFrameWriterPublishForSurfaceGeneration(
    VCAMSharedFrameWriter *writer, CVPixelBufferRef pixelBuffer,
    uint64_t surfaceGeneration) {
    if (writer == NULL || writer->header == NULL || pixelBuffer == NULL ||
        CVPixelBufferGetWidth(pixelBuffer) != VCAMSharedFrameWidth ||
        CVPixelBufferGetHeight(pixelBuffer) != VCAMSharedFrameHeight ||
        CVPixelBufferGetPixelFormatType(pixelBuffer) != kCVPixelFormatType_32BGRA) {
        return false;
    }
    if (CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
        return false;
    }
    // vcamd and SpringBoard can overlap briefly while switching source owners.
    // Serialize the complete mmap publication so they cannot reserve the same
    // sequence/slot and interleave row copies.
    if (!VCAMSharedFrameLockExclusive(writer->descriptor)) {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
        return false;
    }
    if (!VCAMSharedFrameHeaderIsValid(writer->header)) {
        VCAMSharedFrameUnlock(writer->descriptor);
        CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
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
    atomic_store_explicit(&writer->header->slotSurfaceGeneration[slot],
                          surfaceGeneration, memory_order_relaxed);
    atomic_store_explicit(&writer->header->slotSequence[slot], sequence, memory_order_release);
    atomic_store_explicit(&writer->header->publishedTimestampNanoseconds, timestamp,
                          memory_order_relaxed);
    atomic_store_explicit(&writer->header->publishedSlot, slot, memory_order_relaxed);
    atomic_store_explicit(&writer->header->publishedSequence, sequence, memory_order_release);
    VCAMSharedFrameUnlock(writer->descriptor);
    return true;
}

bool VCAMSharedFrameWriterPublish(VCAMSharedFrameWriter *writer,
                                  CVPixelBufferRef pixelBuffer) {
    return VCAMSharedFrameWriterPublishForSurfaceGeneration(
        writer, pixelBuffer, 0);
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

typedef struct {
    uint64_t sequence;
    uint32_t slot;
    uint64_t timestamp;
} VCAMSharedFrameSnapshot;

static bool VCAMSharedFrameReadSnapshot(
    const _Atomic(uint64_t) *publishedSequence,
    const _Atomic(uint32_t) *publishedSlot,
    const _Atomic(uint64_t) *publishedTimestamp,
    const _Atomic(uint64_t) *slotSequences,
    uint32_t slotCount,
    uint32_t width,
    uint32_t height,
    OSType pixelFormat,
    uint64_t maximumAgeNanoseconds,
    VCAMSharedFrameSnapshot *snapshot,
    VCAMSharedFrameMetadata *metadata) {
    if (snapshot == NULL) return false;
    uint64_t sequence = atomic_load_explicit(publishedSequence,
                                             memory_order_acquire);
    uint32_t slot = atomic_load_explicit(publishedSlot, memory_order_relaxed);
    uint64_t timestamp = atomic_load_explicit(publishedTimestamp,
                                              memory_order_relaxed);
    uint64_t now = VCAMSharedFrameMonotonicNanoseconds();
    if (sequence == 0 || slot >= slotCount || timestamp == 0 ||
        (maximumAgeNanoseconds > 0 &&
         (now < timestamp || now - timestamp > maximumAgeNanoseconds)) ||
        atomic_load_explicit(&slotSequences[slot], memory_order_acquire) !=
            sequence) {
        return false;
    }
    snapshot->sequence = sequence;
    snapshot->slot = slot;
    snapshot->timestamp = timestamp;
    if (metadata != NULL) {
        metadata->sequence = sequence;
        metadata->monotonicTimestampNanoseconds = timestamp;
        metadata->width = width;
        metadata->height = height;
        metadata->pixelFormat = pixelFormat;
        metadata->surfaceID = 0;
        metadata->surfaceGeneration = 0;
    }
    return true;
}

static bool VCAMSharedFrameReaderGetSnapshot(
    VCAMSharedFrameReader *reader,
    uint64_t maximumAgeNanoseconds,
    VCAMSharedFrameSnapshot *snapshot,
    VCAMSharedFrameMetadata *metadata) {
    if (reader == NULL || !VCAMSharedFrameReaderEnsureMapped(reader) ||
        (atomic_load_explicit(&reader->header->requestedState,
                              memory_order_acquire) & 1ULL) == 0) {
        return false;
    }
    bool success = VCAMSharedFrameReadSnapshot(
        &reader->header->publishedSequence, &reader->header->publishedSlot,
        &reader->header->publishedTimestampNanoseconds,
        reader->header->slotSequence, reader->header->slotCount,
        reader->header->width, reader->header->height,
        reader->header->pixelFormat, maximumAgeNanoseconds, snapshot,
        metadata);
    if (success && metadata != NULL) {
        uint64_t generation = atomic_load_explicit(
            &reader->header->slotSurfaceGeneration[snapshot->slot],
            memory_order_acquire);
        if (atomic_load_explicit(&reader->header->slotSequence[snapshot->slot],
                                 memory_order_acquire) != snapshot->sequence) {
            return false;
        }
        metadata->surfaceGeneration = generation;
    }
    return success;
}

bool VCAMSharedFrameReaderGetLatestMetadata(
    VCAMSharedFrameReader *reader,
    uint64_t maximumAgeNanoseconds,
    VCAMSharedFrameMetadata *metadata) {
    VCAMSharedFrameSnapshot snapshot = {0};
    return VCAMSharedFrameReaderGetSnapshot(
        reader, maximumAgeNanoseconds, &snapshot, metadata);
}

bool VCAMSharedFrameReaderCopyLatest(VCAMSharedFrameReader *reader,
                                     CVPixelBufferRef destination,
                                     uint64_t maximumAgeNanoseconds,
                                     VCAMSharedFrameMetadata *metadata) {
    if (reader == NULL || destination == NULL ||
        CVPixelBufferGetWidth(destination) != VCAMSharedFrameWidth ||
        CVPixelBufferGetHeight(destination) != VCAMSharedFrameHeight ||
        CVPixelBufferGetPixelFormatType(destination) != kCVPixelFormatType_32BGRA) {
        return false;
    }
    VCAMSharedFrameSnapshot snapshot = {0};
    if (!VCAMSharedFrameReaderGetSnapshot(
            reader, maximumAgeNanoseconds, &snapshot, NULL)) return false;
    uint64_t sequence = snapshot.sequence;
    uint32_t slot = snapshot.slot;

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

    uint64_t surfaceGeneration = atomic_load_explicit(
        &reader->header->slotSurfaceGeneration[slot], memory_order_acquire);
    if (atomic_load_explicit(&reader->header->slotSequence[slot], memory_order_acquire) != sequence ||
        atomic_load_explicit(&reader->header->publishedSequence, memory_order_acquire) < sequence) {
        return false;
    }
    if (metadata != NULL) {
        metadata->sequence = sequence;
        metadata->monotonicTimestampNanoseconds = snapshot.timestamp;
        metadata->width = VCAMSharedFrameWidth;
        metadata->height = VCAMSharedFrameHeight;
        metadata->pixelFormat = kCVPixelFormatType_32BGRA;
        metadata->surfaceID = 0;
        metadata->surfaceGeneration = surfaceGeneration;
    }
    return true;
}

static bool VCAMSharedSurfaceHeaderIsValid(const VCAMSharedSurfaceHeader *header) {
    bool supportedPixelFormat = header != NULL &&
        (header->pixelFormat == kCVPixelFormatType_32BGRA ||
         header->pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
         header->pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);
    if (header == NULL || header->magic != VCAMSharedSurfaceMagic ||
        header->version != VCAMSharedSurfaceVersion ||
        header->headerBytes != sizeof(VCAMSharedSurfaceHeader) ||
        !VCAMSurfaceBrokerSlotCountIsValid(header->slotCount) ||
        header->width == 0 || header->height == 0 ||
        atomic_load_explicit(&header->producerStartToken,
                             memory_order_acquire) == 0 ||
        atomic_load_explicit(&header->producerGeneration,
                             memory_order_acquire) == 0 ||
        !supportedPixelFormat) return false;
    for (uint32_t slot = 0; slot < header->slotCount; slot++) {
        if (atomic_load_explicit(&header->surfaceIDs[slot],
                                 memory_order_acquire) == 0) return false;
    }
    return true;
}

static bool VCAMProcessIsAlive(int32_t processID) {
    if (processID <= 0) return false;
    errno = 0;
    return kill((pid_t)processID, 0) == 0 || errno == EPERM;
}

static bool VCAMProcessMatches(int32_t processID, uint64_t startToken) {
    return startToken != 0 && VCAMProcessIsAlive(processID) &&
        VCAMProcessStartToken((pid_t)processID) == startToken;
}

static uint64_t VCAMSharedSurfaceUseState(uint32_t surfaceID,
                                          uint32_t useCount) {
    return ((uint64_t)surfaceID << 32) | useCount;
}

static bool VCAMSharedSurfaceAcquireUse(_Atomic(uint64_t) *state,
                                        uint32_t surfaceID) {
    uint64_t current = atomic_load_explicit(state, memory_order_acquire);
    while ((uint32_t)(current >> 32) == surfaceID &&
           (uint32_t)current != UINT32_MAX) {
        if (atomic_compare_exchange_weak_explicit(
                state, &current, current + 1,
                memory_order_acq_rel, memory_order_acquire)) return true;
    }
    return false;
}

static void VCAMSharedSurfaceReleaseUse(_Atomic(uint64_t) *state,
                                        uint32_t surfaceID) {
    uint64_t current = atomic_load_explicit(state, memory_order_acquire);
    while ((uint32_t)(current >> 32) == surfaceID && (uint32_t)current > 0) {
        if (atomic_compare_exchange_weak_explicit(
                state, &current, current - 1,
                memory_order_acq_rel, memory_order_acquire)) return;
    }
}

static void VCAMSharedSurfaceWriterReleasePending(
    VCAMSharedSurfaceWriter *writer) {
    if (writer == NULL || writer->header == NULL ||
        writer->pendingSlot >= writer->header->slotCount) return;
    uint32_t slot = writer->pendingSlot;
    uint32_t surfaceID = atomic_load_explicit(
        &writer->header->surfaceIDs[slot], memory_order_acquire);
    uint64_t claimed = VCAMSharedSurfaceUseState(surfaceID, UINT32_MAX);
    (void)atomic_compare_exchange_strong_explicit(
        &writer->header->consumerUseState[slot], &claimed,
        VCAMSharedSurfaceUseState(surfaceID, 0),
        memory_order_release, memory_order_relaxed);
    writer->pendingSlot = UINT32_MAX;
    writer->pendingSequence = 0;
}

bool VCAMSharedSurfaceWriterIsCurrent(VCAMSharedSurfaceWriter *writer) {
    uint64_t ownStartToken = VCAMProcessStartToken(getpid());
    if (writer == NULL || writer->header == NULL ||
        !VCAMSharedSurfaceHeaderIsValid(writer->header) ||
        atomic_load_explicit(&writer->header->producerPID,
                             memory_order_acquire) != (int32_t)getpid() ||
        ownStartToken == 0 ||
        atomic_load_explicit(&writer->header->producerStartToken,
                             memory_order_acquire) != ownStartToken ||
        writer->pixelBuffers[0] == NULL ||
        writer->header->pixelFormat !=
            CVPixelBufferGetPixelFormatType(writer->pixelBuffers[0]) ||
        writer->header->width != CVPixelBufferGetWidth(writer->pixelBuffers[0]) ||
        writer->header->height != CVPixelBufferGetHeight(writer->pixelBuffers[0])) return false;
    for (uint32_t slot = 0; slot < writer->header->slotCount; slot++) {
        if (writer->surfaces[slot] == NULL ||
            atomic_load_explicit(&writer->header->surfaceIDs[slot],
                                 memory_order_acquire) !=
                IOSurfaceGetID(writer->surfaces[slot])) {
            return false;
        }
    }
    return true;
}

uint64_t VCAMSharedSurfaceWriterGeneration(VCAMSharedSurfaceWriter *writer) {
    return VCAMSharedSurfaceWriterIsCurrent(writer)
        ? atomic_load_explicit(&writer->header->producerGeneration,
                               memory_order_acquire)
        : 0;
}

static CVPixelBufferRef VCAMSharedSurfaceCreatePixelBuffer(
    uint32_t width, uint32_t height, OSType pixelFormat) {
    if (pixelFormat == kCVPixelFormatType_32BGRA) {
        NSDictionary *surfaceProperties = @{
            (__bridge id)kIOSurfaceWidth: @(width),
            (__bridge id)kIOSurfaceHeight: @(height),
            (__bridge id)kIOSurfaceBytesPerElement: @4,
            (__bridge id)kIOSurfacePixelFormat: @(pixelFormat),
            @"IOSurfaceIsGlobal": @YES,
        };
        IOSurfaceRef surface = IOSurfaceCreate(
            (__bridge CFDictionaryRef)surfaceProperties);
        CVPixelBufferRef globalPixelBuffer = NULL;
        CVReturn globalStatus = surface == NULL ? kCVReturnAllocationFailed
            : CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, surface,
                                               NULL, &globalPixelBuffer);
        if (surface != NULL) CFRelease(surface);
        if (globalStatus == kCVReturnSuccess && globalPixelBuffer != NULL) {
            return globalPixelBuffer;
        }
        static dispatch_once_t globalFailureToken;
        dispatch_once(&globalFailureToken, ^{
            fprintf(stderr,
                    "vcam direct global BGRA IOSurface failed status=%d size=%ux%u; using CoreVideo fallback\n",
                    globalStatus, width, height);
            fflush(stderr);
        });
    }
    NSDictionary *attributes = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn status = CVPixelBufferCreate(
        kCFAllocatorDefault, width, height, pixelFormat,
        (__bridge CFDictionaryRef)attributes, &pixelBuffer);
    if (status != kCVReturnSuccess) {
        static dispatch_once_t createFailureToken;
        dispatch_once(&createFailureToken, ^{
            fprintf(stderr,
                    "vcam shared IOSurface pixel buffer create failed status=%d size=%ux%u pixel=%08x\n",
                    status, width, height, pixelFormat);
            fflush(stderr);
        });
    }
    return status == kCVReturnSuccess ? pixelBuffer : NULL;
}

VCAMSharedSurfaceWriter *VCAMSharedSurfaceWriterCreate(void) {
    return VCAMSharedSurfaceWriterCreateConfigured(
        VCAMSharedFrameWidth, VCAMSharedFrameHeight,
        kCVPixelFormatType_32BGRA, VCAMSharedFrameSlotCount);
}

VCAMSharedSurfaceWriter *VCAMSharedSurfaceWriterCreateWithPixelFormat(
    OSType pixelFormat) {
    return VCAMSharedSurfaceWriterCreateConfigured(
        VCAMSharedFrameWidth, VCAMSharedFrameHeight, pixelFormat,
        VCAMSharedFrameSlotCount);
}

VCAMSharedSurfaceWriter *VCAMSharedSurfaceWriterCreateConfigured(
    uint32_t width, uint32_t height, OSType pixelFormat, uint32_t slotCount) {
    if (pixelFormat != kCVPixelFormatType_32BGRA &&
        pixelFormat != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
        pixelFormat != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) return NULL;
    if (width == 0 || height == 0 ||
        !VCAMSurfaceBrokerSlotCountIsValid(slotCount)) return NULL;
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

    if (!VCAMSharedFrameLockExclusive(writer->descriptor)) {
        VCAMSharedSurfaceWriterDestroy(writer);
        return NULL;
    }
    bool existingHeaderValid = VCAMSharedSurfaceHeaderIsValid(writer->header);
    int32_t activeProducer = existingHeaderValid
        ? atomic_load_explicit(&writer->header->producerPID, memory_order_acquire)
        : 0;
    uint64_t activeProducerStartToken = existingHeaderValid
        ? atomic_load_explicit(&writer->header->producerStartToken,
                               memory_order_acquire)
        : 0;
    if (VCAMProcessMatches(activeProducer, activeProducerStartToken)) {
        VCAMSharedFrameUnlock(writer->descriptor);
        VCAMSharedSurfaceWriterDestroy(writer);
        return NULL;
    }
    uint64_t producerStartToken = VCAMProcessStartToken(getpid());
    if (producerStartToken == 0) {
        VCAMSharedFrameUnlock(writer->descriptor);
        VCAMSharedSurfaceWriterDestroy(writer);
        return NULL;
    }

    uint32_t surfaceIDs[VCAMSharedFrameSlotCount] = {0};
    for (uint32_t slot = 0; slot < slotCount; slot++) {
        writer->pixelBuffers[slot] = VCAMSharedSurfaceCreatePixelBuffer(
            width, height, pixelFormat);
        writer->surfaces[slot] = writer->pixelBuffers[slot] == NULL ? NULL
            : CVPixelBufferGetIOSurface(writer->pixelBuffers[slot]);
        if (writer->pixelBuffers[slot] == NULL || writer->surfaces[slot] == NULL) {
            VCAMSharedFrameUnlock(writer->descriptor);
            VCAMSharedSurfaceWriterDestroy(writer);
            return NULL;
        }
        CFRetain(writer->surfaces[slot]);
        surfaceIDs[slot] = IOSurfaceGetID(writer->surfaces[slot]);
        if (surfaceIDs[slot] == 0) {
            VCAMSharedFrameUnlock(writer->descriptor);
            VCAMSharedSurfaceWriterDestroy(writer);
            return NULL;
        }
    }
    memset(writer->header, 0, sizeof(*writer->header));
    writer->header->version = VCAMSharedSurfaceVersion;
    writer->header->headerBytes = sizeof(*writer->header);
    writer->header->slotCount = slotCount;
    writer->header->width = width;
    writer->header->height = height;
    writer->header->pixelFormat = pixelFormat;
    atomic_store_explicit(&writer->header->producerPID, (int32_t)getpid(),
                          memory_order_relaxed);
    atomic_store_explicit(&writer->header->producerStartToken,
                          producerStartToken, memory_order_relaxed);
    uint64_t generation = VCAMSharedFrameMonotonicNanoseconds() ^
        ((uint64_t)(uint32_t)getpid() << 32);
    atomic_store_explicit(&writer->header->producerGeneration,
                          generation == 0 ? 1 : generation,
                          memory_order_relaxed);
    for (uint32_t slot = 0; slot < slotCount; slot++) {
        atomic_store_explicit(&writer->header->surfaceIDs[slot],
                              surfaceIDs[slot], memory_order_relaxed);
        atomic_store_explicit(&writer->header->consumerUseState[slot],
                              VCAMSharedSurfaceUseState(surfaceIDs[slot], 0),
                              memory_order_relaxed);
    }
    atomic_thread_fence(memory_order_release);
    writer->header->magic = VCAMSharedSurfaceMagic;
    VCAMSharedFrameUnlock(writer->descriptor);
    VCAMSurfaceBrokerPublish(writer->surfaces, slotCount);
    writer->lastBrokerPublishNanoseconds = VCAMSharedFrameMonotonicNanoseconds();
    return writer;
}

void VCAMSharedSurfaceWriterDestroy(VCAMSharedSurfaceWriter *writer) {
    if (writer == NULL) return;
    if (writer->header != NULL && writer->descriptor >= 0 &&
        VCAMSharedFrameLockExclusive(writer->descriptor)) {
        if (VCAMSharedSurfaceWriterIsCurrent(writer)) writer->header->magic = 0;
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
    if (!VCAMSharedSurfaceWriterIsCurrent(writer)) return NULL;
    // A render that threw or was abandoned must drop one frame, not wedge the
    // bounded transport forever.
    VCAMSharedSurfaceWriterReleasePending(writer);
    uint64_t sequence = atomic_load_explicit(
        &writer->header->publishedSequence, memory_order_relaxed) + 1;
    uint32_t slotCount = writer->header->slotCount;
    for (uint32_t offset = 0; offset < slotCount; offset++) {
        uint32_t slot = (uint32_t)((sequence + offset) % slotCount);
        uint32_t surfaceID = atomic_load_explicit(
            &writer->header->surfaceIDs[slot], memory_order_acquire);
        uint64_t useState = VCAMSharedSurfaceUseState(surfaceID, 0);
        if (!atomic_compare_exchange_strong_explicit(
                &writer->header->consumerUseState[slot], &useState,
                VCAMSharedSurfaceUseState(surfaceID, UINT32_MAX),
                memory_order_acq_rel, memory_order_acquire)) continue;
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
    if (!VCAMSharedSurfaceWriterIsCurrent(writer)) return false;
    if (pixelBuffer == NULL ||
        writer->pendingSlot >=
        writer->header->slotCount ||
        writer->pixelBuffers[writer->pendingSlot] != pixelBuffer) {
        VCAMSharedSurfaceWriterReleasePending(writer);
        return false;
    }
    uint32_t slot = writer->pendingSlot;
    uint64_t sequence = writer->pendingSequence;
    uint64_t timestamp = VCAMSharedFrameMonotonicNanoseconds();
    CFTypeRef primariesValue = CVBufferCopyAttachment(
        pixelBuffer, kCVImageBufferColorPrimariesKey, NULL);
    CFTypeRef transferValue = CVBufferCopyAttachment(
        pixelBuffer, kCVImageBufferTransferFunctionKey, NULL);
    CFTypeRef matrixValue = CVBufferCopyAttachment(
        pixelBuffer, kCVImageBufferYCbCrMatrixKey, NULL);
    uint32_t primaries = VCAMColorPrimariesCode(primariesValue);
    uint32_t transfer = VCAMTransferFunctionCode(transferValue);
    uint32_t matrix = VCAMYCbCrMatrixCode(matrixValue);
    CFBooleanRef decodeHardware = CVBufferCopyAttachment(
        pixelBuffer, CFSTR("com.codex.vcam.decodeHardware"), NULL);
    if (decodeHardware == kCFBooleanTrue) {
        transfer = (transfer & VCAMSharedFrameTransferFunctionMask) |
            (1U << VCAMSharedFrameDecodeHardwareShift);
    }
    if (decodeHardware != NULL) CFRelease(decodeHardware);
    if (primariesValue != NULL) CFRelease(primariesValue);
    if (transferValue != NULL) CFRelease(transferValue);
    if (matrixValue != NULL) CFRelease(matrixValue);
    atomic_store_explicit(&writer->header->slotColorPrimaries[slot], primaries,
                          memory_order_relaxed);
    atomic_store_explicit(&writer->header->slotTransferFunction[slot], transfer,
                          memory_order_relaxed);
    atomic_store_explicit(&writer->header->slotYCbCrMatrix[slot], matrix,
                          memory_order_relaxed);
    atomic_store_explicit(&writer->header->slotSequence[slot], sequence,
                          memory_order_release);
    atomic_store_explicit(&writer->header->publishedTimestampNanoseconds,
                          timestamp, memory_order_relaxed);
    atomic_store_explicit(&writer->header->publishedSlot, slot,
                          memory_order_relaxed);
    atomic_store_explicit(&writer->header->publishedSequence, sequence,
                          memory_order_release);
    VCAMSharedSurfaceWriterReleasePending(writer);
    return true;
}

bool VCAMSharedSurfaceWriterRefreshLatest(VCAMSharedSurfaceWriter *writer) {
    if (!VCAMSharedSurfaceWriterIsCurrent(writer) ||
        writer->header->slotCount != 1 ||
        atomic_load_explicit(&writer->header->publishedSequence,
                             memory_order_acquire) == 0) return false;
    atomic_store_explicit(&writer->header->publishedTimestampNanoseconds,
                          VCAMSharedFrameMonotonicNanoseconds(),
                          memory_order_release);
    return true;
}

bool VCAMSharedSurfaceWriterHasConsumer(VCAMSharedSurfaceWriter *writer) {
    uint64_t now = VCAMSharedFrameMonotonicNanoseconds();
    bool headerValid = VCAMSharedSurfaceWriterIsCurrent(writer);
    if (!headerValid) return false;
    int32_t consumerPID = atomic_load_explicit(
        &writer->header->consumerPID, memory_order_acquire);
    uint64_t consumerStartToken = atomic_load_explicit(
        &writer->header->consumerStartToken, memory_order_acquire);
    uint64_t heartbeat = atomic_load_explicit(
        &writer->header->consumerHeartbeatNanoseconds, memory_order_acquire);
    bool consumerAlive = VCAMProcessMatches(consumerPID, consumerStartToken);
    bool heartbeatFresh = now != 0 && heartbeat != 0 && now >= heartbeat &&
        now - heartbeat <= 2000000000ULL;
    bool ready = consumerAlive && heartbeatFresh &&
        atomic_load_explicit(&writer->header->consumerReady,
                             memory_order_acquire) != 0;
    if (!ready && writer != NULL) {
        atomic_store_explicit(&writer->header->consumerReady, 0,
                              memory_order_release);
        if (!consumerAlive) {
            atomic_store_explicit(&writer->header->consumerPID, 0,
                                  memory_order_release);
            atomic_store_explicit(&writer->header->consumerStartToken, 0,
                                  memory_order_release);
            atomic_store_explicit(
                &writer->header->consumerHeartbeatNanoseconds, 0,
                memory_order_release);
            for (uint32_t slot = 0; slot < writer->header->slotCount; slot++) {
                uint32_t surfaceID = atomic_load_explicit(
                    &writer->header->surfaceIDs[slot], memory_order_acquire);
                atomic_store_explicit(
                    &writer->header->consumerUseState[slot],
                    VCAMSharedSurfaceUseState(surfaceID, 0),
                    memory_order_release);
            }
        }
        if (writer->lastBrokerPublishNanoseconds == 0 || now == 0 ||
            now - writer->lastBrokerPublishNanoseconds >= 1000000000ULL) {
            VCAMSurfaceBrokerPublish(writer->surfaces, writer->header->slotCount);
            writer->lastBrokerPublishNanoseconds = now;
        }
    }
    return ready;
}

VCAMSharedSurfaceReader *VCAMSharedSurfaceReaderCreate(void) {
    VCAMSharedSurfaceReader *reader = calloc(1, sizeof(*reader));
    if (reader != NULL) reader->descriptor = -1;
    VCAMSurfaceBrokerRequestRegistry();
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
    if (reader->descriptor < 0) {
        reader->lastFailure = VCAMSharedSurfaceReaderFailureOpen;
        return false;
    }
    struct stat metadata = {0};
    if (fstat(reader->descriptor, &metadata) != 0 ||
        metadata.st_size < (off_t)sizeof(VCAMSharedSurfaceHeader)) {
        VCAMSharedSurfaceReaderUnmap(reader);
        reader->lastFailure = VCAMSharedSurfaceReaderFailureHeader;
        return false;
    }
    reader->mapping = mmap(NULL, sizeof(VCAMSharedSurfaceHeader),
                           PROT_READ | PROT_WRITE,
                           MAP_SHARED, reader->descriptor, 0);
    if (reader->mapping == MAP_FAILED) {
        reader->mapping = NULL;
        VCAMSharedSurfaceReaderUnmap(reader);
        reader->lastFailure = VCAMSharedSurfaceReaderFailureHeader;
        return false;
    }
    reader->header = reader->mapping;
    if (!VCAMSharedSurfaceHeaderIsValid(reader->header)) {
        VCAMSharedSurfaceReaderUnmap(reader);
        reader->lastFailure = VCAMSharedSurfaceReaderFailureHeader;
        return false;
    }
    return true;
}

static bool VCAMSharedSurfaceReaderGetSnapshot(
    VCAMSharedSurfaceReader *reader,
    uint64_t maximumAgeNanoseconds,
    VCAMSharedFrameSnapshot *snapshot,
    VCAMSharedFrameMetadata *metadata) {
    if (!VCAMSharedSurfaceReaderEnsureMapped(reader)) return false;
    uint64_t generation = atomic_load_explicit(
        &reader->header->producerGeneration, memory_order_acquire);
    bool success = VCAMSharedFrameReadSnapshot(
        &reader->header->publishedSequence, &reader->header->publishedSlot,
        &reader->header->publishedTimestampNanoseconds,
        reader->header->slotSequence, reader->header->slotCount,
        reader->header->width, reader->header->height,
        reader->header->pixelFormat, maximumAgeNanoseconds, snapshot,
        metadata);
    if (success) {
        uint32_t surfaceID = atomic_load_explicit(
            &reader->header->surfaceIDs[snapshot->slot], memory_order_acquire);
        uint32_t primaries = atomic_load_explicit(
            &reader->header->slotColorPrimaries[snapshot->slot], memory_order_relaxed);
        uint32_t transfer = atomic_load_explicit(
            &reader->header->slotTransferFunction[snapshot->slot], memory_order_relaxed);
        uint32_t matrix = atomic_load_explicit(
            &reader->header->slotYCbCrMatrix[snapshot->slot], memory_order_relaxed);
        success = surfaceID != 0 && atomic_load_explicit(
            &reader->header->slotSequence[snapshot->slot],
            memory_order_acquire) == snapshot->sequence &&
            atomic_load_explicit(&reader->header->producerGeneration,
                                 memory_order_acquire) == generation;
        if (success && metadata != NULL) {
            metadata->surfaceID = surfaceID;
            metadata->surfaceGeneration = generation;
            metadata->colorPrimaries = primaries;
            metadata->transferFunction = transfer;
            metadata->yCbCrMatrix = matrix;
        }
    }
    return success;
}

static void VCAMSharedSurfaceReaderSetReady(VCAMSharedSurfaceReader *reader,
                                             bool ready) {
    if (reader == NULL || reader->header == NULL) return;
    _Atomic(int32_t) *consumerPID =
        (_Atomic(int32_t) *)&reader->header->consumerPID;
    _Atomic(uint64_t) *consumerHeartbeat =
        (_Atomic(uint64_t) *)&reader->header->consumerHeartbeatNanoseconds;
    _Atomic(uint64_t) *consumerStartToken =
        (_Atomic(uint64_t) *)&reader->header->consumerStartToken;
    _Atomic(uint32_t) *consumerReady =
        (_Atomic(uint32_t) *)&reader->header->consumerReady;
    if (ready) {
        uint64_t ownStartToken = VCAMProcessStartToken(getpid());
        if (ownStartToken == 0) return;
        atomic_store_explicit(consumerPID, (int32_t)getpid(), memory_order_relaxed);
        atomic_store_explicit(consumerStartToken, ownStartToken,
                              memory_order_relaxed);
        atomic_store_explicit(consumerHeartbeat,
                              VCAMSharedFrameMonotonicNanoseconds(),
                              memory_order_release);
        atomic_store_explicit(consumerReady, 1, memory_order_release);
        reader->ownsConsumerLease = true;
    } else {
        if (reader->ownsConsumerLease &&
            atomic_load_explicit(consumerPID, memory_order_acquire) ==
                (int32_t)getpid() &&
            atomic_load_explicit(consumerStartToken, memory_order_acquire) ==
                VCAMProcessStartToken(getpid())) {
            atomic_store_explicit(consumerReady, 0, memory_order_release);
            atomic_store_explicit(consumerHeartbeat, 0, memory_order_release);
            atomic_store_explicit(consumerPID, 0, memory_order_release);
            atomic_store_explicit(consumerStartToken, 0, memory_order_release);
        }
        reader->ownsConsumerLease = false;
    }
}

void VCAMSharedSurfaceReaderDestroy(VCAMSharedSurfaceReader *reader) {
    if (reader == NULL) return;
    VCAMSharedSurfaceReaderSetReady(reader, false);
    VCAMSharedSurfaceReaderUnmap(reader);
    free(reader);
}

bool VCAMSharedSurfaceReaderGetLatestMetadata(
    VCAMSharedSurfaceReader *reader,
    uint64_t maximumAgeNanoseconds,
    VCAMSharedFrameMetadata *metadata) {
    VCAMSharedFrameSnapshot snapshot = {0};
    return VCAMSharedSurfaceReaderGetSnapshot(
        reader, maximumAgeNanoseconds, &snapshot, metadata);
}

static bool VCAMSharedSurfaceReaderCopyLatestInternal(
    VCAMSharedSurfaceReader *reader,
    uint64_t maximumAgeNanoseconds,
    VCAMSharedSurfaceFrame *frame,
    bool announceConsumer) {
    if (frame == NULL) return false;
    memset(frame, 0, sizeof(*frame));
    if (reader == NULL || !VCAMSharedSurfaceReaderEnsureMapped(reader)) {
        return false;
    }
    VCAMSharedFrameSnapshot snapshot = {0};
    VCAMSharedFrameMetadata surfaceMetadata = {0};
    if (!VCAMSharedSurfaceReaderGetSnapshot(
            reader, maximumAgeNanoseconds, &snapshot, &surfaceMetadata)) {
        reader->lastFailure = VCAMSharedSurfaceReaderFailureStale;
        return false;
    }
    uint64_t sequence = snapshot.sequence;
    uint32_t slot = snapshot.slot;
    uint32_t surfaceID = atomic_load_explicit(
        &reader->header->surfaceIDs[slot],
                                              memory_order_acquire);
    _Atomic(uint64_t) *useCounter =
        (_Atomic(uint64_t) *)&reader->header->consumerUseState[slot];
    if (!VCAMSharedSurfaceAcquireUse(useCounter, surfaceID)) {
        reader->lastFailure = VCAMSharedSurfaceReaderFailureChanged;
        return false;
    }
    IOSurfaceRef surface = VCAMSurfaceBrokerCopySurface(surfaceID);
    if (surface == NULL) {
        surface = IOSurfaceLookup(surfaceID);
    }
    if (surface == NULL) {
        VCAMSharedSurfaceReleaseUse(useCounter, surfaceID);
        if (announceConsumer) VCAMSharedSurfaceReaderSetReady(reader, false);
        reader->lastFailure = VCAMSharedSurfaceReaderFailureLookup;
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
                             memory_order_acquire) >= sequence &&
        atomic_load_explicit(&reader->header->surfaceIDs[slot],
                             memory_order_acquire) == surfaceID &&
        atomic_load_explicit(&reader->header->producerGeneration,
                             memory_order_acquire) ==
            surfaceMetadata.surfaceGeneration;
    if (!unchanged) {
        if (pixelBuffer != NULL) CVPixelBufferRelease(pixelBuffer);
        IOSurfaceDecrementUseCount(surface);
        CFRelease(surface);
        VCAMSharedSurfaceReleaseUse(useCounter, surfaceID);
        if (announceConsumer) VCAMSharedSurfaceReaderSetReady(reader, false);
        reader->lastFailure = status == kCVReturnSuccess
            ? VCAMSharedSurfaceReaderFailureChanged
            : VCAMSharedSurfaceReaderFailurePixelBuffer;
        return false;
    }
    VCAMApplyColorMetadata(pixelBuffer, &surfaceMetadata);
    if (announceConsumer) VCAMSharedSurfaceReaderSetReady(reader, true);
    reader->lastFailure = VCAMSharedSurfaceReaderFailureNone;
    frame->pixelBuffer = pixelBuffer;
    frame->surface = surface;
    frame->useCounter = useCounter;
    frame->surfaceID = surfaceID;
    frame->metadata = surfaceMetadata;
    return true;
}

bool VCAMSharedSurfaceReaderCopyLatest(VCAMSharedSurfaceReader *reader,
                                       uint64_t maximumAgeNanoseconds,
                                       VCAMSharedSurfaceFrame *frame) {
    return VCAMSharedSurfaceReaderCopyLatestInternal(
        reader, maximumAgeNanoseconds, frame, true);
}

bool VCAMSharedSurfaceReaderCopyLatestPassive(
    VCAMSharedSurfaceReader *reader,
    uint64_t maximumAgeNanoseconds,
    VCAMSharedSurfaceFrame *frame) {
    return VCAMSharedSurfaceReaderCopyLatestInternal(
        reader, maximumAgeNanoseconds, frame, false);
}

VCAMSharedSurfaceReaderFailure VCAMSharedSurfaceReaderLastFailure(
    VCAMSharedSurfaceReader *reader) {
    return reader == NULL ? VCAMSharedSurfaceReaderFailureOpen
                          : reader->lastFailure;
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
        VCAMSharedSurfaceReleaseUse(
            (_Atomic(uint64_t) *)frame->useCounter, frame->surfaceID);
    }
    memset(frame, 0, sizeof(*frame));
}

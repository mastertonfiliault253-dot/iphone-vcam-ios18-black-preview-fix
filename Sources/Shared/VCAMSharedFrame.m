#import "VCAMSharedFrame.h"

#include <fcntl.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static const uint32_t VCAMSharedFrameMagic = 0x5643414d;
static const uint32_t VCAMSharedFrameVersion = 1;
static const char *const VCAMSharedFramePath = "/var/tmp/com.codex.vcam.frames";
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
    _Atomic(uint32_t) active;
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

const char *VCAMSharedFrameFileSystemPath(void) {
    return VCAMSharedFramePath;
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
    memset(writer->mapping, 0, writer->mappedBytes);
    writer->header = writer->mapping;
    writer->header->magic = VCAMSharedFrameMagic;
    writer->header->version = VCAMSharedFrameVersion;
    writer->header->headerBytes = sizeof(VCAMSharedFrameHeader);
    writer->header->slotCount = VCAMSharedFrameSlotCount;
    writer->header->width = VCAMSharedFrameWidth;
    writer->header->height = VCAMSharedFrameHeight;
    writer->header->bytesPerRow = (uint32_t)VCAMSharedFrameBytesPerRow;
    writer->header->pixelFormat = kCVPixelFormatType_32BGRA;
    writer->header->slotBytes = VCAMSharedFrameSlotBytes;
    atomic_store_explicit(&writer->header->active, 0, memory_order_release);
    return writer;
}

void VCAMSharedFrameWriterDestroy(VCAMSharedFrameWriter *writer) {
    if (writer == NULL) return;
    if (writer->header != NULL) {
        atomic_store_explicit(&writer->header->active, 0, memory_order_release);
    }
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
    atomic_store_explicit(&writer->header->active, 1, memory_order_release);
    return true;
}

void VCAMSharedFrameWriterClear(VCAMSharedFrameWriter *writer) {
    if (writer == NULL || writer->header == NULL) return;
    atomic_store_explicit(&writer->header->active, 0, memory_order_release);
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

bool VCAMSharedFrameReaderCopyLatest(VCAMSharedFrameReader *reader,
                                     CVPixelBufferRef destination,
                                     uint64_t maximumAgeNanoseconds,
                                     VCAMSharedFrameMetadata *metadata) {
    if (reader == NULL || destination == NULL ||
        !VCAMSharedFrameReaderEnsureMapped(reader) ||
        CVPixelBufferGetWidth(destination) != VCAMSharedFrameWidth ||
        CVPixelBufferGetHeight(destination) != VCAMSharedFrameHeight ||
        CVPixelBufferGetPixelFormatType(destination) != kCVPixelFormatType_32BGRA ||
        atomic_load_explicit(&reader->header->active, memory_order_acquire) == 0) {
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

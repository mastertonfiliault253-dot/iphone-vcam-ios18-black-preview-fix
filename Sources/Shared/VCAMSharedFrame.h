#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

#include <stdbool.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

enum {
    VCAMSharedFrameWidth = 720,
    VCAMSharedFrameHeight = 1280,
    VCAMSharedFrameSlotCount = 3,
};

typedef struct VCAMSharedFrameWriter VCAMSharedFrameWriter;
typedef struct VCAMSharedFrameReader VCAMSharedFrameReader;

typedef struct {
    uint64_t sequence;
    uint64_t monotonicTimestampNanoseconds;
    uint32_t width;
    uint32_t height;
    OSType pixelFormat;
} VCAMSharedFrameMetadata;

/// Producer interface. The implementation owns file creation, mmap layout,
/// slot selection, publication ordering and permissions.
VCAMSharedFrameWriter *_Nullable VCAMSharedFrameWriterCreate(void);
void VCAMSharedFrameWriterDestroy(VCAMSharedFrameWriter *_Nullable writer);
bool VCAMSharedFrameWriterPublish(VCAMSharedFrameWriter *writer,
                                  CVPixelBufferRef pixelBuffer);
void VCAMSharedFrameWriterClear(VCAMSharedFrameWriter *writer);

/// Consumer interface. Copying is non-blocking and fails when the producer is
/// absent, a frame is stale, or a slot changes while it is being copied.
VCAMSharedFrameReader *VCAMSharedFrameReaderCreate(void);
void VCAMSharedFrameReaderDestroy(VCAMSharedFrameReader *_Nullable reader);
bool VCAMSharedFrameReaderCopyLatest(VCAMSharedFrameReader *reader,
                                     CVPixelBufferRef destination,
                                     uint64_t maximumAgeNanoseconds,
                                     VCAMSharedFrameMetadata *_Nullable metadata);

const char *VCAMSharedFrameFileSystemPath(void);
uint64_t VCAMSharedFrameMonotonicNanoseconds(void);

NS_ASSUME_NONNULL_END

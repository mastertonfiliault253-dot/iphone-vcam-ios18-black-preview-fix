#import "VCAMMediaServerRefImageUtils.h"

#import <CoreImage/CoreImage.h>
#import <Metal/Metal.h>
#import "../Shared/VCAMSharedFrame.h"

#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

static VCAMSharedFrameReader *VCAMReader;
static CVPixelBufferPoolRef VCAMScratchPool;
static CIContext *VCAMContext;
static CGColorSpaceRef VCAMColorSpace;

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
    VCAMReader = VCAMSharedFrameReaderCreate();
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    VCAMContext = device != nil
        ? [CIContext contextWithMTLDevice:device options:@{kCIContextUseSoftwareRenderer: @NO}]
        : [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @YES}];
    VCAMColorSpace = CGColorSpaceCreateDeviceRGB();
    NSDictionary *poolAttributes = @{(id)kCVPixelBufferPoolMinimumBufferCountKey: @2};
    NSDictionary *pixelAttributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey: @(VCAMSharedFrameWidth),
        (id)kCVPixelBufferHeightKey: @(VCAMSharedFrameHeight),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    CVReturn result = CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                               (__bridge CFDictionaryRef)poolAttributes,
                                               (__bridge CFDictionaryRef)pixelAttributes,
                                               &VCAMScratchPool);
    VCAMRefLog(result == kCVReturnSuccess
        ? "shared-frame reader initialized"
        : "shared-frame scratch pool initialization failed");
}

void drawReplacementOntoBuffer(CVPixelBufferRef targetBuffer) {
    if (targetBuffer == NULL || VCAMReader == NULL || VCAMScratchPool == NULL) return;

    // This node was confirmed on-device. Widen only after validating additional
    // node sizes; drawing into unrelated camera graph buffers can freeze the GPU.
    size_t targetWidth = CVPixelBufferGetWidth(targetBuffer);
    size_t targetHeight = CVPixelBufferGetHeight(targetBuffer);
    if (targetWidth != 750 || targetHeight != 1334) return;

    CVPixelBufferRef scratch = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, VCAMScratchPool,
                                           &scratch) != kCVReturnSuccess) return;
    VCAMSharedFrameMetadata metadata = {0};
    BOOL copied = VCAMSharedFrameReaderCopyLatest(VCAMReader, scratch,
                                                  1000000000ULL, &metadata);
    if (!copied) {
        CVPixelBufferRelease(scratch);
        return;
    }

    CIImage *image = [CIImage imageWithCVPixelBuffer:scratch];
    CGFloat scale = MIN((CGFloat)targetWidth / CGRectGetWidth(image.extent),
                        (CGFloat)targetHeight / CGRectGetHeight(image.extent));
    image = [image imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    CGFloat x = ((CGFloat)targetWidth - CGRectGetWidth(image.extent)) * 0.5 - CGRectGetMinX(image.extent);
    CGFloat y = ((CGFloat)targetHeight - CGRectGetHeight(image.extent)) * 0.5 - CGRectGetMinY(image.extent);
    image = [image imageByApplyingTransform:CGAffineTransformMakeTranslation(x, y)];
    CIImage *background = [[CIImage imageWithColor:CIColor.blackColor]
        imageByCroppingToRect:CGRectMake(0, 0, targetWidth, targetHeight)];
    image = [[image imageByCompositingOverImage:background]
        imageByCroppingToRect:CGRectMake(0, 0, targetWidth, targetHeight)];
    [VCAMContext render:image toCVPixelBuffer:targetBuffer
                 bounds:CGRectMake(0, 0, targetWidth, targetHeight)
             colorSpace:VCAMColorSpace];
    CVPixelBufferRelease(scratch);

    static unsigned int renderedFrames = 0;
    renderedFrames += 1;
    if (renderedFrames <= 3) {
        char message[160] = {0};
        snprintf(message, sizeof(message), "rendered shared frame sequence=%llu",
                 (unsigned long long)metadata.sequence);
        VCAMRefLog(message);
    }
}

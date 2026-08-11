#import "../Core/VCAMConfiguration.h"
#import "../SpringBoard/VCAMSpringBoardMediaBridge.h"
#import "../UI/VCAMMediaPickerController.h"

#import <CoreVideo/CoreVideo.h>

#include <fcntl.h>
#include <string.h>
#include <unistd.h>

static void VCAMAppendClientProof(const char *line) {
    int descriptor = open("/var/tmp/vcam-springboard-client.log",
                          O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (descriptor >= 0) {
        (void)write(descriptor, line, strlen(line));
        close(descriptor);
    }
}

static void VCAMWriteClientProof(void) {
    char line[128] = {0};
    snprintf(line, sizeof(line), "pid=%d ctor\n", (int)getpid());
    VCAMAppendClientProof(line);
}

static void VCAMProbeSpringBoardSurfaceContext(void) {
    struct {
        const char *name;
        uint32_t width;
        uint32_t height;
        OSType pixelFormat;
    } cases[] = {
        {"exact-bgra", 2066u, 3672u, kCVPixelFormatType_32BGRA},
        {"exact-full", 2066u, 3672u,
         kCVPixelFormatType_420YpCbCr8BiPlanarFullRange},
        {"baseline-bgra", 1080u, 1920u, kCVPixelFormatType_32BGRA},
        {"baseline-full", 1080u, 1920u,
         kCVPixelFormatType_420YpCbCr8BiPlanarFullRange},
    };
    NSDictionary *attributes = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    for (size_t index = 0; index < sizeof(cases) / sizeof(cases[0]); index++) {
        CVPixelBufferRef buffer = NULL;
        CVReturn status = CVPixelBufferCreate(
            kCFAllocatorDefault, cases[index].width, cases[index].height,
            cases[index].pixelFormat,
            (__bridge CFDictionaryRef)attributes, &buffer);
        char line[256] = {0};
        snprintf(line, sizeof(line),
                 "[DEBUG-sb-surface-context-b582] case=%s size=%ux%u pixel=%08x status=%d surface=%d\n",
                 cases[index].name, cases[index].width, cases[index].height,
                 cases[index].pixelFormat, status,
                 buffer != NULL && CVPixelBufferGetIOSurface(buffer) != NULL);
        VCAMAppendClientProof(line);
        if (buffer != NULL) CVPixelBufferRelease(buffer);
    }
}

%ctor {
    @autoreleasepool {
        VCAMWriteClientProof();
        VCAMProbeSpringBoardSurfaceContext();
        [VCAMConfiguration startWriteBroker];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [[VCAMSpringBoardMediaBridge sharedBridge] start];
            [[VCAMMediaPickerController sharedController] startControlUI];
        });
    }
}

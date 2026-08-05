#import "VCAMMediaServerRefImageUtils.h"
#import <sys/time.h>

%hook BWNodeOutput

- (void)emitSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    unsigned int mediaType = ((unsigned int (*)(id, SEL))objc_msgSend)(self, sel_registerName("mediaType"));
    if (mediaType != 'vide') {
        static int otherSamples = 0;
        otherSamples++;
        if (otherSamples <= 3) {
            char msg[128] = {0};
            snprintf(msg, sizeof(msg), "emitSampleBuffer non-video mediaType=%08x count=%d", mediaType, otherSamples);
            VCAMRefLog(msg);
        }
        %orig(sampleBuffer);
        return;
    }

    CVPixelBufferRef originalImageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (originalImageBuffer == NULL) {
        static int nullBuffers = 0;
        nullBuffers++;
        if (nullBuffers <= 3) VCAMRefLog("emitSampleBuffer video buffer NULL");
        %orig(sampleBuffer);
        return;
    }

    static int videoSamples = 0;
    videoSamples++;
    if (videoSamples <= 8 || videoSamples % 300 == 0) {
        char msg[256] = {0};
        snprintf(msg, sizeof(msg), "emitSampleBuffer video count=%d size=%zux%zu",
                 videoSamples, CVPixelBufferGetWidth(originalImageBuffer), CVPixelBufferGetHeight(originalImageBuffer));
        VCAMRefLog(msg);
    }

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        VCAMRefLog("first video sample: loading replacement media");
        loadReplacementMedia();
        VCAMRefLog("loadReplacementMedia finished");
    });

    @autoreleasepool {
        drawReplacementOntoBuffer(originalImageBuffer);
    }

    %orig(sampleBuffer);
}

%end

%ctor {
    VCAMRefLog("ctor: VCAMMediaServerRefEntry loaded");
}

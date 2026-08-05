#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>

#import "VCAMFrameProducer.h"
#import "../Core/VCAMConfiguration.h"
#import "../Shared/VCAMSharedFrame.h"

static VCAMFrameProducer *VCAMProducer;
static VCAMSharedFrameWriter *VCAMWriter;
static dispatch_source_t VCAMTimer;

static void VCAMPublishTick(void) {
    @autoreleasepool {
        if (![VCAMProducer isEnabled]) {
            VCAMSharedFrameWriterClear(VCAMWriter);
            return;
        }
        CMSampleBufferRef sample = [VCAMProducer copyFrameForSize:
            CGSizeMake(VCAMSharedFrameWidth, VCAMSharedFrameHeight)];
        CVPixelBufferRef pixelBuffer = sample == NULL ? NULL : CMSampleBufferGetImageBuffer(sample);
        if (pixelBuffer == NULL || !VCAMSharedFrameWriterPublish(VCAMWriter, pixelBuffer)) {
            VCAMSharedFrameWriterClear(VCAMWriter);
        }
        if (sample != NULL) CFRelease(sample);
    }
}

static void VCAMScheduleTimer(void) {
    NSInteger fps = [VCAMProducer preferredFramesPerSecond];
    uint64_t interval = NSEC_PER_SEC / (uint64_t)MAX(1, MIN(60, fps));
    if (VCAMTimer == nil) {
        VCAMTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                           dispatch_get_main_queue());
        dispatch_source_set_event_handler(VCAMTimer, ^{ VCAMPublishTick(); });
        dispatch_resume(VCAMTimer);
    }
    dispatch_source_set_timer(VCAMTimer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              interval, interval / 10);
}

static void VCAMConfigurationChanged(CFNotificationCenterRef center, void *observer,
                                     CFStringRef name, const void *object,
                                     CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    dispatch_async(dispatch_get_main_queue(), ^{
        [VCAMProducer reload];
        VCAMScheduleTimer();
    });
}

int main(int argc, char *argv[]) {
    (void)argc; (void)argv;
    @autoreleasepool {
        VCAMWriter = VCAMSharedFrameWriterCreate();
        if (VCAMWriter == NULL) return 2;
        VCAMProducer = [VCAMFrameProducer new];
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL, VCAMConfigurationChanged,
                                        CFSTR("com.codex.vcam/preferences.changed"),
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        VCAMScheduleTimer();
        [VCAMConfiguration appendProcessLog:@"vcamd started"];
        CFRunLoopRun();
        VCAMSharedFrameWriterDestroy(VCAMWriter);
    }
    return 0;
}

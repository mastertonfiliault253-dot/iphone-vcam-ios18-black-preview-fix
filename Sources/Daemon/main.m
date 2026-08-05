#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>
#import <errno.h>
#import <stdio.h>
#import <string.h>
#import <unistd.h>

#import "VCAMFrameProducer.h"
#import "../Core/VCAMConfiguration.h"
#import "../Shared/VCAMSharedFrame.h"

static VCAMFrameProducer *VCAMProducer;
static VCAMSharedFrameWriter *VCAMWriter;
static dispatch_source_t VCAMTimer;

enum {
    MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES = 7,
    MEMORYSTATUS_CMD_GET_MEMLIMIT_PROPERTIES = 8,
    VCAMWorkerMemoryLimitMB = 256,
};

typedef struct {
    int32_t memlimit_active;
    uint32_t memlimit_active_attr;
    int32_t memlimit_inactive;
    uint32_t memlimit_inactive_attr;
} VCAMMemorystatusMemlimitProperties;

extern int memorystatus_control(uint32_t command, int32_t pid, uint32_t flags,
                                void *buffer, size_t bufferSize);

static BOOL VCAMRaiseJetsamMemoryLimit(void) {
    VCAMMemorystatusMemlimitProperties properties = {0};
    properties.memlimit_active = VCAMWorkerMemoryLimitMB;
    properties.memlimit_inactive = VCAMWorkerMemoryLimitMB;
    int result = memorystatus_control(MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES,
                                      getpid(), 0, &properties, sizeof(properties));
    if (result == 0) {
        VCAMMemorystatusMemlimitProperties effective = {0};
        int queryResult = memorystatus_control(MEMORYSTATUS_CMD_GET_MEMLIMIT_PROPERTIES,
                                               getpid(), 0, &effective, sizeof(effective));
        if (queryResult == 0) {
            fprintf(stderr,
                    "vcamd jetsam memory limit set to %d MB; effective active=%d inactive=%d MB\n",
                    VCAMWorkerMemoryLimitMB, effective.memlimit_active,
                    effective.memlimit_inactive);
        } else {
            fprintf(stderr, "vcamd jetsam memory limit set to %d MB; query failed: %s\n",
                    VCAMWorkerMemoryLimitMB, strerror(errno));
        }
    } else {
        fprintf(stderr, "vcamd failed to set jetsam memory limit: %s\n", strerror(errno));
    }
    fflush(stderr);
    return result == 0;
}

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
    VCAMRaiseJetsamMemoryLimit();
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

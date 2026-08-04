#import <CoreMedia/CoreMedia.h>
#import <objc/message.h>
#import "VCAMMediaServerProvider.h"
#import "../Core/VCAMConfiguration.h"
#import "../Core/VCAMInjectionPolicy.h"

%group VCAMMediaServerHooks

%hook BWNodeOutput

- (void)emitSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    unsigned int mediaType = ((unsigned int (*)(id, SEL))objc_msgSend)(self, sel_registerName("mediaType"));
    if (mediaType == 'vide') {
        CVPixelBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (imageBuffer != NULL) {
            @autoreleasepool {
                VCAMMediaServerReplacementDrawsIntoBuffer(imageBuffer);
            }
        }
    }
    %orig(sampleBuffer);
}

%end

%end

%ctor {
    @autoreleasepool {
        if ([VCAMInjectionPolicy currentTarget] != VCAMInjectionTargetMediaServer) return;
        BOOL enabled = [VCAMInjectionPolicy isCurrentProcessEnabled];
        [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:@"mediaserverd ctor enabled=%d", enabled]];
        %init(VCAMMediaServerHooks);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL,
                                        [](CFNotificationCenterRef center, void *observer,
                                           CFStringRef name, const void *object,
                                           CFDictionaryRef userInfo) {
            (void)center;
            (void)observer;
            (void)name;
            (void)object;
            (void)userInfo;
            // State is re-read from the shared plist on the next sample.
        },
                                        CFSTR("com.codex.vcam/preferences.changed"),
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
    }
}
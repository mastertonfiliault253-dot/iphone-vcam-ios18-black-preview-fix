#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import <substrate.h>
#import "../Core/VCAMFramePipeline.h"
#import "../Core/VCAMInjectionPolicy.h"
#import "../Core/VCAMConfiguration.h"

#ifndef VCAM_WITH_CONTROL_UI
#define VCAM_WITH_CONTROL_UI 0
#endif
#if VCAM_WITH_CONTROL_UI
#import <UIKit/UIKit.h>
#import "../UI/VCAMMediaPickerController.h"
#endif

static const void *VCAMReplacementPixelBufferKey = &VCAMReplacementPixelBufferKey;
static const void *VCAMReplacementPhotoDataKey = &VCAMReplacementPhotoDataKey;
static const void *VCAMReplacementDepthDataKey = &VCAMReplacementDepthDataKey;
static const void *VCAMReplacementMetadataKey = &VCAMReplacementMetadataKey;
static _Atomic(uint64_t) VCAMPhotoRequestCount;
static _Atomic(uint64_t) VCAMPhotoCallbackCount;
static _Atomic(uint64_t) VCAMRecordingStartCount;
static _Atomic(uint64_t) VCAMRecordingFinishCount;
static _Atomic(uint64_t) VCAMRecordingCopyAttemptCount;
static _Atomic(uint64_t) VCAMRecordingCopySuccessCount;
static _Atomic(uint64_t) VCAMRecordingSourceSize;
static _Atomic(uint64_t) VCAMRecordingOutputSizeBefore;
static _Atomic(uint64_t) VCAMRecordingOutputSizeAfter;
static _Atomic(long) VCAMRecordingRemoveErrorCode;
static _Atomic(long) VCAMRecordingCopyErrorCode;
static _Atomic(BOOL) VCAMRecordingSourceExists;
static _Atomic(BOOL) VCAMRecordingOutputIsFileURL;

extern "C" NSDictionary<NSString *, NSNumber *> *VCAMCaptureHookDiagnosticSnapshot(void) {
    return @{
        @"photoRequest": @(atomic_load_explicit(&VCAMPhotoRequestCount, memory_order_relaxed)),
        @"photoCallback": @(atomic_load_explicit(&VCAMPhotoCallbackCount, memory_order_relaxed)),
        @"recordingStart": @(atomic_load_explicit(&VCAMRecordingStartCount, memory_order_relaxed)),
        @"recordingFinish": @(atomic_load_explicit(&VCAMRecordingFinishCount, memory_order_relaxed)),
        @"copyAttempt": @(atomic_load_explicit(&VCAMRecordingCopyAttemptCount, memory_order_relaxed)),
        @"copySuccess": @(atomic_load_explicit(&VCAMRecordingCopySuccessCount, memory_order_relaxed)),
        @"sourceExists": @(atomic_load_explicit(&VCAMRecordingSourceExists, memory_order_relaxed)),
        @"outputIsFileURL": @(atomic_load_explicit(&VCAMRecordingOutputIsFileURL, memory_order_relaxed)),
        @"sourceSize": @(atomic_load_explicit(&VCAMRecordingSourceSize, memory_order_relaxed)),
        @"outputSizeBefore": @(atomic_load_explicit(&VCAMRecordingOutputSizeBefore, memory_order_relaxed)),
        @"outputSizeAfter": @(atomic_load_explicit(&VCAMRecordingOutputSizeAfter, memory_order_relaxed)),
        @"removeError": @(atomic_load_explicit(&VCAMRecordingRemoveErrorCode, memory_order_relaxed)),
        @"copyError": @(atomic_load_explicit(&VCAMRecordingCopyErrorCode, memory_order_relaxed)),
    };
}

static NSMutableSet<NSString *> *VCAMHookedDelegateClasses(void) {
    static NSMutableSet<NSString *> *classes;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ classes = [NSMutableSet set]; });
    return classes;
}

static void VCAMHookSampleDelegate(id delegate, SEL selector) {
    if (delegate == nil || ![delegate respondsToSelector:selector]) return;
    Class delegateClass = object_getClass(delegate);
    NSString *className = NSStringFromClass(delegateClass);
    NSMutableSet *hooked = VCAMHookedDelegateClasses();
    @synchronized (hooked) {
        if ([hooked containsObject:className]) return;

        __block void (*original)(id, SEL, AVCaptureOutput *, CMSampleBufferRef, AVCaptureConnection *) = NULL;
        IMP replacement = imp_implementationWithBlock(^(id receiver,
                                                         AVCaptureOutput *output,
                                                         CMSampleBufferRef sample,
                                                         AVCaptureConnection *connection) {
            BOOL isAudio = [output isKindOfClass:AVCaptureAudioDataOutput.class];
            CMSampleBufferRef alternate = isAudio
                ? [[VCAMFramePipeline sharedPipeline] copyReplacementAudioForSample:sample]
                : [[VCAMFramePipeline sharedPipeline] copyReplacementVideoForSample:sample];
            original(receiver, selector, output, alternate ?: sample, connection);
            if (alternate != NULL) CFRelease(alternate);
        });
        MSHookMessageEx(delegateClass, selector, replacement, (IMP *)&original);
        [hooked addObject:className];
    }
}

static CMSampleBufferRef VCAMCreateTemplateSample(CVPixelBufferRef pixelBuffer) {
    if (pixelBuffer == NULL) return NULL;
    CMVideoFormatDescriptionRef format = NULL;
    CMSampleBufferRef sample = NULL;
    CMSampleTimingInfo timing = {
        .duration = kCMTimeInvalid,
        .presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock()),
        .decodeTimeStamp = kCMTimeInvalid,
    };
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &format) == noErr) {
        CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, true, NULL, NULL,
                                           format, &timing, &sample);
    }
    if (format != NULL) CFRelease(format);
    return sample;
}

static void VCAMAttachReplacementToPhoto(AVCapturePhoto *photo) {
    NSData *pairedStill = [[VCAMFramePipeline sharedPipeline] pairedLivePhotoStillData];
    if (pairedStill != nil) {
        objc_setAssociatedObject(photo, VCAMReplacementPhotoDataKey, pairedStill, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    AVDepthData *depthData = [[VCAMFramePipeline sharedPipeline] replacementDepthData];
    if (depthData != nil) {
        objc_setAssociatedObject(photo, VCAMReplacementDepthDataKey, depthData, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSDictionary *metadata = [[VCAMFramePipeline sharedPipeline]
        replacementPhotoMetadataForOriginal:photo.metadata ?: @{}];
    if (metadata.count > 0) {
        objc_setAssociatedObject(photo, VCAMReplacementMetadataKey, metadata, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    CVPixelBufferRef originalPixelBuffer = photo.pixelBuffer;
    CMSampleBufferRef templateSample = VCAMCreateTemplateSample(originalPixelBuffer);
    if (templateSample == NULL) return;
    CMSampleBufferRef replacement = [[VCAMFramePipeline sharedPipeline] copyReplacementVideoForSample:templateSample];
    CFRelease(templateSample);
    if (replacement == NULL) return;

    CVPixelBufferRef replacementPixelBuffer = CMSampleBufferGetImageBuffer(replacement);
    if (replacementPixelBuffer != NULL) {
        objc_setAssociatedObject(photo, VCAMReplacementPixelBufferKey,
                                 (__bridge id)replacementPixelBuffer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        CIImage *image = [CIImage imageWithCVPixelBuffer:replacementPixelBuffer];
        CIContext *context = [CIContext contextWithOptions:nil];
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        NSData *jpeg = [context JPEGRepresentationOfImage:image colorSpace:colorSpace options:@{}];
        CGColorSpaceRelease(colorSpace);
        if (jpeg != nil && pairedStill == nil) {
            objc_setAssociatedObject(photo, VCAMReplacementPhotoDataKey, jpeg, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    CFRelease(replacement);
}

static NSMutableSet<NSString *> *VCAMHookedPhotoClasses(void) {
    static NSMutableSet<NSString *> *classes;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ classes = [NSMutableSet set]; });
    return classes;
}

static void VCAMHookPhotoClass(Class photoClass) {
    if (photoClass == Nil) return;
    NSString *className = NSStringFromClass(photoClass);
    NSMutableSet *hooked = VCAMHookedPhotoClasses();
    @synchronized (hooked) {
        if ([hooked containsObject:className]) return;

        __block NSData *(*originalData)(id, SEL) = NULL;
        MSHookMessageEx(photoClass, @selector(fileDataRepresentation),
                        imp_implementationWithBlock(^NSData *(id receiver) {
            NSData *replacement = objc_getAssociatedObject(receiver, VCAMReplacementPhotoDataKey);
            return replacement ?: originalData(receiver, @selector(fileDataRepresentation));
        }), (IMP *)&originalData);

        __block CVPixelBufferRef (*originalPixelBuffer)(id, SEL) = NULL;
        MSHookMessageEx(photoClass, @selector(pixelBuffer),
                        imp_implementationWithBlock(^CVPixelBufferRef(id receiver) {
            id replacement = objc_getAssociatedObject(receiver, VCAMReplacementPixelBufferKey);
            return replacement != nil ? (__bridge CVPixelBufferRef)replacement
                                      : originalPixelBuffer(receiver, @selector(pixelBuffer));
        }), (IMP *)&originalPixelBuffer);

        __block AVDepthData *(*originalDepthData)(id, SEL) = NULL;
        MSHookMessageEx(photoClass, @selector(depthData),
                        imp_implementationWithBlock(^AVDepthData *(id receiver) {
            AVDepthData *replacement = objc_getAssociatedObject(receiver, VCAMReplacementDepthDataKey);
            return replacement ?: originalDepthData(receiver, @selector(depthData));
        }), (IMP *)&originalDepthData);

        __block NSDictionary *(*originalMetadata)(id, SEL) = NULL;
        MSHookMessageEx(photoClass, @selector(metadata),
                        imp_implementationWithBlock(^NSDictionary *(id receiver) {
            NSDictionary *replacement = objc_getAssociatedObject(receiver, VCAMReplacementMetadataKey);
            return replacement ?: originalMetadata(receiver, @selector(metadata));
        }), (IMP *)&originalMetadata);
        [hooked addObject:className];
    }
}

static NSMutableSet<NSString *> *VCAMHookedPhotoDelegateClasses(void) {
    static NSMutableSet<NSString *> *classes;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ classes = [NSMutableSet set]; });
    return classes;
}

static void VCAMHookPhotoDelegate(id delegate) {
    SEL selector = @selector(captureOutput:didFinishProcessingPhoto:error:);
    if (delegate == nil || ![delegate respondsToSelector:selector]) return;
    Class delegateClass = object_getClass(delegate);
    NSString *className = NSStringFromClass(delegateClass);
    NSMutableSet *hooked = VCAMHookedPhotoDelegateClasses();
    @synchronized (hooked) {
        if ([hooked containsObject:className]) return;
        __block void (*original)(id, SEL, AVCapturePhotoOutput *, AVCapturePhoto *, NSError *) = NULL;
        MSHookMessageEx(delegateClass, selector,
                        imp_implementationWithBlock(^(id receiver,
                                                       AVCapturePhotoOutput *output,
                                                       AVCapturePhoto *photo,
                                                       NSError *error) {
            atomic_fetch_add_explicit(&VCAMPhotoCallbackCount, 1, memory_order_relaxed);
            VCAMHookPhotoClass(object_getClass(photo));
            VCAMAttachReplacementToPhoto(photo);
            original(receiver, selector, output, photo, error);
        }), (IMP *)&original);
        [hooked addObject:className];
    }
}

static NSMutableSet<NSString *> *VCAMHookedLivePhotoDelegateClasses(void) {
    static NSMutableSet<NSString *> *classes;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ classes = [NSMutableSet set]; });
    return classes;
}

static void VCAMHookLivePhotoDelegate(id delegate) {
    SEL selector = @selector(captureOutput:didFinishProcessingLivePhotoToMovieFileAtURL:duration:photoDisplayTime:resolvedSettings:error:);
    if (delegate == nil || ![delegate respondsToSelector:selector]) return;
    Class delegateClass = object_getClass(delegate);
    NSString *className = NSStringFromClass(delegateClass);
    NSMutableSet *hooked = VCAMHookedLivePhotoDelegateClasses();
    @synchronized (hooked) {
        if ([hooked containsObject:className]) return;
        __block void (*original)(id, SEL, AVCapturePhotoOutput *, NSURL *, CMTime, CMTime,
                                 AVCaptureResolvedPhotoSettings *, NSError *) = NULL;
        MSHookMessageEx(delegateClass, selector,
                        imp_implementationWithBlock(^(id receiver,
                                                       AVCapturePhotoOutput *output,
                                                       NSURL *outputURL,
                                                       CMTime duration,
                                                       CMTime photoDisplayTime,
                                                       AVCaptureResolvedPhotoSettings *resolvedSettings,
                                                       NSError *error) {
            NSString *replacementPath = [[VCAMFramePipeline sharedPipeline] pairedLivePhotoMoviePath];
            if (replacementPath.length > 0 && outputURL.isFileURL) {
                NSData *movieData = [NSData dataWithContentsOfFile:replacementPath
                                                           options:NSDataReadingMappedIfSafe
                                                             error:nil];
                if (movieData.length > 0) {
                    [movieData writeToURL:outputURL options:NSDataWritingAtomic error:nil];
                }
            }
            original(receiver, selector, output, outputURL, duration, photoDisplayTime, resolvedSettings, error);
        }), (IMP *)&original);
        [hooked addObject:className];
    }
}

static NSMutableSet<NSString *> *VCAMHookedRecordingDelegateClasses(void) {
    static NSMutableSet<NSString *> *classes;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ classes = [NSMutableSet set]; });
    return classes;
}

static void VCAMHookRecordingDelegate(id delegate) {
    SEL selector = @selector(captureOutput:didFinishRecordingToOutputFileAtURL:fromConnections:error:);
    if (delegate == nil || ![delegate respondsToSelector:selector]) return;
    Class delegateClass = object_getClass(delegate);
    NSString *className = NSStringFromClass(delegateClass);
    NSMutableSet *hooked = VCAMHookedRecordingDelegateClasses();
    @synchronized (hooked) {
        if ([hooked containsObject:className]) return;
        __block void (*original)(id, SEL, AVCaptureFileOutput *, NSURL *, NSArray<AVCaptureConnection *> *, NSError *) = NULL;
        MSHookMessageEx(delegateClass, selector,
                        imp_implementationWithBlock(^(id receiver,
                                                       AVCaptureFileOutput *output,
                                                       NSURL *outputURL,
                                                       NSArray<AVCaptureConnection *> *connections,
                                                       NSError *error) {
            atomic_fetch_add_explicit(&VCAMRecordingFinishCount, 1, memory_order_relaxed);
            NSError *replacementError = nil;
            NSString *replacementPath = [[VCAMFramePipeline sharedPipeline] localRecordingReplacementPath];
            NSURL *recordedOBSFile = [[VCAMFramePipeline sharedPipeline] finishReplacementRecording];
            if (replacementPath.length == 0) replacementPath = recordedOBSFile.path;
            NSFileManager *manager = NSFileManager.defaultManager;
            BOOL sourceExists = replacementPath.length > 0 && [manager fileExistsAtPath:replacementPath];
            NSDictionary *sourceAttributes = sourceExists ? [manager attributesOfItemAtPath:replacementPath error:nil] : nil;
            NSDictionary *outputAttributes = outputURL.isFileURL ? [manager attributesOfItemAtPath:outputURL.path error:nil] : nil;
            atomic_store_explicit(&VCAMRecordingSourceExists, sourceExists, memory_order_relaxed);
            atomic_store_explicit(&VCAMRecordingOutputIsFileURL, outputURL.isFileURL, memory_order_relaxed);
            atomic_store_explicit(&VCAMRecordingSourceSize, [sourceAttributes fileSize], memory_order_relaxed);
            atomic_store_explicit(&VCAMRecordingOutputSizeBefore, [outputAttributes fileSize], memory_order_relaxed);
            atomic_store_explicit(&VCAMRecordingRemoveErrorCode, 0, memory_order_relaxed);
            atomic_store_explicit(&VCAMRecordingCopyErrorCode, 0, memory_order_relaxed);
            if (replacementPath.length > 0 && outputURL.isFileURL &&
                ![replacementPath isEqualToString:outputURL.path]) {
                atomic_fetch_add_explicit(&VCAMRecordingCopyAttemptCount, 1, memory_order_relaxed);
                NSError *removeError = nil;
                [manager removeItemAtURL:outputURL error:&removeError];
                BOOL copied = [manager copyItemAtURL:[NSURL fileURLWithPath:replacementPath]
                                               toURL:outputURL
                                               error:&replacementError];
                if (copied) atomic_fetch_add_explicit(&VCAMRecordingCopySuccessCount, 1, memory_order_relaxed);
                atomic_store_explicit(&VCAMRecordingRemoveErrorCode, removeError.code, memory_order_relaxed);
                atomic_store_explicit(&VCAMRecordingCopyErrorCode, replacementError.code, memory_order_relaxed);
                NSDictionary *afterAttributes = [manager attributesOfItemAtPath:outputURL.path error:nil];
                atomic_store_explicit(&VCAMRecordingOutputSizeAfter, [afterAttributes fileSize], memory_order_relaxed);
            }
            original(receiver, selector, output, outputURL, connections, replacementError ?: error);
        }), (IMP *)&original);
        [hooked addObject:className];
    }
}

%group VCAMMediaHooks

%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate
                           queue:(dispatch_queue_t)queue {
    VCAMHookSampleDelegate(delegate,
                           @selector(captureOutput:didOutputSampleBuffer:fromConnection:));
    %orig;
}

%end

%hook AVCapturePhotoOutput

- (void)capturePhotoWithSettings:(AVCapturePhotoSettings *)settings
                         delegate:(id<AVCapturePhotoCaptureDelegate>)delegate {
    atomic_fetch_add_explicit(&VCAMPhotoRequestCount, 1, memory_order_relaxed);
    VCAMHookPhotoDelegate(delegate);
    if (settings.livePhotoMovieFileURL != nil) VCAMHookLivePhotoDelegate(delegate);
    %orig;
}

%end

%hook AVCaptureAudioDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureAudioDataOutputSampleBufferDelegate>)delegate
                           queue:(dispatch_queue_t)queue {
    VCAMHookSampleDelegate(delegate,
                           @selector(captureOutput:didOutputSampleBuffer:fromConnection:));
    %orig;
}

%end

%hook AVCaptureMovieFileOutput

- (void)startRecordingToOutputFileURL:(NSURL *)outputFileURL
                    recordingDelegate:(id<AVCaptureFileOutputRecordingDelegate>)delegate {
    atomic_fetch_add_explicit(&VCAMRecordingStartCount, 1, memory_order_relaxed);
    VCAMHookRecordingDelegate(delegate);
    [[VCAMFramePipeline sharedPipeline] startReplacementRecording];
    %orig;
}

%end

%end

%ctor {
    @autoreleasepool {
        if (![VCAMInjectionPolicy isRecognizedTarget]) return;
        BOOL installMediaHooks = [VCAMInjectionPolicy isCurrentProcessMediaReplacementEnabled];
        BOOL supportsControlUI = [VCAMInjectionPolicy supportsControlUIInCurrentProcess];
        [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:@"ctor target=%ld installMediaHooks=%d supportsControlUI=%d", (long)[VCAMInjectionPolicy currentTarget], installMediaHooks, supportsControlUI]];
        if (!installMediaHooks && !supportsControlUI) return;
        if (installMediaHooks) {
            %init(VCAMMediaHooks);
            [VCAMFramePipeline sharedPipeline];
        }
#if VCAM_WITH_CONTROL_UI
        if (supportsControlUI) [[VCAMMediaPickerController sharedController] startControlUI];
#endif
        if (installMediaHooks) CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL,
                                        [](CFNotificationCenterRef center, void *observer,
                                           CFStringRef name, const void *object,
                                           CFDictionaryRef userInfo) {
            (void)center;
            (void)observer;
            (void)name;
            (void)object;
            (void)userInfo;
            [[VCAMFramePipeline sharedPipeline] reloadConfiguration];
        },
                                        CFSTR("com.codex.vcam/preferences.changed"),
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
    }
}

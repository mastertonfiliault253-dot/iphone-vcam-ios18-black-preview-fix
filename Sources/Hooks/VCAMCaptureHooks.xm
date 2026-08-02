#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import <substrate.h>
#import <UIKit/UIKit.h>
#import "../Core/VCAMFramePipeline.h"
#import "../UI/VCAMMediaPickerController.h"
#import "VCAMPreviewDriver.h"

static const void *VCAMReplacementPixelBufferKey = &VCAMReplacementPixelBufferKey;
static const void *VCAMReplacementPhotoDataKey = &VCAMReplacementPhotoDataKey;
static const void *VCAMReplacementDepthDataKey = &VCAMReplacementDepthDataKey;
static const void *VCAMReplacementMetadataKey = &VCAMReplacementMetadataKey;
static const void *VCAMPreviewDriverKey = &VCAMPreviewDriverKey;
static _Atomic(uint64_t) VCAMPhotoRequestCount;
static _Atomic(uint64_t) VCAMPhotoCallbackCount;
static _Atomic(uint64_t) VCAMRecordingStartCount;
static _Atomic(uint64_t) VCAMRecordingFinishCount;

extern "C" NSDictionary<NSString *, NSNumber *> *VCAMCaptureHookDiagnosticSnapshot(void) {
    return @{
        @"photoRequest": @(atomic_load_explicit(&VCAMPhotoRequestCount, memory_order_relaxed)),
        @"photoCallback": @(atomic_load_explicit(&VCAMPhotoCallbackCount, memory_order_relaxed)),
        @"recordingStart": @(atomic_load_explicit(&VCAMRecordingStartCount, memory_order_relaxed)),
        @"recordingFinish": @(atomic_load_explicit(&VCAMRecordingFinishCount, memory_order_relaxed)),
    };
}

static BOOL VCAMIsAllowedProcess(void) {
    NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
    NSString *processName = NSProcessInfo.processInfo.processName;
    return [bundleIdentifier isEqualToString:@"com.apple.camera"] ||
           [processName isEqualToString:@"Camera"];
}

static void VCAMInstallPreviewDriver(AVCaptureVideoPreviewLayer *layer) {
    if (layer == nil || objc_getAssociatedObject(layer, VCAMPreviewDriverKey) != nil) return;
    VCAMPreviewDriver *driver = [[VCAMPreviewDriver alloc] initWithPreviewLayer:layer];
    objc_setAssociatedObject(layer, VCAMPreviewDriverKey, driver, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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
            if (replacementPath.length > 0 && outputURL.isFileURL &&
                ![replacementPath isEqualToString:outputURL.path]) {
                NSFileManager *manager = NSFileManager.defaultManager;
                [manager removeItemAtURL:outputURL error:nil];
                [manager copyItemAtURL:[NSURL fileURLWithPath:replacementPath]
                                 toURL:outputURL
                                 error:&replacementError];
            }
            original(receiver, selector, output, outputURL, connections, replacementError ?: error);
        }), (IMP *)&original);
        [hooked addObject:className];
    }
}

%group VCAMCameraHooks

%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate
                           queue:(dispatch_queue_t)queue {
    VCAMHookSampleDelegate(delegate,
                           @selector(captureOutput:didOutputSampleBuffer:fromConnection:));
    %orig;
}

%end

%hook AVCaptureVideoPreviewLayer

- (instancetype)initWithSession:(AVCaptureSession *)session {
    AVCaptureVideoPreviewLayer *layer = %orig;
    VCAMInstallPreviewDriver(layer);
    return layer;
}

- (instancetype)initWithSessionWithNoConnection:(AVCaptureSession *)session {
    AVCaptureVideoPreviewLayer *layer = %orig;
    VCAMInstallPreviewDriver(layer);
    return layer;
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
        if (!VCAMIsAllowedProcess()) return;
        %init(VCAMCameraHooks);
        [VCAMFramePipeline sharedPipeline];
        [[VCAMMediaPickerController sharedController] start];
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
            [[VCAMFramePipeline sharedPipeline] reloadConfiguration];
        },
                                        CFSTR("com.codex.vcam/preferences.changed"),
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
    }
}

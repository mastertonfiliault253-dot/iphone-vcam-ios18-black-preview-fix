#import "VCAMMediaServerRefImageUtils.h"
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <stdio.h>
#include <string.h>
#import <sys/time.h>

static void VCAMFourCCString(OSType value, char output[5]) {
    output[0] = (char)((value >> 24) & 0xff);
    output[1] = (char)((value >> 16) & 0xff);
    output[2] = (char)((value >> 8) & 0xff);
    output[3] = (char)(value & 0xff);
    output[4] = '\0';
    for (int index = 0; index < 4; index++) {
        if (output[index] < 32 || output[index] > 126) output[index] = '?';
    }
}

static id VCAMSafeObjectResult(id object, SEL selector) {
    if (object == nil || selector == NULL) return nil;
    Method method = class_getInstanceMethod([object class], selector);
    if (method == NULL) return nil;
    char returnType[16] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    const char *type = returnType;
    while (*type != '\0' && strchr("rnNoORV", *type) != NULL) type++;
    if (*type != '@') return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSString *VCAMSafeStringValue(id value) {
    return [value isKindOfClass:NSString.class] ? value : @"(none)";
}

static BOOL VCAMBasicOutputSignatureWasSeen(id output, NSString *basicSignature) {
    static NSMapTable<id, NSMutableSet<NSString *> *> *signaturesByOutput;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        signaturesByOutput = [NSMapTable
            mapTableWithKeyOptions:NSPointerFunctionsWeakMemory |
                                   NSPointerFunctionsObjectPointerPersonality
                      valueOptions:NSPointerFunctionsStrongMemory];
    });
    @synchronized (signaturesByOutput) {
        NSMutableSet<NSString *> *signatures = [signaturesByOutput objectForKey:output];
        if (signatures == nil) {
            signatures = [NSMutableSet set];
            [signaturesByOutput setObject:signatures forKey:output];
        }
        if ([signatures containsObject:basicSignature]) return YES;
        [signatures addObject:basicSignature];
        return NO;
    }
}

typedef NS_ENUM(NSUInteger, VCAMReplacementRoute) {
    VCAMReplacementRouteNone = 0,
    VCAMReplacementRouteCameraSourceVideo,
    VCAMReplacementRouteVideoConverter,
    VCAMReplacementRouteCameraPreview,
    VCAMReplacementRouteVideoRecording,
    VCAMReplacementRouteStillPhoto,
};

static const char *VCAMReplacementRouteName(VCAMReplacementRoute route) {
    switch (route) {
        case VCAMReplacementRouteCameraSourceVideo: return "camera-source-video";
        case VCAMReplacementRouteVideoConverter: return "video-converter";
        case VCAMReplacementRouteCameraPreview: return "camera-preview";
        case VCAMReplacementRouteVideoRecording: return "video-recording";
        case VCAMReplacementRouteStillPhoto: return "still-photo";
        case VCAMReplacementRouteNone: return "none";
    }
    return "none";
}

static BOOL VCAMStringMatches(NSString *value, NSString *expected) {
    return [value isKindOfClass:NSString.class] &&
        [expected isKindOfClass:NSString.class] &&
        [value isEqualToString:expected];
}

enum { VCAMRecordingFrameOutcomeCapacity = 128 };

typedef struct {
    BOOL valid;
    BOOL succeeded;
    CMTime presentationTime;
    int32_t width;
    int32_t height;
    uint64_t serial;
} VCAMRecordingFrameOutcome;

static VCAMRecordingFrameOutcome
    VCAMRecordingFrameOutcomes[VCAMRecordingFrameOutcomeCapacity];
static uint64_t VCAMRecordingFrameOutcomeSerial;
static uintptr_t VCAMRecordingAuthorizingStream;
static CFAbsoluteTime VCAMRecordingAuthorizingStreamLastSeen;
static CFAbsoluteTime VCAMRecordingConcurrentUntil;

static NSLock *VCAMRecordingFrameOutcomeLock(void) {
    static NSLock *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ lock = [NSLock new]; });
    return lock;
}

static BOOL VCAMUsablePresentationTime(CMTime time) {
    return CMTIME_IS_NUMERIC(time);
}

static void VCAMRecordRecordingFrameOutcome(id output,
                                            CMSampleBufferRef sampleBuffer,
                                            CVPixelBufferRef pixelBuffer,
                                            BOOL succeeded) {
    CMTime presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    if (!VCAMUsablePresentationTime(presentationTime) || pixelBuffer == NULL) return;
    int32_t width = (int32_t)CVPixelBufferGetWidth(pixelBuffer);
    int32_t height = (int32_t)CVPixelBufferGetHeight(pixelBuffer);
    NSLock *lock = VCAMRecordingFrameOutcomeLock();
    [lock lock];
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    id node = VCAMSafeObjectResult(output, sel_registerName("node"));
    uintptr_t stream = (uintptr_t)(__bridge void *)(node ?: output);
    BOOL concurrentStreamDetected = NO;
    if (VCAMRecordingAuthorizingStream == 0 ||
        VCAMRecordingAuthorizingStream == stream ||
        now - VCAMRecordingAuthorizingStreamLastSeen > 1.0) {
        VCAMRecordingAuthorizingStream = stream;
        VCAMRecordingAuthorizingStreamLastSeen = now;
    } else {
        // The encoded output does not expose a stable public graph identity.
        // Fail all streams closed while two raw recording outputs overlap so
        // one stream's PTS can never authorize another stream's real frame.
        concurrentStreamDetected = YES;
        VCAMRecordingConcurrentUntil = now + 2.0;
        VCAMRecordingAuthorizingStream = stream;
        VCAMRecordingAuthorizingStreamLastSeen = now;
        for (NSUInteger index = 0;
             index < VCAMRecordingFrameOutcomeCapacity; index++) {
            VCAMRecordingFrameOutcomes[index].succeeded = NO;
        }
    }
    succeeded = succeeded && now >= VCAMRecordingConcurrentUntil;
    NSInteger matchingIndex = -1;
    NSInteger emptyIndex = -1;
    NSInteger oldestIndex = 0;
    uint64_t oldestSerial = UINT64_MAX;
    for (NSUInteger index = 0; index < VCAMRecordingFrameOutcomeCapacity; index++) {
        VCAMRecordingFrameOutcome *entry = &VCAMRecordingFrameOutcomes[index];
        if (!entry->valid) {
            if (emptyIndex < 0) emptyIndex = (NSInteger)index;
            continue;
        }
        if (entry->width == width && entry->height == height &&
            CMTimeCompare(entry->presentationTime, presentationTime) == 0) {
            matchingIndex = (NSInteger)index;
            break;
        }
        if (entry->serial < oldestSerial) {
            oldestSerial = entry->serial;
            oldestIndex = (NSInteger)index;
        }
    }
    if (matchingIndex >= 0) {
        // Failure wins when duplicate branches report the same frame.
        VCAMRecordingFrameOutcomes[matchingIndex].succeeded =
            VCAMRecordingFrameOutcomes[matchingIndex].succeeded && succeeded;
        VCAMRecordingFrameOutcomes[matchingIndex].serial =
            ++VCAMRecordingFrameOutcomeSerial;
    } else {
        NSInteger replacementIndex = emptyIndex >= 0 ? emptyIndex : oldestIndex;
        VCAMRecordingFrameOutcomes[replacementIndex] = (VCAMRecordingFrameOutcome){
            .valid = YES,
            .succeeded = succeeded,
            .presentationTime = presentationTime,
            .width = width,
            .height = height,
            .serial = ++VCAMRecordingFrameOutcomeSerial,
        };
    }
    [lock unlock];
    if (concurrentStreamDetected) {
        static volatile int concurrentEvents = 0;
        int eventCount = __sync_add_and_fetch(&concurrentEvents, 1);
        if (eventCount <= 8 || eventCount % 300 == 0) {
            char message[176] = {0};
            snprintf(message, sizeof(message),
                     "concurrent recording streams fail closed count=%d",
                     eventCount);
            VCAMRefLog(message);
        }
    }
}

static BOOL VCAMEncodedRecordingSampleCanPass(CMSampleBufferRef sampleBuffer) {
    CMTime presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sampleBuffer);
    if (!VCAMUsablePresentationTime(presentationTime) || format == NULL) return NO;
    CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(format);
    BOOL found = NO;
    BOOL succeeded = NO;
    NSLock *lock = VCAMRecordingFrameOutcomeLock();
    [lock lock];
    for (NSUInteger index = 0; index < VCAMRecordingFrameOutcomeCapacity; index++) {
        VCAMRecordingFrameOutcome *entry = &VCAMRecordingFrameOutcomes[index];
        if (!entry->valid || entry->width != dimensions.width ||
            entry->height != dimensions.height ||
            CMTimeCompare(entry->presentationTime, presentationTime) != 0) continue;
        found = YES;
        succeeded = entry->succeeded;
        entry->valid = NO;
        break;
    }
    [lock unlock];
    return found && succeeded;
}

static BOOL VCAMOutputIsCameraVideoCompressor(id output) {
    id node = VCAMSafeObjectResult(output, sel_registerName("node"));
    NSString *nodeClass = node == nil ? nil : NSStringFromClass([node class]);
    NSString *nodeName = VCAMSafeObjectResult(node, sel_registerName("name"));
    return VCAMStringMatches(nodeClass, @"BWVideoCompressorNode") &&
        [nodeName isKindOfClass:NSString.class] &&
        [nodeName containsString:@"Video Compressor"];
}

static BOOL VCAMSampleContainsEncodedCameraVideo(CMSampleBufferRef sampleBuffer) {
    if (sampleBuffer == NULL || CMSampleBufferGetDataBuffer(sampleBuffer) == NULL) {
        return NO;
    }
    CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sampleBuffer);
    OSType subtype = format == NULL ? 0 : CMFormatDescriptionGetMediaSubType(format);
    return subtype == kCMVideoCodecType_H264 ||
        subtype == kCMVideoCodecType_HEVC || subtype == (OSType)'hev1';
}

static void VCAMCopyDictionaryEntry(const void *key, const void *value,
                                    void *context) {
    CFDictionarySetValue((CFMutableDictionaryRef)context, key, value);
}

static void VCAMCopyAttachmentMode(CMAttachmentBearerRef source,
                                   CMAttachmentBearerRef destination,
                                   CMAttachmentMode mode) {
    CFDictionaryRef attachments = CMCopyDictionaryOfAttachments(
        kCFAllocatorDefault, source, mode);
    if (attachments == NULL) return;
    CMSetAttachments(destination, attachments, mode);
    CFRelease(attachments);
}

static CMSampleBufferRef VCAMCreateSampleBufferWithReplacementImage(
    CMSampleBufferRef originalSampleBuffer,
    CVPixelBufferRef replacementImageBuffer) {
    if (originalSampleBuffer == NULL || replacementImageBuffer == NULL) return NULL;
    CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(
        originalSampleBuffer);
    if (format == NULL) return NULL;
    CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(format);
    if (dimensions.width != (int32_t)CVPixelBufferGetWidth(replacementImageBuffer) ||
        dimensions.height != (int32_t)CVPixelBufferGetHeight(replacementImageBuffer) ||
        CMFormatDescriptionGetMediaSubType(format) !=
            CVPixelBufferGetPixelFormatType(replacementImageBuffer)) return NULL;

    CMSampleTimingInfo timing;
    memset(&timing, 0, sizeof(timing));
    if (CMSampleBufferGetSampleTimingInfo(originalSampleBuffer, 0, &timing) != noErr) {
        return NULL;
    }
    CMSampleBufferRef replacementSampleBuffer = NULL;
    OSStatus createStatus = CMSampleBufferCreateReadyWithImageBuffer(
        kCFAllocatorDefault, replacementImageBuffer, format, &timing,
        &replacementSampleBuffer);
    if (createStatus != noErr || replacementSampleBuffer == NULL) {
        static volatile int creationFailures = 0;
        int failureCount = __sync_add_and_fetch(&creationFailures, 1);
        if (failureCount <= 8 || failureCount % 300 == 0) {
            char message[176] = {0};
            snprintf(message, sizeof(message),
                     "compressed replacement sample creation failed count=%d status=%d",
                     failureCount, (int)createStatus);
            VCAMRefLog(message);
        }
        return NULL;
    }

    VCAMCopyAttachmentMode(originalSampleBuffer, replacementSampleBuffer,
                           kCMAttachmentMode_ShouldPropagate);
    VCAMCopyAttachmentMode(originalSampleBuffer, replacementSampleBuffer,
                           kCMAttachmentMode_ShouldNotPropagate);
    CFArrayRef sourceSampleAttachments = CMSampleBufferGetSampleAttachmentsArray(
        originalSampleBuffer, false);
    CFArrayRef destinationSampleAttachments = CMSampleBufferGetSampleAttachmentsArray(
        replacementSampleBuffer, true);
    if (sourceSampleAttachments != NULL && destinationSampleAttachments != NULL &&
        CFArrayGetCount(sourceSampleAttachments) > 0 &&
        CFArrayGetCount(destinationSampleAttachments) > 0) {
        CFDictionaryRef sourceDictionary = (CFDictionaryRef)CFArrayGetValueAtIndex(
            sourceSampleAttachments, 0);
        CFMutableDictionaryRef destinationDictionary =
            (CFMutableDictionaryRef)CFArrayGetValueAtIndex(
                destinationSampleAttachments, 0);
        CFDictionaryRemoveAllValues(destinationDictionary);
        CFDictionaryApplyFunction(sourceDictionary, VCAMCopyDictionaryEntry,
                                  destinationDictionary);
    }
    return replacementSampleBuffer;
}

static CFStringRef const VCAMPropagationMarkerKey =
    CFSTR("com.codex.vcam.virtual-frame.v1");

static BOOL VCAMRouteUsesPropagationMarker(VCAMReplacementRoute route) {
    return route == VCAMReplacementRouteVideoConverter ||
        route == VCAMReplacementRouteCameraPreview ||
        route == VCAMReplacementRouteVideoRecording;
}

static BOOL VCAMWritePropagationMarker(CMSampleBufferRef sampleBuffer,
                                       CVPixelBufferRef imageBuffer) {
    if (sampleBuffer == NULL || imageBuffer == NULL) return NO;
    CMTime presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    if (!CMTIME_IS_NUMERIC(presentationTime)) return NO;
    NSDictionary<NSString *, NSNumber *> *marker = @{
        @"version": @1,
        @"value": @(presentationTime.value),
        @"timescale": @(presentationTime.timescale),
        @"flags": @(presentationTime.flags),
        @"epoch": @(presentationTime.epoch),
    };
    CMSetAttachment(sampleBuffer, VCAMPropagationMarkerKey,
                    (__bridge CFDictionaryRef)marker,
                    kCMAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(imageBuffer, VCAMPropagationMarkerKey,
                          (__bridge CFDictionaryRef)marker,
                          kCVAttachmentMode_ShouldPropagate);
    return YES;
}

static BOOL VCAMPropagationMarkerGetTime(CFTypeRef markerObject,
                                         CMTime *presentationTimeOut) {
    if (markerObject == NULL || presentationTimeOut == NULL ||
        CFGetTypeID(markerObject) != CFDictionaryGetTypeID()) return NO;
    NSDictionary *marker = (__bridge NSDictionary *)markerObject;
    NSNumber *version = [marker objectForKey:@"version"];
    NSNumber *value = [marker objectForKey:@"value"];
    NSNumber *timescale = [marker objectForKey:@"timescale"];
    NSNumber *flags = [marker objectForKey:@"flags"];
    NSNumber *epoch = [marker objectForKey:@"epoch"];
    if (![version isKindOfClass:NSNumber.class] || version.integerValue != 1 ||
        ![value isKindOfClass:NSNumber.class] ||
        ![timescale isKindOfClass:NSNumber.class] ||
        ![flags isKindOfClass:NSNumber.class] ||
        ![epoch isKindOfClass:NSNumber.class]) return NO;
    CMTime markerTime = {
        .value = value.longLongValue,
        .timescale = timescale.intValue,
        .flags = (CMTimeFlags)flags.unsignedIntValue,
        .epoch = epoch.longLongValue,
    };
    if (!CMTIME_IS_NUMERIC(markerTime)) return NO;
    *presentationTimeOut = markerTime;
    return YES;
}

static BOOL VCAMSampleHasMatchingPropagationMarker(
    CMSampleBufferRef sampleBuffer,
    CVPixelBufferRef imageBuffer) {
    if (sampleBuffer == NULL) return NO;
    CMTime presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    if (!CMTIME_IS_NUMERIC(presentationTime)) return NO;

    CMAttachmentMode sampleMode = kCMAttachmentMode_ShouldNotPropagate;
    CFTypeRef sampleMarker = CMGetAttachment(sampleBuffer,
                                             VCAMPropagationMarkerKey,
                                             &sampleMode);
    CMTime markerTime = kCMTimeInvalid;
    if (sampleMode == kCMAttachmentMode_ShouldPropagate &&
        VCAMPropagationMarkerGetTime(sampleMarker, &markerTime) &&
        CMTIME_IS_NUMERIC(markerTime) &&
        CMTimeCompare(markerTime, presentationTime) == 0) return YES;

    if (imageBuffer == NULL) return NO;
    CVAttachmentMode imageMode = kCVAttachmentMode_ShouldNotPropagate;
    CFTypeRef imageMarker = CVBufferGetAttachment(imageBuffer,
                                                  VCAMPropagationMarkerKey,
                                                  &imageMode);
    markerTime = kCMTimeInvalid;
    return imageMode == kCVAttachmentMode_ShouldPropagate &&
        VCAMPropagationMarkerGetTime(imageMarker, &markerTime) &&
        CMTIME_IS_NUMERIC(markerTime) &&
        CMTimeCompare(markerTime, presentationTime) == 0;
}

static VCAMReplacementRoute VCAMReplacementRouteForOutput(id output,
                                                            CVPixelBufferRef pixelBuffer) {
    id node = VCAMSafeObjectResult(output, sel_registerName("node"));
    NSString *nodeClass = node == nil ? nil : NSStringFromClass([node class]);
    NSString *outputName = VCAMSafeObjectResult(output, sel_registerName("name"));
    NSString *nodeName = VCAMSafeObjectResult(node, sel_registerName("name"));

    // This is the device-observed raw VideoCapture branch feeding SmartCam and
    // other camera analysis consumers. Route by the exact output role, not by
    // buffer format support: a recognized source role must fail closed when a
    // future format cannot be rendered instead of exposing the physical frame.
    if (VCAMStringMatches(nodeClass, @"BWMultiStreamCameraSourceNode") &&
        VCAMStringMatches(outputName, @"VideoCapture")) {
        return VCAMReplacementRouteCameraSourceVideo;
    }

    // These are the terminal conversion roles observed for Safari getUserMedia
    // and the stock Camera preview. They are deliberately independent of the
    // physical camera node name. A known terminal role remains selected even
    // for a future unsupported pixel format so enabled mode drops that sample
    // instead of leaking a real frame.
    if (VCAMStringMatches(nodeClass, @"BWPixelTransferNode")) {
        if (VCAMStringMatches(nodeName, @"Video Data Converter/Scaler/Zoomer")) {
            return VCAMReplacementRouteVideoConverter;
        }
        if (VCAMStringMatches(nodeName, @"Preview Scaler")) {
            return VCAMReplacementRouteCameraPreview;
        }
        if (VCAMStringMatches(nodeName, @"Movie File Zoomer")) {
            return VCAMReplacementRouteVideoRecording;
        }
    }

    // Stock Camera still capture reaches this last standard 8-bit pixel stage
    // immediately before the photo encoder. Match the role rather than a lens
    // name, resolution or pixel format. Unsupported future formats fail closed
    // in the hook rather than reaching the encoder as a real frame.
    if (VCAMStringMatches(nodeClass, @"BWMeteorHeadroomNode") &&
        VCAMStringMatches(nodeName, @"Meteor Headroom") && pixelBuffer != NULL) {
        return VCAMReplacementRouteStillPhoto;
    }

    return VCAMReplacementRouteNone;
}

static void VCAMLogOutputSignature(id output, CMSampleBufferRef sampleBuffer,
                                   CVPixelBufferRef pixelBuffer,
                                   VCAMReplacementRoute replacementRoute) {
    CMFormatDescriptionRef description = CMSampleBufferGetFormatDescription(sampleBuffer);
    OSType subtype = description == NULL ? 0 : CMFormatDescriptionGetMediaSubType(description);
    OSType pixelFormat = pixelBuffer == NULL ? 0 : CVPixelBufferGetPixelFormatType(pixelBuffer);
    size_t width = pixelBuffer == NULL ? 0 : CVPixelBufferGetWidth(pixelBuffer);
    size_t height = pixelBuffer == NULL ? 0 : CVPixelBufferGetHeight(pixelBuffer);
    NSString *basicSignature = [NSString stringWithFormat:@"%zu/%zu/%u/%u/%d/%d",
        width, height, pixelFormat, subtype,
        CMSampleBufferGetDataBuffer(sampleBuffer) != NULL,
        replacementRoute != VCAMReplacementRouteNone];
    if (VCAMBasicOutputSignatureWasSeen(output, basicSignature)) return;

    id node = VCAMSafeObjectResult(output, sel_registerName("node"));
    NSString *outputClass = NSStringFromClass([output class]) ?: @"(none)";
    NSString *nodeClass = node == nil ? @"(none)" :
        (NSStringFromClass([node class]) ?: @"(none)");
    NSString *outputName = VCAMSafeStringValue(
        VCAMSafeObjectResult(output, sel_registerName("name")));
    NSString *nodeName = VCAMSafeStringValue(
        VCAMSafeObjectResult(node, sel_registerName("name")));
    NSString *key = [NSString stringWithFormat:@"%@/%@/%@/%@/%@",
        outputClass, nodeClass, outputName, nodeName, basicSignature];
    static NSMutableSet<NSString *> *signatures;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ signatures = [NSMutableSet set]; });
    BOOL shouldLog = NO;
    @synchronized (signatures) {
        if (signatures.count < 96 && ![signatures containsObject:key]) {
            [signatures addObject:key];
            shouldLog = YES;
        }
    }
    if (!shouldLog) return;

    char pixelFourCC[5] = {0};
    char subtypeFourCC[5] = {0};
    VCAMFourCCString(pixelFormat, pixelFourCC);
    VCAMFourCCString(subtype, subtypeFourCC);
    char message[700] = {0};
    snprintf(message, sizeof(message),
             "output signature output=%p outputClass=%s outputName=%s node=%p nodeClass=%s nodeName=%s size=%zux%zu pixel=%s/%08x subtype=%s/%08x planes=%zu data=%d supported=%d allowed=%d route=%s",
             output, outputClass.UTF8String, outputName.UTF8String, node,
             nodeClass.UTF8String, nodeName.UTF8String,
             width, height, pixelFourCC, pixelFormat, subtypeFourCC, subtype,
             pixelBuffer == NULL ? 0 : CVPixelBufferGetPlaneCount(pixelBuffer),
             CMSampleBufferGetDataBuffer(sampleBuffer) != NULL,
             VCAMTargetBufferIsSupported(pixelBuffer),
             replacementRoute != VCAMReplacementRouteNone,
             VCAMReplacementRouteName(replacementRoute));
    VCAMRefLog(message);
}

%hook BWNodeOutput

- (void)emitSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (sampleBuffer == NULL) {
        %orig(sampleBuffer);
        return;
    }
    unsigned int mediaType = ((unsigned int (*)(id, SEL))objc_msgSend)(self, sel_registerName("mediaType"));
    if (mediaType != 'vide') {
        static volatile int otherSamples = 0;
        int otherSampleCount = __sync_add_and_fetch(&otherSamples, 1);
        if (otherSampleCount <= 3) {
            char msg[128] = {0};
            snprintf(msg, sizeof(msg), "emitSampleBuffer non-video mediaType=%08x count=%d",
                     mediaType, otherSampleCount);
            VCAMRefLog(msg);
        }
        %orig(sampleBuffer);
        return;
    }

    // Usually completed by the constructor warm-up. dispatch_once inside the
    // renderer makes this a no-op; an unusually early first frame waits for the
    // same initialization instead of racing a partially published context.
    loadReplacementMedia();

    CVPixelBufferRef originalImageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    VCAMReplacementRoute replacementRoute =
        VCAMReplacementRouteForOutput(self, originalImageBuffer);
    BOOL replacementAllowed = replacementRoute != VCAMReplacementRouteNone;
    VCAMLogOutputSignature(self, sampleBuffer, originalImageBuffer, replacementRoute);
    if (originalImageBuffer == NULL &&
        VCAMOutputIsCameraVideoCompressor(self) &&
        VCAMSampleContainsEncodedCameraVideo(sampleBuffer) &&
        VCAMVirtualModeIsEnabled()) {
        if (!VCAMEncodedRecordingSampleCanPass(sampleBuffer)) {
            static volatile int guardedEncodedSamples = 0;
            int guardedCount = __sync_add_and_fetch(&guardedEncodedSamples, 1);
            if (guardedCount <= 8 || guardedCount % 300 == 0) {
                char message[176] = {0};
                snprintf(message, sizeof(message),
                         "guarding encoded recording sample count=%d reason=missing-or-failed-virtual-frame",
                         guardedCount);
                VCAMRefLog(message);
            }
            return;
        }
        %orig(sampleBuffer);
        return;
    }
    if (originalImageBuffer == NULL) {
        static volatile int nullBuffers = 0;
        int nullBufferCount = __sync_add_and_fetch(&nullBuffers, 1);
        if (nullBufferCount <= 3) VCAMRefLog("emitSampleBuffer video buffer NULL");
        if (replacementAllowed && VCAMVirtualModeIsEnabled()) {
            VCAMRefLog("suppressing routed sample with NULL image buffer");
            return;
        }
        %orig(sampleBuffer);
        return;
    }
    if (!replacementAllowed) {
        %orig(sampleBuffer);
        return;
    }

    BOOL propagatedReplacement =
        VCAMRouteUsesPropagationMarker(replacementRoute) &&
        VCAMSampleHasMatchingPropagationMarker(sampleBuffer, originalImageBuffer);
    if (propagatedReplacement) {
        if (replacementRoute == VCAMReplacementRouteVideoRecording) {
            VCAMRecordRecordingFrameOutcome(self, sampleBuffer,
                                            originalImageBuffer, YES);
        }
        static volatile int propagatedSamples = 0;
        int propagatedCount = __sync_add_and_fetch(&propagatedSamples, 1);
        if (propagatedCount <= 8 || propagatedCount % 300 == 0) {
            char message[176] = {0};
            snprintf(message, sizeof(message),
                     "passing propagated virtual frame count=%d route=%s",
                     propagatedCount, VCAMReplacementRouteName(replacementRoute));
            VCAMRefLog(message);
        }
        %orig(sampleBuffer);
        return;
    }

    static volatile int videoSamples = 0;
    int videoSampleCount = __sync_add_and_fetch(&videoSamples, 1);
    if (videoSampleCount <= 8 || videoSampleCount % 300 == 0) {
        char msg[256] = {0};
        char format[5] = {0};
        OSType pixelFormat = CVPixelBufferGetPixelFormatType(originalImageBuffer);
        VCAMFourCCString(pixelFormat, format);
        snprintf(msg, sizeof(msg), "emitSampleBuffer video count=%d size=%zux%zu format=%s/%08x route=%s",
                 videoSampleCount, CVPixelBufferGetWidth(originalImageBuffer),
                 CVPixelBufferGetHeight(originalImageBuffer), format, pixelFormat,
                 VCAMReplacementRouteName(replacementRoute));
        VCAMRefLog(msg);
    }

    CVPixelBufferRef replacementImageBuffer = NULL;
    CMSampleBufferRef replacementSampleBuffer = NULL;
    BOOL replacementSucceeded = NO;
    @autoreleasepool {
        @try {
            replacementSucceeded = drawReplacementOntoBuffer(
                originalImageBuffer,
                replacementRoute != VCAMReplacementRouteStillPhoto,
                &replacementImageBuffer);
            if (replacementSucceeded && replacementImageBuffer != NULL) {
                replacementSampleBuffer = VCAMCreateSampleBufferWithReplacementImage(
                    sampleBuffer, replacementImageBuffer);
                replacementSucceeded = replacementSampleBuffer != NULL;
            }
            if (replacementSucceeded &&
                replacementRoute == VCAMReplacementRouteCameraSourceVideo) {
                replacementSucceeded = VCAMWritePropagationMarker(
                    replacementSampleBuffer, replacementImageBuffer);
            }
        } @catch (NSException *exception) {
            static dispatch_once_t exceptionToken;
            dispatch_once(&exceptionToken, ^{
                VCAMRefLog([NSString stringWithFormat:@"replacement render exception %@",
                    exception.name].UTF8String);
            });
            replacementSucceeded = NO;
        }
    }

    if (replacementRoute == VCAMReplacementRouteVideoRecording) {
        VCAMRecordRecordingFrameOutcome(self, sampleBuffer, originalImageBuffer,
                                        replacementSucceeded);
    }

    BOOL virtualModeEnabled = VCAMVirtualModeIsEnabled();
    if (!replacementSucceeded && virtualModeEnabled) {
        static volatile int suppressedSamples = 0;
        int suppressedCount = __sync_add_and_fetch(&suppressedSamples, 1);
        if (suppressedCount <= 8 || suppressedCount % 300 == 0) {
            char message[224] = {0};
            const char *reason = replacementRoute == VCAMReplacementRouteVideoRecording
                ? "no-safe-compressed-virtual-fallback"
                : "replacement-failed";
            snprintf(message, sizeof(message),
                     "suppressing real sample after replacement failure count=%d route=%s reason=%s",
                     suppressedCount, VCAMReplacementRouteName(replacementRoute), reason);
            VCAMRefLog(message);
        }
        if (replacementSampleBuffer != NULL) CFRelease(replacementSampleBuffer);
        if (replacementImageBuffer != NULL) CVPixelBufferRelease(replacementImageBuffer);
        return;
    }

    if (replacementSucceeded && replacementSampleBuffer != NULL) {
        static volatile int emittedCompressedSamples = 0;
        int emittedCount = __sync_add_and_fetch(&emittedCompressedSamples, 1);
        if (emittedCount <= 4) {
            char message[176] = {0};
            snprintf(message, sizeof(message),
                     "emitting compressed replacement sample count=%d route=%s",
                     emittedCount, VCAMReplacementRouteName(replacementRoute));
            VCAMRefLog(message);
        }
        %orig(replacementSampleBuffer);
        CFRelease(replacementSampleBuffer);
        CVPixelBufferRelease(replacementImageBuffer);
        return;
    }
    if (replacementSampleBuffer != NULL) CFRelease(replacementSampleBuffer);
    if (replacementImageBuffer != NULL) CVPixelBufferRelease(replacementImageBuffer);

    %orig(sampleBuffer);
}

%end

%ctor {
    VCAMRefLog("ctor: VCAMMediaServerRefEntry loaded");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            loadReplacementMedia();
            VCAMRefLog("ctor: replacement renderer initialized");
        }
    });
}

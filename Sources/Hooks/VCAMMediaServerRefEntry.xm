#import "VCAMMediaServerRefImageUtils.h"
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <stdio.h>
#include <string.h>

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

static void VCAMSetStillPhotoDisplayOrientation(
    CMSampleBufferRef sampleBuffer,
    CVPixelBufferRef imageBuffer,
    BOOL requiresRightOrientation) {
    if (!requiresRightOrientation) return;
    NSNumber *orientation = @(kCGImagePropertyOrientationRight);
    if (sampleBuffer != NULL) {
        CMSetAttachment(sampleBuffer, kCGImagePropertyOrientation,
                        (__bridge CFTypeRef)orientation,
                        kCMAttachmentMode_ShouldPropagate);
    }
    if (imageBuffer != NULL) {
        CVBufferSetAttachment(imageBuffer, kCGImagePropertyOrientation,
                              (__bridge CFTypeRef)orientation,
                              kCVAttachmentMode_ShouldPropagate);
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
    CVPixelBufferRef replacementImageBuffer,
    BOOL allowPrivateCameraFormatFallback) {
    if (originalSampleBuffer == NULL || replacementImageBuffer == NULL) return NULL;
    CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(
        originalSampleBuffer);
    if (format == NULL) return NULL;
    CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(format);
    OSType sourceSubtype = CMFormatDescriptionGetMediaSubType(format);
    if (dimensions.width != (int32_t)CVPixelBufferGetWidth(replacementImageBuffer) ||
        dimensions.height != (int32_t)CVPixelBufferGetHeight(replacementImageBuffer) ||
        sourceSubtype !=
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
    OSStatus derivedFormatStatus = noErr;
    BOOL attemptedDerivedFormat = NO;
    BOOL derivedFormatMatchesSource = NO;
    BOOL privateCompressedCameraFormat =
        sourceSubtype == (OSType)0x5b387630 || // observed '[8v0'
        sourceSubtype == (OSType)0x7d387630 || // observed '}8v0'
        sourceSubtype == (OSType)0x26786630 || // iOS 16.1 StillImage '&xf0'
        sourceSubtype == (OSType)0x26787630 || // SDK '&xv0' lossless 10-bit
        sourceSubtype == (OSType)0x2d787630;   // SDK '-xv0' lossy 10-bit
    if (allowPrivateCameraFormatFallback && privateCompressedCameraFormat &&
        createStatus == kCMSampleBufferError_InvalidMediaFormat) {
        // Some private camera formats carry format-description extensions
        // that do not match an otherwise compatible clone created from the
        // source buffer's own pixel attributes. Derive the retry description
        // from the replacement image itself so CoreMedia sees the exact
        // attachment contract it validates. The original sample timing and
        // sample-level attachments are still copied below.
        attemptedDerivedFormat = YES;
        if (replacementSampleBuffer != NULL) {
            CFRelease(replacementSampleBuffer);
            replacementSampleBuffer = NULL;
        }
        CMVideoFormatDescriptionRef derivedFormat = NULL;
        derivedFormatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            kCFAllocatorDefault, replacementImageBuffer, &derivedFormat);
        if (derivedFormatStatus == noErr && derivedFormat != NULL) {
            CMVideoDimensions derivedDimensions =
                CMVideoFormatDescriptionGetDimensions(derivedFormat);
            derivedFormatMatchesSource =
                derivedDimensions.width == dimensions.width &&
                derivedDimensions.height == dimensions.height &&
                CMFormatDescriptionGetMediaSubType(derivedFormat) ==
                    sourceSubtype;
            if (derivedFormatMatchesSource) {
                createStatus = CMSampleBufferCreateReadyWithImageBuffer(
                    kCFAllocatorDefault, replacementImageBuffer, derivedFormat,
                    &timing, &replacementSampleBuffer);
            }
        }
        if (derivedFormat != NULL) {
            CFRelease(derivedFormat);
        }
    }
    if (createStatus != noErr || replacementSampleBuffer == NULL) {
        if (replacementSampleBuffer != NULL) {
            CFRelease(replacementSampleBuffer);
            replacementSampleBuffer = NULL;
        }
        static volatile int creationFailures = 0;
        int failureCount = __sync_add_and_fetch(&creationFailures, 1);
        if (failureCount <= 8 || failureCount % 300 == 0) {
            char message[256] = {0};
            snprintf(message, sizeof(message),
                     "compressed replacement sample creation failed count=%d status=%d derivedAttempt=%d derivedStatus=%d derivedMatch=%d",
                     failureCount, (int)createStatus, attemptedDerivedFormat,
                     (int)derivedFormatStatus, derivedFormatMatchesSource);
            VCAMRefLog(message);
        }
        return NULL;
    }
    if (attemptedDerivedFormat) {
        static volatile int derivedFormatRecoveries = 0;
        int recoveryCount = __sync_add_and_fetch(&derivedFormatRecoveries, 1);
        if (recoveryCount <= 8 || recoveryCount % 300 == 0) {
            char message[160] = {0};
            snprintf(message, sizeof(message),
                     "compressed replacement sample used derived format count=%d",
                     recoveryCount);
            VCAMRefLog(message);
        }
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
    // WebKit's terminal converter must redraw from the canonical shared frame.
    // Passing the upstream marker would preserve pixels that already traversed
    // the camera source's private compressed buffer.
    return route == VCAMReplacementRouteCameraPreview ||
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

static void VCAMClearPropagationMarker(CMSampleBufferRef sampleBuffer,
                                       CVPixelBufferRef imageBuffer) {
    if (sampleBuffer != NULL) {
        CMRemoveAttachment(sampleBuffer, VCAMPropagationMarkerKey);
    }
    if (imageBuffer != NULL) {
        CVBufferRemoveAttachment(imageBuffer, VCAMPropagationMarkerKey);
    }
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

    // Do not inject canonical shared pixels into the raw VideoCapture sensor
    // branch. Camera preview and WebKit apply different physical-camera
    // transforms after this node; replacing here rotated an already-oriented
    // Photos/RTSP frame a second time. The exact terminal routes below are the
    // fail-closed app boundaries and render the canonical pixels directly.
    // iOS 16 emits the raw still source as private pf20 on the target device.
    // That surface cannot be rendered safely, and suppressing it prevents the
    // verified downstream 420f Meteor Headroom stage from producing a photo.
    // Pass unsupported private source frames only inside the media graph; the
    // downstream still-photo route remains the fail-closed app boundary.
    if (VCAMStringMatches(nodeClass, @"BWMultiStreamCameraSourceNode") &&
        VCAMStringMatches(outputName, @"StillImage") &&
        VCAMTargetBufferIsSupported(pixelBuffer)) {
        return VCAMReplacementRouteStillPhoto;
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
        if (VCAMStringMatches(nodeName, @"Video Data Converter/Rotator/Zoomer")) {
            return VCAMReplacementRouteVideoConverter;
        }
        if (VCAMStringMatches(nodeName, @"Video Data Converter/Zoomer")) {
            return VCAMReplacementRouteVideoConverter;
        }
        if (VCAMStringMatches(nodeName, @"Preview Scaler")) {
            return VCAMReplacementRouteCameraPreview;
        }
        if (VCAMStringMatches(nodeName, @"Movie File Zoomer")) {
            return VCAMReplacementRouteVideoRecording;
        }
    }

    // iOS 16.1 routes movie frames through this exact 420f governor even when
    // the older Movie File Zoomer terminal is absent. Treat it as the same
    // fail-closed recording boundary so the system encoder receives the
    // virtual raw frame instead of suppressing the entire recording.
    if (VCAMStringMatches(nodeClass, @"BWFrameRateGovernorNode") &&
        VCAMStringMatches(nodeName, @"Movie File Frame Rate Governor")) {
        return VCAMReplacementRouteVideoRecording;
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
        // Keep enough one-shot signatures to include photo and movie graphs,
        // which are created after the initial preview graph on iOS 16.1.
        if (signatures.count < 384 && ![signatures containsObject:key]) {
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

// BWRemoteQueueSinkNode consumes frames for remote VideoDataOutput clients and
// therefore has no BWNodeOutput of its own for the graph probe below to see.
// Keep this hook diagnostic-only until device traces prove its exact coverage;
// preview, still-photo, recording and SmartCam consumers use other pipelines.
%hook BWRemoteQueueSinkNode

- (void)renderSampleBuffer:(CMSampleBufferRef)sampleBuffer forInput:(id)input {
    CMFormatDescriptionRef description = sampleBuffer == NULL ? NULL
        : CMSampleBufferGetFormatDescription(sampleBuffer);
    CMMediaType mediaType = description == NULL ? 0
        : CMFormatDescriptionGetMediaType(description);
    if (mediaType == kCMMediaType_Video) {
        static volatile int remoteVideoSamples = 0;
        int sampleCount = __sync_add_and_fetch(&remoteVideoSamples, 1);
        if (sampleCount <= 12 || sampleCount % 300 == 0) {
            CVPixelBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
            OSType subtype = CMFormatDescriptionGetMediaSubType(description);
            OSType pixelFormat = imageBuffer == NULL ? 0
                : CVPixelBufferGetPixelFormatType(imageBuffer);
            size_t width = imageBuffer == NULL ? 0 : CVPixelBufferGetWidth(imageBuffer);
            size_t height = imageBuffer == NULL ? 0 : CVPixelBufferGetHeight(imageBuffer);
            NSString *inputClass = input == nil ? @"(none)"
                : (NSStringFromClass([input class]) ?: @"(none)");
            NSString *inputName = VCAMSafeStringValue(
                VCAMSafeObjectResult(input, sel_registerName("name")));
            BOOL marked = VCAMSampleHasMatchingPropagationMarker(sampleBuffer, imageBuffer);
            char subtypeFourCC[5] = {0};
            char pixelFourCC[5] = {0};
            VCAMFourCCString(subtype, subtypeFourCC);
            VCAMFourCCString(pixelFormat, pixelFourCC);
            char message[420] = {0};
            snprintf(message, sizeof(message),
                     "remote queue sink diagnostic video count=%d inputClass=%s inputName=%s size=%zux%zu pixel=%s/%08x subtype=%s/%08x marked=%d",
                     sampleCount, inputClass.UTF8String, inputName.UTF8String,
                     width, height, pixelFourCC, pixelFormat,
                     subtypeFourCC, subtype, marked);
            VCAMRefLog(message);
        }
    } else if (sampleBuffer != NULL) {
        static volatile int remoteNonVideoSamples = 0;
        int sampleCount = __sync_add_and_fetch(&remoteNonVideoSamples, 1);
        if (sampleCount <= 4) {
            char message[160] = {0};
            snprintf(message, sizeof(message),
                     "remote queue sink diagnostic non-video count=%d mediaType=%08x",
                     sampleCount, (unsigned int)mediaType);
            VCAMRefLog(message);
        }
    }
    %orig(sampleBuffer, input);
}

%end

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
    BOOL stillPhotoRequiresRightOrientation = NO;
    BOOL replacementSucceeded = NO;
    @autoreleasepool {
        @try {
            replacementSucceeded = drawReplacementOntoBuffer(
                originalImageBuffer,
                replacementRoute != VCAMReplacementRouteStillPhoto,
                replacementRoute == VCAMReplacementRouteCameraPreview,
                replacementRoute == VCAMReplacementRouteVideoConverter,
                &replacementImageBuffer,
                replacementRoute == VCAMReplacementRouteStillPhoto
                    ? &stillPhotoRequiresRightOrientation : NULL);
            if (replacementSucceeded && replacementImageBuffer != NULL) {
                replacementSampleBuffer = VCAMCreateSampleBufferWithReplacementImage(
                    sampleBuffer, replacementImageBuffer,
                    replacementRoute == VCAMReplacementRouteCameraSourceVideo ||
                    replacementRoute == VCAMReplacementRouteStillPhoto);
                replacementSucceeded = replacementSampleBuffer != NULL;
            }
            if (replacementSucceeded &&
                replacementRoute == VCAMReplacementRouteStillPhoto) {
                CMSampleBufferRef finalSample = replacementSampleBuffer != NULL
                    ? replacementSampleBuffer : sampleBuffer;
                CVPixelBufferRef finalImage = replacementImageBuffer != NULL
                    ? replacementImageBuffer : originalImageBuffer;
                VCAMSetStillPhotoDisplayOrientation(
                    finalSample, finalImage,
                    stillPhotoRequiresRightOrientation);
            }
            if (replacementSucceeded &&
                replacementRoute == VCAMReplacementRouteVideoConverter) {
                VCAMClearPropagationMarker(
                    replacementSampleBuffer != NULL ? replacementSampleBuffer : sampleBuffer,
                    replacementImageBuffer != NULL ? replacementImageBuffer : originalImageBuffer);
            }
            if (replacementSucceeded &&
                replacementRoute == VCAMReplacementRouteCameraSourceVideo) {
                // Standard 420f source buffers are rendered in place, so the
                // renderer intentionally leaves replacementImageBuffer NULL.
                // Mark that original sample/image pair after its pixels have
                // been replaced. Private compressed source formats instead
                // use the separately allocated replacement pair.
                CMSampleBufferRef markerSampleBuffer = replacementSampleBuffer != NULL
                    ? replacementSampleBuffer : sampleBuffer;
                CVPixelBufferRef markerImageBuffer = replacementImageBuffer != NULL
                    ? replacementImageBuffer : originalImageBuffer;
                replacementSucceeded = VCAMWritePropagationMarker(
                    markerSampleBuffer, markerImageBuffer);
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

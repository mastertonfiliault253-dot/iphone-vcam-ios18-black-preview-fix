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
    VCAMReplacementRouteLegacyPreview,
    VCAMReplacementRouteVideoConverter,
    VCAMReplacementRouteCameraPreview,
    VCAMReplacementRouteVideoRecording,
    VCAMReplacementRouteGenericPixelTransfer,
    VCAMReplacementRouteStillPhoto,
};

static const char *VCAMReplacementRouteName(VCAMReplacementRoute route) {
    switch (route) {
        case VCAMReplacementRouteLegacyPreview: return "legacy-preview";
        case VCAMReplacementRouteVideoConverter: return "video-converter";
        case VCAMReplacementRouteCameraPreview: return "camera-preview";
        case VCAMReplacementRouteVideoRecording: return "video-recording";
        case VCAMReplacementRouteGenericPixelTransfer: return "generic-pixel-transfer";
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

static VCAMReplacementRoute VCAMReplacementRouteForOutput(id output,
                                                            CVPixelBufferRef pixelBuffer) {
    id node = VCAMSafeObjectResult(output, sel_registerName("node"));
    NSString *nodeClass = node == nil ? nil : NSStringFromClass([node class]);
    NSString *nodeName = VCAMSafeObjectResult(node, sel_registerName("name"));
    BOOL targetSupported = VCAMTargetBufferIsSupported(pixelBuffer);
    OSType pixelFormat = pixelBuffer == NULL ? 0 :
        CVPixelBufferGetPixelFormatType(pixelBuffer);
    size_t width = pixelBuffer == NULL ? 0 : CVPixelBufferGetWidth(pixelBuffer);
    size_t height = pixelBuffer == NULL ? 0 : CVPixelBufferGetHeight(pixelBuffer);

    // These are the terminal conversion roles observed for Safari getUserMedia
    // and the stock Camera preview. They are deliberately independent of the
    // physical camera node name. A known terminal role remains selected even
    // for a future unsupported pixel format so enabled mode drops that sample
    // instead of leaking a real frame. Other supported pixel-transfer nodes
    // cover public AVFoundation consumers whose private role name differs.
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
        if (targetSupported) return VCAMReplacementRouteGenericPixelTransfer;
    }

    // Stock Camera still capture reaches this last standard 8-bit pixel stage
    // immediately before the photo encoder. Match the role rather than a lens
    // name, resolution or pixel format. Unsupported future formats fail closed
    // in the hook rather than reaching the encoder as a real frame.
    if (VCAMStringMatches(nodeClass, @"BWMeteorHeadroomNode") &&
        VCAMStringMatches(nodeName, @"Meteor Headroom") && pixelBuffer != NULL) {
        return VCAMReplacementRouteStillPhoto;
    }

    // Retain the original device-proven BGRA path for clients which still ask
    // for this exact shape.
    if (targetSupported && pixelFormat == kCVPixelFormatType_32BGRA &&
        width == 750 && height == 1334) {
        return VCAMReplacementRouteLegacyPreview;
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
    if (originalImageBuffer == NULL) {
        static volatile int nullBuffers = 0;
        int nullBufferCount = __sync_add_and_fetch(&nullBuffers, 1);
        if (nullBufferCount <= 3) VCAMRefLog("emitSampleBuffer video buffer NULL");
        %orig(sampleBuffer);
        return;
    }
    if (!replacementAllowed) {
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

    @autoreleasepool {
        @try {
            BOOL replacementSucceeded = drawReplacementOntoBuffer(
                originalImageBuffer,
                replacementRoute != VCAMReplacementRouteStillPhoto);
            if (!replacementSucceeded && VCAMVirtualModeIsEnabled()) {
                static volatile int suppressedSamples = 0;
                int suppressedCount = __sync_add_and_fetch(&suppressedSamples, 1);
                if (suppressedCount <= 8 || suppressedCount % 300 == 0) {
                    char message[192] = {0};
                    snprintf(message, sizeof(message),
                             "suppressing real sample after replacement failure count=%d route=%s",
                             suppressedCount, VCAMReplacementRouteName(replacementRoute));
                    VCAMRefLog(message);
                }
                return;
            }
        } @catch (NSException *exception) {
            static dispatch_once_t exceptionToken;
            dispatch_once(&exceptionToken, ^{
                VCAMRefLog([NSString stringWithFormat:@"replacement render exception %@",
                    exception.name].UTF8String);
            });
            if (VCAMVirtualModeIsEnabled()) return;
        }
    }

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

#import "VCAMMediaServerRefImageUtils.h"
#import "../Shared/VCAMProcessIdentity.h"
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <notify.h>
#include <unistd.h>

static char g_lastOutputSignature[768] = {0};
static int g_sigaddrToken = -1;

// iPhoneOS 16.5 SDK exposes IOSurface-backed CVPixelBuffers through
// CoreVideo, but does not ship the private IOSurface header. Keep the small
// byte-surface ABI local, as the shared-surface implementation does.
extern size_t IOSurfaceGetAllocSize(IOSurfaceRef surface);
extern int32_t IOSurfaceLock(IOSurfaceRef surface, uint32_t options,
                             uint32_t *seed);
extern int32_t IOSurfaceUnlock(IOSurfaceRef surface, uint32_t options,
                               uint32_t *seed);
extern void *IOSurfaceGetBaseAddress(IOSurfaceRef surface);

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
    // Fallback for every other video output. This keeps the replacement at
    // the cameracaptured boundary even when a future app creates a graph
    // terminal whose private node/name is not in the route table.
    VCAMReplacementRouteUniversalVideo,
    VCAMReplacementRouteCameraSourceVideo,
    VCAMReplacementRouteVideoConverter,
    VCAMReplacementRouteCameraPreview,
    VCAMReplacementRouteVideoRecording,
    VCAMReplacementRouteStillPhoto,
    // SumUp's BWPhotoEncoderNode is an app-specific terminal. It is not the
    // stock Camera still branch, so keep its still-basis transform scoped to
    // this node instead of reopening the historically unsafe raw-camera route.
    VCAMReplacementRoutePhotoEncoder,
};

// cameracaptured cannot reliably write the normal process log locations.
// Publish bounded scalar state instead so a root listener can prove that the
// production dylib loaded in this exact PID and which graph entry receives
// samples, without reading target memory or trusting injector exit status.
typedef NS_ENUM(uint64_t, VCAMRuntimeSampleKind) {
    VCAMRuntimeSampleKindNone = 0,
    VCAMRuntimeSampleKindOutput = 1,
    VCAMRuntimeSampleKindRemoteQueue = 2,
    VCAMRuntimeSampleKindPhotoEncoder = 3,
};

static int g_runtimeCtorToken = -1;
static int g_runtimePIDToken = -1;
static int g_runtimeStartToken = -1;
static int g_runtimeOutputCountToken = -1;
static int g_runtimeRemoteCountToken = -1;
static int g_runtimePhotoCountToken = -1;
static int g_runtimeReplacementCountToken = -1;
static int g_runtimeReplacementRouteToken = -1;
static int g_runtimeLastKindToken = -1;
static int g_runtimeLastCountToken = -1;
static int g_runtimeLastDimensionsToken = -1;
static int g_runtimeLastFormatToken = -1;

static void VCAMRuntimeSetState(int *token, const char *name,
                                uint64_t value) {
    if (*token < 0) {
        notify_register_check(name, token);
    }
    if (*token >= 0) notify_set_state(*token, value);
}

static void VCAMRuntimePublishSample(VCAMRuntimeSampleKind kind,
                                     uint64_t count,
                                     CMSampleBufferRef sampleBuffer) {
    if (count > 8 && count % 30 != 0) return;
    CVPixelBufferRef imageBuffer = sampleBuffer == NULL
        ? NULL : CMSampleBufferGetImageBuffer(sampleBuffer);
    size_t width = imageBuffer == NULL ? 0 : CVPixelBufferGetWidth(imageBuffer);
    size_t height = imageBuffer == NULL ? 0 : CVPixelBufferGetHeight(imageBuffer);
    OSType format = imageBuffer == NULL
        ? 0 : CVPixelBufferGetPixelFormatType(imageBuffer);
    VCAMRuntimeSetState(&g_runtimeLastKindToken,
                        "com.codex.vcam.ios18.production.last-kind.state", kind);
    VCAMRuntimeSetState(&g_runtimeLastCountToken,
                        "com.codex.vcam.ios18.production.last-count.state", count);
    VCAMRuntimeSetState(&g_runtimeLastDimensionsToken,
                        "com.codex.vcam.ios18.production.last-dimensions.state",
                        ((uint64_t)(uint32_t)width << 32) |
                        (uint64_t)(uint32_t)height);
    VCAMRuntimeSetState(&g_runtimeLastFormatToken,
                        "com.codex.vcam.ios18.production.last-format.state",
                        (uint64_t)format);
    notify_post("com.codex.vcam.ios18.production.sample");
}

static void VCAMRuntimePublishConstructor(void) {
    VCAMRuntimeSetState(&g_runtimeCtorToken,
                        "com.codex.vcam.ios18.production.ctor.state", 1);
    VCAMRuntimeSetState(&g_runtimePIDToken,
                        "com.codex.vcam.ios18.production.pid.state",
                        (uint64_t)(uint32_t)getpid());
    VCAMRuntimeSetState(&g_runtimeStartToken,
                        "com.codex.vcam.ios18.production.start.state",
                        VCAMProcessStartToken(getpid()));
    VCAMRuntimeSetState(&g_runtimeOutputCountToken,
                        "com.codex.vcam.ios18.production.output-count.state", 0);
    VCAMRuntimeSetState(&g_runtimeRemoteCountToken,
                        "com.codex.vcam.ios18.production.remote-count.state", 0);
    VCAMRuntimeSetState(&g_runtimePhotoCountToken,
                        "com.codex.vcam.ios18.production.photo-count.state", 0);
    VCAMRuntimeSetState(&g_runtimeReplacementCountToken,
                        "com.codex.vcam.ios18.production.replacement-count.state", 0);
    VCAMRuntimeSetState(&g_runtimeReplacementRouteToken,
                        "com.codex.vcam.ios18.production.replacement-route.state", 0);
    notify_post("com.codex.vcam.ios18.production.loaded");
}

static void VCAMRuntimePublishReplacement(VCAMReplacementRoute route) {
    static uint64_t replacementCount = 0;
    uint64_t count = __sync_add_and_fetch(&replacementCount, 1);
    VCAMRuntimeSetState(&g_runtimeReplacementCountToken,
                        "com.codex.vcam.ios18.production.replacement-count.state",
                        count);
    VCAMRuntimeSetState(&g_runtimeReplacementRouteToken,
                        "com.codex.vcam.ios18.production.replacement-route.state",
                        (uint64_t)route);
    notify_post("com.codex.vcam.ios18.production.replacement");
}

static const char *VCAMReplacementRouteName(VCAMReplacementRoute route) {
    switch (route) {
        case VCAMReplacementRouteUniversalVideo: return "universal-video";
        case VCAMReplacementRouteCameraSourceVideo: return "camera-source-video";
        case VCAMReplacementRouteVideoConverter: return "video-converter";
        case VCAMReplacementRouteCameraPreview: return "camera-preview";
        case VCAMReplacementRouteVideoRecording: return "video-recording";
        case VCAMReplacementRouteStillPhoto: return "still-photo";
        case VCAMReplacementRoutePhotoEncoder: return "photo-encoder";
        case VCAMReplacementRouteNone: return "none";
    }
    return "none";
}

static VCAMFramePresentation VCAMPresentationForReplacementRoute(
    VCAMReplacementRoute route) {
    switch (route) {
        case VCAMReplacementRouteUniversalVideo:
            return VCAMFramePresentationRealtimeFill;
        case VCAMReplacementRouteVideoConverter:
            return VCAMFramePresentationWebKitFill;
        case VCAMReplacementRouteCameraPreview:
            return VCAMFramePresentationCameraPreviewFit;
        case VCAMReplacementRouteStillPhoto:
        case VCAMReplacementRoutePhotoEncoder:
            return VCAMFramePresentationStillPhotoFill;
        case VCAMReplacementRouteCameraSourceVideo:
        case VCAMReplacementRouteVideoRecording:
        case VCAMReplacementRouteNone:
            return VCAMFramePresentationRealtimeFill;
    }
    return VCAMFramePresentationRealtimeFill;
}

static BOOL VCAMStringMatches(NSString *value, NSString *expected) {
    return [value isKindOfClass:NSString.class] &&
        [expected isKindOfClass:NSString.class] &&
        [value isEqualToString:expected];
}

// SumUp's still callback reaches the private camera graph through more than
// one sink on iOS 16.1. Keep this probe read-only: method names identify the
// actual terminal without changing the fail-closed replacement policy.
static void VCAMLogRuntimeMethodsOnce(Class klass, NSString *tag) {
    if (klass == Nil || tag.length == 0) return;
    static NSMutableSet<NSString *> *loggedClasses;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ loggedClasses = [NSMutableSet set]; });
    NSString *classKey = [NSString stringWithFormat:@"%@/%@",
        tag, NSStringFromClass(klass) ?: @"(none)"];
    @synchronized (loggedClasses) {
        if ([loggedClasses containsObject:classKey]) return;
        [loggedClasses addObject:classKey];
    }
    unsigned int count = 0;
    Method *methods = class_copyMethodList(klass, &count);
    for (unsigned int index = 0; index < count; index++) {
        SEL selector = method_getName(methods[index]);
        const char *name = selector == NULL ? "(none)" : sel_getName(selector);
        char message[320] = {0};
        snprintf(message, sizeof(message),
                 "runtime methods tag=%s class=%s selector=%s types=%s",
                 tag.UTF8String, NSStringFromClass(klass).UTF8String, name,
                 method_getTypeEncoding(methods[index]));
        VCAMRefLog(message);
    }
    if (methods != NULL) free(methods);
}

// Bounded schema-only probe: never print attachment values or encoded data.
static void VCAMLogPhotoAttachmentKeys(CMSampleBufferRef sampleBuffer,
                                        const char *stage) {
    if (sampleBuffer == NULL) return;
    CVPixelBufferRef image = CMSampleBufferGetImageBuffer(sampleBuffer);
    const CMAttachmentMode modes[] = {
        kCMAttachmentMode_ShouldPropagate, kCMAttachmentMode_ShouldNotPropagate
    };
    const CVAttachmentMode imageModes[] = {
        kCVAttachmentMode_ShouldPropagate, kCVAttachmentMode_ShouldNotPropagate
    };
    NSUInteger logged = 0;
    for (NSUInteger bearer = 0; bearer < 2; bearer++) {
        for (NSUInteger index = 0; index < 2; index++) {
            CFDictionaryRef dictionary = bearer == 0
                ? CMCopyDictionaryOfAttachments(kCFAllocatorDefault, sampleBuffer, modes[index])
                : (image == NULL ? NULL : CVBufferCopyAttachments(image, imageModes[index]));
            NSDictionary *attachments = CFBridgingRelease(dictionary);
            for (id key in attachments) {
                if (logged >= 64) return;
                if (![key isKindOfClass:NSString.class]) continue;
                char message[280] = {0};
                snprintf(message, sizeof(message),
                         "photo attachment key stage=%s bearer=%s mode=%u key=%.160s",
                         stage, bearer == 0 ? "sample" : "image",
                         (unsigned int)modes[index], [key UTF8String]);
                VCAMRefLog(message);
                logged += 1;
            }
        }
    }
}

static BOOL VCAMHasStillPhotoOrientation(
    CMSampleBufferRef sampleBuffer,
    CVPixelBufferRef imageBuffer) {
    CFTypeRef value = sampleBuffer == NULL ? NULL
        : CMGetAttachment(sampleBuffer, kCGImagePropertyOrientation, NULL);
    if (value == NULL && imageBuffer != NULL) {
        value = CVBufferGetAttachment(imageBuffer,
                                      kCGImagePropertyOrientation, NULL);
    }
    if (value == NULL || CFGetTypeID(value) != CFNumberGetTypeID()) return NO;
    int orientation = 0;
    if (!CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &orientation)) {
        return NO;
    }
    return orientation >= (int)kCGImagePropertyOrientationUp &&
        orientation <= (int)kCGImagePropertyOrientationLeftMirrored;
}

static void VCAMSetStillPhotoDisplayOrientationIfMissing(
    CMSampleBufferRef sampleBuffer,
    CVPixelBufferRef imageBuffer,
    BOOL requiresRightOrientation) {
    if (!requiresRightOrientation ||
        VCAMHasStillPhotoOrientation(sampleBuffer, imageBuffer)) return;
    VCAMSetStillPhotoDisplayOrientation(sampleBuffer, imageBuffer, YES);
}

// Shape-only probe for deferred-photo side channels. Never stringify or copy
// attachment values: the value may contain a private IOSurface or photo bytes.
static void VCAMLogPhotoAttachmentShapes(CMSampleBufferRef sampleBuffer,
                                          const char *stage) {
    if (sampleBuffer == NULL) return;
    CFDictionaryRef raw = CMCopyDictionaryOfAttachments(
        kCFAllocatorDefault, sampleBuffer, kCMAttachmentMode_ShouldPropagate);
    NSDictionary *attachments = CFBridgingRelease(raw);
    if (attachments == nil) return;
    NSArray<NSString *> *keys = @[
        @"AttachedMedia", @"PhotoManifest",
        @"DeferredPhotoProxyEncodedImageSurface",
        @"DeferredPhotoProxyEncodedImageSurfaceSize", @"EncodedImageSurface",
        @"PreviewSurface"
    ];
    for (NSString *key in keys) {
        id value = attachments[key];
        if (value == nil) continue;
        NSUInteger count = [value respondsToSelector:@selector(count)]
            ? [value count] : 0;
        NSUInteger nestedKeys = CFGetTypeID((__bridge CFTypeRef)value) ==
            CFDictionaryGetTypeID()
            ? CFDictionaryGetCount((__bridge CFDictionaryRef)value) : 0;
        NSString *className = NSStringFromClass([value class]) ?: @"(none)";
        char message[320] = {0};
        snprintf(message, sizeof(message),
                 "photo attachment shape stage=%s key=%s class=%s count=%lu nestedKeys=%lu cfType=%lu",
                 stage, key.UTF8String, className.UTF8String,
                 (unsigned long)count, (unsigned long)nestedKeys,
                 (unsigned long)CFGetTypeID((__bridge CFTypeRef)value));
        VCAMRefLog(message);
    }

    CFTypeRef attachedMedia = CFDictionaryGetValue(
        (__bridge CFDictionaryRef)attachments, CFSTR("AttachedMedia"));
    if (attachedMedia == NULL ||
        CFGetTypeID(attachedMedia) != CFDictionaryGetTypeID()) return;
    CFIndex entryCount = CFDictionaryGetCount(
        (CFDictionaryRef)attachedMedia);
    if (entryCount > 8) {
        char message[160] = {0};
        snprintf(message, sizeof(message),
                 "photo attached-media shape stage=%s entries=%ld truncated=1",
                 stage, (long)entryCount);
        VCAMRefLog(message);
        return;
    }
    const void *entryKeys[8] = {0};
    const void *entryValues[8] = {0};
    CFDictionaryGetKeysAndValues((CFDictionaryRef)attachedMedia,
                                 entryKeys, entryValues);
    for (CFIndex index = 0; index < entryCount; index++) {
        char keyName[128] = "(non-string)";
        if (entryKeys[index] != NULL &&
            CFGetTypeID(entryKeys[index]) == CFStringGetTypeID()) {
            CFStringGetCString((CFStringRef)entryKeys[index], keyName,
                               sizeof(keyName), kCFStringEncodingUTF8);
        }
        CFTypeID valueType = entryValues[index] == NULL
            ? 0 : CFGetTypeID(entryValues[index]);
        char message[240] = {0};
        snprintf(message, sizeof(message),
                 "photo attached-media shape stage=%s key=%.120s valueType=%lu",
                 stage, keyName, (unsigned long)valueType);
        VCAMRefLog(message);
    }
}

// The real camera still branch carries a deferred HDR side channel alongside
// the image. Once Photos finishes its deferred pass it applies that GainMap to
// the encoded image, which is wrong for our already-rendered SDR replacement
// and causes the photo to change colour a few seconds after capture. Remove
// only the gain-map/headroom metadata; all unrelated capture metadata remains
// available to the app.
static void VCAMStripVirtualPhotoGainMap(CMSampleBufferRef sampleBuffer,
                                          CVPixelBufferRef imageBuffer) {
    static volatile int strippedCount = 0;
    BOOL stripped = NO;
    if (sampleBuffer != NULL) {
        CFTypeRef attachedMedia = CMGetAttachment(
            sampleBuffer, CFSTR("AttachedMedia"), NULL);
        if (attachedMedia != NULL &&
            CFGetTypeID(attachedMedia) == CFDictionaryGetTypeID()) {
            CFMutableDictionaryRef media = CFDictionaryCreateMutableCopy(
                kCFAllocatorDefault, 0, (CFDictionaryRef)attachedMedia);
            if (media != NULL &&
                CFDictionaryContainsKey(media, CFSTR("GainMap"))) {
                CFDictionaryRemoveValue(media, CFSTR("GainMap"));
                if (CFDictionaryGetCount(media) == 0) {
                    CMRemoveAttachment(sampleBuffer, CFSTR("AttachedMedia"));
                } else {
                    CMSetAttachment(sampleBuffer, CFSTR("AttachedMedia"),
                                    media, kCMAttachmentMode_ShouldPropagate);
                }
                stripped = YES;
            }
            if (media != NULL) CFRelease(media);
        }
        CMRemoveAttachment(sampleBuffer, CFSTR("MeteorHeadroom"));
        CMRemoveAttachment(sampleBuffer, CFSTR("MeteorPlusGainMapAverage"));
    }
    if (imageBuffer != NULL) {
        CVBufferRemoveAttachment(imageBuffer, CFSTR("MeteorHeadroom"));
        CVBufferRemoveAttachment(imageBuffer, CFSTR("MeteorPlusGainMapAverage"));
    }
    if (stripped) {
        int count = __sync_add_and_fetch(&strippedCount, 1);
        if (count <= 4 || count % 100 == 0) {
            VCAMRefLog("stripped deferred photo gain-map metadata");
        }
    }
}

static CFStringRef VCAMPhotoFileType(CMSampleBufferRef sampleBuffer) {
    if (sampleBuffer == NULL) return CFSTR("public.jpeg");
    CFTypeRef value = CMGetAttachment(sampleBuffer, CFSTR("EncodedImageFileType"), NULL);
    if (value == NULL || CFGetTypeID(value) != CFStringGetTypeID()) {
        return CFSTR("public.jpeg");
    }
    // Only accept standard ImageIO types. Never pass an arbitrary private
    // attachment string into the encoder.
    CFStringRef stringValue = (CFStringRef)value;
    if (CFStringCompare(stringValue, CFSTR("public.jpeg"), 0) == kCFCompareEqualTo ||
        CFStringCompare(stringValue, CFSTR("public.heic"), 0) == kCFCompareEqualTo ||
        CFStringCompare(stringValue, CFSTR("public.heif"), 0) == kCFCompareEqualTo) {
        return (CFStringRef)value;
    }
    return CFSTR("public.jpeg");
}

static NSData *VCAMEncodeReplacementPhoto(CMSampleBufferRef sampleBuffer,
                                           BOOL *requiresRightOrientationOut,
                                           CFStringRef *fileTypeOut) {
    if (requiresRightOrientationOut != NULL) {
        *requiresRightOrientationOut = NO;
    }
    if (fileTypeOut != NULL) *fileTypeOut = CFSTR("public.jpeg");
    CVPixelBufferRef source = sampleBuffer == NULL
        ? NULL : CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!VCAMTargetBufferIsSupported(source)) return nil;

    size_t width = CVPixelBufferGetWidth(source);
    size_t height = CVPixelBufferGetHeight(source);
    NSDictionary *attributes = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferWidthKey: @(width),
        (id)kCVPixelBufferHeightKey: @(height),
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
    };
    CVPixelBufferRef renderedBuffer = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA,
                            (__bridge CFDictionaryRef)attributes,
                            &renderedBuffer) != kCVReturnSuccess ||
        !VCAMTargetBufferIsSupported(renderedBuffer)) {
        if (renderedBuffer != NULL) CVPixelBufferRelease(renderedBuffer);
        return nil;
    }

    BOOL requiresRightOrientation = NO;
    BOOL rendered = drawReplacementOntoBuffer(
        renderedBuffer, VCAMFramePresentationStillPhotoFill, NULL,
        &requiresRightOrientation);
    if (!rendered) {
        CVPixelBufferRelease(renderedBuffer);
        return nil;
    }

    CIImage *image = [CIImage imageWithCVPixelBuffer:renderedBuffer];
    // Do not let the device display profile decide how the deferred encoded
    // surface is tagged. The preview and the later Photos decode must see the
    // same SDR colour space; otherwise the image is initially correct and then
    // shifts when the deferred HEIF/JPEG replaces the preview surface.
    CGColorSpaceRef outputColorSpace =
        CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    NSDictionary *contextOptions = outputColorSpace == NULL ? nil : @{
        (id)kCIContextWorkingColorSpace: (__bridge id)outputColorSpace,
        (id)kCIContextOutputColorSpace: (__bridge id)outputColorSpace,
    };
    CIContext *context = contextOptions == nil
        ? [CIContext contextWithOptions:nil]
        : [CIContext contextWithOptions:contextOptions];
    CGImageRef cgImage = context == nil ? NULL
        : (outputColorSpace == NULL
            ? [context createCGImage:image fromRect:image.extent]
            : [context createCGImage:image fromRect:image.extent
                                format:kCIFormatBGRA8
                            colorSpace:outputColorSpace]);
    NSData *encoded = nil;
    CFStringRef requestedType = VCAMPhotoFileType(sampleBuffer);
    CFStringRef encodedType = requestedType;
    if (cgImage != NULL) {
        NSMutableData *data = [NSMutableData data];
        CGImageDestinationRef destination = CGImageDestinationCreateWithData(
            (__bridge CFMutableDataRef)data, requestedType, 1, NULL);
        if (destination == NULL &&
            CFStringCompare(requestedType, CFSTR("public.jpeg"), 0) !=
                kCFCompareEqualTo) {
            encodedType = CFSTR("public.jpeg");
            destination = CGImageDestinationCreateWithData(
                (__bridge CFMutableDataRef)data, encodedType, 1, NULL);
        }
        if (destination != NULL) {
            CFTypeRef orientation = sampleBuffer == NULL ? NULL
                : CMGetAttachment(sampleBuffer, kCGImagePropertyOrientation, NULL);
            NSMutableDictionary *properties = [NSMutableDictionary dictionary];
            if (orientation != NULL &&
                CFGetTypeID(orientation) == CFNumberGetTypeID()) {
                properties[(id)kCGImagePropertyOrientation] =
                    (__bridge id)orientation;
            } else if (requiresRightOrientation) {
                properties[(id)kCGImagePropertyOrientation] =
                    @(kCGImagePropertyOrientationRight);
            }
            CGImageDestinationAddImage(destination, cgImage,
                                       (__bridge CFDictionaryRef)properties);
            if (CGImageDestinationFinalize(destination)) encoded = [data copy];
            CFRelease(destination);
        }
        CGImageRelease(cgImage);
    }
    if (outputColorSpace != NULL) CGColorSpaceRelease(outputColorSpace);
    CVPixelBufferRelease(renderedBuffer);
    if (encoded.length == 0) return nil;
    if (requiresRightOrientationOut != NULL) {
        *requiresRightOrientationOut = requiresRightOrientation;
    }
    if (fileTypeOut != NULL) *fileTypeOut = encodedType;
    return encoded;
}

static IOSurfaceRef VCAMCreateEncodedPhotoSurface(NSUInteger length) {
    if (length == 0) return NULL;
    NSDictionary *attributes = @{
        @"IOSurfaceWidth": @1,
        @"IOSurfaceHeight": @1,
        @"IOSurfaceBytesPerElement": @1,
        @"IOSurfaceAllocSize": @(length),
        @"IOSurfaceIsGlobal": @NO,
    };
    return IOSurfaceCreate((__bridge CFDictionaryRef)attributes);
}

static BOOL VCAMWriteEncodedPhotoSurface(IOSurfaceRef surface,
                                          NSData *encoded) {
    if (surface == NULL || encoded.length == 0 ||
        IOSurfaceGetAllocSize(surface) < encoded.length) return NO;
    if (IOSurfaceLock(surface, 0, NULL) != 0) return NO;
    void *base = IOSurfaceGetBaseAddress(surface);
    if (base == NULL) {
        IOSurfaceUnlock(surface, 0, NULL);
        return NO;
    }
    memcpy(base, encoded.bytes, encoded.length);
    IOSurfaceUnlock(surface, 0, NULL);
    return YES;
}

static BOOL VCAMReplaceEncodedPhotoBytes(CMSampleBufferRef sampleBuffer,
                                         IOSurfaceRef originalSurface,
                                         CFStringRef surfaceKey,
                                         BOOL *requiresRightOrientationOut) {
    CFStringRef fileType = NULL;
    NSData *encoded = VCAMEncodeReplacementPhoto(
        sampleBuffer, requiresRightOrientationOut, &fileType);
    if (encoded.length == 0) return NO;

    IOSurfaceRef surface = originalSurface;
    BOOL replaceAttachment = NO;
    if (!VCAMWriteEncodedPhotoSurface(surface, encoded)) {
        surface = VCAMCreateEncodedPhotoSurface(encoded.length);
        replaceAttachment = surface != NULL;
        if (!replaceAttachment || !VCAMWriteEncodedPhotoSurface(surface, encoded)) {
            if (surface != NULL && replaceAttachment) CFRelease(surface);
            return NO;
        }
    }
    if (replaceAttachment && surfaceKey != NULL) {
        CMSetAttachment(sampleBuffer, surfaceKey, surface,
                        kCMAttachmentMode_ShouldPropagate);
    }
    if (surfaceKey != NULL) {
        CMSetAttachment(sampleBuffer, CFSTR("DeferredPhotoProxyEncodedImageSurfaceSize"),
                        (__bridge CFTypeRef)@(encoded.length),
                        kCMAttachmentMode_ShouldPropagate);
        CMSetAttachment(sampleBuffer, CFSTR("EncodedImageSurfaceSize"),
                        (__bridge CFTypeRef)@(encoded.length),
                        kCMAttachmentMode_ShouldPropagate);
        if (fileType != NULL) {
            CMSetAttachment(sampleBuffer, CFSTR("EncodedImageFileType"), fileType,
                            kCMAttachmentMode_ShouldPropagate);
        }
    }
    static volatile int encodedReplacements = 0;
    int count = __sync_add_and_fetch(&encodedReplacements, 1);
    if (count <= 8 || count % 100 == 0) {
        char message[240] = {0};
        char keyName[96] = "(none)";
        if (surfaceKey != NULL) {
            CFStringGetCString(surfaceKey, keyName, sizeof(keyName),
                               kCFStringEncodingUTF8);
        }
        snprintf(message, sizeof(message),
                 "photo encoded-bytes replacement count=%d key=%s bytes=%lu replacedSurface=%d",
                 count, keyName,
                 (unsigned long)encoded.length, replaceAttachment);
        VCAMRefLog(message);
    }
    if (replaceAttachment) CFRelease(surface);
    return YES;
}

// SumUp's deferred-photo output carries the surface that the app eventually
// saves separately from the ordinary image buffer. iOS 16.1 has been seen to
// publish this surface under both the old EncodedImageSurface spelling and
// the deferred-photo spelling below. When the attachment is a supported
// IOSurface-backed pixel buffer, compose the same canonical frame into it
// before the app consumes the BWPhotoEncoder output. Private encoded or
// compressed surfaces fail the strict CVPixelBuffer gate and are left
// untouched; the normal sample replacement remains the safe fallback.
static BOOL VCAMReplacePhotoEncodedSurface(CMSampleBufferRef sampleBuffer) {
    if (sampleBuffer == NULL || !VCAMVirtualModeIsEnabled()) return NO;
    CFDictionaryRef attachments = CMCopyDictionaryOfAttachments(
        kCFAllocatorDefault, sampleBuffer, kCMAttachmentMode_ShouldPropagate);
    CFTypeRef surfaceValue = NULL;
    const char *surfaceKey = NULL;
    CFStringRef surfaceAttachmentKey = NULL;
    const CFStringRef surfaceKeys[] = {
        CFSTR("DeferredPhotoProxyEncodedImageSurface"),
        CFSTR("EncodedImageSurface"),
    };
    const char *surfaceKeyNames[] = {
        "DeferredPhotoProxyEncodedImageSurface",
        "EncodedImageSurface",
    };
    for (NSUInteger index = 0; index < sizeof(surfaceKeys) / sizeof(surfaceKeys[0]); index++) {
        if (attachments != NULL) {
            surfaceValue = CFDictionaryGetValue(attachments, surfaceKeys[index]);
            if (surfaceValue != NULL) {
                surfaceKey = surfaceKeyNames[index];
                surfaceAttachmentKey = surfaceKeys[index];
                break;
            }
        }
    }
    if (surfaceValue == NULL && attachments != NULL) {
        CFRelease(attachments);
        attachments = CMCopyDictionaryOfAttachments(
            kCFAllocatorDefault, sampleBuffer,
            kCMAttachmentMode_ShouldNotPropagate);
        for (NSUInteger index = 0; index < sizeof(surfaceKeys) / sizeof(surfaceKeys[0]); index++) {
            if (attachments != NULL) {
                surfaceValue = CFDictionaryGetValue(attachments, surfaceKeys[index]);
                if (surfaceValue != NULL) {
                    surfaceKey = surfaceKeyNames[index];
                    surfaceAttachmentKey = surfaceKeys[index];
                    break;
                }
            }
        }
    }
    if (surfaceValue == NULL ||
        CFGetTypeID(surfaceValue) != IOSurfaceGetTypeID()) {
        if (attachments != NULL) CFRelease(attachments);
        return NO;
    }

    IOSurfaceRef surface = (IOSurfaceRef)surfaceValue;
    size_t surfaceWidth = IOSurfaceGetWidth(surface);
    size_t surfaceHeight = IOSurfaceGetHeight(surface);
    // DeferredPhotoProxyEncodedImageSurface is a byte surface on iOS 16.1:
    // it intentionally reports 0x0 dimensions and cannot be wrapped as a
    // CVPixelBuffer. Replace the encoded bytes directly in that case.
    if (surfaceWidth == 0 || surfaceHeight == 0) {
        BOOL requiresRightOrientation = NO;
        BOOL replaced = VCAMReplaceEncodedPhotoBytes(
            sampleBuffer, surface, surfaceAttachmentKey, &requiresRightOrientation);
        if (attachments != NULL) CFRelease(attachments);
        if (replaced) {
            VCAMRefLog("photo encoded-surface replacement=encoded-bytes");
        }
        return replaced;
    }
    CVPixelBufferRef target = NULL;
    NSDictionary *attributes = @{
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
    };
    CVReturn createStatus = CVPixelBufferCreateWithIOSurface(
        kCFAllocatorDefault, surface, (__bridge CFDictionaryRef)attributes,
        &target);
    BOOL supported = createStatus == kCVReturnSuccess && target != NULL &&
        VCAMTargetBufferIsSupported(target);
    static volatile int surfaceAttempts = 0;
    int attempt = __sync_add_and_fetch(&surfaceAttempts, 1);
    if (attempt <= 8 || !supported) {
        char message[256] = {0};
        snprintf(message, sizeof(message),
                 "photo encoded-surface attempt=%d key=%s id=%u size=%zux%zu create=%d supported=%d format=%08x",
                 attempt, surfaceKey == NULL ? "(none)" : surfaceKey,
                 (unsigned int)IOSurfaceGetID(surface), surfaceWidth,
                 surfaceHeight, (int)createStatus, supported,
                 target == NULL ? 0 : CVPixelBufferGetPixelFormatType(target));
        VCAMRefLog(message);
    }
    BOOL rendered = NO;
    BOOL requiresRightOrientation = NO;
    if (supported) {
        rendered = drawReplacementOntoBuffer(
            target, VCAMFramePresentationStillPhotoFill, NULL,
            &requiresRightOrientation);
        if (rendered) {
            VCAMSetStillPhotoDisplayOrientationIfMissing(
                sampleBuffer, target, requiresRightOrientation);
        }
    }
    if (target != NULL) CVPixelBufferRelease(target);
    if (attachments != NULL) CFRelease(attachments);
    if (rendered) {
        VCAMRefLog("photo encoded-surface replacement=rendered");
    }
    return rendered;
}

static CFStringRef const VCAMPropagationMarkerKey =
    CFSTR("com.codex.vcam.virtual-frame.v1");

static BOOL VCAMOperatingSystemIsAtLeast18(void);

static BOOL VCAMRouteUsesPropagationMarker(VCAMReplacementRoute route) {
    // iOS 16 WebKit must redraw from the canonical shared frame because its
    // terminal can receive pixels that traversed a private compressed buffer.
    // On iOS 18 the observed Video Data Converter is itself the final standard
    // pixel boundary before BWRemoteQueueSinkNode. Mark that rendered result so
    // the remote sink does not synchronously compose the same dynamic frame a
    // second time.
    return route == VCAMReplacementRouteCameraSourceVideo ||
        route == VCAMReplacementRouteCameraPreview ||
        route == VCAMReplacementRouteVideoRecording ||
        (route == VCAMReplacementRouteVideoConverter &&
         VCAMOperatingSystemIsAtLeast18());
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

static BOOL VCAMOutputIsKnownInternalGraphStage(NSString *nodeClass,
                                                 NSString *nodeName,
                                                 NSString *outputName) {
    // These exact iOS 18 stages only fan out, synchronize, analyse or stage a
    // frame inside cameracaptured. Re-rendering the same canonical image at
    // every one of them multiplied a single Camera stream into dozens of
    // synchronous software renders. Consumer boundaries below (Preview Scaler,
    // video converters, Movie File governor and remote queue sink) remain
    // fail-closed and still perform the replacement.
    if (VCAMStringMatches(nodeClass, @"BWMultiStreamCameraSourceNode") &&
        VCAMStringMatches(outputName, @"VideoCapture(PrimaryScaler)")) {
        return YES;
    }
    if (VCAMStringMatches(nodeClass, @"BWFrameRateGovernorNode") &&
        VCAMStringMatches(nodeName, @"Preview Governor")) {
        return YES;
    }
    return VCAMStringMatches(nodeClass, @"BWSlaveFrameSynchronizerNode") ||
        VCAMStringMatches(nodeClass, @"BWSynchronizerNode") ||
        VCAMStringMatches(nodeClass, @"BWFanOutNode") ||
        VCAMStringMatches(nodeClass, @"BWPreviewStitcherNode") ||
        VCAMStringMatches(nodeClass, @"BWStreamingFilterNode") ||
        VCAMStringMatches(nodeClass, @"BWInferenceNode") ||
        VCAMStringMatches(nodeClass, @"BWCrossoverNode") ||
        VCAMStringMatches(nodeClass, @"BWMetadataDetectorGatingNode");
}

static BOOL VCAMOperatingSystemIsAtLeast18(void) {
    static dispatch_once_t onceToken;
    static BOOL isAtLeast18 = NO;
    dispatch_once(&onceToken, ^{
        NSOperatingSystemVersion version =
            NSProcessInfo.processInfo.operatingSystemVersion;
        isAtLeast18 = version.majorVersion >= 18;
    });
    return isAtLeast18;
}

static VCAMReplacementRoute VCAMReplacementRouteForOutput(id output,
                                                            CVPixelBufferRef pixelBuffer) {
    id node = VCAMSafeObjectResult(output, sel_registerName("node"));
    NSString *nodeClass = node == nil ? nil : NSStringFromClass([node class]);
    NSString *outputName = VCAMSafeObjectResult(output, sel_registerName("name"));
    NSString *nodeName = VCAMSafeObjectResult(node, sel_registerName("name"));

    // Lens position is available only on the physical source node, before the
    // generic converter/remote-queue fan-out. Record it for WebKit presentation
    // compensation, but do not use it to choose a replacement route.
    if (VCAMStringMatches(nodeClass, @"BWMultiStreamCameraSourceNode")) {
        if ([nodeName isKindOfClass:NSString.class] &&
            [nodeName rangeOfString:@"Front Camera"].location != NSNotFound) {
            VCAMSetLastCameraIsFront(YES);
        } else if ([nodeName isKindOfClass:NSString.class] &&
                   [nodeName rangeOfString:@"Back Camera"].location != NSNotFound) {
            VCAMSetLastCameraIsFront(NO);
        }
    }

    // Keep ordinary VideoCapture frames untouched: preview/WebKit apply their
    // own physical-camera transforms after this node. The iOS 16 still branch
    // is different, however. Its final high-resolution photo is carried on the
    // raw StillImage output as a private compressed format. iOS 16.1 reports
    // StillImage/&xf0; iOS 18.3.1 reports StillImage(StillImage)/pf20. Replacing
    // only those device-observed outputs closes the side path which bypasses
    // Meteor Headroom/BWPhotoEncoder. The compressed renderer preserves the
    // negotiated surface contract and applies still-photo orientation metadata.
    if (VCAMStringMatches(nodeClass, @"BWMultiStreamCameraSourceNode") &&
        (VCAMStringMatches(outputName, @"StillImage") ||
         VCAMStringMatches(outputName, @"StillImage(StillImage)"))) {
        OSType pixelFormat = pixelBuffer == NULL
            ? 0 : CVPixelBufferGetPixelFormatType(pixelBuffer);
        if ((pixelFormat == (OSType)0x26786630 ||
             pixelFormat == (OSType)0x70663230) &&
            VCAMTargetBufferIsSupported(pixelBuffer)) {
            return VCAMReplacementRouteStillPhoto;
        }
        return VCAMReplacementRouteUniversalVideo;
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
        if (VCAMStringMatches(nodeName, @"Video Data Converter/Rotator/Scaler/Zoomer")) {
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

    // iOS 18 also runs this 4:3 governor throughout still-photo preview. If it
    // is replaced there, its RealtimeFill propagation marker can reach Preview
    // Scaler and bypass CameraPreviewFit, alternating landscape and portrait
    // compositions while doing a second full-frame render. The actual iOS 18
    // recording consumer remains the exact Movie File Zoomer route above.
    //
    // iOS 16.1 can use this governor as its final movie boundary when the older
    // Movie File Zoomer is absent, so retain that fail-closed fallback on every
    // pre-iOS-18 system for which no prewarm-only trace has been established.
    if (VCAMStringMatches(nodeClass, @"BWFrameRateGovernorNode") &&
        VCAMStringMatches(nodeName, @"Movie File Frame Rate Governor")) {
        if (VCAMOperatingSystemIsAtLeast18()) {
            return VCAMReplacementRouteNone;
        }
        return VCAMReplacementRouteVideoRecording;
    }

    // Stock Camera still capture reaches this last standard 8-bit pixel stage
    // immediately before the photo encoder. Match the role rather than a lens
    // name, resolution or pixel format. Unsupported future formats fail closed
    // in the hook rather than reaching the encoder as a real frame.
    if (VCAMStringMatches(nodeClass, @"BWMeteorHeadroomNode") &&
        VCAMStringMatches(nodeName, @"Meteor Headroom") && pixelBuffer != NULL) {
        return VCAMReplacementRouteCameraSourceVideo;
    }

    // SumUp on iOS 16.1 emits a standard 420f frame from this final still
    // boundary instead of the Meteor Headroom node used by stock Camera.
    // ponytail: keep this exact node/name match; add another terminal only
    // after a device signature proves it is the same still-photo boundary.
    if (VCAMStringMatches(nodeClass, @"BWPhotoEncoderNode") &&
        VCAMStringMatches(nodeName, @"Encoder") &&
        VCAMTargetBufferIsSupported(pixelBuffer)) {
        return VCAMReplacementRoutePhotoEncoder;
    }

    // iOS 18 front-camera traces place this node immediately before the
    // explicitly routed Video Data Converter/Zoomer. It is a graph-processing
    // stage, not a consumer boundary; replacing both outputs rendered every
    // dynamic frame twice before the remote queue saw it.
    if (VCAMOperatingSystemIsAtLeast18() &&
        VCAMStringMatches(nodeClass, @"BWBackgroundBlurNode") &&
        VCAMStringMatches(nodeName, @"BWBackgroundBlurNode")) {
        return VCAMReplacementRouteNone;
    }

    // Stock Camera's physical QR/metadata detector consumes this exact fan-out.
    // iOS 16 left it untouched while replacing only the visible preview, so a
    // QR code in front of the real lens could still produce the system link UI.
    // Preserve that split by default; replacing this branch with VCAM pixels
    // makes physical QR recognition impossible whenever the virtual source has
    // no QR code of its own. KYC face detection reads AVMetadataFaceObject off
    // this same branch, so `metadataBranch=replace` opts the branch into the
    // replacement route and lets face metadata flow on the virtual stream.
    if (VCAMOperatingSystemIsAtLeast18() &&
        VCAMStringMatches(nodeClass, @"BWFanOutNode") &&
        VCAMStringMatches(nodeName, @"Preview Splitter") &&
        VCAMStringMatches(outputName, @"MetadataObject")) {
        return VCAMMetadataBranchReplaceEnabled() ? VCAMReplacementRouteUniversalVideo
                                                 : VCAMReplacementRouteNone;
    }

    if (VCAMOutputIsKnownInternalGraphStage(nodeClass, nodeName, outputName)) {
        return VCAMReplacementRouteNone;
    }

    // BWNodeOutput is the common cameracaptured boundary. Known terminals keep
    // their route-specific composition above; every other video terminal uses
    // the same canonical replacement and never silently receives the camera.
    return VCAMReplacementRouteUniversalVideo;
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
    if ([nodeClass isEqualToString:@"BWPhotoEncoderNode"]) {
        VCAMLogRuntimeMethodsOnce([node class], @"photo-node");
        static volatile int photoOutputProbes = 0;
        if (__sync_add_and_fetch(&photoOutputProbes, 1) <= 2) {
            VCAMLogPhotoAttachmentKeys(sampleBuffer, "output");
            VCAMLogPhotoAttachmentShapes(sampleBuffer, "output");
        }
    }
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
    strlcpy(g_lastOutputSignature, message, sizeof(g_lastOutputSignature));
    if (g_sigaddrToken == -1) {
        notify_register_check("com.codex.vcam.ios18.sigaddr", &g_sigaddrToken);
    }
    if (g_sigaddrToken >= 0) {
        notify_set_state(g_sigaddrToken, (uint64_t)(uintptr_t)g_lastOutputSignature);
        notify_post("com.codex.vcam.ios18.signew");
    }
    VCAMRefLog(message);
}

static BOOL VCAMReplaceSampleBufferInPlace(
    CMSampleBufferRef sampleBuffer,
    VCAMFramePresentation presentation,
    VCAMReplacementRoute route) {
    if (sampleBuffer == NULL || !VCAMVirtualModeIsEnabled()) return NO;
    CVPixelBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!VCAMTargetBufferIsSupported(imageBuffer)) return NO;
    if (route == VCAMReplacementRoutePhotoEncoder) {
        VCAMStripVirtualPhotoGainMap(sampleBuffer, imageBuffer);
    }
    CVPixelBufferRef replacementBuffer = NULL;
    BOOL requiresRightOrientation = NO;
    BOOL rendered = drawReplacementOntoBuffer(
        imageBuffer, presentation, &replacementBuffer,
        route == VCAMReplacementRoutePhotoEncoder
            ? &requiresRightOrientation : NULL);
    BOOL inPlace = rendered;
    if (rendered && replacementBuffer != NULL) {
        // Private/10-bit targets are rendered into a safe clone by the common
        // renderer. Copy it back to the graph-owned target rather than handing
        // cameracaptured a newly-created CMSampleBuffer.
        inPlace = VCAMCopyReplacementBufferIntoTarget(
            replacementBuffer, imageBuffer);
    }
    if (replacementBuffer != NULL) CVPixelBufferRelease(replacementBuffer);
    if (!inPlace) return NO;

    if (VCAMRouteUsesPropagationMarker(route)) {
        inPlace = VCAMWritePropagationMarker(sampleBuffer, imageBuffer);
    }
    if (inPlace && route == VCAMReplacementRouteVideoConverter &&
        !VCAMOperatingSystemIsAtLeast18()) {
        VCAMClearPropagationMarker(sampleBuffer, imageBuffer);
    }
    if (inPlace && route == VCAMReplacementRoutePhotoEncoder) {
        VCAMSetStillPhotoDisplayOrientationIfMissing(
            sampleBuffer, imageBuffer, requiresRightOrientation);
    }
    if (inPlace) VCAMRuntimePublishReplacement(route);
    return inPlace;
}

// SumUp's final still encoder consumes its input through this node method
// before the BWNodeOutput callback. Replacing only the output is too late for
// the encoded photo data returned to the app.
%hook BWPhotoEncoderNode

- (void)renderSampleBuffer:(CMSampleBufferRef)sampleBuffer forInput:(id)input {
    BOOL enabled = VCAMVirtualModeIsEnabled();
    CVPixelBufferRef imageBuffer = sampleBuffer == NULL ? NULL
        : CMSampleBufferGetImageBuffer(sampleBuffer);
    static volatile int photoInputSamples = 0;
    int sampleCount = __sync_add_and_fetch(&photoInputSamples, 1);
    BOOL logSample = sampleCount <= 8 || sampleCount % 100 == 0;
    if (sampleCount <= 2) {
        VCAMLogPhotoAttachmentKeys(sampleBuffer, "input");
        VCAMLogPhotoAttachmentShapes(sampleBuffer, "input");
    }
    if (logSample) {
        char message[240] = {0};
        NSString *inputClass = input == nil ? @"(none)"
            : (NSStringFromClass([input class]) ?: @"(none)");
        NSString *inputName = VCAMSafeStringValue(
            VCAMSafeObjectResult(input, sel_registerName("name")));
        snprintf(message, sizeof(message),
                 "photo encoder input diagnostic count=%d enabled=%d sample=%d image=%d data=%d format=%08x size=%zux%zu inputClass=%s inputName=%s",
                 sampleCount, enabled, sampleBuffer != NULL, imageBuffer != NULL,
                 sampleBuffer != NULL && CMSampleBufferGetDataBuffer(sampleBuffer) != NULL,
                 imageBuffer == NULL ? 0 : CVPixelBufferGetPixelFormatType(imageBuffer),
                 imageBuffer == NULL ? 0 : CVPixelBufferGetWidth(imageBuffer),
                 imageBuffer == NULL ? 0 : CVPixelBufferGetHeight(imageBuffer),
                 inputClass.UTF8String, inputName.UTF8String);
         VCAMRefLog(message);
     }
    VCAMRuntimeSetState(&g_runtimePhotoCountToken,
                        "com.codex.vcam.ios18.production.photo-count.state",
                        (uint64_t)sampleCount);
    VCAMRuntimePublishSample(VCAMRuntimeSampleKindPhotoEncoder,
                             (uint64_t)sampleCount, sampleBuffer);
    if (sampleBuffer != NULL && enabled) {
        if (imageBuffer != NULL) {
            BOOL replaced = VCAMReplaceSampleBufferInPlace(
                sampleBuffer, VCAMFramePresentationStillPhotoFill,
                VCAMReplacementRoutePhotoEncoder);
            if (logSample && replaced) {
                VCAMRefLog("photo encoder input diagnostic replacement=in-place");
            }
            if (!replaced) {
                VCAMRefLog("suppressing PhotoEncoder real sample after replacement failure");
                return;
            }
        }
    }
    %orig(sampleBuffer, input);
}

%end

// BWRemoteQueueSinkNode consumes frames for remote VideoDataOutput clients and
// therefore has no BWNodeOutput of its own for the graph probe below to see.
// Device traces show SumUp receives unmarked BGRA frames here, so this is now
// a narrow consumer boundary with the same fail-closed policy as BWNodeOutput.
%hook BWRemoteQueueSinkNode

- (void)renderSampleBuffer:(CMSampleBufferRef)sampleBuffer forInput:(id)input {
    VCAMLogRuntimeMethodsOnce(object_getClass(self), @"remote-sink");
    CMFormatDescriptionRef description = sampleBuffer == NULL ? NULL
        : CMSampleBufferGetFormatDescription(sampleBuffer);
    CMMediaType mediaType = description == NULL ? 0
        : CMFormatDescriptionGetMediaType(description);
    if (mediaType == kCMMediaType_Video) {
        static volatile int remoteVideoSamples = 0;
        int sampleCount = __sync_add_and_fetch(&remoteVideoSamples, 1);
        VCAMRuntimeSetState(&g_runtimeRemoteCountToken,
                            "com.codex.vcam.ios18.production.remote-count.state",
                            (uint64_t)sampleCount);
        VCAMRuntimePublishSample(VCAMRuntimeSampleKindRemoteQueue,
                                 (uint64_t)sampleCount, sampleBuffer);
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
        if (VCAMVirtualModeIsEnabled()) {
            CVPixelBufferRef imageBuffer =
                CMSampleBufferGetImageBuffer(sampleBuffer);
            BOOL propagatedReplacement =
                VCAMOperatingSystemIsAtLeast18() &&
                VCAMSampleHasMatchingPropagationMarker(
                    sampleBuffer, imageBuffer);
            if (propagatedReplacement) {
                static volatile int propagatedRemoteSamples = 0;
                int propagatedCount = __sync_add_and_fetch(
                    &propagatedRemoteSamples, 1);
                if (propagatedCount <= 8 || propagatedCount % 300 == 0) {
                    char message[144] = {0};
                    snprintf(message, sizeof(message),
                             "passing propagated remote queue virtual frame count=%d",
                             propagatedCount);
                    VCAMRefLog(message);
                }
            }
            BOOL replaced = propagatedReplacement ||
                VCAMReplaceSampleBufferInPlace(
                    sampleBuffer, VCAMFramePresentationCameraPreviewFit,
                    VCAMReplacementRouteCameraPreview);
            if (!replaced) {
                VCAMRefLog("suppressing remote queue real sample after replacement failure");
                return;
            }
        }
    } else if (sampleBuffer != NULL) {
        static volatile int remoteNonVideoSamples = 0;
        int sampleCount = __sync_add_and_fetch(&remoteNonVideoSamples, 1);
        if (sampleCount <= 4) {
            CVPixelBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
            NSString *inputClass = input == nil ? @"(none)"
                : (NSStringFromClass([input class]) ?: @"(none)");
            char message[160] = {0};
            snprintf(message, sizeof(message),
                     "remote queue sink diagnostic non-video count=%d mediaType=%08x image=%p size=%zux%zu inputClass=%s",
                     sampleCount, (unsigned int)mediaType, imageBuffer,
                     imageBuffer == NULL ? 0 : CVPixelBufferGetWidth(imageBuffer),
                     imageBuffer == NULL ? 0 : CVPixelBufferGetHeight(imageBuffer),
                     inputClass.UTF8String);
            VCAMRefLog(message);
        }
    }
    %orig(sampleBuffer, input);
}

%end

// —— P0-1a BW 图符号发现（决定 torch/AE 状态观测走路线 A 还是 B）——
// 设备侧没有工具链解析 dyld shared cache；cameracaptured 直接链接 BWCore，
// 类与方法名在 ObjC runtime 里可见。`touch /var/mobile/Library/VirtualCaptureCard/VCAM/bw_dump.request`
// 后开一次相机，本 hook 把所有 BW* 前缀类中含 Torch/Exposure/Gain/Flash/Illum
// 的方法名导出到 bw_symbols.log 并删除 marker（幂等、可重复触发；
// 2s 节流让未触发时每帧只多一次 access()）。
// 路径必须用 cameracaptured 沙箱已授权的 VirtualCaptureCard 目录：
// /var/mobile/Media/VCAM 对它不可见（与模式配置走 notifyd 同一原因）。
static void VCAMMaybeDumpBWGraphSymbols(void) {
    static const char *requestPath =
        "/var/mobile/Library/VirtualCaptureCard/VCAM/bw_dump.request";
    static CFAbsoluteTime lastCheck;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (lastCheck != 0 && now - lastCheck < 2.0) return;
    lastCheck = now;
    if (access(requestPath, F_OK) != 0) return;
    unlink(requestPath);
    FILE *file = fopen("/var/mobile/Library/VirtualCaptureCard/VCAM/bw_symbols.log", "w");
    if (file == NULL) return;
    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);
    fprintf(file, "# bw graph symbol dump classes=%u\n", classCount);
    for (unsigned int i = 0; i < classCount; i++) {
        const char *className = class_getName(classes[i]);
        if (className == NULL || strncmp(className, "BW", 2) != 0) continue;
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(classes[i], &methodCount);
        for (unsigned int m = 0; m < methodCount; m++) {
            const char *selector = sel_getName(method_getName(methods[m]));
            if (selector == NULL) continue;
            if (strstr(selector, "Torch") != NULL || strstr(selector, "torch") != NULL ||
                strstr(selector, "Exposure") != NULL || strstr(selector, "exposure") != NULL ||
                strstr(selector, "Gain") != NULL || strstr(selector, "Flash") != NULL ||
                strstr(selector, "Illum") != NULL) {
                fprintf(file, "%s %s\n", className, selector);
            }
        }
        free(methods);
    }
    free(classes);
    fclose(file);
    VCAMRefLog("bw symbol dump written");
}

// —— 路线 A：真实 torch 观测（P0-1）——
// BW 符号 dump 证实 cameracaptured 进程内 BWFigVideoCaptureDevice 有
// setTorchLevel:/torchLevel。setTorchLevel: 即状态变更事件：任何 App（含
// KYC SDK）打闪光活体时都会经过它，单点覆盖全部宿主，无需 App 侧注入。
// 参数编码（float/double）随系统版本可能不同，安装时读取实际类型编码
// 二选一，避免 ABI 错位。真机实测编码 "i20@0:8f16"：该 setter 返回 int/BOOL，
// 上层依据返回值判断 level 是否生效——包装必须原样转发返回值（03:23 真机
// setTorchModeOnWithLevel: 报 level-fallback 的根因就是 void 包装吞了返回值）。
// 首帧时安装：此时 CMCapture/BWCore 必已加载。
typedef int (*VCAMSetTorchLevelDoubleIMP)(id, SEL, double);
typedef int (*VCAMSetTorchLevelFloatIMP)(id, SEL, float);
static VCAMSetTorchLevelDoubleIMP VCAMOriginalSetTorchLevelD;
static VCAMSetTorchLevelFloatIMP VCAMOriginalSetTorchLevelF;

static int VCAMReplacedSetTorchLevelD(id receiver, SEL selector, double level) {
    VCAMSetObservedTorchLevel(level);
    return VCAMOriginalSetTorchLevelD != NULL
        ? VCAMOriginalSetTorchLevelD(receiver, selector, level) : 0;
}

static int VCAMReplacedSetTorchLevelF(id receiver, SEL selector, float level) {
    VCAMSetObservedTorchLevel(level);
    return VCAMOriginalSetTorchLevelF != NULL
        ? VCAMOriginalSetTorchLevelF(receiver, selector, level) : 0;
}

static void VCAMInstallTorchObservationIfNeeded(void) {
    static BOOL installed = NO;
    if (installed) return;
    Class deviceClass = objc_getClass("BWFigVideoCaptureDevice");
    if (deviceClass == NULL) return;
    SEL selector = sel_registerName("setTorchLevel:");
    Method method = class_getInstanceMethod(deviceClass, selector);
    if (method == NULL) {
        installed = YES;  // 该类没有此方法：走配置注入回路，不再重试
        VCAMRefLog("torch observation unavailable: setTorchLevel: not found");
        return;
    }
    const char *encoding = method_getTypeEncoding(method);
    // ObjC 类型编码里参数只能是 f 或 d；v/@/: 与数字不含这两个字母。
    if (encoding != NULL && strchr(encoding, 'f') != NULL) {
        MSHookMessageEx(deviceClass, selector, (IMP)VCAMReplacedSetTorchLevelF,
                        (IMP *)&VCAMOriginalSetTorchLevelF);
    } else {
        MSHookMessageEx(deviceClass, selector, (IMP)VCAMReplacedSetTorchLevelD,
                        (IMP *)&VCAMOriginalSetTorchLevelD);
    }
    installed = YES;
    char message[192];
    snprintf(message, sizeof(message), "torch observation installed encoding=%s",
             encoding != NULL ? encoding : "?");
    VCAMRefLog(message);
}

// —— 路线 A-2：真实 AE 观测（P0 遗留项补齐：AE 元数据↔亮度全耦合）——
// 两条通道：
// 1) 显式控制路径：BWFigVideoCaptureDevice 的
//    setExposureModeCustomWithExposureDuration:minFrameRate:maxFrameRate:ISO:requestID:
//    （手动曝光=曝光时长+ISO 终值；KYC App 常见做法是锁曝光采集，直接命中）
//    与 setExposureTargetBias:requestID:（EV 偏移，仅记录对表，增益用终值）。
//    包装与 torch 同款：读实际类型编码选 float/double 变体、原样转发返回值。
// 2) 数据路径：输出 sample buffer 的 attachment（auto-AE 内部环不走 ObjC setter，
//    只有 attachment 携带终值）。键名 Apple 未公开：前 3 个样本把顶层与已知
//    子字典的键转储到 ae_attach.log 钉键，同时按候选键防御式解析；取不到
//    则如实按局限处理（控制路径仍覆盖显式设曝光的场景）。
// 前/后摄像头：receiver 实例变化=物理设备切换，作废全部观测/基线
// （前后面标志翻转另有 SetLastCameraIsFront 入口，两处都会复位）。
static void *VCAMLastObservedDeviceInstance = NULL;

static void VCAMNoteObservedDevice(id receiver) {
    void *instance = (__bridge void *)receiver;
    if (VCAMLastObservedDeviceInstance == NULL) {
        VCAMLastObservedDeviceInstance = instance;
        return;
    }
    if (VCAMLastObservedDeviceInstance != instance) {
        VCAMLastObservedDeviceInstance = instance;
        VCAMResetObservedPhysicalState();
    }
}

typedef int (*VCAMSetExposureCustomFloatIMP)(id, SEL, CMTime, float, float, float, id);
typedef int (*VCAMSetExposureCustomDoubleIMP)(id, SEL, CMTime, double, double, double, id);
static VCAMSetExposureCustomFloatIMP VCAMOriginalSetExposureCustomF;
static VCAMSetExposureCustomDoubleIMP VCAMOriginalSetExposureCustomD;

static int VCAMReplacedSetExposureCustomF(id receiver, SEL selector, CMTime exposureDuration,
                                          float minFrameRate, float maxFrameRate, float ISO,
                                          id requestID) {
    VCAMNoteObservedDevice(receiver);
    if (CMTIME_IS_NUMERIC(exposureDuration) && ISO > 0.0f) {
        VCAMSetObservedExposure(CMTimeGetSeconds(exposureDuration), (double)ISO);
    }
    return VCAMOriginalSetExposureCustomF != NULL
        ? VCAMOriginalSetExposureCustomF(receiver, selector, exposureDuration, minFrameRate,
                                         maxFrameRate, ISO, requestID) : 0;
}

static int VCAMReplacedSetExposureCustomD(id receiver, SEL selector, CMTime exposureDuration,
                                          double minFrameRate, double maxFrameRate, double ISO,
                                          id requestID) {
    VCAMNoteObservedDevice(receiver);
    if (CMTIME_IS_NUMERIC(exposureDuration) && ISO > 0.0) {
        VCAMSetObservedExposure(CMTimeGetSeconds(exposureDuration), ISO);
    }
    return VCAMOriginalSetExposureCustomD != NULL
        ? VCAMOriginalSetExposureCustomD(receiver, selector, exposureDuration, minFrameRate,
                                         maxFrameRate, ISO, requestID) : 0;
}

typedef int (*VCAMSetExposureBiasFloatIMP)(id, SEL, float, id);
typedef int (*VCAMSetExposureBiasDoubleIMP)(id, SEL, double, id);
static VCAMSetExposureBiasFloatIMP VCAMOriginalSetExposureBiasF;
static VCAMSetExposureBiasDoubleIMP VCAMOriginalSetExposureBiasD;

static int VCAMReplacedSetExposureBiasF(id receiver, SEL selector, float biasEV, id requestID) {
    VCAMNoteObservedDevice(receiver);
    VCAMSetObservedExposureBias((double)biasEV);
    return VCAMOriginalSetExposureBiasF != NULL
        ? VCAMOriginalSetExposureBiasF(receiver, selector, biasEV, requestID) : 0;
}

static int VCAMReplacedSetExposureBiasD(id receiver, SEL selector, double biasEV, id requestID) {
    VCAMNoteObservedDevice(receiver);
    VCAMSetObservedExposureBias(biasEV);
    return VCAMOriginalSetExposureBiasD != NULL
        ? VCAMOriginalSetExposureBiasD(receiver, selector, biasEV, requestID) : 0;
}

static void VCAMInstallAEObservationIfNeeded(void) {
    static BOOL installed = NO;
    if (installed) return;
    Class deviceClass = objc_getClass("BWFigVideoCaptureDevice");
    if (deviceClass == NULL) return;
    SEL customSelector = sel_registerName(
        "setExposureModeCustomWithExposureDuration:minFrameRate:maxFrameRate:ISO:requestID:");
    Method customMethod = class_getInstanceMethod(deviceClass, customSelector);
    if (customMethod != NULL) {
        const char *encoding = method_getTypeEncoding(customMethod);
        if (encoding != NULL && strchr(encoding, 'f') != NULL) {
            MSHookMessageEx(deviceClass, customSelector, (IMP)VCAMReplacedSetExposureCustomF,
                            (IMP *)&VCAMOriginalSetExposureCustomF);
        } else {
            MSHookMessageEx(deviceClass, customSelector, (IMP)VCAMReplacedSetExposureCustomD,
                            (IMP *)&VCAMOriginalSetExposureCustomD);
        }
    }
    SEL biasSelector = sel_registerName("setExposureTargetBias:requestID:");
    Method biasMethod = class_getInstanceMethod(deviceClass, biasSelector);
    if (biasMethod != NULL) {
        const char *encoding = method_getTypeEncoding(biasMethod);
        if (encoding != NULL && strchr(encoding, 'f') != NULL) {
            MSHookMessageEx(deviceClass, biasSelector, (IMP)VCAMReplacedSetExposureBiasF,
                            (IMP *)&VCAMOriginalSetExposureBiasF);
        } else {
            MSHookMessageEx(deviceClass, biasSelector, (IMP)VCAMReplacedSetExposureBiasD,
                            (IMP *)&VCAMOriginalSetExposureBiasD);
        }
    }
    installed = YES;
    VCAMRefLog(customMethod != NULL && biasMethod != NULL
                   ? "ae control observation installed custom+bias"
                   : customMethod != NULL
                         ? "ae control observation installed custom-only"
                         : biasMethod != NULL
                               ? "ae control observation installed bias-only"
                               : "ae control observation unavailable");
}

static double VCAMAttachmentDouble(CFTypeRef value) {
    if (value == NULL) return -1.0;
    if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        double result = 0;
        if (CFNumberGetValue((CFNumberRef)value, kCFNumberDoubleType, &result)) return result;
        return -1.0;
    }
    if (CFGetTypeID(value) == CFStringGetTypeID()) {
        const char *text = CFStringGetCStringPtr((CFStringRef)value, kCFStringEncodingUTF8);
        char buffer[64];
        if (text == NULL &&
            CFStringGetCString((CFStringRef)value, buffer, sizeof(buffer), kCFStringEncodingUTF8)) {
            text = buffer;
        }
        if (text != NULL) return strtod(text, NULL);
    }
    return -1.0;
}

// 候选键防御式查找（深度≤2：顶层 + EXIF 子字典）。真实键名以 ae_attach.log 诊断为准。
static const char *const kExposureAttachmentKeys[] = {
    "ExposureTime", "ExposureTimeSeconds", "Exposure Time", "ExposureTimeSecondsFloat"};
static const char *const kISOAttachmentKeys[] = {
    "ISOSpeedRatings", "ISOSpeed", "ISO", "ISOValue", "ISO Speed", "ISO Speed Ratings"};

static double VCAMFindAttachmentCandidate(CFDictionaryRef dict, const char *const *keys,
                                         size_t keyCount, int depth) {
    for (size_t i = 0; i < keyCount; i++) {
        CFStringRef candidateKey = CFStringCreateWithCString(
            kCFAllocatorDefault, keys[i], kCFStringEncodingUTF8);
        if (candidateKey == NULL) continue;
        CFTypeRef value = NULL;
        BOOL found = CFDictionaryGetValueIfPresent(dict, candidateKey, &value);
        CFRelease(candidateKey);
        if (found) {
            double result = VCAMAttachmentDouble(value);
            if (result > 0.0) return result;
        }
    }
    if (depth >= 2) return -1.0;
    // 已知 EXIF 容器再挖一层。
    static const char *const kNestedContainers[] = {
        "ExifDict", "Apple3Note", "Apple10Note", "Apple11Note", "Apple12Note", "MakerNote"};
    for (size_t i = 0; i < sizeof(kNestedContainers) / sizeof(kNestedContainers[0]); i++) {
        CFStringRef containerKey = CFStringCreateWithCString(
            kCFAllocatorDefault, kNestedContainers[i], kCFStringEncodingUTF8);
        CFTypeRef container = containerKey != NULL
            ? CFDictionaryGetValue(dict, containerKey) : NULL;
        if (containerKey != NULL) CFRelease(containerKey);
        if (container != NULL && CFGetTypeID(container) == CFDictionaryGetTypeID()) {
            double result = VCAMFindAttachmentCandidate((CFDictionaryRef)container, keys,
                                                       keyCount, depth + 1);
            if (result > 0.0) return result;
        }
    }
    return -1.0;
}

static void VCAMDumpAttachmentKeys(FILE *file, CFDictionaryRef dict, const char *prefix,
                                  int depth) {
    CFIndex count = CFDictionaryGetCount(dict);
    if (count <= 0 || count > 96) return;
    const void *keys[96];
    const void *values[96];
    CFDictionaryGetKeysAndValues(dict, keys, values);
    for (CFIndex i = 0; i < count; i++) {
        if (CFGetTypeID(keys[i]) != CFStringGetTypeID()) continue;
        char keyText[128];
        if (!CFStringGetCString((CFStringRef)keys[i], keyText, sizeof(keyText),
                               kCFStringEncodingUTF8)) {
            continue;
        }
        CFStringRef description = CFCopyTypeIDDescription(CFGetTypeID(values[i]));
        char valueClass[64];
        NSString *className = description != NULL
            ? (__bridge_transfer NSString *)description : nil;
        snprintf(valueClass, sizeof(valueClass), "%s",
                 className != NULL ? className.UTF8String : "unknown");
        fprintf(file, "%s%s (%s)\n", prefix, keyText, valueClass);
        if (depth < 1 && CFGetTypeID(values[i]) == CFDictionaryGetTypeID()) {
            VCAMDumpAttachmentKeys(file, (CFDictionaryRef)values[i], "  ", depth + 1);
        }
    }
}

static void VCAMObserveSampleBufferExposure(CMSampleBufferRef sampleBuffer, BOOL withKeyDump) {
    // CI 构建 SDK（16.5）未导出 kCGImageAuxiliaryDataInfo 常量；公开文档钉其
    // 字符串值为 "AuxiliaryData"，另试 Fig 私有键拼写。哪个命中由 ae_attach.log
    // 的 aux_present 逐键记录验证（键名最终以真机诊断为权威）。
    static const CFStringRef attachmentKeyCandidates[] = {
        CFSTR("AuxiliaryData"),
        CFSTR("FigAppleSimplifiedCMExifInfo"),
        CFSTR("kFigAppleSimplifiedCMExifInfo"),
    };
    CFTypeRef attachment = NULL;
    for (size_t i = 0; i < sizeof(attachmentKeyCandidates) / sizeof(attachmentKeyCandidates[0]); i++) {
        attachment = CMGetAttachment(sampleBuffer, attachmentKeyCandidates[i], NULL);
        if (attachment != NULL) {
            if (withKeyDump) {
                FILE *logFile = fopen("/var/mobile/Library/VirtualCaptureCard/VCAM/ae_attach.log", "a");
                if (logFile != NULL) {
                    char keyName[64];
                    snprintf(keyName, sizeof(keyName), "%s",
                             ((__bridge NSString *)attachmentKeyCandidates[i]).UTF8String);
                    fprintf(logFile, "t=%.2f attachment_key=%s\n",
                            CFAbsoluteTimeGetCurrent(), keyName);
                    fclose(logFile);
                }
            }
            break;
        }
    }
    CFTypeRef root = NULL;
    if (attachment != NULL && CFGetTypeID(attachment) == CFDataGetTypeID()) {
        root = CFPropertyListCreateWithData(kCFAllocatorDefault, (CFDataRef)attachment,
                                           kCFPropertyListImmutable, NULL, NULL);
    } else if (attachment != NULL && CFGetTypeID(attachment) == CFDictionaryGetTypeID()) {
        root = CFRetain(attachment);
    }
    if (withKeyDump) {
        FILE *file = fopen("/var/mobile/Library/VirtualCaptureCard/VCAM/ae_attach.log", "a");
        if (file != NULL) {
            fprintf(file, "t=%.2f aux_present=%d\n", CFAbsoluteTimeGetCurrent(),
                    attachment != NULL ? 1 : 0);
            if (root != NULL && CFGetTypeID(root) == CFDictionaryGetTypeID()) {
                VCAMDumpAttachmentKeys(file, (CFDictionaryRef)root, "  ", 0);
            }
            fclose(file);
        }
    }
    if (root != NULL && CFGetTypeID(root) == CFDictionaryGetTypeID()) {
        double exposure = VCAMFindAttachmentCandidate(
            (CFDictionaryRef)root, kExposureAttachmentKeys,
            sizeof(kExposureAttachmentKeys) / sizeof(kExposureAttachmentKeys[0]), 0);
        double iso = VCAMFindAttachmentCandidate(
            (CFDictionaryRef)root, kISOAttachmentKeys,
            sizeof(kISOAttachmentKeys) / sizeof(kISOAttachmentKeys[0]), 0);
        if (exposure > 0.0 && iso > 0.0) {
            VCAMSetObservedExposure(exposure, iso);
        }
    }
    if (root != NULL) CFRelease(root);
}

%hook BWNodeOutput

- (void)emitSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    VCAMMaybeDumpBWGraphSymbols();
    VCAMInstallTorchObservationIfNeeded();
    VCAMInstallAEObservationIfNeeded();
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

    static volatile int outputVideoSamples = 0;
    int outputSampleCount = __sync_add_and_fetch(&outputVideoSamples, 1);
    VCAMRuntimeSetState(&g_runtimeOutputCountToken,
                        "com.codex.vcam.ios18.production.output-count.state",
                        (uint64_t)outputSampleCount);
    VCAMRuntimePublishSample(VCAMRuntimeSampleKindOutput,
                             (uint64_t)outputSampleCount, sampleBuffer);

    // Usually completed by the constructor warm-up. dispatch_once inside the
    // renderer makes this a no-op; an unusually early first frame waits for the
    // same initialization instead of racing a partially published context.
    loadReplacementMedia();

    // Heat reduction: when virtual mode is off, skip all routing,
    // signature logging and rendering -- just pass the real frame.
    if (!VCAMVirtualModeIsEnabled()) {
        %orig(sampleBuffer);
        return;
    }

    // AE 数据路径观测（auto-AE 终值只在 attachment 里）：前 3 个样本做键诊断
    // 转储，此后每 120 帧（约 4s@30fps）取一次——AE 漂移是慢过程，无需每帧。
    static volatile int aeObservationCount = 0;
    int aeCount = __sync_add_and_fetch(&aeObservationCount, 1);
    if (aeCount <= 3 || aeCount % 120 == 0) {
        VCAMObserveSampleBufferExposure(sampleBuffer, aeCount <= 3);
    }

    // Consumer-activity evidence for HLS/RTSP demand: only frames that
    // virtual mode actually serves should refresh it. Both receivers
    // (vcamd demand tracking and the SpringBoard HLS suspend/resume gate)
    // implement "a lease on the VCAM frame stream" semantics, so posting
    // before the enable check pinned HLS to running while the camera was
    // used in real mode with the replacement off.
    notify_post("com.codex.vcam.ios18.frame");
    notify_post("com.codex.vcam.ios18.vmode");

    CVPixelBufferRef originalImageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    VCAMReplacementRoute replacementRoute =
        VCAMReplacementRouteForOutput(self, originalImageBuffer);
    BOOL replacementAllowed = replacementRoute != VCAMReplacementRouteNone;
    switch (replacementRoute) {
        case VCAMReplacementRouteCameraSourceVideo:
            notify_post("com.codex.vcam.ios18.route.camsrc"); break;
        case VCAMReplacementRouteVideoConverter:
            notify_post("com.codex.vcam.ios18.route.converter"); break;
        case VCAMReplacementRouteCameraPreview:
            notify_post("com.codex.vcam.ios18.route.preview"); break;
        case VCAMReplacementRouteVideoRecording:
            notify_post("com.codex.vcam.ios18.route.recording"); break;
        case VCAMReplacementRouteStillPhoto:
            notify_post("com.codex.vcam.ios18.route.still"); break;
        case VCAMReplacementRoutePhotoEncoder:
            notify_post("com.codex.vcam.ios18.route.photo-encoder"); break;
        default:
            notify_post("com.codex.vcam.ios18.route.other"); break;
    }
    if (replacementRoute == VCAMReplacementRouteStillPhoto ||
        replacementRoute == VCAMReplacementRoutePhotoEncoder) {
        VCAMStripVirtualPhotoGainMap(sampleBuffer, originalImageBuffer);
    }
    BOOL photoEncodedSurfaceReplaced = replacementRoute ==
        VCAMReplacementRoutePhotoEncoder
        ? VCAMReplacePhotoEncodedSurface(sampleBuffer) : NO;
    VCAMLogOutputSignature(self, sampleBuffer, originalImageBuffer, replacementRoute);
    if (originalImageBuffer == NULL) {
        static volatile int nullBuffers = 0;
        int nullBufferCount = __sync_add_and_fetch(&nullBuffers, 1);
        if (nullBufferCount <= 3) VCAMRefLog("emitSampleBuffer video buffer NULL");
        if (replacementAllowed && VCAMVirtualModeIsEnabled() &&
            !photoEncodedSurfaceReplaced) {
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

    BOOL replacementSucceeded = NO;
    @try {
        replacementSucceeded = VCAMReplaceSampleBufferInPlace(
            sampleBuffer,
            VCAMPresentationForReplacementRoute(replacementRoute),
            replacementRoute);
    } @catch (NSException *exception) {
        static dispatch_once_t exceptionToken;
        dispatch_once(&exceptionToken, ^{
            VCAMRefLog([NSString stringWithFormat:@"replacement render exception %@",
                exception.name].UTF8String);
        });
        replacementSucceeded = NO;
    }

    BOOL virtualModeEnabled = VCAMVirtualModeIsEnabled();
    if (!replacementSucceeded && virtualModeEnabled &&
        !photoEncodedSurfaceReplaced) {
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
        return;
    }
    // cameracaptured accepts the original graph-owned sample, not a VCAM-built
    // sample with a copied format description. The helper above has already
    // rendered in place or copied a compressed clone back into its image buffer.
    %orig(sampleBuffer);
}

%end

%ctor {
    VCAMRuntimePublishConstructor();
    VCAMRefLog("ctor: VCAMMediaServerRefEntry loaded");
    char message[160] = {0};
    snprintf(message, sizeof(message),
             "ctor hook targets available photoEncoder=%d remoteQueue=%d nodeOutput=%d",
             objc_getClass("BWPhotoEncoderNode") != Nil,
             objc_getClass("BWRemoteQueueSinkNode") != Nil,
             objc_getClass("BWNodeOutput") != Nil);
    VCAMRefLog(message);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            loadReplacementMedia();
            VCAMRefLog("ctor: replacement renderer initialized");
        }
    });
}

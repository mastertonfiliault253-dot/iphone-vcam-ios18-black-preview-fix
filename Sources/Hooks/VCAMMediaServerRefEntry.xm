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

static BOOL VCAMMatchesValidatedReplacementOutput(CVPixelBufferRef pixelBuffer) {
    if (!VCAMTargetBufferIsSupported(pixelBuffer)) return NO;
    // This is the only consumer-facing output shape already proven on this
    // device. Unknown Camera/WebRTC outputs are logged but fail open until their
    // stable signature and synchronous render cost have been measured.
    return CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA &&
        CVPixelBufferGetWidth(pixelBuffer) == 750 &&
        CVPixelBufferGetHeight(pixelBuffer) == 1334;
}

static void VCAMLogOutputSignature(id output, CMSampleBufferRef sampleBuffer,
                                   CVPixelBufferRef pixelBuffer, BOOL replacementAllowed) {
    CMFormatDescriptionRef description = CMSampleBufferGetFormatDescription(sampleBuffer);
    OSType subtype = description == NULL ? 0 : CMFormatDescriptionGetMediaSubType(description);
    OSType pixelFormat = pixelBuffer == NULL ? 0 : CVPixelBufferGetPixelFormatType(pixelBuffer);
    size_t width = pixelBuffer == NULL ? 0 : CVPixelBufferGetWidth(pixelBuffer);
    size_t height = pixelBuffer == NULL ? 0 : CVPixelBufferGetHeight(pixelBuffer);
    NSString *basicSignature = [NSString stringWithFormat:@"%zu/%zu/%u/%u/%d/%d",
        width, height, pixelFormat, subtype,
        CMSampleBufferGetDataBuffer(sampleBuffer) != NULL, replacementAllowed];
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
             "output signature output=%p outputClass=%s outputName=%s node=%p nodeClass=%s nodeName=%s size=%zux%zu pixel=%s/%08x subtype=%s/%08x planes=%zu data=%d supported=%d allowed=%d",
             output, outputClass.UTF8String, outputName.UTF8String, node,
             nodeClass.UTF8String, nodeName.UTF8String,
             width, height, pixelFourCC, pixelFormat, subtypeFourCC, subtype,
             pixelBuffer == NULL ? 0 : CVPixelBufferGetPlaneCount(pixelBuffer),
             CMSampleBufferGetDataBuffer(sampleBuffer) != NULL,
             VCAMTargetBufferIsSupported(pixelBuffer), replacementAllowed);
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

    CVPixelBufferRef originalImageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    BOOL replacementAllowed = VCAMMatchesValidatedReplacementOutput(originalImageBuffer);
    VCAMLogOutputSignature(self, sampleBuffer, originalImageBuffer, replacementAllowed);
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
        snprintf(msg, sizeof(msg), "emitSampleBuffer video count=%d size=%zux%zu format=%s/%08x",
                 videoSampleCount, CVPixelBufferGetWidth(originalImageBuffer),
                 CVPixelBufferGetHeight(originalImageBuffer), format, pixelFormat);
        VCAMRefLog(msg);
    }

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        VCAMRefLog("first video sample: loading replacement media");
        loadReplacementMedia();
        VCAMRefLog("loadReplacementMedia finished");
    });

    @autoreleasepool {
        @try {
            (void)drawReplacementOntoBuffer(originalImageBuffer);
        } @catch (NSException *exception) {
            static dispatch_once_t exceptionToken;
            dispatch_once(&exceptionToken, ^{
                VCAMRefLog([NSString stringWithFormat:@"replacement render exception %@",
                    exception.name].UTF8String);
            });
        }
    }

    %orig(sampleBuffer);
}

%end

%ctor {
    VCAMRefLog("ctor: VCAMMediaServerRefEntry loaded");
}

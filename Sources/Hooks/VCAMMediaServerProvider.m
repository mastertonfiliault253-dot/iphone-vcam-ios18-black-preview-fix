#import "VCAMMediaServerProvider.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <objc/runtime.h>
#import <math.h>
#import "../Core/VCAMConfiguration.h"

@interface VCAMMediaServerProvider : NSObject
@end

@implementation VCAMMediaServerProvider

+ (instancetype)sharedProvider {
    static VCAMMediaServerProvider *provider;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ provider = [VCAMMediaServerProvider new]; });
    return provider;
}

@end

static CIContext *VCAMSharedCIContext(void) {
    static CIContext *context;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        context = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}];
    });
    return context;
}

static CGColorSpaceRef VCAMSharedColorSpace(void) {
    static CGColorSpaceRef colorSpace;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ colorSpace = CGColorSpaceCreateDeviceRGB(); });
    return colorSpace;
}

@interface VCAMMediaServerProviderState : NSObject
@property(nonatomic) BOOL enabled;
@property(nonatomic, copy, nullable) NSString *mediaPath;
@property(nonatomic) NSInteger rotationDegrees;
@property(nonatomic) BOOL mirrorHorizontally;
@property(nonatomic) VCAMContentMode contentMode;
@property(nonatomic) BOOL videoMode;
@property(nonatomic, assign, nullable) CGImageRef replacementImage;
@property(nonatomic, strong, nullable) AVAssetReader *reader;
@property(nonatomic, strong, nullable) AVAssetReaderTrackOutput *videoOutput;
@property(nonatomic) CGAffineTransform videoTransform;
@property(nonatomic, copy, nullable) NSString *loadedPath;
@end

@implementation VCAMMediaServerProviderState
@end

static VCAMMediaServerProviderState *VCAMCurrentState(void) {
    static VCAMMediaServerProviderState *state;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        state = [VCAMMediaServerProviderState new];
        state.contentMode = VCAMContentModeAspectFill;
        state.videoTransform = CGAffineTransformIdentity;
    });
    return state;
}

static void VCAMResetMedia(VCAMMediaServerProviderState *state) {
    [state.reader cancelReading];
    state.reader = nil;
    state.videoOutput = nil;
    state.videoMode = NO;
    if (state.replacementImage != NULL) {
        CGImageRelease(state.replacementImage);
        state.replacementImage = NULL;
    }
    state.loadedPath = nil;
}

static BOOL VCAMLoadImageMedia(VCAMMediaServerProviderState *state) {
    NSURL *url = [NSURL fileURLWithPath:state.mediaPath];
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (source == NULL) return NO;
    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    CFRelease(source);
    if (image == NULL) return NO;
    state.replacementImage = image;
    state.videoMode = NO;
    return YES;
}

static BOOL VCAMLoadVideoMedia(VCAMMediaServerProviderState *state) {
    NSURL *url = [NSURL fileURLWithPath:state.mediaPath];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    AVAssetTrack *videoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    if (videoTrack == nil) return NO;
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:nil];
    if (reader == nil) return NO;
    NSDictionary *outputSettings = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    AVAssetReaderTrackOutput *output = [AVAssetReaderTrackOutput
        assetReaderTrackOutputWithTrack:videoTrack outputSettings:outputSettings];
    output.alwaysCopiesSampleData = NO;
    if (![reader canAddOutput:output]) return NO;
    [reader addOutput:output];
    if (![reader startReading]) return NO;
    state.reader = reader;
    state.videoOutput = output;
    state.videoTransform = videoTrack.preferredTransform;
    state.videoMode = YES;
    return YES;
}

static BOOL VCAMEnsureMediaLoaded(VCAMMediaServerProviderState *state) {
    NSDictionary *values = [VCAMConfiguration currentValues];
    BOOL enabled = [values[@"enabled"] boolValue] && [values[@"injectionMediaServerEnabled"] boolValue];
    NSString *source = [values[@"source"] lowercaseString];
    NSString *path = [values[@"mediaPath"] isKindOfClass:NSString.class] ? values[@"mediaPath"] : nil;
    BOOL localRequested = enabled && [source isEqualToString:@"local"] && path.length > 0;

    if (!localRequested) {
        if (state.enabled || state.loadedPath != nil) VCAMResetMedia(state);
        state.enabled = NO;
        return NO;
    }

    state.enabled = YES;
    state.rotationDegrees = [values[@"rotationDegrees"] integerValue] % 360;
    state.mirrorHorizontally = [values[@"mirrorHorizontally"] boolValue];
    NSString *contentMode = [values[@"contentMode"] lowercaseString];
    if ([contentMode isEqualToString:@"fit"]) {
        state.contentMode = VCAMContentModeAspectFit;
    } else if ([contentMode isEqualToString:@"stretch"]) {
        state.contentMode = VCAMContentModeStretch;
    } else {
        state.contentMode = VCAMContentModeAspectFill;
    }

    if (![state.mediaPath isEqualToString:path] || ![state.loadedPath isEqualToString:path]) {
        state.mediaPath = [path copy];
        VCAMResetMedia(state);
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            NSString *extension = path.pathExtension.lowercaseString;
            if ([@[@"png", @"jpg", @"jpeg", @"heic", @"gif"] containsObject:extension]) {
                VCAMLoadImageMedia(state);
            } else {
                VCAMLoadVideoMedia(state);
            }
        }
        if (state.videoMode || state.replacementImage != NULL) {
            state.loadedPath = [path copy];
        }
    }
    return state.videoMode || state.replacementImage != NULL;
}

static CVPixelBufferRef VCAMCopyNextVideoPixelBuffer(VCAMMediaServerProviderState *state) {
    CMSampleBufferRef sample = [state.videoOutput copyNextSampleBuffer];
    if (sample == NULL) {
        NSString *path = state.mediaPath;
        VCAMResetMedia(state);
        state.mediaPath = path;
        if (!VCAMLoadVideoMedia(state)) return NULL;
        sample = [state.videoOutput copyNextSampleBuffer];
    }
    if (sample == NULL) return NULL;
    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sample);
    CVPixelBufferRef retained = pixelBuffer == NULL ? NULL : CVPixelBufferRetain(pixelBuffer);
    CFRelease(sample);
    return retained;
}

static CIImage *VCAMTransformedReplacement(CIImage *image,
                                           CGRect target,
                                           NSInteger rotationDegrees,
                                           BOOL mirrorHorizontally,
                                           VCAMContentMode contentMode) {
    CGRect extent = image.extent;
    CGAffineTransform transform = CGAffineTransformIdentity;
    transform = CGAffineTransformTranslate(transform, -CGRectGetMidX(extent), -CGRectGetMidY(extent));
    if (rotationDegrees != 0) {
        transform = CGAffineTransformRotate(transform, rotationDegrees * M_PI / 180.0);
    }
    if (mirrorHorizontally) {
        transform = CGAffineTransformScale(transform, -1.0, 1.0);
    }
    CIImage *result = [image imageByApplyingTransform:transform];
    CGRect transformedExtent = result.extent;

    CGFloat sx = CGRectGetWidth(target) / MAX(1.0, CGRectGetWidth(transformedExtent));
    CGFloat sy = CGRectGetHeight(target) / MAX(1.0, CGRectGetHeight(transformedExtent));
    if (contentMode == VCAMContentModeAspectFit) {
        sx = sy = MIN(sx, sy);
    } else if (contentMode == VCAMContentModeAspectFill) {
        sx = sy = MAX(sx, sy);
    }
    result = [result imageByApplyingTransform:CGAffineTransformMakeScale(sx, sy)];
    CGRect scaled = result.extent;
    CGFloat tx = CGRectGetMidX(target) - CGRectGetMidX(scaled);
    CGFloat ty = CGRectGetMidY(target) - CGRectGetMidY(scaled);
    result = [result imageByApplyingTransform:CGAffineTransformMakeTranslation(tx, ty)];
    if (contentMode == VCAMContentModeAspectFit) {
        CIImage *background = [CIImage imageWithColor:CIColor.blackColor];
        result = [result imageByCompositingOverImage:[background imageByCroppingToRect:target]];
    }
    return [result imageByCroppingToRect:target];
}

BOOL VCAMMediaServerReplacementDrawsIntoBuffer(CVPixelBufferRef targetBuffer) {
    if (targetBuffer == NULL) return NO;
    VCAMMediaServerProviderState *state = VCAMCurrentState();
    @synchronized (state) {
        @autoreleasepool {
            if (!VCAMEnsureMediaLoaded(state)) return NO;

            CIImage *replacement = nil;
            if (state.videoMode) {
                CVPixelBufferRef frame = VCAMCopyNextVideoPixelBuffer(state);
                if (frame == NULL) return NO;
                replacement = [CIImage imageWithCVPixelBuffer:frame];
                CVPixelBufferRelease(frame);
            } else if (state.replacementImage != NULL) {
                replacement = [CIImage imageWithCGImage:state.replacementImage];
            }
            if (replacement == nil) return NO;

            if (!CGAffineTransformIsIdentity(state.videoTransform)) {
                replacement = [replacement imageByApplyingTransform:state.videoTransform];
            }

            size_t width = CVPixelBufferGetWidth(targetBuffer);
            size_t height = CVPixelBufferGetHeight(targetBuffer);
            CGRect target = CGRectMake(0, 0, (CGFloat)width, (CGFloat)height);
            CIImage *final = VCAMTransformedReplacement(replacement, target,
                                                        state.rotationDegrees,
                                                        state.mirrorHorizontally,
                                                        state.contentMode);
            if (final == nil) return NO;

            CVPixelBufferLockBaseAddress(targetBuffer, 0);
            [VCAMSharedCIContext() render:final
                          toCVPixelBuffer:targetBuffer
                                   bounds:target
                               colorSpace:VCAMSharedColorSpace()];
            CVPixelBufferUnlockBaseAddress(targetBuffer, 0);
            return YES;
        }
    }
}
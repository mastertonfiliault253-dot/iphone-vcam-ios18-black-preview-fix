#import "VCAMFrameProducer.h"

#import "../Core/VCAMConfiguration.h"
#import "../Core/VCAMFrameRenderer.h"
#import "../Core/VCAMMediaSource.h"
#import "../Sources/VCAMLocalMediaSource.h"
#import "../Sources/VCAMOBSStreamSource.h"
#import "../Sources/VCAMRTSPStreamSource.h"

#include <unistd.h>

static const char *const VCAMLegacyHLSDaemonMarker =
    "/var/tmp/vcam-hls-legacy-vcamd.enable";

static BOOL VCAMObjectsEqual(id left, id right) {
    return left == right || (left != nil && [left isEqual:right]);
}

static BOOL VCAMConfigurationsProduceSameFrames(VCAMConfiguration *left,
                                                VCAMConfiguration *right) {
    if (left == nil || right == nil) return NO;
    return left.enabled == right.enabled &&
        left.replaceAudio == right.replaceAudio &&
        left.loopMedia == right.loopMedia &&
        left.mirrorHorizontally == right.mirrorHorizontally &&
        left.rotationDegrees == right.rotationDegrees &&
        left.sourceKind == right.sourceKind &&
        left.contentMode == right.contentMode &&
        left.preferredFramesPerSecond == right.preferredFramesPerSecond &&
        left.localDecoderMode == right.localDecoderMode &&
        VCAMObjectsEqual(left.mediaPath, right.mediaPath) &&
        VCAMObjectsEqual(left.obsWebSocketURL, right.obsWebSocketURL) &&
        VCAMObjectsEqual(left.rtspURL, right.rtspURL) &&
        VCAMObjectsEqual(left.hlsURL, right.hlsURL);
}

@interface VCAMFrameProducer () {
    CMSampleBufferRef _templateSample;
    CGSize _templateSize;
}
@property(nonatomic, strong) VCAMConfiguration *configuration;
@property(nonatomic, strong) VCAMFrameRenderer *renderer;
@property(nonatomic, strong, nullable) id<VCAMMediaSource> source;
@property(nonatomic, strong) dispatch_queue_t stateQueue;
@end

@implementation VCAMFrameProducer

- (instancetype)init {
    self = [super init];
    if (self) {
        _renderer = [VCAMFrameRenderer new];
        _stateQueue = dispatch_queue_create("com.codex.vcamd.producer", DISPATCH_QUEUE_SERIAL);
        [self reload];
    }
    return self;
}

- (void)dealloc {
    [self.source stop];
    if (_templateSample != NULL) CFRelease(_templateSample);
}

- (void)reload {
    dispatch_sync(self.stateQueue, ^{
        VCAMConfiguration *nextConfiguration = [VCAMConfiguration loadCurrent];
        BOOL sourceHealthy = self.source != nil || !nextConfiguration.enabled ||
            nextConfiguration.sourceKind == VCAMSourceKindCamera;
        if (sourceHealthy &&
            VCAMConfigurationsProduceSameFrames(self.configuration, nextConfiguration)) {
            [VCAMConfiguration appendProcessLog:@"vcamd reload skipped unchanged media configuration"];
            return;
        }
        [self.source stop];
        self.source = nil;
        if (self->_templateSample != NULL) {
            CFRelease(self->_templateSample);
            self->_templateSample = NULL;
        }
        self->_templateSize = CGSizeZero;
        self.configuration = nextConfiguration;
        if (!self.configuration.enabled || self.configuration.sourceKind == VCAMSourceKindCamera) return;
        switch (self.configuration.sourceKind) {
            case VCAMSourceKindLocalMedia:
                self.source = [[VCAMLocalMediaSource alloc] initWithConfiguration:self.configuration
                                                                          renderer:self.renderer];
                break;
            case VCAMSourceKindOBSWebSocket:
                self.source = [[VCAMOBSStreamSource alloc] initWithConfiguration:self.configuration
                                                                          renderer:self.renderer];
                break;
            case VCAMSourceKindRTSP:
                self.source = [[VCAMRTSPStreamSource alloc] initWithConfiguration:self.configuration
                                                                          renderer:self.renderer];
                break;
            case VCAMSourceKindHLS:
                // SpringBoard owns the production AVPlayer HLS path. Retain
                // the previous daemon decoder as an explicit rollback only.
                if (access(VCAMLegacyHLSDaemonMarker, F_OK) == 0) {
                    self.source = [[VCAMRTSPStreamSource alloc]
                        initWithConfiguration:self.configuration renderer:self.renderer];
                }
                break;
            case VCAMSourceKindCamera:
                break;
        }
        NSError *error = nil;
        if (![self.source start:&error]) self.source = nil;
        [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
            @"vcamd reload source=%ld enabled=%d started=%d error=%@",
            (long)self.configuration.sourceKind, self.configuration.enabled,
            self.source != nil, error.localizedDescription ?: @"(none)"]];
    });
}

- (BOOL)isEnabled {
    __block BOOL enabled = NO;
    // This reports the user's requested virtual-camera mode, not decoder
    // health. A missing/reconnecting source must keep mediaserverd fail-closed.
    dispatch_sync(self.stateQueue, ^{ enabled = self.configuration.enabled; });
    return enabled;
}

- (NSInteger)preferredFramesPerSecond {
    __block NSInteger framesPerSecond = 30;
    dispatch_sync(self.stateQueue, ^{ framesPerSecond = self.configuration.preferredFramesPerSecond; });
    return MAX(1, MIN(60, framesPerSecond));
}

- (CMSampleBufferRef)copyTemplateForSize:(CGSize)size {
    size_t width = (size_t)MAX(1.0, round(size.width));
    size_t height = (size_t)MAX(1.0, round(size.height));
    if (_templateSample == NULL || (size_t)_templateSize.width != width ||
        (size_t)_templateSize.height != height) {
        if (_templateSample != NULL) CFRelease(_templateSample);
        _templateSample = NULL;
        _templateSize = CGSizeMake(width, height);
        CVPixelBufferRef pixelBuffer = NULL;
        NSDictionary *attributes = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferWidthKey: @(width),
            (id)kCVPixelBufferHeightKey: @(height),
            (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
            (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
        };
        if (CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                kCVPixelFormatType_32BGRA,
                                (__bridge CFDictionaryRef)attributes,
                                &pixelBuffer) != kCVReturnSuccess) return NULL;
        CMVideoFormatDescriptionRef format = NULL;
        CMSampleTimingInfo timing = {
            .duration = CMTimeMake(1, (int32_t)MAX(1, self.configuration.preferredFramesPerSecond)),
            .presentationTimeStamp = kCMTimeZero,
            .decodeTimeStamp = kCMTimeInvalid,
        };
        if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer,
                                                         &format) == noErr) {
            CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, true,
                                               NULL, NULL, format, &timing, &_templateSample);
        }
        if (format != NULL) CFRelease(format);
        CVPixelBufferRelease(pixelBuffer);
    }
    if (_templateSample == NULL) return NULL;
    CMSampleTimingInfo timing = {
        .duration = CMTimeMake(1, (int32_t)MAX(1, self.configuration.preferredFramesPerSecond)),
        .presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock()),
        .decodeTimeStamp = kCMTimeInvalid,
    };
    CMSampleBufferRef result = NULL;
    CMSampleBufferCreateCopyWithNewTiming(kCFAllocatorDefault, _templateSample, 1,
                                          &timing, &result);
    return result;
}

- (CMSampleBufferRef)copyFrameForSize:(CGSize)size {
    __block CMSampleBufferRef result = NULL;
    dispatch_sync(self.stateQueue, ^{
        if (self.source == nil) return;
        CMSampleBufferRef template = [self copyTemplateForSize:size];
        if (template != NULL) {
            result = [self.source copyVideoSampleForTemplate:template];
            CFRelease(template);
        }
    });
    return result;
}

@end

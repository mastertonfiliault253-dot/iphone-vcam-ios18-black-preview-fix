#import "VCAMFramePipeline.h"
#import <QuartzCore/QuartzCore.h>
#import "VCAMConfiguration.h"
#import "VCAMAssetWriterRecorder.h"
#import "VCAMFrameRenderer.h"
#import "VCAMMediaSource.h"
#import "VCAMPhotoAuxiliaryData.h"
#import "../Sources/VCAMLocalMediaSource.h"
#import "../Sources/VCAMOBSStreamSource.h"

@interface VCAMFramePipeline () {
    CMSampleBufferRef _latestVideoSample;
    CFTimeInterval _latestVideoHostTime;
}
@property(nonatomic, strong) VCAMConfiguration *configuration;
@property(nonatomic, strong) VCAMFrameRenderer *renderer;
@property(nonatomic, strong, nullable) id<VCAMMediaSource> source;
@property(nonatomic, strong) VCAMPhotoAuxiliaryData *photoAuxiliaryData;
@property(nonatomic, strong) VCAMAssetWriterRecorder *recorder;
@property(nonatomic, strong) dispatch_queue_t stateQueue;
@end

@implementation VCAMFramePipeline

+ (instancetype)sharedPipeline {
    static VCAMFramePipeline *pipeline;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ pipeline = [VCAMFramePipeline new]; });
    return pipeline;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _renderer = [VCAMFrameRenderer new];
        _recorder = [VCAMAssetWriterRecorder new];
        _stateQueue = dispatch_queue_create("com.codex.vcam.pipeline", DISPATCH_QUEUE_SERIAL);
        [self reloadConfiguration];
    }
    return self;
}

- (void)reloadConfiguration {
    dispatch_sync(self.stateQueue, ^{
        [self.source stop];
        self.source = nil;
        if (self->_latestVideoSample != NULL) {
            CFRelease(self->_latestVideoSample);
            self->_latestVideoSample = NULL;
        }
        self.configuration = [VCAMConfiguration loadCurrent];
        self.photoAuxiliaryData = [[VCAMPhotoAuxiliaryData alloc] initWithConfiguration:self.configuration];
        if (!self.configuration.enabled) return;

        switch (self.configuration.sourceKind) {
            case VCAMSourceKindLocalMedia:
                self.source = [[VCAMLocalMediaSource alloc] initWithConfiguration:self.configuration
                                                                          renderer:self.renderer];
                break;
            case VCAMSourceKindOBSWebSocket:
                self.source = [[VCAMOBSStreamSource alloc] initWithConfiguration:self.configuration
                                                                          renderer:self.renderer];
                break;
            case VCAMSourceKindCamera:
                return;
        }
        NSError *error = nil;
        if (![self.source start:&error]) {
            NSLog(@"[VCAM] Media source failed to start: %@", error);
            self.source = nil;
        }
    });
}

- (BOOL)isEnabled {
    __block BOOL enabled;
    dispatch_sync(self.stateQueue, ^{ enabled = self.configuration.enabled && self.source != nil; });
    return enabled;
}

- (CMSampleBufferRef)copyReplacementVideoForSample:(CMSampleBufferRef)sample {
    __block CMSampleBufferRef replacement = NULL;
    dispatch_sync(self.stateQueue, ^{
        replacement = [self.source copyVideoSampleForTemplate:sample];
        if (replacement != NULL) {
            [self rememberVideoSample:replacement];
            [self.recorder appendVideoSample:replacement];
        }
    });
    return replacement;
}

- (void)rememberVideoSample:(CMSampleBufferRef)sample {
    if (_latestVideoSample != NULL) CFRelease(_latestVideoSample);
    _latestVideoSample = NULL;
    CMSampleBufferCreateCopy(kCFAllocatorDefault, sample, &_latestVideoSample);
    _latestVideoHostTime = CACurrentMediaTime();
}

- (CMSampleBufferRef)copyPreviewVideoForSize:(CGSize)size {
    __block CMSampleBufferRef result = NULL;
    dispatch_sync(self.stateQueue, ^{
        if (self->_latestVideoSample != NULL && CACurrentMediaTime() - self->_latestVideoHostTime < 0.20) {
            CMSampleBufferCreateCopy(kCFAllocatorDefault, self->_latestVideoSample, &result);
            return;
        }
        if (self.source == nil || size.width < 1 || size.height < 1) return;

        CVPixelBufferRef pixelBuffer = NULL;
        NSDictionary *attributes = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferWidthKey: @((NSInteger)size.width),
            (id)kCVPixelBufferHeightKey: @((NSInteger)size.height),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        };
        if (CVPixelBufferCreate(kCFAllocatorDefault, (size_t)size.width, (size_t)size.height,
                                kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attributes,
                                &pixelBuffer) != kCVReturnSuccess) return;

        CMVideoFormatDescriptionRef format = NULL;
        CMSampleBufferRef template = NULL;
        CMSampleTimingInfo timing = {
            .duration = CMTimeMake(1, (int32_t)self.configuration.preferredFramesPerSecond),
            .presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock()),
            .decodeTimeStamp = kCMTimeInvalid,
        };
        if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &format) == noErr) {
            CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, true, NULL, NULL,
                                               format, &timing, &template);
        }
        if (template != NULL) {
            result = [self.source copyVideoSampleForTemplate:template];
            if (result != NULL) {
                [self rememberVideoSample:result];
                [self.recorder appendVideoSample:result];
            }
            CFRelease(template);
        }
        if (format != NULL) CFRelease(format);
        CVPixelBufferRelease(pixelBuffer);
    });
    return result;
}

- (CMSampleBufferRef)copyReplacementAudioForSample:(CMSampleBufferRef)sample {
    __block CMSampleBufferRef replacement = NULL;
    dispatch_sync(self.stateQueue, ^{
        replacement = [self.source copyAudioSampleForTemplate:sample];
    });
    return replacement;
}

- (AVDepthData *)replacementDepthData {
    __block AVDepthData *depthData;
    dispatch_sync(self.stateQueue, ^{ depthData = [self.photoAuxiliaryData replacementDepthData]; });
    return depthData;
}

- (NSDictionary<NSString *,id> *)replacementPhotoMetadataForOriginal:(NSDictionary<NSString *,id> *)original {
    __block NSDictionary *metadata;
    dispatch_sync(self.stateQueue, ^{
        metadata = [self.photoAuxiliaryData metadataByMergingOriginal:original];
    });
    return metadata;
}

- (NSData *)pairedLivePhotoStillData {
    __block NSData *data;
    dispatch_sync(self.stateQueue, ^{ data = [self.photoAuxiliaryData pairedLivePhotoStillData]; });
    return data;
}

- (NSString *)pairedLivePhotoMoviePath {
    __block NSString *path;
    dispatch_sync(self.stateQueue, ^{ path = [self.photoAuxiliaryData pairedLivePhotoMoviePath]; });
    return path;
}

- (NSString *)localRecordingReplacementPath {
    __block NSString *path;
    dispatch_sync(self.stateQueue, ^{
        VCAMLocalMediaSource *localSource =
            [self.source isKindOfClass:VCAMLocalMediaSource.class] ? (VCAMLocalMediaSource *)self.source : nil;
        if (self.configuration.enabled && [localSource hasVideoAsset]) {
            path = self.configuration.mediaPath;
        }
    });
    return path;
}

- (BOOL)shouldEncodeRecording {
    if (!self.configuration.enabled) return NO;
    if (self.configuration.sourceKind == VCAMSourceKindOBSWebSocket) return YES;
    VCAMLocalMediaSource *localSource =
        [self.source isKindOfClass:VCAMLocalMediaSource.class] ? (VCAMLocalMediaSource *)self.source : nil;
    return localSource != nil && ![localSource hasVideoAsset];
}

- (void)startReplacementRecording {
    dispatch_sync(self.stateQueue, ^{
        if ([self shouldEncodeRecording]) [self.recorder start];
    });
}

- (NSURL *)finishReplacementRecording {
    __block BOOL shouldFinish;
    dispatch_sync(self.stateQueue, ^{
        shouldFinish = [self shouldEncodeRecording];
    });
    return shouldFinish ? [self.recorder finishAndWait:5.0] : nil;
}

@end

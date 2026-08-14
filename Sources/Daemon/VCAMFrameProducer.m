#import "VCAMFrameProducer.h"

#import "../Core/VCAMConfiguration.h"
#import "../Core/VCAMFrameRenderer.h"
#import "../Core/VCAMMediaSource.h"
#import "../Sources/VCAMLocalMediaSource.h"
#import "../Sources/VCAMOBSStreamSource.h"
#import "../Sources/VCAMRTSPStreamSource.h"
#import "../Shared/VCAMSharedFrame.h"

#include <unistd.h>

static const char *const VCAMLegacyHLSDaemonMarker =
    "/var/tmp/vcam-hls-legacy-vcamd.enable";
static const char *const VCAMSpringBoardRTSPMarker =
    "/var/tmp/vcam-rtsp-springboard-vt.enable";
static const char *const VCAMLegacyLocalVideoDaemonMarker =
    "/var/tmp/vcam-local-video-legacy-vcamd.enable";
static const char *const VCAMLegacyLocalImageDaemonMarker =
    "/var/tmp/vcam-local-image-legacy-vcamd.enable";

static BOOL VCAMLocalMediaPathIsVideo(NSString *path) {
    NSString *extension = path.pathExtension.lowercaseString;
    return [@[@"mov", @"mp4", @"m4v"] containsObject:extension];
}

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
            case VCAMSourceKindLocalMedia: {
                // SpringBoard owns production local-video playback through the
                // same AVPlayer/NV12/Metal path as HLS. Keep the old daemon
                // reader behind an explicit on-device rollback marker.
                BOOL localVideo = VCAMLocalMediaPathIsVideo(
                    self.configuration.mediaPath);
                BOOL daemonRollback = localVideo
                    ? access(VCAMLegacyLocalVideoDaemonMarker, F_OK) == 0
                    : access(VCAMLegacyLocalImageDaemonMarker, F_OK) == 0;
                if (daemonRollback) {
                    self.source = [[VCAMLocalMediaSource alloc]
                        initWithConfiguration:self.configuration renderer:self.renderer];
                }
                break;
            }
            case VCAMSourceKindOBSWebSocket:
                self.source = [[VCAMOBSStreamSource alloc] initWithConfiguration:self.configuration
                                                                          renderer:self.renderer];
                break;
            case VCAMSourceKindRTSP:
                // Daemon software decode is the default RTSP path. SpringBoard's
                // direct-VT decoder is an opt-in experiment behind a marker.
                if (access(VCAMSpringBoardRTSPMarker, F_OK) != 0) {
                    self.source = [[VCAMRTSPStreamSource alloc] initWithConfiguration:self.configuration
                                                                              renderer:self.renderer];
                }
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

- (BOOL)usesNativeSurfaceTransport {
    __block BOOL enabled = NO;
    dispatch_sync(self.stateQueue, ^{
        BOOL nativeRTSP = self.configuration.sourceKind == VCAMSourceKindRTSP &&
            [self.source isKindOfClass:VCAMRTSPStreamSource.class];
        BOOL nativeOBS = self.configuration.sourceKind == VCAMSourceKindOBSWebSocket &&
            [self.source isKindOfClass:VCAMOBSStreamSource.class];
        BOOL nativeStill = self.configuration.sourceKind == VCAMSourceKindLocalMedia &&
            !VCAMLocalMediaPathIsVideo(self.configuration.mediaPath) &&
            [self.source isKindOfClass:VCAMLocalMediaSource.class];
        enabled = self.configuration.enabled &&
            (nativeOBS || nativeRTSP || nativeStill);
    });
    return enabled;
}

- (uint32_t)nativeSurfaceSlotCount {
    __block uint32_t slotCount = VCAMSharedFrameSlotCount;
    dispatch_sync(self.stateQueue, ^{
        if (self.configuration.sourceKind == VCAMSourceKindLocalMedia &&
            !VCAMLocalMediaPathIsVideo(self.configuration.mediaPath) &&
            [self.source isKindOfClass:VCAMLocalMediaSource.class]) {
            slotCount = 1;
        }
    });
    return slotCount;
}

- (CGSize)nativeStillImageSize {
    __block CGSize size = CGSizeZero;
    dispatch_sync(self.stateQueue, ^{
        if (self.configuration.sourceKind == VCAMSourceKindLocalMedia &&
            !VCAMLocalMediaPathIsVideo(self.configuration.mediaPath) &&
            [self.source isKindOfClass:VCAMLocalMediaSource.class]) {
            size = [(VCAMLocalMediaSource *)self.source orientedStillImageSize];
        }
    });
    return size;
}

- (BOOL)renderNativeStillImageIntoPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    __block BOOL rendered = NO;
    dispatch_sync(self.stateQueue, ^{
        if (self.configuration.sourceKind == VCAMSourceKindLocalMedia &&
            !VCAMLocalMediaPathIsVideo(self.configuration.mediaPath) &&
            [self.source isKindOfClass:VCAMLocalMediaSource.class]) {
            rendered = [(VCAMLocalMediaSource *)self.source
                renderStillImageIntoPixelBuffer:pixelBuffer];
        }
    });
    return rendered;
}

- (CVPixelBufferRef)copyNativePixelBufferForSurface {
    __block CVPixelBufferRef pixelBuffer = NULL;
    dispatch_sync(self.stateQueue, ^{
        if (self.configuration.sourceKind == VCAMSourceKindOBSWebSocket &&
            [self.source isKindOfClass:VCAMOBSStreamSource.class]) {
            VCAMOBSStreamSource *obs = (VCAMOBSStreamSource *)self.source;
            CGImageRef image = [obs copyLatestImage];
            CGSize size = image == NULL ? CGSizeZero : CGSizeMake(
                CGImageGetWidth(image), CGImageGetHeight(image));
            NSInteger rotation = ((self.configuration.rotationDegrees % 360) + 360) % 360;
            if (rotation == 90 || rotation == 270) {
                size = CGSizeMake(size.height, size.width);
            }
            CMSampleBufferRef template = CGSizeEqualToSize(size, CGSizeZero)
                ? NULL : [self copyTemplateForSize:size];
            CMSampleBufferRef sample = template == NULL ? NULL
                : [self.renderer copySampleFromCGImage:image
                                       sourceTransform:CGAffineTransformIdentity
                                              template:template
                                         configuration:self.configuration];
            CVPixelBufferRef imageBuffer = sample == NULL ? NULL
                : CMSampleBufferGetImageBuffer(sample);
            if (imageBuffer != NULL) pixelBuffer = CVPixelBufferRetain(imageBuffer);
            if (sample != NULL) CFRelease(sample);
            if (template != NULL) CFRelease(template);
            if (image != NULL) CGImageRelease(image);
        } else if (self.configuration.sourceKind == VCAMSourceKindRTSP &&
            [self.source isKindOfClass:VCAMRTSPStreamSource.class]) {
            VCAMRTSPStreamSource *rtsp = (VCAMRTSPStreamSource *)self.source;
            CVPixelBufferRef native = [rtsp copyNativePixelBufferForSurface];
            NSInteger rotation = ((self.configuration.rotationDegrees % 360) + 360) % 360;
            BOOL needsTransform = self.configuration.mirrorHorizontally || rotation != 0;
            if (native != NULL && needsTransform) {
                size_t width = CVPixelBufferGetWidth(native);
                size_t height = CVPixelBufferGetHeight(native);
                CGSize outputSize = rotation == 90 || rotation == 270
                    ? CGSizeMake(height, width) : CGSizeMake(width, height);
                CMSampleBufferRef template = [self copyTemplateForSize:outputSize];
                CMSampleBufferRef sample = template == NULL ? NULL
                    : [self.renderer copySampleFromPixelBuffer:native
                                                      template:template
                                                 configuration:self.configuration];
                CVPixelBufferRef imageBuffer = sample == NULL ? NULL
                    : CMSampleBufferGetImageBuffer(sample);
                if (imageBuffer != NULL) pixelBuffer = CVPixelBufferRetain(imageBuffer);
                if (sample != NULL) CFRelease(sample);
                if (template != NULL) CFRelease(template);
                CVPixelBufferRelease(native);
            } else {
                pixelBuffer = native;
            }
        }
    });
    return pixelBuffer;
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

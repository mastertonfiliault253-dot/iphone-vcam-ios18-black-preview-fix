#import "VCAMSpringBoardMediaBridge.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

#include <math.h>
#include <unistd.h>

#import "../Core/VCAMConfiguration.h"
#import "../Shared/VCAMSharedFrame.h"

static const char *const VCAMLegacyHLSDaemonMarker =
    "/var/tmp/vcam-hls-legacy-vcamd.enable";
static const char *const VCAMLegacyLocalVideoDaemonMarker =
    "/var/tmp/vcam-local-video-legacy-vcamd.enable";
static const char *const VCAMLegacyLocalImageDaemonMarker =
    "/var/tmp/vcam-local-image-legacy-vcamd.enable";
static const uint64_t VCAMHLSStallTimeoutNanoseconds = 8ULL * 1000000000ULL;
static const uint64_t VCAMSurfaceHandshakeProbeIntervalNanoseconds =
    1ULL * 1000000000ULL;
static const NSUInteger VCAMStaticImageMaximumStartRetries = 20;
static const NSTimeInterval VCAMStaticImageStartRetryDelaySeconds = 0.25;
static const uint64_t VCAMStaticImageMaximumSurfaceBytes = 64ULL * 1024ULL * 1024ULL;

static BOOL VCAMLocalMediaPathIsVideo(NSString *path) {
    NSString *extension = path.pathExtension.lowercaseString;
    return [@[@"mov", @"mp4", @"m4v"] containsObject:extension];
}

static CGAffineTransform VCAMCoreImageLinearTransformForTrack(
    CGAffineTransform preferredTransform) {
    // Track presentation matrices use the video/display top-left basis while
    // Core Image renders in a bottom-left basis. Conjugating by the vertical
    // axis flip preserves track mirroring but reverses 90-degree rotation in
    // Core Image; applying the raw matrix produced an upside-down portrait.
    return CGAffineTransformMake(
        preferredTransform.a, -preferredTransform.b,
        -preferredTransform.c, preferredTransform.d, 0, 0);
}

static double VCAMLiveEdgeLagSeconds(AVPlayerItem *item) {
    NSValue *value = item.seekableTimeRanges.lastObject;
    if (value == nil) return NAN;
    CMTimeRange range = value.CMTimeRangeValue;
    double edge = CMTimeGetSeconds(CMTimeRangeGetEnd(range));
    double current = CMTimeGetSeconds(item.currentTime);
    return isfinite(edge) && isfinite(current) ? MAX(0.0, edge - current) : NAN;
}

static void VCAMSetVideoColorAttachments(CVPixelBufferRef pixelBuffer) {
    OSType format = pixelBuffer == NULL ? 0 : CVPixelBufferGetPixelFormatType(pixelBuffer);
    if (format != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
        format != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) return;
    CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey,
                          kCVImageBufferColorPrimaries_ITU_R_709_2,
                          kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey,
                          kCVImageBufferTransferFunction_ITU_R_709_2,
                          kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey,
                          kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                          kCVAttachmentMode_ShouldPropagate);
}

static void VCAMSetRGBColorAttachments(CVPixelBufferRef pixelBuffer) {
    if (pixelBuffer == NULL) return;
    CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey,
                          kCVImageBufferColorPrimaries_ITU_R_709_2,
                          kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey,
                          kCVImageBufferTransferFunction_ITU_R_709_2,
                          kCVAttachmentMode_ShouldPropagate);
}

static void VCAMSpringBoardMediaPreferencesChanged(
    CFNotificationCenterRef center, void *observer, CFStringRef name,
    const void *object, CFDictionaryRef userInfo) {
    (void)center; (void)name; (void)object; (void)userInfo;
    VCAMSpringBoardMediaBridge *bridge =
        (__bridge VCAMSpringBoardMediaBridge *)observer;
    dispatch_async(dispatch_get_main_queue(), ^{ [bridge reload]; });
}

@interface VCAMSpringBoardMediaBridge ()
@property(nonatomic, strong, nullable) VCAMConfiguration *configuration;
@property(nonatomic, strong, nullable) AVPlayer *player;
@property(nonatomic, strong, nullable) AVPlayerItemVideoOutput *output;
@property(nonatomic, strong, nullable) AVPlayerLayer *playerLayer;
@property(nonatomic, strong, nullable) CADisplayLink *displayLink;
@property(nonatomic, strong, nullable) id playbackEndObserver;
@property(nonatomic, strong, nullable) CIContext *context;
@property(nonatomic, strong, nullable) id<MTLDevice> metalDevice;
@property(nonatomic) CVPixelBufferPoolRef outputPool;
@property(nonatomic) CGColorSpaceRef colorSpace;
@property(nonatomic) VCAMSharedFrameWriter *writer;
@property(nonatomic) VCAMSharedSurfaceWriter *surfaceWriter;
@property(nonatomic) uint32_t surfaceWidth;
@property(nonatomic) uint32_t surfaceHeight;
@property(nonatomic) BOOL started;
@property(nonatomic) NSUInteger decodedFrames;
@property(nonatomic) NSUInteger displayTicks;
@property(nonatomic) NSUInteger emptyCopies;
@property(nonatomic) NSUInteger publishedFrames;
@property(nonatomic) NSUInteger publishFailures;
@property(nonatomic) uint64_t lastFrameTimestampNanoseconds;
@property(nonatomic) uint64_t lastDecodedFrameTimestampNanoseconds;
@property(nonatomic) uint64_t lastSurfaceProbeTimestampNanoseconds;
@property(nonatomic) NSUInteger reconnectAttempt;
@property(nonatomic) BOOL reconnectPending;
@property(nonatomic) BOOL localVideo;
@property(nonatomic) BOOL localVideoReachedEnd;
@property(nonatomic) BOOL staticImage;
@property(nonatomic) BOOL staticImageStartRetryable;
@property(nonatomic) BOOL staticImageStartRetryPending;
@property(nonatomic) NSUInteger staticImageStartRetryAttempt;
@property(nonatomic, strong, nullable) CIImage *staticRenderImage;
@property(nonatomic) CGAffineTransform sourceTransform;
@property(nonatomic) CGSize sourceNaturalSize;
@property(nonatomic, copy, nullable) NSString *lastError;
@end

@implementation VCAMSpringBoardMediaBridge

+ (instancetype)sharedBridge {
    static VCAMSpringBoardMediaBridge *bridge;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ bridge = [VCAMSpringBoardMediaBridge new]; });
    return bridge;
}

- (void)dealloc {
    [self stop];
    if (_outputPool != NULL) CVPixelBufferPoolRelease(_outputPool);
    if (_colorSpace != NULL) CGColorSpaceRelease(_colorSpace);
    if (_writer != NULL) VCAMSharedFrameWriterDestroy(_writer);
    if (_surfaceWriter != NULL) VCAMSharedSurfaceWriterDestroy(_surfaceWriter);
}

- (void)start {
    NSAssert(NSThread.isMainThread, @"SpringBoard media bridge requires main thread");
    if (self.started ||
        ![NSProcessInfo.processInfo.processName isEqualToString:@"SpringBoard"]) return;
    self.started = YES;
    self.metalDevice = MTLCreateSystemDefaultDevice();
    if (self.metalDevice != nil) {
        self.context = [CIContext contextWithMTLDevice:self.metalDevice options:@{
            kCIContextCacheIntermediates: @NO,
            kCIContextPriorityRequestLow: @YES,
        }];
    }
    if (self.context == nil) {
        self.context = [CIContext contextWithOptions:@{
            kCIContextUseSoftwareRenderer: @NO,
            kCIContextCacheIntermediates: @NO,
        }];
    }
    self.colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceITUR_709);
    self.writer = VCAMSharedFrameWriterCreate();
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)self, VCAMSpringBoardMediaPreferencesChanged,
        CFSTR("com.codex.vcam/preferences.changed"), NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);
    [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
        @"springboard media bridge started metal=%d writer=%d surface=%d",
        self.metalDevice != nil, self.writer != NULL,
        self.surfaceWriter != NULL]];
    [self reload];
}

- (void)stopPlayback {
    AVPlayer *retiredPlayer = self.player;
    AVPlayerItemVideoOutput *retiredOutput = self.output;
    AVPlayerLayer *retiredLayer = self.playerLayer;
    [self.displayLink invalidate];
    self.displayLink = nil;
    if (self.playbackEndObserver != nil) {
        [NSNotificationCenter.defaultCenter removeObserver:self.playbackEndObserver];
        self.playbackEndObserver = nil;
    }
    [retiredLayer removeFromSuperlayer];
    self.playerLayer = nil;
    self.output = nil;
    self.player = nil;
    self.configuration = nil;
    self.localVideo = NO;
    self.staticImage = NO;
    self.staticRenderImage = nil;
    self.sourceTransform = CGAffineTransformIdentity;
    self.sourceNaturalSize = CGSizeZero;
    if (self.surfaceWriter != NULL) {
        VCAMSharedSurfaceWriterDestroy(self.surfaceWriter);
        self.surfaceWriter = NULL;
    }
    self.surfaceWidth = 0;
    self.surfaceHeight = 0;
    self.lastSurfaceProbeTimestampNanoseconds = 0;
    if (retiredPlayer != nil) {
        // AVPlayer can synchronously wait on an HLS media queue while pausing
        // or releasing its item. SpringBoard's main thread only detaches the
        // old graph; teardown happens off-main while reload creates the next.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            @autoreleasepool {
                [retiredPlayer pause];
                (void)retiredOutput;
                (void)retiredLayer;
            }
        });
        [VCAMConfiguration appendProcessLog:@"springboard HLS stop detached"];
    }
}

- (void)stop {
    if (!self.started) return;
    [self stopPlayback];
    CFNotificationCenterRemoveObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)self,
        CFSTR("com.codex.vcam/preferences.changed"), NULL);
    self.started = NO;
}

- (BOOL)configurationMatches:(VCAMConfiguration *)configuration {
    if (self.configuration == nil || configuration == nil) return NO;
    return self.configuration.sourceKind == configuration.sourceKind &&
        ((self.configuration.hlsURL == nil && configuration.hlsURL == nil) ||
            [self.configuration.hlsURL isEqual:configuration.hlsURL]) &&
        ((self.configuration.rtspURL == nil && configuration.rtspURL == nil) ||
            [self.configuration.rtspURL isEqual:configuration.rtspURL]) &&
        ((self.configuration.mediaPath == nil && configuration.mediaPath == nil) ||
            [self.configuration.mediaPath isEqual:configuration.mediaPath]) &&
        self.configuration.loopMedia == configuration.loopMedia &&
        self.configuration.rotationDegrees == configuration.rotationDegrees &&
        self.configuration.mirrorHorizontally == configuration.mirrorHorizontally &&
        self.configuration.contentMode == configuration.contentMode &&
        self.configuration.preferredFramesPerSecond == configuration.preferredFramesPerSecond;
}

- (nullable UIWindow *)hostWindow {
    UIWindow *fallback = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (fallback == nil) fallback = window;
            if (window.isKeyWindow) return window;
        }
    }
    return fallback;
}

- (BOOL)prepareOutputPool {
    if (self.outputPool != NULL) return YES;
    NSDictionary *poolAttributes = @{
        (id)kCVPixelBufferPoolMinimumBufferCountKey: @(VCAMSharedFrameSlotCount),
    };
    NSDictionary *pixelAttributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey: @(VCAMSharedFrameWidth),
        (id)kCVPixelBufferHeightKey: @(VCAMSharedFrameHeight),
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    CVReturn status = CVPixelBufferPoolCreate(
        kCFAllocatorDefault, (__bridge CFDictionaryRef)poolAttributes,
        (__bridge CFDictionaryRef)pixelAttributes, &_outputPool);
    if (status != kCVReturnSuccess) {
        self.lastError = [NSString stringWithFormat:@"output pool status=%d", status];
        return NO;
    }
    return YES;
}

- (nullable CIImage *)imageByApplyingConfiguredTransform:(CIImage *)image {
    if (image == nil || self.configuration == nil) return nil;
    CGRect extent = image.extent;
    image = [image imageByApplyingTransform:CGAffineTransformMakeTranslation(
        -CGRectGetMidX(extent), -CGRectGetMidY(extent))];
    if (self.configuration.mirrorHorizontally) {
        image = [image imageByApplyingTransform:CGAffineTransformMakeScale(-1, 1)];
    }
    CGFloat radians = self.configuration.rotationDegrees * (CGFloat)M_PI / 180.0;
    if (fabs(radians) > 0.0001) {
        image = [image imageByApplyingTransform:CGAffineTransformMakeRotation(radians)];
    }
    CGRect oriented = CGRectStandardize(image.extent);
    return [image imageByApplyingTransform:CGAffineTransformMakeTranslation(
        -CGRectGetMinX(oriented), -CGRectGetMinY(oriented))];
}

- (BOOL)publishStaticBootstrap {
    if (self.staticRenderImage == nil || self.writer == NULL ||
        self.outputPool == NULL || self.surfaceWriter == NULL) return NO;
    CVPixelBufferRef bootstrap = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, self.outputPool,
                                           &bootstrap) != kCVReturnSuccess ||
        bootstrap == NULL) return NO;
    CGRect target = CGRectMake(0, 0, VCAMSharedFrameWidth, VCAMSharedFrameHeight);
    CIImage *image = [self legacyCanvasImageFromOrientedImage:self.staticRenderImage];
    [self.context render:image toCVPixelBuffer:bootstrap bounds:target
              colorSpace:self.colorSpace];
    VCAMSetRGBColorAttachments(bootstrap);
    BOOL published = VCAMSharedFrameWriterPublishForSurfaceGeneration(
        self.writer, bootstrap,
        VCAMSharedSurfaceWriterGeneration(self.surfaceWriter));
    CVPixelBufferRelease(bootstrap);
    return published;
}

- (BOOL)startStaticImage:(VCAMConfiguration *)configuration {
    self.staticImageStartRetryable = NO;
    NSURL *url = [NSURL fileURLWithPath:configuration.mediaPath];
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (source == NULL) {
        self.lastError = @"static image source unavailable";
        return NO;
    }
    size_t index = CGImageSourceGetPrimaryImageIndex(source);
    NSDictionary *properties = CFBridgingRelease(
        CGImageSourceCopyPropertiesAtIndex(source, index, NULL));
    NSUInteger width = [properties[(id)kCGImagePropertyPixelWidth] unsignedIntegerValue];
    NSUInteger height = [properties[(id)kCGImagePropertyPixelHeight] unsignedIntegerValue];
    uint64_t pixelCount = (uint64_t)width * (uint64_t)height;
    if (width == 0 || height == 0 || width > UINT32_MAX || height > UINT32_MAX ||
        pixelCount > VCAMStaticImageMaximumSurfaceBytes / 4ULL) {
        CFRelease(source);
        self.lastError = @"static image exceeds the 64 MiB source-sized surface budget";
        return NO;
    }
    NSDictionary *options = @{
        (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
        (id)kCGImageSourceThumbnailMaxPixelSize: @(MAX(width, height)),
        (id)kCGImageSourceShouldCacheImmediately: @YES,
    };
    CGImageRef decoded = CGImageSourceCreateThumbnailAtIndex(
        source, index, (__bridge CFDictionaryRef)options);
    if (decoded == NULL) decoded = CGImageSourceCreateImageAtIndex(source, index, NULL);
    CFRelease(source);
    if (decoded == NULL) {
        self.lastError = @"static image decode failed";
        return NO;
    }
    CIImage *image = [self imageByApplyingConfiguredTransform:
        [CIImage imageWithCGImage:decoded]];
    CGImageRelease(decoded);
    CGRect extent = image.extent;
    double transformedWidth = MAX(1.0, ceil(CGRectGetWidth(extent)));
    double transformedHeight = MAX(1.0, ceil(CGRectGetHeight(extent)));
    if (!isfinite(transformedWidth) || !isfinite(transformedHeight) ||
        transformedWidth > UINT32_MAX || transformedHeight > UINT32_MAX ||
        (uint64_t)transformedWidth * (uint64_t)transformedHeight >
            VCAMStaticImageMaximumSurfaceBytes / 4ULL) {
        self.lastError = @"transformed static image exceeds the 64 MiB surface budget";
        return NO;
    }
    uint32_t outputWidth = (uint32_t)transformedWidth;
    uint32_t outputHeight = (uint32_t)transformedHeight;
    self.surfaceWriter = VCAMSharedSurfaceWriterCreateConfigured(
        outputWidth, outputHeight, kCVPixelFormatType_32BGRA, 1);
    if (self.surfaceWriter == NULL) {
        self.staticImageStartRetryable = YES;
        self.lastError = [NSString stringWithFormat:
            @"static IOSurface unavailable size=%ux%u", outputWidth, outputHeight];
        return NO;
    }
    self.surfaceWidth = outputWidth;
    self.surfaceHeight = outputHeight;
    self.staticRenderImage = image;
    CVPixelBufferRef destination =
        VCAMSharedSurfaceWriterCopyNextPixelBuffer(self.surfaceWriter);
    BOOL surfacePublished = NO;
    if (destination != NULL) {
        [self.context render:image toCVPixelBuffer:destination
                      bounds:CGRectMake(0, 0, outputWidth, outputHeight)
                 colorSpace:self.colorSpace];
        VCAMSetRGBColorAttachments(destination);
        surfacePublished = VCAMSharedSurfaceWriterPublish(self.surfaceWriter, destination);
        CVPixelBufferRelease(destination);
    }
    if (!surfacePublished) {
        self.staticImageStartRetryable = YES;
        self.lastError = @"static image publish failed";
        return NO;
    }
    // The IOSurface is the authoritative transport. The fixed mmap frame only
    // bridges the XPC handshake and is retried by refreshStaticImage if needed.
    BOOL bootstrapPublished = [self publishStaticBootstrap];
    if (!bootstrapPublished) {
        [VCAMConfiguration appendProcessLog:
            @"springboard static bootstrap deferred until refresh"];
    }
    self.publishedFrames = 1;
    self.lastFrameTimestampNanoseconds = VCAMSharedFrameMonotonicNanoseconds();
    self.displayLink = [CADisplayLink displayLinkWithTarget:self
                                                   selector:@selector(refreshStaticImage:)];
    self.displayLink.preferredFramesPerSecond = 1;
    [self.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
        @"springboard static image published size=%ux%u slots=1 generation=%llu",
        outputWidth, outputHeight,
        (unsigned long long)VCAMSharedSurfaceWriterGeneration(self.surfaceWriter)]];
    return YES;
}

- (void)scheduleStaticImageStartRetryForConfiguration:
    (VCAMConfiguration *)configuration {
    if (self.staticImageStartRetryPending ||
        self.staticImageStartRetryAttempt >= VCAMStaticImageMaximumStartRetries) return;
    self.staticImageStartRetryPending = YES;
    self.staticImageStartRetryAttempt += 1;
    NSUInteger attempt = self.staticImageStartRetryAttempt;
    NSString *mediaPath = [configuration.mediaPath copy];
    [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
        @"springboard static start retry=%lu/%lu error=%@",
        (unsigned long)attempt,
        (unsigned long)VCAMStaticImageMaximumStartRetries,
        self.lastError ?: @"unknown"]];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(VCAMStaticImageStartRetryDelaySeconds * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        self.staticImageStartRetryPending = NO;
        if (!self.started) return;
        VCAMConfiguration *current = [VCAMConfiguration loadCurrent];
        BOOL stillCurrent = current.enabled &&
            current.sourceKind == VCAMSourceKindLocalMedia &&
            current.mediaPath.length > 0 &&
            !VCAMLocalMediaPathIsVideo(current.mediaPath) &&
            [current.mediaPath isEqualToString:mediaPath];
        if (!stillCurrent) {
            self.staticImageStartRetryAttempt = 0;
            return;
        }
        [self reload];
    });
}

- (void)refreshStaticImage:(CADisplayLink *)displayLink {
    (void)displayLink;
    if (!self.staticImage || self.surfaceWriter == NULL) return;
    if (!VCAMSharedSurfaceWriterIsCurrent(self.surfaceWriter)) {
        [self reload];
        return;
    }
    BOOL refreshed = VCAMSharedSurfaceWriterRefreshLatest(self.surfaceWriter);
    BOOL consumerReady = VCAMSharedSurfaceWriterHasConsumer(self.surfaceWriter);
    BOOL bootstrap = consumerReady || [self publishStaticBootstrap];
    if (refreshed && bootstrap) {
        self.lastFrameTimestampNanoseconds = VCAMSharedFrameMonotonicNanoseconds();
    } else {
        self.publishFailures += 1;
    }
}

- (void)reload {
    NSAssert(NSThread.isMainThread, @"SpringBoard media bridge reload requires main thread");
    if (!self.started) return;
    VCAMConfiguration *next = [VCAMConfiguration loadCurrent];
    BOOL hls = next.sourceKind == VCAMSourceKindHLS && next.hlsURL != nil &&
        access(VCAMLegacyHLSDaemonMarker, F_OK) != 0;
    BOOL localVideo = next.sourceKind == VCAMSourceKindLocalMedia &&
        VCAMLocalMediaPathIsVideo(next.mediaPath) &&
        access(VCAMLegacyLocalVideoDaemonMarker, F_OK) != 0;
    BOOL staticImage = next.sourceKind == VCAMSourceKindLocalMedia &&
        next.mediaPath.length > 0 && !VCAMLocalMediaPathIsVideo(next.mediaPath) &&
        access(VCAMLegacyLocalImageDaemonMarker, F_OK) != 0;
    BOOL shouldPlay = next.enabled && (hls || localVideo || staticImage);
    if (!shouldPlay) {
        [self stopPlayback];
        return;
    }
    BOOL transportCurrent = !self.staticImage ||
        VCAMSharedSurfaceWriterIsCurrent(self.surfaceWriter);
    if (self.configuration != nil && transportCurrent &&
        [self configurationMatches:next]) return;
    [self stopPlayback];
    self.configuration = next;
    self.localVideo = localVideo;
    self.staticImage = staticImage;
    BOOL transportReady = self.writer != NULL && [self prepareOutputPool];
    if (!transportReady || self.context == nil) {
        self.lastError = self.lastError ?: @"renderer unavailable";
        return;
    }
    if (staticImage) {
        if (![self startStaticImage:next]) {
            BOOL retryable = self.staticImageStartRetryable;
            [self stopPlayback];
            if (retryable &&
                self.staticImageStartRetryAttempt < VCAMStaticImageMaximumStartRetries) {
                [self scheduleStaticImageStartRetryForConfiguration:next];
            } else {
                self.staticImageStartRetryAttempt = 0;
            }
        } else {
            self.staticImageStartRetryAttempt = 0;
        }
        return;
    }
    self.staticImageStartRetryAttempt = 0;

    self.output = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:@{
        (id)kCVPixelBufferPixelFormatTypeKey:
            @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    }];
    NSURL *playbackURL = localVideo ? [NSURL fileURLWithPath:next.mediaPath]
                                    : next.hlsURL;
    AVAsset *asset = localVideo
        ? [AVURLAsset URLAssetWithURL:playbackURL options:nil] : nil;
    AVPlayerItem *item = localVideo
        ? [AVPlayerItem playerItemWithAsset:asset]
        : [AVPlayerItem playerItemWithURL:playbackURL];
    if (!localVideo) {
        item.preferredForwardBufferDuration = 1.0;
        item.automaticallyPreservesTimeOffsetFromLive = NO;
    }
    [item addOutput:self.output];
    self.player = [AVPlayer playerWithPlayerItem:item];
    // A one-second preferred buffer keeps the live edge close, while automatic
    // resume is still required on iOS 16.1. Disabling it leaves rate=0 after
    // the first HLS frame even as the server playlist continues advancing.
    self.player.automaticallyWaitsToMinimizeStalling = YES;
    AVAssetTrack *videoTrack = localVideo
        ? [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject] : nil;
    self.sourceTransform = videoTrack == nil
        ? CGAffineTransformIdentity : videoTrack.preferredTransform;
    self.sourceNaturalSize = videoTrack == nil ? CGSizeZero : videoTrack.naturalSize;
    if (localVideo) {
        __weak typeof(self) weakSelf = self;
        self.playbackEndObserver = [NSNotificationCenter.defaultCenter
            addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                        object:item
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(__unused NSNotification *notification) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf == nil) return;
            if (!strongSelf.configuration.loopMedia) {
                strongSelf.localVideoReachedEnd = YES;
                [VCAMConfiguration appendProcessLog:
                    @"springboard local video reached end; holding last frame"];
                return;
            }
            strongSelf.localVideoReachedEnd = NO;
            [strongSelf.player seekToTime:kCMTimeZero toleranceBefore:kCMTimeZero
                           toleranceAfter:kCMTimeZero completionHandler:^(BOOL finished) {
                if (finished && strongSelf.player != nil) [strongSelf.player play];
            }];
            [VCAMConfiguration appendProcessLog:@"springboard local video loop"];
        }];
    }

    // A compositor-attached AVPlayerLayer keeps the system decode path active.
    // One near-transparent pixel is imperceptible and avoids a full-screen
    // overlay while AVPlayerItemVideoOutput supplies the real frames.
    self.playerLayer = [AVPlayerLayer playerLayerWithPlayer:self.player];
    self.playerLayer.frame = CGRectMake(0, 0, 1, 1);
    self.playerLayer.opacity = 0.01f;
    [[self hostWindow].layer addSublayer:self.playerLayer];

    self.decodedFrames = 0;
    self.localVideoReachedEnd = NO;
    self.displayTicks = 0;
    self.emptyCopies = 0;
    self.publishedFrames = 0;
    self.publishFailures = 0;
    self.lastFrameTimestampNanoseconds = 0;
    self.lastDecodedFrameTimestampNanoseconds =
        VCAMSharedFrameMonotonicNanoseconds();
    self.lastError = nil;
    [self.player play];
    self.displayLink = [CADisplayLink displayLinkWithTarget:self
                                                   selector:@selector(tick:)];
    NSInteger sourceFramesPerSecond = MAX(1, MIN(60, next.preferredFramesPerSecond));
    // HLS frames arrive in segment bursts. Sampling at the nominal 30 Hz can
    // skip two decoded frames that become available between adjacent ticks.
    // A 60 Hz display link still publishes only when AVPlayer reports a new
    // pixel buffer, so it improves cadence without duplicating shared frames.
    self.displayLink.preferredFramesPerSecond = localVideo ? sourceFramesPerSecond : 60;
    [self.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    NSString *startFormat = localVideo
        ? @"springboard local video start url=%@ output=%d layer=%d fps=%ld"
        : @"springboard HLS start url=%@ output=%d layer=%d fps=%ld";
    [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:startFormat,
        playbackURL.absoluteString, [item.outputs containsObject:self.output],
        self.playerLayer.superlayer != nil,
        (long)self.displayLink.preferredFramesPerSecond]];
}

- (void)scheduleReconnectForItem:(AVPlayerItem *)item reason:(NSString *)reason {
    if (self.reconnectPending || item != self.player.currentItem) return;
    NSUInteger delay = MIN((NSUInteger)30,
        (NSUInteger)1 << MIN(self.reconnectAttempt, (NSUInteger)5));
    self.reconnectAttempt += 1;
    self.reconnectPending = YES;
    self.lastError = reason.length > 0 ? reason : @"player item failed";
    NSString *reconnectFormat = self.localVideo
        ? @"springboard local video reconnect attempt=%lu delay=%lus error=%@"
        : @"springboard HLS reconnect attempt=%lu delay=%lus error=%@";
    [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:reconnectFormat,
        (unsigned long)self.reconnectAttempt, (unsigned long)delay,
        self.lastError]];
    [self stopPlayback];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
        (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self.reconnectPending = NO;
        if (self.started) [self reload];
    });
}

- (nullable CIImage *)imageByOrientingPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    if (pixelBuffer == NULL || self.configuration == nil) return nil;
    CIImage *image = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    CGRect extent = image.extent;
    image = [image imageByApplyingTransform:CGAffineTransformMakeTranslation(
        -CGRectGetMidX(extent), -CGRectGetMidY(extent))];
    if (self.localVideo && !CGAffineTransformIsIdentity(self.sourceTransform)) {
        CGAffineTransform linear =
            VCAMCoreImageLinearTransformForTrack(self.sourceTransform);
        image = [image imageByApplyingTransform:linear];
    }
    CGRect oriented = CGRectStandardize(image.extent);
    image = [image imageByApplyingTransform:CGAffineTransformMakeTranslation(
        -CGRectGetMinX(oriented), -CGRectGetMinY(oriented))];
    return [self imageByApplyingConfiguredTransform:image];
}

- (CIImage *)legacyCanvasImageFromOrientedImage:(CIImage *)image {
    CGRect oriented = image.extent;
    CGFloat scaleX = VCAMSharedFrameWidth / MAX(1.0, CGRectGetWidth(oriented));
    CGFloat scaleY = VCAMSharedFrameHeight / MAX(1.0, CGRectGetHeight(oriented));
    if (self.configuration.contentMode == VCAMContentModeAspectFit) {
        scaleX = scaleY = MIN(scaleX, scaleY);
    } else if (self.configuration.contentMode == VCAMContentModeAspectFill) {
        scaleX = scaleY = MAX(scaleX, scaleY);
    }
    image = [image imageByApplyingTransform:CGAffineTransformMakeScale(scaleX, scaleY)];
    CGRect scaled = image.extent;
    image = [image imageByApplyingTransform:CGAffineTransformMakeTranslation(
        VCAMSharedFrameWidth * 0.5 - CGRectGetMidX(scaled),
        VCAMSharedFrameHeight * 0.5 - CGRectGetMidY(scaled))];
    CGRect target = CGRectMake(0, 0, VCAMSharedFrameWidth, VCAMSharedFrameHeight);
    CIImage *black = [[CIImage imageWithColor:CIColor.blackColor] imageByCroppingToRect:target];
    return [[image imageByCompositingOverImage:black] imageByCroppingToRect:target];
}

- (void)tick:(CADisplayLink *)displayLink {
    (void)displayLink;
    if (self.output == nil || self.player.currentItem == nil) return;
    AVPlayerItem *item = self.player.currentItem;
    if (item.status == AVPlayerItemStatusFailed) {
        [self scheduleReconnectForItem:item
                                reason:item.error.localizedDescription];
        return;
    }
    CMTime itemTime = [self.output itemTimeForHostTime:CACurrentMediaTime()];
    BOOL hasNewFrame = [self.output hasNewPixelBufferForItemTime:itemTime];
    uint64_t now = VCAMSharedFrameMonotonicNanoseconds();
    self.displayTicks += 1;
    double liveLag = self.localVideo ? NAN : VCAMLiveEdgeLagSeconds(item);
    if (self.displayTicks % 300 == 0) {
        CGSize presentationSize = item.presentationSize;
        NSString *healthFormat = self.localVideo
            ? @"springboard local video health ticks=%lu hasNew=%d itemStatus=%ld timeControl=%ld wait=%@ current=%.3f liveLag=%.3f size=%.0fx%.0f error=%@"
            : @"springboard HLS health ticks=%lu hasNew=%d itemStatus=%ld timeControl=%ld wait=%@ current=%.3f liveLag=%.3f size=%.0fx%.0f error=%@";
        [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:healthFormat,
            (unsigned long)self.displayTicks, hasNewFrame, (long)item.status,
            (long)self.player.timeControlStatus,
            self.player.reasonForWaitingToPlay ?: @"none",
            CMTimeGetSeconds(item.currentTime), liveLag, presentationSize.width,
            presentationSize.height,
            item.error.localizedDescription ?: @"none"]];
    }
    if (!hasNewFrame) {
        if (self.localVideoReachedEnd) return;
        if (item.status == AVPlayerItemStatusReadyToPlay &&
            now - self.lastDecodedFrameTimestampNanoseconds >=
                VCAMHLSStallTimeoutNanoseconds) {
            NSString *stallFormat = self.localVideo
                ? @"springboard local video stalled %.1fs status=%ld timeControl=%ld"
                : @"springboard HLS stalled %.1fs status=%ld timeControl=%ld";
            [self scheduleReconnectForItem:item reason:[NSString stringWithFormat:stallFormat,
                (double)(now - self.lastDecodedFrameTimestampNanoseconds) / 1e9,
                (long)item.status, (long)self.player.timeControlStatus]];
        }
        return;
    }
    CMTime displayTime = kCMTimeInvalid;
    CVPixelBufferRef source = [self.output copyPixelBufferForItemTime:itemTime
                                                   itemTimeForDisplay:&displayTime];
    if (source == NULL) {
        self.emptyCopies += 1;
        return;
    }
    self.decodedFrames += 1;
    self.lastDecodedFrameTimestampNanoseconds = now;
    self.reconnectAttempt = 0;
    if (self.localVideo && self.decodedFrames <= 3) {
        CGRect displayed = CGRectStandardize(CGRectApplyAffineTransform(
            (CGRect){CGPointZero, self.sourceNaturalSize}, self.sourceTransform));
        [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
            @"springboard local video orientation frame=%lu raw=%zux%zu natural=%.0fx%.0f display=%.0fx%.0f apply=%d matrix=[%.0f %.0f %.0f %.0f]",
            (unsigned long)self.decodedFrames,
            CVPixelBufferGetWidth(source), CVPixelBufferGetHeight(source),
            self.sourceNaturalSize.width, self.sourceNaturalSize.height,
            CGRectGetWidth(displayed), CGRectGetHeight(displayed),
            !CGAffineTransformIsIdentity(self.sourceTransform),
            self.sourceTransform.a, self.sourceTransform.b,
            self.sourceTransform.c, self.sourceTransform.d]];
    }
    [self publishPixelBuffer:source sourceName:(self.localVideo ? @"local video" : @"HLS")];
    CVPixelBufferRelease(source);
}

- (BOOL)publishPixelBuffer:(CVPixelBufferRef)source sourceName:(NSString *)sourceName {
    uint64_t now = VCAMSharedFrameMonotonicNanoseconds();
    CIImage *image = [self imageByOrientingPixelBuffer:source];
    CGRect sourceExtent = image == nil ? CGRectZero : image.extent;
    uint32_t outputWidth = (uint32_t)MAX(2.0, ceil(CGRectGetWidth(sourceExtent)));
    uint32_t outputHeight = (uint32_t)MAX(2.0, ceil(CGRectGetHeight(sourceExtent)));
    outputWidth = (outputWidth + 1U) & ~1U;
    outputHeight = (outputHeight + 1U) & ~1U;
    if (self.surfaceWriter != NULL &&
        (!VCAMSharedSurfaceWriterIsCurrent(self.surfaceWriter) ||
         self.surfaceWidth != outputWidth || self.surfaceHeight != outputHeight)) {
        VCAMSharedSurfaceWriterDestroy(self.surfaceWriter);
        self.surfaceWriter = NULL;
        self.surfaceWidth = 0;
        self.surfaceHeight = 0;
        self.lastSurfaceProbeTimestampNanoseconds = 0;
    }
    if (image != nil && self.surfaceWriter == NULL) {
        self.surfaceWriter = VCAMSharedSurfaceWriterCreateConfigured(
            outputWidth, outputHeight,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            VCAMSharedFrameSlotCount);
        if (self.surfaceWriter != NULL) {
            self.surfaceWidth = outputWidth;
            self.surfaceHeight = outputHeight;
            [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
                @"springboard %@ IOSurface configured size=%ux%u slots=%d",
                self.localVideo ? @"local video" : @"HLS", outputWidth,
                outputHeight, VCAMSharedFrameSlotCount]];
        }
    }
    BOOL surfaceTransport = self.surfaceWriter != NULL;
    BOOL surfaceConsumerReady = surfaceTransport &&
        VCAMSharedSurfaceWriterHasConsumer(self.surfaceWriter);
    BOOL surfaceProbeDue = surfaceTransport && !surfaceConsumerReady &&
        (self.lastSurfaceProbeTimestampNanoseconds == 0 ||
         now - self.lastSurfaceProbeTimestampNanoseconds >=
             VCAMSurfaceHandshakeProbeIntervalNanoseconds);
    BOOL useSurfaceDestination = surfaceTransport &&
        (surfaceConsumerReady || surfaceProbeDue);
    CVPixelBufferRef destination = useSurfaceDestination
        ? VCAMSharedSurfaceWriterCopyNextPixelBuffer(self.surfaceWriter)
        : NULL;
    if (useSurfaceDestination && destination == NULL) {
        useSurfaceDestination = NO;
    }
    CVReturn destinationStatus = destination != NULL ? kCVReturnSuccess
        : CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault,
                                             self.outputPool, &destination);
    BOOL published = NO;
    if (destinationStatus == kCVReturnSuccess && destination != NULL) {
        if (image != nil) {
            CGRect target = useSurfaceDestination
                ? CGRectMake(0, 0, outputWidth, outputHeight)
                : CGRectMake(0, 0, VCAMSharedFrameWidth, VCAMSharedFrameHeight);
            CIImage *renderImage = useSurfaceDestination ? image
                : [self legacyCanvasImageFromOrientedImage:image];
            VCAMSetVideoColorAttachments(destination);
            [self.context render:renderImage toCVPixelBuffer:destination bounds:target
                      colorSpace:self.colorSpace];
            if (useSurfaceDestination) {
                BOOL surfacePublished = VCAMSharedSurfaceWriterPublish(
                    self.surfaceWriter, destination);
                if (surfacePublished && !surfaceConsumerReady) {
                    self.lastSurfaceProbeTimestampNanoseconds = now;
                }
                // Keep the compatibility path live until mediaserverd proves
                // that this OS/process pair can look up the global surface.
                BOOL compatibilityPublished = surfaceConsumerReady;
                if (!surfaceConsumerReady) {
                    CVPixelBufferRef bootstrap = NULL;
                    if (CVPixelBufferPoolCreatePixelBuffer(
                            kCFAllocatorDefault, self.outputPool, &bootstrap) ==
                            kCVReturnSuccess && bootstrap != NULL) {
                        CGRect bootstrapTarget = CGRectMake(
                            0, 0, VCAMSharedFrameWidth, VCAMSharedFrameHeight);
                        CIImage *bootstrapImage =
                            [self legacyCanvasImageFromOrientedImage:image];
                        [self.context render:bootstrapImage
                             toCVPixelBuffer:bootstrap bounds:bootstrapTarget
                                  colorSpace:self.colorSpace];
                        compatibilityPublished =
                            VCAMSharedFrameWriterPublishForSurfaceGeneration(
                                self.writer, bootstrap,
                                VCAMSharedSurfaceWriterGeneration(
                                    self.surfaceWriter));
                        CVPixelBufferRelease(bootstrap);
                    }
                }
                published = surfacePublished && compatibilityPublished;
            } else {
                published = surfaceTransport
                    ? VCAMSharedFrameWriterPublishForSurfaceGeneration(
                          self.writer, destination,
                          VCAMSharedSurfaceWriterGeneration(self.surfaceWriter))
                    : VCAMSharedFrameWriterPublish(self.writer, destination);
            }
        }
        CVPixelBufferRelease(destination);
    }
    if (published) {
        self.publishedFrames += 1;
        self.lastFrameTimestampNanoseconds = VCAMSharedFrameMonotonicNanoseconds();
    } else {
        self.publishFailures += 1;
    }
    if (self.decodedFrames <= 3 || self.decodedFrames % 300 == 0) {
        NSString *frameFormat = [NSString stringWithFormat:
            @"springboard %@ frame decoded=%lu published=%lu empty=%lu failures=%lu transport=%@",
            sourceName, (unsigned long)self.decodedFrames,
            (unsigned long)self.publishedFrames, (unsigned long)self.emptyCopies,
            (unsigned long)self.publishFailures,
            surfaceTransport
                ? (surfaceConsumerReady ? @"iosurface" : @"iosurface+bootstrap-mmap")
                : @"mmap"];
        [VCAMConfiguration appendProcessLog:frameFormat];
    }
    return published;
}

- (NSDictionary<NSString *, id> *)healthSnapshot {
    return @{
        @"running": @(self.displayLink != nil &&
            (self.player != nil || self.staticImage)),
        @"decodedFrames": @(self.decodedFrames),
        @"publishedFrames": @(self.publishedFrames),
        @"emptyCopies": @(self.emptyCopies),
        @"publishFailures": @(self.publishFailures),
        @"lastFrameTimestampNanoseconds": @(self.lastFrameTimestampNanoseconds),
        @"playerStatus": @(self.player.currentItem.status),
        @"playerRate": @(self.player.rate),
        @"transport": self.surfaceWriter != NULL
            ? (VCAMSharedSurfaceWriterHasConsumer(self.surfaceWriter)
                ? @"iosurface" : @"iosurface+bootstrap-mmap")
            : @"mmap",
        @"error": self.lastError ?: self.player.currentItem.error.localizedDescription ?: @"",
    };
}

@end

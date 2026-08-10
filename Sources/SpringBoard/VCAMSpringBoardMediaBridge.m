#import "VCAMSpringBoardMediaBridge.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
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
static const uint64_t VCAMHLSStallTimeoutNanoseconds = 8ULL * 1000000000ULL;

static BOOL VCAMLocalMediaPathIsVideo(NSString *path) {
    NSString *extension = path.pathExtension.lowercaseString;
    return [@[@"mov", @"mp4", @"m4v"] containsObject:extension];
}

static double VCAMLiveEdgeLagSeconds(AVPlayerItem *item) {
    NSValue *value = item.seekableTimeRanges.lastObject;
    if (value == nil) return NAN;
    CMTimeRange range = value.CMTimeRangeValue;
    double edge = CMTimeGetSeconds(CMTimeRangeGetEnd(range));
    double current = CMTimeGetSeconds(item.currentTime);
    return isfinite(edge) && isfinite(current) ? MAX(0.0, edge - current) : NAN;
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
@property(nonatomic) BOOL started;
@property(nonatomic) NSUInteger decodedFrames;
@property(nonatomic) NSUInteger displayTicks;
@property(nonatomic) NSUInteger emptyCopies;
@property(nonatomic) NSUInteger publishedFrames;
@property(nonatomic) NSUInteger publishFailures;
@property(nonatomic) uint64_t lastFrameTimestampNanoseconds;
@property(nonatomic) uint64_t lastDecodedFrameTimestampNanoseconds;
@property(nonatomic) NSUInteger reconnectAttempt;
@property(nonatomic) BOOL reconnectPending;
@property(nonatomic) BOOL localVideo;
@property(nonatomic) CGAffineTransform sourceTransform;
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
    self.colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    self.writer = VCAMSharedFrameWriterCreate();
    self.surfaceWriter = VCAMSharedSurfaceWriterCreate();
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
    self.sourceTransform = CGAffineTransformIdentity;
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
        [self.configuration.hlsURL isEqual:configuration.hlsURL] &&
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

- (void)reload {
    NSAssert(NSThread.isMainThread, @"SpringBoard media bridge reload requires main thread");
    if (!self.started) return;
    VCAMConfiguration *next = [VCAMConfiguration loadCurrent];
    BOOL hls = next.sourceKind == VCAMSourceKindHLS && next.hlsURL != nil &&
        access(VCAMLegacyHLSDaemonMarker, F_OK) != 0;
    BOOL localVideo = next.sourceKind == VCAMSourceKindLocalMedia &&
        VCAMLocalMediaPathIsVideo(next.mediaPath) &&
        access(VCAMLegacyLocalVideoDaemonMarker, F_OK) != 0;
    BOOL shouldPlay = next.enabled && (hls || localVideo);
    if (!shouldPlay) {
        [self stopPlayback];
        return;
    }
    if (self.player != nil && [self configurationMatches:next]) return;
    [self stopPlayback];
    self.configuration = next;
    self.localVideo = localVideo;
    BOOL transportReady = self.surfaceWriter != NULL ||
        (self.writer != NULL && [self prepareOutputPool]);
    if (!transportReady || self.context == nil) {
        self.lastError = self.lastError ?: @"renderer unavailable";
        return;
    }

    self.output = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:@{
        (id)kCVPixelBufferPixelFormatTypeKey:
            @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    }];
    NSURL *playbackURL = localVideo ? [NSURL fileURLWithPath:next.mediaPath]
                                    : next.hlsURL;
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:playbackURL];
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
        ? [[item.asset tracksWithMediaType:AVMediaTypeVideo] firstObject] : nil;
    self.sourceTransform = videoTrack == nil
        ? CGAffineTransformIdentity : videoTrack.preferredTransform;
    if (localVideo) {
        __weak typeof(self) weakSelf = self;
        self.playbackEndObserver = [NSNotificationCenter.defaultCenter
            addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                        object:item
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(__unused NSNotification *notification) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf == nil || !strongSelf.configuration.loopMedia) return;
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
    self.displayLink.preferredFramesPerSecond =
        MAX(1, MIN(60, next.preferredFramesPerSecond));
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

- (nullable CIImage *)imageByTransformingPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    if (pixelBuffer == NULL || self.configuration == nil) return nil;
    CIImage *image = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    CGRect extent = image.extent;
    image = [image imageByApplyingTransform:CGAffineTransformMakeTranslation(
        -CGRectGetMidX(extent), -CGRectGetMidY(extent))];
    BOOL sourceMirrored = self.sourceTransform.a * self.sourceTransform.d -
        self.sourceTransform.b * self.sourceTransform.c < 0;
    if (sourceMirrored != self.configuration.mirrorHorizontally) {
        image = [image imageByApplyingTransform:CGAffineTransformMakeScale(-1, 1)];
    }
    CGFloat radians = atan2(self.sourceTransform.b, self.sourceTransform.a) +
        self.configuration.rotationDegrees * (CGFloat)M_PI / 180.0;
    if (fabs(radians) > 0.0001) {
        image = [image imageByApplyingTransform:CGAffineTransformMakeRotation(radians)];
    }

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
    self.displayTicks += 1;
    if (self.displayTicks % 300 == 0) {
        CGSize presentationSize = item.presentationSize;
        double liveLag = self.localVideo ? NAN : VCAMLiveEdgeLagSeconds(item);
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
    uint64_t now = VCAMSharedFrameMonotonicNanoseconds();
    if (!hasNewFrame) {
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
    BOOL surfaceTransport = self.surfaceWriter != NULL;
    BOOL surfaceConsumerReady = surfaceTransport &&
        VCAMSharedSurfaceWriterHasConsumer(self.surfaceWriter);
    CVPixelBufferRef destination = surfaceTransport
        ? VCAMSharedSurfaceWriterCopyNextPixelBuffer(self.surfaceWriter)
        : NULL;
    BOOL published = NO;
    CVReturn destinationStatus = destination != NULL ? kCVReturnSuccess
        : (surfaceTransport ? kCVReturnWouldExceedAllocationThreshold
                            : CVPixelBufferPoolCreatePixelBuffer(
                                  kCFAllocatorDefault, self.outputPool,
                                  &destination));
    if (destinationStatus == kCVReturnSuccess && destination != NULL) {
        CIImage *image = [self imageByTransformingPixelBuffer:source];
        if (image != nil) {
            CGRect target = CGRectMake(0, 0, VCAMSharedFrameWidth, VCAMSharedFrameHeight);
            [self.context render:image toCVPixelBuffer:destination bounds:target
                      colorSpace:self.colorSpace];
            if (surfaceTransport) {
                BOOL surfacePublished = VCAMSharedSurfaceWriterPublish(
                    self.surfaceWriter, destination);
                // Keep the compatibility path live until mediaserverd proves
                // that this OS/process pair can look up the global surface.
                published = surfacePublished && (surfaceConsumerReady ||
                    VCAMSharedFrameWriterPublish(self.writer, destination));
            } else {
                published = VCAMSharedFrameWriterPublish(self.writer, destination);
            }
        }
        CVPixelBufferRelease(destination);
    }
    CVPixelBufferRelease(source);
    if (published) {
        self.publishedFrames += 1;
        self.lastFrameTimestampNanoseconds = VCAMSharedFrameMonotonicNanoseconds();
    } else {
        self.publishFailures += 1;
    }
    if (self.decodedFrames <= 3 || self.decodedFrames % 300 == 0) {
        NSString *frameFormat = self.localVideo
            ? @"springboard local video frame decoded=%lu published=%lu empty=%lu failures=%lu transport=%@ status=%ld rate=%.1f"
            : @"springboard HLS frame decoded=%lu published=%lu empty=%lu failures=%lu transport=%@ status=%ld rate=%.1f";
        [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:frameFormat,
            (unsigned long)self.decodedFrames, (unsigned long)self.publishedFrames,
            (unsigned long)self.emptyCopies, (unsigned long)self.publishFailures,
            surfaceTransport
                ? (surfaceConsumerReady ? @"iosurface" : @"iosurface+bootstrap-mmap")
                : @"mmap",
            (long)self.player.currentItem.status, self.player.rate]];
    }
}

- (NSDictionary<NSString *, id> *)healthSnapshot {
    return @{
        @"running": @(self.player != nil && self.displayLink != nil),
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

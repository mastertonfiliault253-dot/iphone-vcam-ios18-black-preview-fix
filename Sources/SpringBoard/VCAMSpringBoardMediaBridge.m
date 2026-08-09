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
@property(nonatomic, strong, nullable) CIContext *context;
@property(nonatomic, strong, nullable) id<MTLDevice> metalDevice;
@property(nonatomic) CVPixelBufferPoolRef outputPool;
@property(nonatomic) CGColorSpaceRef colorSpace;
@property(nonatomic) VCAMSharedFrameWriter *writer;
@property(nonatomic) VCAMSharedSurfaceWriter *surfaceWriter;
@property(nonatomic) BOOL started;
@property(nonatomic) NSUInteger decodedFrames;
@property(nonatomic) NSUInteger emptyCopies;
@property(nonatomic) NSUInteger publishedFrames;
@property(nonatomic) NSUInteger publishFailures;
@property(nonatomic) uint64_t lastFrameTimestampNanoseconds;
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
    [self.displayLink invalidate];
    self.displayLink = nil;
    [self.player pause];
    [self.playerLayer removeFromSuperlayer];
    self.playerLayer = nil;
    if (self.output != nil && [self.player.currentItem.outputs containsObject:self.output]) {
        [self.player.currentItem removeOutput:self.output];
    }
    self.output = nil;
    self.player = nil;
    self.configuration = nil;
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
    return [self.configuration.hlsURL isEqual:configuration.hlsURL] &&
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
    BOOL legacyDaemon = access(VCAMLegacyHLSDaemonMarker, F_OK) == 0;
    BOOL shouldPlay = next.enabled && next.sourceKind == VCAMSourceKindHLS &&
        next.hlsURL != nil && !legacyDaemon;
    if (!shouldPlay) {
        [self stopPlayback];
        return;
    }
    if (self.player != nil && [self configurationMatches:next]) return;
    [self stopPlayback];
    self.configuration = next;
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
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:next.hlsURL];
    [item addOutput:self.output];
    self.player = [AVPlayer playerWithPlayerItem:item];
    self.player.automaticallyWaitsToMinimizeStalling = YES;

    // A compositor-attached AVPlayerLayer keeps the system decode path active.
    // One near-transparent pixel is imperceptible and avoids a full-screen
    // overlay while AVPlayerItemVideoOutput supplies the real frames.
    self.playerLayer = [AVPlayerLayer playerLayerWithPlayer:self.player];
    self.playerLayer.frame = CGRectMake(0, 0, 1, 1);
    self.playerLayer.opacity = 0.01f;
    [[self hostWindow].layer addSublayer:self.playerLayer];

    self.decodedFrames = 0;
    self.emptyCopies = 0;
    self.publishedFrames = 0;
    self.publishFailures = 0;
    self.lastFrameTimestampNanoseconds = 0;
    self.lastError = nil;
    [self.player play];
    self.displayLink = [CADisplayLink displayLinkWithTarget:self
                                                   selector:@selector(tick:)];
    self.displayLink.preferredFramesPerSecond =
        MAX(1, MIN(60, next.preferredFramesPerSecond));
    [self.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
        @"springboard HLS start url=%@ output=%d layer=%d fps=%ld",
        next.hlsURL.absoluteString, [item.outputs containsObject:self.output],
        self.playerLayer.superlayer != nil,
        (long)self.displayLink.preferredFramesPerSecond]];
}

- (nullable CIImage *)imageByTransformingPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    if (pixelBuffer == NULL || self.configuration == nil) return nil;
    CIImage *image = [CIImage imageWithCVPixelBuffer:pixelBuffer];
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
    CMTime itemTime = [self.output itemTimeForHostTime:CACurrentMediaTime()];
    if (![self.output hasNewPixelBufferForItemTime:itemTime]) return;
    CMTime displayTime = kCMTimeInvalid;
    CVPixelBufferRef source = [self.output copyPixelBufferForItemTime:itemTime
                                                   itemTimeForDisplay:&displayTime];
    if (source == NULL) {
        self.emptyCopies += 1;
        return;
    }
    self.decodedFrames += 1;
    BOOL surfaceTransport = self.surfaceWriter != NULL;
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
            published = surfaceTransport
                ? VCAMSharedSurfaceWriterPublish(self.surfaceWriter, destination)
                : VCAMSharedFrameWriterPublish(self.writer, destination);
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
        [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
            @"springboard HLS frame decoded=%lu published=%lu empty=%lu failures=%lu transport=%@ status=%ld rate=%.1f",
            (unsigned long)self.decodedFrames, (unsigned long)self.publishedFrames,
            (unsigned long)self.emptyCopies, (unsigned long)self.publishFailures,
            surfaceTransport ? @"iosurface" : @"mmap",
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
        @"transport": self.surfaceWriter != NULL ? @"iosurface" : @"mmap",
        @"error": self.lastError ?: self.player.currentItem.error.localizedDescription ?: @"",
    };
}

@end

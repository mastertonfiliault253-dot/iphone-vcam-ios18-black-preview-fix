#import "VCAMPreviewDriver.h"
#import <UIKit/UIKit.h>
#import "../Core/VCAMFramePipeline.h"
#import "../Core/VCAMConfiguration.h"
#import "../Shared/VCAMSystemVersion.h"

@interface VCAMPreviewDriver ()
@property(nonatomic, weak) AVCaptureVideoPreviewLayer *previewLayer;
@property(nonatomic, strong) AVPlayerLayer *localPlayerLayer;
@property(nonatomic, strong) AVSampleBufferDisplayLayer *replacementLayer;
@property(nonatomic, strong) CADisplayLink *displayLink;
@property(nonatomic) dispatch_queue_t frameQueue;
@property(atomic) BOOL frameInFlight;
@property(nonatomic) NSInteger configuredFramesPerSecond;
@end


@implementation VCAMPreviewDriver

- (instancetype)initWithPreviewLayer:(AVCaptureVideoPreviewLayer *)previewLayer {
    self = [super init];
    if (self) {
        _previewLayer = previewLayer;
        _localPlayerLayer = [AVPlayerLayer playerLayerWithPlayer:nil];
        _localPlayerLayer.videoGravity = previewLayer.videoGravity;
        _localPlayerLayer.hidden = YES;
        [previewLayer addSublayer:_localPlayerLayer];
        _replacementLayer = [AVSampleBufferDisplayLayer layer];
        _replacementLayer.videoGravity = previewLayer.videoGravity;
        _replacementLayer.hidden = YES;
        [previewLayer addSublayer:_replacementLayer];
        [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:@"preview driver installed bounds=%.0fx%.0f", previewLayer.bounds.size.width, previewLayer.bounds.size.height]];
        _frameQueue = dispatch_queue_create("com.codex.vcam.preview", DISPATCH_QUEUE_SERIAL);
        _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(displayTick:)];
        if (VCAMSystemVersionAtLeast(15, 0)) {
            _displayLink.preferredFrameRateRange = CAFrameRateRangeMake(15, 30, 30);
        } else {
            _displayLink.preferredFramesPerSecond = 30;
        }
        _configuredFramesPerSecond = 30;
        [_displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
    return self;
}

- (void)dealloc {
    [self.displayLink invalidate];
    self.localPlayerLayer.player = nil;
    [self.replacementLayer flushAndRemoveImage];
}

- (void)displayTick:(CADisplayLink *)displayLink {
    AVCaptureVideoPreviewLayer *preview = self.previewLayer;
    if (preview == nil) {
        [displayLink invalidate];
        return;
    }
    self.localPlayerLayer.frame = preview.bounds;
    self.localPlayerLayer.videoGravity = preview.videoGravity;
    self.replacementLayer.frame = preview.bounds;
    self.replacementLayer.videoGravity = preview.videoGravity;
    VCAMFramePipeline *pipeline = [VCAMFramePipeline sharedPipeline];
    static NSUInteger vcamTickCounter = 0;
    if ((vcamTickCounter++ % 60) == 0) {
        [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:@"preview tick=%lu enabled=%d player=%d localHidden=%d replHidden=%d", (unsigned long)vcamTickCounter, [pipeline isEnabled], [pipeline localPreviewPlayer] != nil, self.localPlayerLayer.hidden, self.replacementLayer.hidden]];
    }
    NSInteger preferredFramesPerSecond = [pipeline preferredFramesPerSecond];
    if (preferredFramesPerSecond != self.configuredFramesPerSecond) {
        self.configuredFramesPerSecond = preferredFramesPerSecond;
        if (VCAMSystemVersionAtLeast(15, 0)) {
            NSInteger minimum = MIN(15, preferredFramesPerSecond);
            displayLink.preferredFrameRateRange = CAFrameRateRangeMake(minimum,
                                                                       preferredFramesPerSecond,
                                                                       preferredFramesPerSecond);
        } else {
            displayLink.preferredFramesPerSecond = preferredFramesPerSecond;
        }
    }
    if (![pipeline isEnabled]) {
        self.localPlayerLayer.hidden = YES;
        self.localPlayerLayer.player = nil;
        self.replacementLayer.hidden = YES;
        [self.replacementLayer flushAndRemoveImage];
        return;
    }
    AVPlayer *localPlayer = [pipeline localPreviewPlayer];
    if (localPlayer != nil) {
        if (self.localPlayerLayer.player != localPlayer) {
            self.localPlayerLayer.player = localPlayer;
        }
        self.localPlayerLayer.hidden = NO;
        [pipeline tickLocalPreviewDiagnostics];
        if (!self.replacementLayer.hidden) {
            self.replacementLayer.hidden = YES;
            [self.replacementLayer flushAndRemoveImage];
        }
        return;
    }
    self.localPlayerLayer.hidden = YES;
    self.localPlayerLayer.player = nil;
    if (self.frameInFlight) return;
    self.frameInFlight = YES;
    CGFloat pixelScale = MAX(1.0, UIScreen.mainScreen.nativeScale);
    CGSize targetSize = CGSizeMake(round(preview.bounds.size.width * pixelScale),
                                   round(preview.bounds.size.height * pixelScale));
    self.replacementLayer.contentsScale = pixelScale;
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.frameQueue, ^{
        BOOL directPreviewSupported = NO;
        CMSampleBufferRef sample = [pipeline copyDirectPreviewVideoSample:&directPreviewSupported];
        if (!directPreviewSupported) {
            sample = [pipeline copyPreviewVideoForSize:targetSize];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (self == nil) {
                if (sample != NULL) CFRelease(sample);
                return;
            }
            if (sample != NULL && [pipeline isEnabled]) {
                self.replacementLayer.hidden = NO;
                if (self.replacementLayer.status == AVQueuedSampleBufferRenderingStatusFailed) {
                    [self.replacementLayer flush];
                }
                if (self.replacementLayer.readyForMoreMediaData) {
                    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, true);
                    if (attachments != NULL && CFArrayGetCount(attachments) > 0) {
                        CFMutableDictionaryRef attachment = (CFMutableDictionaryRef)
                            CFArrayGetValueAtIndex(attachments, 0);
                        CFDictionarySetValue(attachment,
                                             kCMSampleAttachmentKey_DisplayImmediately,
                                             kCFBooleanTrue);
                    }
                    [self.replacementLayer enqueueSampleBuffer:sample];
                }
                CFRelease(sample);
            } else if (sample != NULL) {
                CFRelease(sample);
            }
            self.frameInFlight = NO;
        });
    });
}

@end

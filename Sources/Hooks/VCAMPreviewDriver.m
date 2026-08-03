#import "VCAMPreviewDriver.h"
#import <UIKit/UIKit.h>
#import "../Core/VCAMFramePipeline.h"

@interface VCAMPreviewDriver ()
@property(nonatomic, weak) AVCaptureVideoPreviewLayer *previewLayer;
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
        _replacementLayer = [AVSampleBufferDisplayLayer layer];
        _replacementLayer.videoGravity = previewLayer.videoGravity;
        _replacementLayer.hidden = YES;
        [previewLayer addSublayer:_replacementLayer];
        _frameQueue = dispatch_queue_create("com.codex.vcam.preview", DISPATCH_QUEUE_SERIAL);
        _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(displayTick:)];
        if (@available(iOS 15.0, *)) {
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
    [self.replacementLayer flushAndRemoveImage];
}

- (void)displayTick:(CADisplayLink *)displayLink {
    AVCaptureVideoPreviewLayer *preview = self.previewLayer;
    if (preview == nil) {
        [displayLink invalidate];
        return;
    }
    self.replacementLayer.frame = preview.bounds;
    self.replacementLayer.videoGravity = preview.videoGravity;
    VCAMFramePipeline *pipeline = [VCAMFramePipeline sharedPipeline];
    NSInteger preferredFramesPerSecond = [pipeline preferredFramesPerSecond];
    if (preferredFramesPerSecond != self.configuredFramesPerSecond) {
        self.configuredFramesPerSecond = preferredFramesPerSecond;
        if (@available(iOS 15.0, *)) {
            NSInteger minimum = MIN(15, preferredFramesPerSecond);
            displayLink.preferredFrameRateRange = CAFrameRateRangeMake(minimum,
                                                                       preferredFramesPerSecond,
                                                                       preferredFramesPerSecond);
        } else {
            displayLink.preferredFramesPerSecond = preferredFramesPerSecond;
        }
    }
    if (![pipeline isEnabled]) {
        self.replacementLayer.hidden = YES;
        [self.replacementLayer flushAndRemoveImage];
        return;
    }
    if (self.frameInFlight) return;
    self.frameInFlight = YES;
    CGFloat pixelScale = MAX(1.0, UIScreen.mainScreen.nativeScale);
    CGSize targetSize = CGSizeMake(round(preview.bounds.size.width * pixelScale),
                                   round(preview.bounds.size.height * pixelScale));
    self.replacementLayer.contentsScale = pixelScale;
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.frameQueue, ^{
        CMSampleBufferRef sample = [pipeline copyPreviewVideoForSize:targetSize];
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

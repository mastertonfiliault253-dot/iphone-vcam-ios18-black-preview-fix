#import "VCAMSharedFramePreviewView.h"

#import <AVFoundation/AVFoundation.h>
#import "../Shared/VCAMSharedFrame.h"
#import "../Shared/VCAMSystemVersion.h"

@interface VCAMSharedFramePreviewView () {
    VCAMSharedFrameReader *_reader;
    CVPixelBufferPoolRef _pixelBufferPool;
    CMVideoFormatDescriptionRef _formatDescription;
}
@property(nonatomic, strong) CADisplayLink *displayLink;
@property(nonatomic) uint64_t lastSequence;
@end

@implementation VCAMSharedFramePreviewView

+ (Class)layerClass {
    return AVSampleBufferDisplayLayer.class;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.blackColor;
        self.layer.cornerRadius = 14.0;
        self.layer.masksToBounds = YES;
        AVSampleBufferDisplayLayer *displayLayer = (AVSampleBufferDisplayLayer *)self.layer;
        displayLayer.videoGravity = AVLayerVideoGravityResizeAspect;
        _reader = VCAMSharedFrameReaderCreate();
        NSDictionary *poolAttributes = @{(id)kCVPixelBufferPoolMinimumBufferCountKey: @3};
        NSDictionary *pixelAttributes = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferWidthKey: @(VCAMSharedFrameWidth),
            (id)kCVPixelBufferHeightKey: @(VCAMSharedFrameHeight),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        };
        CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                (__bridge CFDictionaryRef)poolAttributes,
                                (__bridge CFDictionaryRef)pixelAttributes,
                                &_pixelBufferPool);
        _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(displayTick:)];
        if (VCAMSystemVersionAtLeast(15, 0)) {
            _displayLink.preferredFrameRateRange = CAFrameRateRangeMake(10, 15, 15);
        } else {
            _displayLink.preferredFramesPerSecond = 15;
        }
        [_displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
    return self;
}

- (void)dealloc {
    [self.displayLink invalidate];
    VCAMSharedFrameReaderDestroy(_reader);
    if (_pixelBufferPool != NULL) CVPixelBufferPoolRelease(_pixelBufferPool);
    if (_formatDescription != NULL) CFRelease(_formatDescription);
}

- (void)displayTick:(CADisplayLink *)displayLink {
    (void)displayLink;
    if (_reader == NULL || _pixelBufferPool == NULL) return;
    CVPixelBufferRef pixelBuffer = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _pixelBufferPool,
                                           &pixelBuffer) != kCVReturnSuccess) return;
    VCAMSharedFrameMetadata metadata = {0};
    BOOL copied = VCAMSharedFrameReaderCopyLatest(_reader, pixelBuffer,
                                                  1000000000ULL, &metadata);
    if (!copied || metadata.sequence == self.lastSequence) {
        CVPixelBufferRelease(pixelBuffer);
        return;
    }
    self.lastSequence = metadata.sequence;
    if (_formatDescription == NULL) {
        CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer,
                                                      &_formatDescription);
    }
    CMSampleBufferRef sample = NULL;
    CMSampleTimingInfo timing = {
        .duration = CMTimeMake(1, 15),
        .presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock()),
        .decodeTimeStamp = kCMTimeInvalid,
    };
    if (_formatDescription != NULL) {
        CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, true,
                                           NULL, NULL, _formatDescription, &timing,
                                           &sample);
    }
    CVPixelBufferRelease(pixelBuffer);
    if (sample == NULL) return;
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, true);
    if (attachments != NULL && CFArrayGetCount(attachments) > 0) {
        CFMutableDictionaryRef attachment =
            (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
        CFDictionarySetValue(attachment, kCMSampleAttachmentKey_DisplayImmediately,
                             kCFBooleanTrue);
    }
    AVSampleBufferDisplayLayer *layer = (AVSampleBufferDisplayLayer *)self.layer;
    if (layer.status == AVQueuedSampleBufferRenderingStatusFailed) [layer flush];
    [layer enqueueSampleBuffer:sample];
    CFRelease(sample);
}

@end

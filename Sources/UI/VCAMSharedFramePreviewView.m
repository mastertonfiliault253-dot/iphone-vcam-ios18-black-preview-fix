#import "VCAMSharedFramePreviewView.h"

#import <AVFoundation/AVFoundation.h>
#import "../Shared/VCAMSharedFrame.h"

@interface VCAMSharedFramePreviewView () {
    VCAMSharedFrameReader *_reader;
    VCAMSharedSurfaceReader *_surfaceReader;
    CVPixelBufferPoolRef _pixelBufferPool;
    CMVideoFormatDescriptionRef _formatDescription;
    OSType _formatPixelFormat;
    size_t _formatWidth;
    size_t _formatHeight;
}
@property(nonatomic, strong) CADisplayLink *displayLink;
@property(nonatomic) uint64_t lastSequence;
@property(nonatomic) uint64_t lastSurfaceGeneration;
@property(nonatomic) BOOL hasLastFrame;
@property(nonatomic) BOOL lastFrameWasSurface;
@end

static NSUInteger VCAMPreviewWindowFrames;
static CFTimeInterval VCAMPreviewWindowStart;

static BOOL VCAMPreviewGetLatestMetadata(
    VCAMSharedFrameReader *frameReader,
    VCAMSharedSurfaceReader *surfaceReader,
    uint64_t maximumAge,
    VCAMSharedFrameMetadata *metadataOut,
    BOOL *surfaceOut) {
    VCAMSharedFrameMetadata frameMetadata = {0};
    VCAMSharedFrameMetadata surfaceMetadata = {0};
    BOOL hasFrame = frameReader != NULL &&
        VCAMSharedFrameReaderGetLatestMetadata(
            frameReader, maximumAge, &frameMetadata);
    BOOL hasSurface = surfaceReader != NULL &&
        VCAMSharedSurfaceReaderGetLatestMetadata(
            surfaceReader, maximumAge, &surfaceMetadata);
    if (!hasFrame && !hasSurface) return NO;
    BOOL useSurface = hasSurface && (!hasFrame ||
        surfaceMetadata.monotonicTimestampNanoseconds >=
            frameMetadata.monotonicTimestampNanoseconds);
    if (metadataOut != NULL) {
        *metadataOut = useSurface ? surfaceMetadata : frameMetadata;
    }
    if (surfaceOut != NULL) *surfaceOut = useSurface;
    return YES;
}

@implementation VCAMSharedFramePreviewView

+ (NSDictionary<NSString *, id> *)streamingStatus {
    NSAssert(NSThread.isMainThread, @"VCAM stream health requires main thread");
    static VCAMSharedFrameReader *frameReader;
    static VCAMSharedSurfaceReader *surfaceReader;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        frameReader = VCAMSharedFrameReaderCreate();
        surfaceReader = VCAMSharedSurfaceReaderCreate();
    });
    const uint64_t maximumAge = 2000000000ULL;
    VCAMSharedFrameMetadata metadata = {0};
    BOOL hasMetadata = VCAMPreviewGetLatestMetadata(
        frameReader, surfaceReader, maximumAge, &metadata, NULL);
    uint64_t timestamp = hasMetadata
        ? metadata.monotonicTimestampNanoseconds : 0;
    uint64_t monotonicNow = VCAMSharedFrameMonotonicNanoseconds();
    BOOL receiving = timestamp > 0 && monotonicNow >= timestamp &&
        monotonicNow - timestamp <= maximumAge;
    CFTimeInterval now = CACurrentMediaTime();
    double ageMilliseconds = receiving
        ? (double)(monotonicNow - timestamp) / 1000000.0 : 0;
    double fps = 0;
    if (VCAMPreviewWindowStart > 0) {
        CFTimeInterval elapsed = now - VCAMPreviewWindowStart;
        if (elapsed >= 0.9) {
            fps = (double)VCAMPreviewWindowFrames / elapsed;
        }
    }
    return @{
        @"receiving": @(receiving),
        @"ageMs": @(ageMilliseconds),
        @"fps": @(fps),
    };
}

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
        _surfaceReader = VCAMSharedSurfaceReaderCreate();
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
        if (@available(iOS 15.0, *)) {
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
    VCAMSharedSurfaceReaderDestroy(_surfaceReader);
    if (_pixelBufferPool != NULL) CVPixelBufferPoolRelease(_pixelBufferPool);
    if (_formatDescription != NULL) CFRelease(_formatDescription);
}

- (void)displayTick:(CADisplayLink *)displayLink {
    (void)displayLink;
    if ((_reader == NULL && _surfaceReader == NULL) || _pixelBufferPool == NULL) return;
    const uint64_t maximumAge = 1000000000ULL;
    BOOL frameWasSurface = NO;
    if (!VCAMPreviewGetLatestMetadata(
            _reader, _surfaceReader, maximumAge, NULL, &frameWasSurface)) return;

    CVPixelBufferRef pixelBuffer = NULL;
    VCAMSharedFrameMetadata metadata = {0};
    VCAMSharedSurfaceFrame surfaceFrame = {0};
    if (frameWasSurface) {
        if (!VCAMSharedSurfaceReaderCopyLatestPassive(
                _surfaceReader, maximumAge, &surfaceFrame)) return;
        pixelBuffer = surfaceFrame.pixelBuffer;
        metadata = surfaceFrame.metadata;
    } else {
        if (CVPixelBufferPoolCreatePixelBuffer(
                kCFAllocatorDefault, _pixelBufferPool, &pixelBuffer) !=
                kCVReturnSuccess) return;
        if (!VCAMSharedFrameReaderCopyLatest(
                _reader, pixelBuffer, maximumAge, &metadata)) {
            CVPixelBufferRelease(pixelBuffer);
            return;
        }
    }
    if (self.hasLastFrame && metadata.sequence == self.lastSequence &&
        frameWasSurface == self.lastFrameWasSurface &&
        metadata.surfaceGeneration == self.lastSurfaceGeneration) {
        if (frameWasSurface) VCAMSharedSurfaceFrameRelease(&surfaceFrame);
        else CVPixelBufferRelease(pixelBuffer);
        return;
    }
    OSType pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);
    size_t width = CVPixelBufferGetWidth(pixelBuffer);
    size_t height = CVPixelBufferGetHeight(pixelBuffer);
    AVSampleBufferDisplayLayer *layer = (AVSampleBufferDisplayLayer *)self.layer;
    if (_formatDescription == NULL || pixelFormat != _formatPixelFormat ||
        width != _formatWidth || height != _formatHeight) {
        if (_formatDescription != NULL) CFRelease(_formatDescription);
        _formatDescription = NULL;
        CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer,
                                                      &_formatDescription);
        if (_formatDescription != NULL) {
            _formatPixelFormat = pixelFormat;
            _formatWidth = width;
            _formatHeight = height;
            [layer flush];
        }
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
    if (sample == NULL) {
        if (frameWasSurface) VCAMSharedSurfaceFrameRelease(&surfaceFrame);
        else CVPixelBufferRelease(pixelBuffer);
        return;
    }
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, true);
    if (attachments != NULL && CFArrayGetCount(attachments) > 0) {
        CFMutableDictionaryRef attachment =
            (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
        CFDictionarySetValue(attachment, kCMSampleAttachmentKey_DisplayImmediately,
                             kCFBooleanTrue);
    }
    if (layer.status == AVQueuedSampleBufferRenderingStatusFailed) [layer flush];
    [layer enqueueSampleBuffer:sample];
    CFTimeInterval now = CACurrentMediaTime();
    VCAMPreviewWindowFrames += 1;
    if (VCAMPreviewWindowStart == 0) VCAMPreviewWindowStart = now;
    if (now - VCAMPreviewWindowStart >= 1.0) {
        VCAMPreviewWindowStart = now;
        VCAMPreviewWindowFrames = 0;
    }
    self.lastSequence = metadata.sequence;
    self.lastSurfaceGeneration = metadata.surfaceGeneration;
    self.hasLastFrame = YES;
    self.lastFrameWasSurface = frameWasSurface;
    CFRelease(sample);
    if (frameWasSurface) VCAMSharedSurfaceFrameRelease(&surfaceFrame);
    else CVPixelBufferRelease(pixelBuffer);
}

@end

#import "VCAMSharedFramePreviewView.h"

#import <AVFoundation/AVFoundation.h>
#import "../Core/VCAMConfiguration.h"
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
@property(nonatomic, strong) UIImageView *brokerImageView;
@property(nonatomic) BOOL brokerFetchInFlight;
@property(nonatomic) uint64_t lastBrokerFetchNanoseconds;
@end

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

static BOOL VCAMPreviewGetBrokerMetadata(
    NSDictionary<NSString *, id> *snapshot,
    VCAMSharedFrameMetadata *metadataOut,
    BOOL *surfaceOut) {
    NSNumber *sequence = [snapshot[@"sequence"] isKindOfClass:NSNumber.class]
        ? snapshot[@"sequence"] : nil;
    NSNumber *timestamp = [snapshot[@"timestampNs"] isKindOfClass:NSNumber.class]
        ? snapshot[@"timestampNs"] : nil;
    NSNumber *width = [snapshot[@"width"] isKindOfClass:NSNumber.class]
        ? snapshot[@"width"] : nil;
    NSNumber *height = [snapshot[@"height"] isKindOfClass:NSNumber.class]
        ? snapshot[@"height"] : nil;
    if (sequence == nil || timestamp == nil || width == nil || height == nil ||
        sequence.unsignedLongLongValue == 0 ||
        timestamp.unsignedLongLongValue == 0 ||
        width.unsignedIntValue == 0 || height.unsignedIntValue == 0) return NO;
    if (metadataOut != NULL) {
        metadataOut->sequence = sequence.unsignedLongLongValue;
        metadataOut->monotonicTimestampNanoseconds =
            timestamp.unsignedLongLongValue;
        metadataOut->width = width.unsignedIntValue;
        metadataOut->height = height.unsignedIntValue;
        metadataOut->surfaceGeneration =
            [snapshot[@"surfaceGeneration"] unsignedLongLongValue];
    }
    if (surfaceOut != NULL) *surfaceOut = [snapshot[@"surface"] boolValue];
    return YES;
}

@implementation VCAMSharedFramePreviewView

+ (NSDictionary<NSString *, id> *)streamingStatus {
    NSAssert(NSThread.isMainThread, @"VCAM stream health requires main thread");
    static VCAMSharedFrameReader *frameReader;
    static VCAMSharedSurfaceReader *surfaceReader;
    static uint64_t lastSequence;
    static uint64_t lastSurfaceGeneration;
    static uint64_t lastMeasurementNanoseconds;
    static double measuredFPS;
    static BOOL lastWasSurface;
    static BOOL hasMeasurement;
    static NSDictionary<NSString *, id> *brokerMetadata;
    static BOOL brokerStatusFetchInFlight;
    static uint64_t lastBrokerStatusFetchNanoseconds;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        frameReader = VCAMSharedFrameReaderCreate();
        surfaceReader = VCAMSharedSurfaceReaderCreate();
    });
    const uint64_t maximumAge = 2000000000ULL;
    VCAMSharedFrameMetadata metadata = {0};
    BOOL frameWasSurface = NO;
    BOOL hasMetadata = VCAMPreviewGetLatestMetadata(
        frameReader, surfaceReader, maximumAge, &metadata, &frameWasSurface);
    if (!hasMetadata) {
        hasMetadata = VCAMPreviewGetBrokerMetadata(
            brokerMetadata, &metadata, &frameWasSurface);
        uint64_t now = VCAMSharedFrameMonotonicNanoseconds();
        BOOL retryDue = lastBrokerStatusFetchNanoseconds == 0 || now == 0 ||
            now - lastBrokerStatusFetchNanoseconds >= 250000000ULL;
        if (!brokerStatusFetchInFlight && retryDue) {
            brokerStatusFetchInFlight = YES;
            lastBrokerStatusFetchNanoseconds = now;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                NSDictionary<NSString *, id> *snapshot =
                    [VCAMConfiguration copyPreviewSnapshotFromBroker];
                NSMutableDictionary<NSString *, id> *metadataOnly =
                    [snapshot mutableCopy];
                [metadataOnly removeObjectForKey:@"jpegData"];
                dispatch_async(dispatch_get_main_queue(), ^{
                    brokerMetadata = metadataOnly;
                    brokerStatusFetchInFlight = NO;
                });
            });
        }
    }
    uint64_t timestamp = hasMetadata
        ? metadata.monotonicTimestampNanoseconds : 0;
    uint64_t monotonicNow = VCAMSharedFrameMonotonicNanoseconds();
    BOOL receiving = timestamp > 0 && monotonicNow >= timestamp &&
        monotonicNow - timestamp <= maximumAge;
    // A static local image publishes one frame and then idles; it is still the
    // active virtual stream, so a configured local media path counts as
    // receiving (green dot) until the user clears the source.
    if (!receiving) {
        NSDictionary *values = [VCAMConfiguration currentValues];
        BOOL enabled = [values[@"enabled"] boolValue];
        NSString *source = [values[@"source"] isKindOfClass:NSString.class]
            ? values[@"source"] : nil;
        NSString *mediaPath = [values[@"mediaPath"] isKindOfClass:NSString.class]
            ? values[@"mediaPath"] : nil;
        if (enabled && [source isEqualToString:@"local"] &&
            mediaPath.length > 0) {
            receiving = YES;
        }
    }
    double ageMilliseconds = receiving
        ? (double)(monotonicNow - timestamp) / 1000000.0 : 0;
    if (!receiving) {
        hasMeasurement = NO;
        measuredFPS = 0;
    } else {
        BOOL producerChanged = !hasMeasurement ||
            frameWasSurface != lastWasSurface ||
            metadata.surfaceGeneration != lastSurfaceGeneration ||
            metadata.sequence < lastSequence;
        if (producerChanged) {
            lastSequence = metadata.sequence;
            lastSurfaceGeneration = metadata.surfaceGeneration;
            lastMeasurementNanoseconds = monotonicNow;
            lastWasSurface = frameWasSurface;
            hasMeasurement = YES;
            measuredFPS = 0;
        } else if (metadata.sequence > lastSequence &&
                   monotonicNow - lastMeasurementNanoseconds >= 500000000ULL) {
            uint64_t elapsed = monotonicNow - lastMeasurementNanoseconds;
            measuredFPS = (double)(metadata.sequence - lastSequence) *
                1000000000.0 / (double)elapsed;
            lastSequence = metadata.sequence;
            lastMeasurementNanoseconds = monotonicNow;
        }
    }
    BOOL decodeHardware = ((metadata.transferFunction &
        VCAMSharedFrameDecodeHardwareMask) >> VCAMSharedFrameDecodeHardwareShift) == 1;
    return @{
        @"receiving": @(receiving),
        @"ageMs": @(ageMilliseconds),
        @"fps": @(measuredFPS),
        @"decodeHardware": @(decodeHardware),
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
        _brokerImageView = [[UIImageView alloc] initWithFrame:self.bounds];
        _brokerImageView.autoresizingMask =
            UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _brokerImageView.backgroundColor = UIColor.blackColor;
        _brokerImageView.contentMode = UIViewContentModeScaleAspectFit;
        _brokerImageView.hidden = YES;
        _brokerImageView.accessibilityIdentifier = @"vcam-broker-preview";
        [self addSubview:_brokerImageView];
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

- (void)requestBrokerPreviewIfNeeded {
    uint64_t now = VCAMSharedFrameMonotonicNanoseconds();
    if (self.brokerFetchInFlight ||
        (self.lastBrokerFetchNanoseconds != 0 && now != 0 &&
         now - self.lastBrokerFetchNanoseconds < 250000000ULL)) return;
    self.brokerFetchInFlight = YES;
    self.lastBrokerFetchNanoseconds = now;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary<NSString *, id> *snapshot =
            [VCAMConfiguration copyPreviewSnapshotFromBroker];
        NSData *jpegData = [snapshot[@"jpegData"] isKindOfClass:NSData.class]
            ? snapshot[@"jpegData"] : nil;
        UIImage *image = jpegData.length > 0
            ? [UIImage imageWithData:jpegData] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (strongSelf == nil) return;
            strongSelf.brokerFetchInFlight = NO;
            if (image == nil) return;
            if (VCAMPreviewGetLatestMetadata(
                    strongSelf->_reader, strongSelf->_surfaceReader,
                    1000000000ULL, NULL, NULL)) return;
            strongSelf.brokerImageView.image = image;
            strongSelf.brokerImageView.hidden = NO;
        });
    });
}

- (void)displayTick:(CADisplayLink *)displayLink {
    (void)displayLink;
    const uint64_t maximumAge = 1000000000ULL;
    BOOL frameWasSurface = NO;
    if (!VCAMPreviewGetLatestMetadata(
            _reader, _surfaceReader, maximumAge, NULL, &frameWasSurface)) {
        [self requestBrokerPreviewIfNeeded];
        return;
    }

    CVPixelBufferRef pixelBuffer = NULL;
    VCAMSharedFrameMetadata metadata = {0};
    VCAMSharedSurfaceFrame surfaceFrame = {0};
    if (frameWasSurface) {
        if (!VCAMSharedSurfaceReaderCopyLatestPassive(
                _surfaceReader, maximumAge, &surfaceFrame)) {
            [self requestBrokerPreviewIfNeeded];
            return;
        }
        pixelBuffer = surfaceFrame.pixelBuffer;
        metadata = surfaceFrame.metadata;
    } else {
        if (_pixelBufferPool == NULL) {
            [self requestBrokerPreviewIfNeeded];
            return;
        }
        if (CVPixelBufferPoolCreatePixelBuffer(
                kCFAllocatorDefault, _pixelBufferPool, &pixelBuffer) !=
                kCVReturnSuccess) {
            [self requestBrokerPreviewIfNeeded];
            return;
        }
        if (!VCAMSharedFrameReaderCopyLatest(
                _reader, pixelBuffer, maximumAge, &metadata)) {
            CVPixelBufferRelease(pixelBuffer);
            [self requestBrokerPreviewIfNeeded];
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
    self.brokerImageView.hidden = YES;
    self.lastSequence = metadata.sequence;
    self.lastSurfaceGeneration = metadata.surfaceGeneration;
    self.hasLastFrame = YES;
    self.lastFrameWasSurface = frameWasSurface;
    CFRelease(sample);
    if (frameWasSurface) VCAMSharedSurfaceFrameRelease(&surfaceFrame);
    else CVPixelBufferRelease(pixelBuffer);
}

@end

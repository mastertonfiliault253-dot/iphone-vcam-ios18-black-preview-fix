#import "VCAMHLSStreamSource.h"

#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>

@interface VCAMHLSStreamSource () {
    CVPixelBufferRef _latestPixelBuffer;
    CFTimeInterval _latestFrameHostTime;
    uint64_t _latestSequence;
    uint64_t _lastRenderedSequence;
    CMSampleBufferRef _lastRenderedSample;
    size_t _lastRenderedWidth;
    size_t _lastRenderedHeight;
    OSType _lastRenderedPixelFormat;
}
@property(nonatomic, strong) VCAMConfiguration *configuration;
@property(nonatomic, strong) VCAMFrameRenderer *renderer;
@property(nonatomic, strong, nullable) AVPlayer *player;
@property(nonatomic, strong, nullable) AVPlayerItem *playerItem;
@property(nonatomic, strong, nullable) AVPlayerItemVideoOutput *videoOutput;
@property(nonatomic, strong, nullable) id endTimeObserver;
@property(nonatomic, strong, nullable) dispatch_source_t pullTimer;
@property(nonatomic) BOOL running;
@property(nonatomic) BOOL playbackReady;
- (CVPixelBufferRef)copyLatestPixelBuffer CF_RETURNS_RETAINED;
@end

@implementation VCAMHLSStreamSource

- (instancetype)initWithConfiguration:(VCAMConfiguration *)configuration
                             renderer:(VCAMFrameRenderer *)renderer {
    self = [super init];
    if (self) {
        _configuration = configuration;
        _renderer = renderer;
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

- (BOOL)start:(NSError **)error {
    NSURL *url = self.configuration.hlsURL;
    if (url == nil) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"VCAMHLSStreamSource" code:1
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         @"HLS URL is missing"}];
        }
        return NO;
    }
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url
                                            options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @YES}];
    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
    NSDictionary *pixelAttributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey:
            @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
    };
    AVPlayerItemVideoOutput *output = [[AVPlayerItemVideoOutput alloc]
        initWithPixelBufferAttributes:pixelAttributes];
    output.suppressesPlayerRendering = YES;
    [item addOutput:output];
    AVPlayer *player = [AVPlayer playerWithPlayerItem:item];
    player.volume = 0.0;
    player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
    player.automaticallyWaitsToMinimizeStalling = NO;
    __weak typeof(self) weakSelf = self;
    self.endTimeObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                    object:item
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *notification) {
        (void)notification;
        __strong typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil || !strongSelf.configuration.loopMedia) return;
        [strongSelf.player seekToTime:kCMTimeZero
                    completionHandler:^(BOOL finished) {
            if (finished) [strongSelf.player play];
        }];
    }];
    self.player = player;
    self.playerItem = item;
    self.videoOutput = output;
    self.running = YES;
    self.playbackReady = NO;
    dispatch_source_t pullTimer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    uint64_t interval = NSEC_PER_SEC /
        (uint64_t)MAX(1, MIN(60, self.configuration.preferredFramesPerSecond));
    dispatch_source_set_timer(pullTimer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              interval, interval / 10);
    dispatch_source_set_event_handler(pullTimer, ^{
        __strong typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil || !strongSelf.running) return;
        CVPixelBufferRef fresh = [strongSelf copyLatestPixelBuffer];
        if (fresh == NULL) return;
        @synchronized (strongSelf) {
            strongSelf->_latestSequence += 1;
            if (strongSelf->_latestPixelBuffer != NULL) {
                CVPixelBufferRelease(strongSelf->_latestPixelBuffer);
            }
            strongSelf->_latestPixelBuffer = fresh;
            strongSelf->_latestFrameHostTime = CACurrentMediaTime();
            if (!strongSelf.playbackReady) {
                strongSelf.playbackReady = YES;
                [VCAMConfiguration appendProcessLog:
                    [NSString stringWithFormat:@"hls first frame sequence=%llu size=%zux%zu",
                        (unsigned long long)strongSelf->_latestSequence,
                        CVPixelBufferGetWidth(strongSelf->_latestPixelBuffer),
                        CVPixelBufferGetHeight(strongSelf->_latestPixelBuffer)]];
            }
        }
    });
    self.pullTimer = pullTimer;
    dispatch_resume(pullTimer);
    [player playImmediatelyAtRate:1.0];
    [VCAMConfiguration appendProcessLog:
        [NSString stringWithFormat:@"hls start output=%@", output]];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        __strong typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil || !strongSelf.running || strongSelf.playbackReady) return;
        [strongSelf.player playImmediatelyAtRate:1.0];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        __strong typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil || !strongSelf.running || strongSelf.playbackReady) return;
        [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
            @"hls first-frame timeout player=%ld control=%ld rate=%.2f reason=%@ item=%ld error=%@",
            (long)strongSelf.player.status,
            (long)strongSelf.player.timeControlStatus,
            strongSelf.player.rate,
            strongSelf.player.reasonForWaitingToPlay ?: @"(none)",
            (long)strongSelf.playerItem.status,
            strongSelf.playerItem.error.localizedDescription ?: @"(none)"]];
    });
    return YES;
}

- (void)stop {
    self.running = NO;
    if (self.pullTimer != nil) {
        dispatch_source_cancel(self.pullTimer);
        self.pullTimer = nil;
    }
    if (self.endTimeObserver != nil) {
        [[NSNotificationCenter defaultCenter] removeObserver:self.endTimeObserver];
        self.endTimeObserver = nil;
    }
    [self.player pause];
    self.player = nil;
    self.playerItem = nil;
    self.videoOutput = nil;
    @synchronized (self) {
        if (_latestPixelBuffer != NULL) {
            CVPixelBufferRelease(_latestPixelBuffer);
            _latestPixelBuffer = NULL;
        }
        if (_lastRenderedSample != NULL) {
            CFRelease(_lastRenderedSample);
            _lastRenderedSample = NULL;
        }
        _latestFrameHostTime = 0;
        _latestSequence = 0;
        _lastRenderedSequence = 0;
    }
}

- (CVPixelBufferRef)copyLatestPixelBuffer {
    CMTime itemTime = [self.videoOutput itemTimeForHostTime:CACurrentMediaTime()];
    if (!CMTIME_IS_NUMERIC(itemTime) ||
        ![self.videoOutput hasNewPixelBufferForItemTime:itemTime]) {
        // Live HLS can report a valid host-time mapping just ahead of the
        // newest decoded frame. Retry at the player's actual item time before
        // treating the tick as empty.
        itemTime = self.playerItem.currentTime;
    }
    if (!CMTIME_IS_NUMERIC(itemTime) ||
        ![self.videoOutput hasNewPixelBufferForItemTime:itemTime]) {
        return NULL;
    }
    CMTime displayTime = kCMTimeInvalid;
    CVPixelBufferRef pixelBuffer = [self.videoOutput
        copyPixelBufferForItemTime:itemTime itemTimeForDisplay:&displayTime];
    if (pixelBuffer == NULL) return NULL;
    return pixelBuffer;
}

- (CMSampleBufferRef)copyVideoSampleForTemplate:(CMSampleBufferRef)templateBuffer {
    if (!self.running || self.videoOutput == nil) return NULL;
    @synchronized (self) {
        if (_latestPixelBuffer == NULL) return NULL;
    }
    CVPixelBufferRef pixelBuffer = NULL;
    uint64_t sequence = 0;
    @synchronized (self) {
        pixelBuffer = CVPixelBufferRetain(_latestPixelBuffer);
        sequence = _latestSequence;
    }
    if (pixelBuffer == NULL) return NULL;
    CVImageBufferRef templateImage = CMSampleBufferGetImageBuffer(templateBuffer);
    size_t width = templateImage == NULL ? 0 : CVPixelBufferGetWidth(templateImage);
    size_t height = templateImage == NULL ? 0 : CVPixelBufferGetHeight(templateImage);
    OSType pixelFormat = templateImage == NULL ? 0
        : CVPixelBufferGetPixelFormatType(templateImage);
    @synchronized (self) {
        if (sequence == _lastRenderedSequence &&
            width == _lastRenderedWidth && height == _lastRenderedHeight &&
            pixelFormat == _lastRenderedPixelFormat &&
            _lastRenderedSample != NULL) {
            CMSampleTimingInfo timing = {
                .duration = CMSampleBufferGetDuration(templateBuffer),
                .presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(templateBuffer),
                .decodeTimeStamp = CMSampleBufferGetDecodeTimeStamp(templateBuffer),
            };
            CMSampleBufferRef sample = NULL;
            CMSampleBufferCreateCopyWithNewTiming(kCFAllocatorDefault,
                                                  _lastRenderedSample,
                                                  1, &timing, &sample);
            CVPixelBufferRelease(pixelBuffer);
            return sample;
        }
    }
    CMSampleBufferRef sample = [self.renderer copySampleFromPixelBuffer:pixelBuffer
                                                               template:templateBuffer
                                                          configuration:self.configuration];
    if (sample != NULL) {
        @synchronized (self) {
            if (_lastRenderedSample != NULL) CFRelease(_lastRenderedSample);
            _lastRenderedSample = NULL;
            CMSampleBufferCreateCopy(kCFAllocatorDefault, sample,
                                     &_lastRenderedSample);
            _lastRenderedSequence = sequence;
            _lastRenderedWidth = width;
            _lastRenderedHeight = height;
            _lastRenderedPixelFormat = pixelFormat;
        }
    }
    CVPixelBufferRelease(pixelBuffer);
    return sample;
}

- (CMSampleBufferRef)copyAudioSampleForTemplate:(CMSampleBufferRef)templateBuffer {
    (void)templateBuffer;
    return NULL;
}

@end

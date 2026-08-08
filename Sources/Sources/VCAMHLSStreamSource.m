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
@property(nonatomic) BOOL running;
@property(nonatomic) BOOL playbackReady;
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
    [player playImmediatelyAtRate:1.0];
    [VCAMConfiguration appendProcessLog:
        [NSString stringWithFormat:@"hls start output=%@", output]];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        __strong typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil || !strongSelf.running || strongSelf.playbackReady) return;
        [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
            @"hls first-frame timeout player=%ld control=%ld reason=%@ item=%ld error=%@",
            (long)strongSelf.player.status,
            (long)strongSelf.player.timeControlStatus,
            strongSelf.player.reasonForWaitingToPlay ?: @"(none)",
            (long)strongSelf.playerItem.status,
            strongSelf.playerItem.error.localizedDescription ?: @"(none)"]];
    });
    return YES;
}

- (void)stop {
    self.running = NO;
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

- (CVPixelBufferRef)copyLatestPixelBufferForTemplate:(CMSampleBufferRef)templateBuffer {
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
    (void)templateBuffer;
    return pixelBuffer;
}

- (CMSampleBufferRef)copyVideoSampleForTemplate:(CMSampleBufferRef)templateBuffer {
    if (!self.running || self.videoOutput == nil) return NULL;
    @synchronized (self) {
        // Pull a fresh decoded frame on every consumer tick so live HLS stays
        // live. Fall back to the cached frame when the player has no new
        // output yet (e.g. between segments or before the first keyframe).
        CVPixelBufferRef fresh = [self copyLatestPixelBufferForTemplate:templateBuffer];
        if (fresh != NULL) {
            _latestSequence += 1;
            if (_latestPixelBuffer != NULL) CVPixelBufferRelease(_latestPixelBuffer);
            _latestPixelBuffer = fresh;
            _latestFrameHostTime = CACurrentMediaTime();
        }
        if (_latestPixelBuffer == NULL) return NULL;
        if (!self.playbackReady) {
            self.playbackReady = YES;
            [VCAMConfiguration appendProcessLog:
                [NSString stringWithFormat:@"hls first frame sequence=%llu size=%zux%zu",
                    (unsigned long long)_latestSequence,
                    CVPixelBufferGetWidth(_latestPixelBuffer),
                    CVPixelBufferGetHeight(_latestPixelBuffer)]];
        }
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

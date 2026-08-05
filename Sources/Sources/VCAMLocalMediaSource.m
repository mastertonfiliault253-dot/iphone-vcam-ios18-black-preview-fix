#import "VCAMLocalMediaSource.h"
#import "../Core/VCAMConfiguration.h"
#import <ImageIO/ImageIO.h>
#import <QuartzCore/QuartzCore.h>
#import <fcntl.h>
#import <math.h>
#import <stdarg.h>
#import <stdlib.h>
#import <unistd.h>

static NSString * const VCAMDiagnosticPath = @"/var/mobile/Library/Preferences/com.codex.vcam.diagnostics.log";
static NSDictionary<NSString *, id> *VCAMLocalPerformanceSnapshot;

NSDictionary<NSString *, id> *VCAMLocalPlaybackPerformanceSnapshot(void) {
    @synchronized ([VCAMLocalMediaSource class]) {
        return [VCAMLocalPerformanceSnapshot copy] ?: @{};
    }
}

static void VCAMPublishLocalPerformanceSnapshot(NSDictionary<NSString *, id> *snapshot) {
    @synchronized ([VCAMLocalMediaSource class]) {
        VCAMLocalPerformanceSnapshot = [snapshot copy];
    }
}

static void VCAMWriteDiagnostic(NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    NSData *data = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    int descriptor = open(VCAMDiagnosticPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (descriptor < 0) return;
    (void)write(descriptor, data.bytes, data.length);
    (void)close(descriptor);
}

static int VCAMCompareDouble(const void *left, const void *right) {
    double a = *(const double *)left;
    double b = *(const double *)right;
    return (a > b) - (a < b);
}

@interface VCAMLocalMediaSource () {
    CGImageRef _stillImage;
    CVPixelBufferRef _currentPlayerPixelBuffer;
    CMTime _currentPlayerItemTime;
    CMSampleBufferRef _lastRenderedVideoSample;
    CMTime _lastRenderedSourcePTS;
    size_t _lastRenderedWidth;
    size_t _lastRenderedHeight;
    OSType _lastRenderedPixelFormat;
    NSUInteger _diagnosticCallbacks;
    NSUInteger _diagnosticNewFrames;
    NSUInteger _diagnosticMisses;
    NSUInteger _diagnosticOutputReconfigurations;
    NSUInteger _diagnosticTemplateSwitches;
    NSUInteger _diagnosticCacheHits;
    NSUInteger _diagnosticRenders;
    CFTimeInterval _diagnosticWindowStart;
    CFTimeInterval _diagnosticRenderTotal;
    CFTimeInterval _diagnosticRenderMaximum;
    CMTime _diagnosticWindowItemStart;
    OSType _diagnosticLastTemplateFormat;
    CMSampleBufferRef _tripleBGRAFrame;
    CMSampleBufferRef _tripleVideoRangeFrame;
    CMSampleBufferRef _tripleFullRangeFrame;
    CMTime _tripleCurrentPTS;
    CMTime _tripleMediaStartPTS;
    CFTimeInterval _tripleHostStart;
    CFTimeInterval _diagnosticLastSourceFrameHostTime;
    double _diagnosticSourceFrameIntervals[256];
    NSUInteger _diagnosticSourceFrameIntervalCount;
}
@property(nonatomic, strong) VCAMConfiguration *configuration;
@property(nonatomic, strong) VCAMFrameRenderer *renderer;
@property(nonatomic, strong, nullable) AVURLAsset *asset;
@property(nonatomic, strong, nullable) AVAssetReader *audioReader;
@property(nonatomic, strong, nullable) AVAssetReaderTrackOutput *audioOutput;
@property(nonatomic, strong, nullable) AVPlayerItem *playerItem;
@property(nonatomic, strong, nullable) AVPlayer *player;
@property(nonatomic, strong, nullable) AVPlayerItemVideoOutput *playerVideoOutput;
@property(nonatomic, strong, nullable) AVAssetReader *tripleVideoReader;
@property(nonatomic, strong, nullable) AVAssetReaderTrackOutput *tripleBGRAOutput;
@property(nonatomic, strong, nullable) AVAssetReaderTrackOutput *tripleVideoRangeOutput;
@property(nonatomic, strong, nullable) AVAssetReaderTrackOutput *tripleFullRangeOutput;
@property(nonatomic) Float64 audioSampleRate;
@property(nonatomic) UInt32 audioChannelCount;
@property(nonatomic) BOOL running;
@property(nonatomic) CGAffineTransform videoTransform;
@property(nonatomic) OSType playerOutputPixelFormat;
@end

@implementation VCAMLocalMediaSource

- (instancetype)initWithConfiguration:(VCAMConfiguration *)configuration
                              renderer:(VCAMFrameRenderer *)renderer {
    self = [super init];
    if (self) {
        _configuration = configuration;
        _renderer = renderer;
        _videoTransform = CGAffineTransformIdentity;
        _currentPlayerItemTime = kCMTimeInvalid;
        _lastRenderedSourcePTS = kCMTimeInvalid;
        _diagnosticWindowItemStart = kCMTimeInvalid;
        _tripleCurrentPTS = kCMTimeInvalid;
        _tripleMediaStartPTS = kCMTimeInvalid;
    }
    return self;
}

- (BOOL)start:(NSError **)error {
    NSString *path = self.configuration.mediaPath;
    [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:@"local start path=%@ exists=%d", path ?: @"(none)", [[NSFileManager defaultManager] fileExistsAtPath:path]]];
    if (path.length == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"VCAMLocalMediaSource"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Configured media file does not exist"}];
        }
        return NO;
    }

    NSURL *url = [NSURL fileURLWithPath:path];
    [[NSFileManager defaultManager] removeItemAtPath:VCAMDiagnosticPath error:nil];
    CGImageSourceRef imageSource = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (imageSource != NULL) {
        _stillImage = CGImageSourceCreateImageAtIndex(imageSource, 0, NULL);
        CFRelease(imageSource);
    }
    if (_stillImage == NULL) {
        self.asset = [AVURLAsset URLAssetWithURL:url options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @YES}];
        BOOL videoStarted = self.configuration.localDecoderMode == VCAMLocalDecoderModeUpstreamTriple
            ? [self startTripleVideoReader:error]
            : [self startVideoPlayer:error];
        if (!videoStarted) {
            return NO;
        }
        [self rebuildAudioReaderForSampleRate:0 channelCount:0 error:nil];
    }
    self.running = YES;
    [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:@"local start ok decoder=%ld still=%d asset=%d player=%d", (long)self.configuration.localDecoderMode, _stillImage != NULL, self.asset != nil, self.player != nil]];
    return YES;
}

- (void)stop {
    @synchronized (self) {
        [self.player pause];
        if (self.playerItem != nil) {
            [[NSNotificationCenter defaultCenter] removeObserver:self
                                                            name:AVPlayerItemDidPlayToEndTimeNotification
                                                          object:self.playerItem];
        }
        if (self.playerVideoOutput != nil) [self.playerItem removeOutput:self.playerVideoOutput];
        [self.audioReader cancelReading];
        [self.tripleVideoReader cancelReading];
        self.player = nil;
        self.playerItem = nil;
        self.playerVideoOutput = nil;
        self.audioReader = nil;
        self.audioOutput = nil;
        if (_stillImage != NULL) {
            CGImageRelease(_stillImage);
            _stillImage = NULL;
        }
        [self resetTripleVideoReaderState];
        [self resetVideoPlaybackState];
        VCAMPublishLocalPerformanceSnapshot(@{});
        self.running = NO;
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (_stillImage != NULL) CGImageRelease(_stillImage);
    [self resetTripleVideoReaderState];
    [self resetVideoPlaybackState];
}

- (void)releaseTripleFrames {
    if (_tripleBGRAFrame != NULL) CFRelease(_tripleBGRAFrame);
    if (_tripleVideoRangeFrame != NULL) CFRelease(_tripleVideoRangeFrame);
    if (_tripleFullRangeFrame != NULL) CFRelease(_tripleFullRangeFrame);
    _tripleBGRAFrame = NULL;
    _tripleVideoRangeFrame = NULL;
    _tripleFullRangeFrame = NULL;
    _tripleCurrentPTS = kCMTimeInvalid;
}

- (void)resetTripleVideoReaderState {
    [self.tripleVideoReader cancelReading];
    [self releaseTripleFrames];
    self.tripleVideoReader = nil;
    self.tripleBGRAOutput = nil;
    self.tripleVideoRangeOutput = nil;
    self.tripleFullRangeOutput = nil;
    _tripleMediaStartPTS = kCMTimeInvalid;
    _tripleHostStart = 0;
}

- (void)resetVideoPlaybackState {
    if (_currentPlayerPixelBuffer != NULL) CVPixelBufferRelease(_currentPlayerPixelBuffer);
    if (_lastRenderedVideoSample != NULL) CFRelease(_lastRenderedVideoSample);
    _currentPlayerPixelBuffer = NULL;
    _currentPlayerItemTime = kCMTimeInvalid;
    _lastRenderedVideoSample = NULL;
    _lastRenderedSourcePTS = kCMTimeInvalid;
    _lastRenderedWidth = 0;
    _lastRenderedHeight = 0;
    _lastRenderedPixelFormat = 0;
}

- (void)recordDiagnosticSourceFrame {
    CFTimeInterval now = CACurrentMediaTime();
    if (_diagnosticLastSourceFrameHostTime > 0 && _diagnosticSourceFrameIntervalCount < 256) {
        _diagnosticSourceFrameIntervals[_diagnosticSourceFrameIntervalCount++] =
            (now - _diagnosticLastSourceFrameHostTime) * 1000.0;
    }
    _diagnosticLastSourceFrameHostTime = now;
}

- (void)resetDiagnosticWindow {
    _diagnosticCallbacks = 0;
    _diagnosticNewFrames = 0;
    _diagnosticMisses = 0;
    _diagnosticOutputReconfigurations = 0;
    _diagnosticTemplateSwitches = 0;
    _diagnosticCacheHits = 0;
    _diagnosticRenders = 0;
    _diagnosticRenderTotal = 0;
    _diagnosticRenderMaximum = 0;
    _diagnosticSourceFrameIntervalCount = 0;
    _diagnosticLastSourceFrameHostTime = 0;
    _diagnosticWindowStart = 0;
    _diagnosticWindowItemStart = kCMTimeInvalid;
}

- (BOOL)startTripleVideoReader:(NSError **)error {
    [self resetVideoPlaybackState];
    AVAssetTrack *videoTrack = [[self.asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    if (videoTrack == nil) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"VCAMLocalMediaSource"
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey: @"Media contains neither an image nor a video track"}];
        }
        return NO;
    }
    self.videoTransform = videoTrack.preferredTransform;
    CGFloat transformAngle = atan2(self.videoTransform.b, self.videoTransform.a) * 180.0 / M_PI;
    VCAMWriteDiagnostic(
        @"[DEBUG-vcamdiag] asset decoderMode=upstreamTriple natural=%.0fx%.0f transform=[%.3f %.3f %.3f %.3f %.1f %.1f] angle=%.1f configRotation=%ld requestedFps=%ld",
        videoTrack.naturalSize.width, videoTrack.naturalSize.height,
        self.videoTransform.a, self.videoTransform.b, self.videoTransform.c,
        self.videoTransform.d, self.videoTransform.tx, self.videoTransform.ty,
        transformAngle, (long)self.configuration.rotationDegrees,
        (long)self.configuration.preferredFramesPerSecond);
    return [self rebuildTripleVideoReader:error];
}

- (BOOL)rebuildTripleVideoReader:(NSError **)error {
    [self resetTripleVideoReaderState];
    [self resetDiagnosticWindow];
    AVAssetTrack *videoTrack = [[self.asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    if (videoTrack == nil) return NO;
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:self.asset error:error];
    if (reader == nil) return NO;
    AVAssetReaderTrackOutput *(^makeOutput)(OSType) = ^AVAssetReaderTrackOutput *(OSType pixelFormat) {
        AVAssetReaderTrackOutput *output = [AVAssetReaderTrackOutput
            assetReaderTrackOutputWithTrack:videoTrack
                              outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey: @(pixelFormat)}];
        output.alwaysCopiesSampleData = NO;
        return output;
    };
    AVAssetReaderTrackOutput *bgra = makeOutput(kCVPixelFormatType_32BGRA);
    AVAssetReaderTrackOutput *videoRange = makeOutput(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
    AVAssetReaderTrackOutput *fullRange = makeOutput(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);
    if (![reader canAddOutput:bgra] || ![reader canAddOutput:videoRange] || ![reader canAddOutput:fullRange]) {
        if (error != NULL && *error == nil) {
            *error = [NSError errorWithDomain:@"VCAMLocalMediaSource" code:3
                                     userInfo:@{NSLocalizedDescriptionKey: @"Cannot attach all three upstream decoder outputs"}];
        }
        return NO;
    }
    [reader addOutput:bgra];
    [reader addOutput:videoRange];
    [reader addOutput:fullRange];
    if (![reader startReading]) {
        if (error != NULL && *error == nil) *error = reader.error;
        return NO;
    }
    self.tripleVideoReader = reader;
    self.tripleBGRAOutput = bgra;
    self.tripleVideoRangeOutput = videoRange;
    self.tripleFullRangeOutput = fullRange;
    return YES;
}

- (BOOL)advanceTripleVideoFrame {
    CMSampleBufferRef bgra = [self.tripleBGRAOutput copyNextSampleBuffer];
    CMSampleBufferRef videoRange = [self.tripleVideoRangeOutput copyNextSampleBuffer];
    CMSampleBufferRef fullRange = [self.tripleFullRangeOutput copyNextSampleBuffer];
    if (bgra == NULL || videoRange == NULL || fullRange == NULL) {
        if (bgra != NULL) CFRelease(bgra);
        if (videoRange != NULL) CFRelease(videoRange);
        if (fullRange != NULL) CFRelease(fullRange);
        return NO;
    }
    [self releaseTripleFrames];
    _tripleBGRAFrame = bgra;
    _tripleVideoRangeFrame = videoRange;
    _tripleFullRangeFrame = fullRange;
    _tripleCurrentPTS = CMSampleBufferGetPresentationTimeStamp(videoRange);
    _diagnosticNewFrames += 1;
    [self recordDiagnosticSourceFrame];
    return YES;
}

- (CMTime)durationForTripleFrame {
    CMTime duration = _tripleVideoRangeFrame == NULL ? kCMTimeInvalid
        : CMSampleBufferGetDuration(_tripleVideoRangeFrame);
    if (!CMTIME_IS_NUMERIC(duration) || CMTimeCompare(duration, kCMTimeZero) <= 0) {
        duration = CMTimeMake(1, (int32_t)MAX(1, self.configuration.preferredFramesPerSecond));
    }
    return duration;
}

- (CVPixelBufferRef)copyCurrentTriplePixelBufferForTemplate:(CMSampleBufferRef)templateBuffer
                                                   itemTime:(CMTime *)itemTimeOut {
    if (_tripleVideoRangeFrame == NULL && ![self advanceTripleVideoFrame]) return NULL;
    CFTimeInterval now = CACurrentMediaTime();
    if (_tripleHostStart == 0 || !CMTIME_IS_VALID(_tripleMediaStartPTS)) {
        _tripleHostStart = now;
        _tripleMediaStartPTS = _tripleCurrentPTS;
    }
    NSUInteger catchUpCount = 0;
    while (catchUpCount < 8) {
        CMTime nextDuePTS = CMTimeAdd(_tripleCurrentPTS, [self durationForTripleFrame]);
        Float64 dueSeconds = CMTimeGetSeconds(CMTimeSubtract(nextDuePTS, _tripleMediaStartPTS));
        if (!isfinite(dueSeconds) || now - _tripleHostStart + 0.001 < dueSeconds) break;
        if (![self advanceTripleVideoFrame]) {
            if (!self.configuration.loopMedia || ![self rebuildTripleVideoReader:nil] ||
                ![self advanceTripleVideoFrame]) break;
            _tripleHostStart = now;
            _tripleMediaStartPTS = _tripleCurrentPTS;
            break;
        }
        catchUpCount += 1;
    }
    if (itemTimeOut != NULL) *itemTimeOut = _tripleCurrentPTS;
    CVImageBufferRef templateImage = templateBuffer == NULL ? NULL : CMSampleBufferGetImageBuffer(templateBuffer);
    OSType requested = templateImage == NULL ? kCVPixelFormatType_32BGRA
        : CVPixelBufferGetPixelFormatType(templateImage);
    CMSampleBufferRef selected = _tripleBGRAFrame;
    if (requested == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
        selected = _tripleVideoRangeFrame;
    } else if (requested == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
        selected = _tripleFullRangeFrame;
    }
    CVPixelBufferRef pixelBuffer = selected == NULL ? NULL : CMSampleBufferGetImageBuffer(selected);
    return pixelBuffer == NULL ? NULL : CVPixelBufferRetain(pixelBuffer);
}

- (BOOL)hasVideoAsset {
    @synchronized (self) { return self.asset != nil; }
}

- (AVPlayer *)previewPlayer {
    @synchronized (self) { return self.player; }
}

- (void)configurePlayerVideoOutputForPixelFormat:(OSType)pixelFormat {
    _diagnosticOutputReconfigurations += 1;
    if (self.playerVideoOutput != nil) [self.playerItem removeOutput:self.playerVideoOutput];
    NSDictionary *attributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(pixelFormat),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
    };
    AVPlayerItemVideoOutput *output = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:attributes];
    [self.playerItem addOutput:output];
    self.playerVideoOutput = output;
    self.playerOutputPixelFormat = pixelFormat;
    if (_currentPlayerPixelBuffer != NULL) {
        CVPixelBufferRelease(_currentPlayerPixelBuffer);
        _currentPlayerPixelBuffer = NULL;
    }
}

- (BOOL)startVideoPlayer:(NSError **)error {
    [self resetVideoPlaybackState];
    AVAssetTrack *videoTrack = [[self.asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    if (videoTrack == nil) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"VCAMLocalMediaSource"
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey: @"Media contains neither an image nor a video track"}];
        }
        return NO;
    }
    self.videoTransform = videoTrack.preferredTransform;
    CGFloat transformAngle = atan2(self.videoTransform.b, self.videoTransform.a) * 180.0 / M_PI;
    VCAMWriteDiagnostic(
        @"[DEBUG-vcamdiag] asset natural=%.0fx%.0f transform=[%.3f %.3f %.3f %.3f %.1f %.1f] angle=%.1f configRotation=%ld requestedFps=%ld",
        videoTrack.naturalSize.width, videoTrack.naturalSize.height,
        self.videoTransform.a, self.videoTransform.b, self.videoTransform.c,
        self.videoTransform.d, self.videoTransform.tx, self.videoTransform.ty,
        transformAngle, (long)self.configuration.rotationDegrees,
        (long)self.configuration.preferredFramesPerSecond);
    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:self.asset];
    self.playerItem = item;
    [self configurePlayerVideoOutputForPixelFormat:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange];
    AVPlayer *player = [AVPlayer playerWithPlayerItem:item];
    player.muted = YES;
    player.volume = 0;
    player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
    if ([player respondsToSelector:@selector(setAutomaticallyWaitsToMinimizeStalling:)]) {
        player.automaticallyWaitsToMinimizeStalling = NO;
    }
    self.player = player;
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(playerItemDidPlayToEnd:)
                                                 name:AVPlayerItemDidPlayToEndTimeNotification
                                               object:item];
    [player play];
    return YES;
}

- (void)playerItemDidPlayToEnd:(NSNotification *)notification {
    if (!self.running || !self.configuration.loopMedia || notification.object != self.playerItem) return;
    [self.player seekToTime:kCMTimeZero toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero
          completionHandler:^(BOOL finished) {
        if (finished && self.running) [self.player play];
    }];
}

- (CVPixelBufferRef)copyCurrentPlayerPixelBufferForTemplate:(CMSampleBufferRef)templateBuffer
                                                   itemTime:(CMTime *)itemTimeOut {
    (void)templateBuffer;
    CMTime itemTime = [self.playerVideoOutput itemTimeForHostTime:CACurrentMediaTime()];
    if (!CMTIME_IS_VALID(itemTime)) itemTime = self.player.currentTime;
    if ([self.playerVideoOutput hasNewPixelBufferForItemTime:itemTime]) {
        CMTime displayTime = kCMTimeInvalid;
        CVPixelBufferRef newest = [self.playerVideoOutput copyPixelBufferForItemTime:itemTime
                                                                   itemTimeForDisplay:&displayTime];
        if (newest != NULL) {
            _diagnosticNewFrames += 1;
            [self recordDiagnosticSourceFrame];
            if (_currentPlayerPixelBuffer != NULL) CVPixelBufferRelease(_currentPlayerPixelBuffer);
            _currentPlayerPixelBuffer = newest;
            _currentPlayerItemTime = CMTIME_IS_VALID(displayTime) ? displayTime : itemTime;
        }
    }
    if (itemTimeOut != NULL) *itemTimeOut = _currentPlayerItemTime;
    if (_currentPlayerPixelBuffer == NULL) return NULL;
    return CVPixelBufferRetain(_currentPlayerPixelBuffer);
}

- (void)emitDiagnosticsForTemplate:(CMSampleBufferRef)templateBuffer
                        sourceTime:(CMTime)sourceTime
                    renderDuration:(CFTimeInterval)renderDuration
                          hadFrame:(BOOL)hadFrame
                          cacheHit:(BOOL)cacheHit {
    _diagnosticCallbacks += 1;
    if (!hadFrame) _diagnosticMisses += 1;
    if (cacheHit) _diagnosticCacheHits += 1;
    if (renderDuration > 0) {
        _diagnosticRenders += 1;
        _diagnosticRenderTotal += renderDuration;
        _diagnosticRenderMaximum = MAX(_diagnosticRenderMaximum, renderDuration);
    }
    CVImageBufferRef templateImage = templateBuffer == NULL ? NULL : CMSampleBufferGetImageBuffer(templateBuffer);
    OSType templateFormat = templateImage == NULL ? 0 : CVPixelBufferGetPixelFormatType(templateImage);
    if (_diagnosticLastTemplateFormat != 0 && templateFormat != _diagnosticLastTemplateFormat) {
        _diagnosticTemplateSwitches += 1;
    }
    _diagnosticLastTemplateFormat = templateFormat;

    CFTimeInterval now = CACurrentMediaTime();
    if (_diagnosticWindowStart == 0) {
        _diagnosticWindowStart = now;
        _diagnosticWindowItemStart = sourceTime;
        return;
    }
    CFTimeInterval elapsed = now - _diagnosticWindowStart;
    if (elapsed < 1.0) return;

    Float64 itemAdvance = 0;
    if (CMTIME_IS_VALID(sourceTime) && CMTIME_IS_VALID(_diagnosticWindowItemStart)) {
        itemAdvance = CMTimeGetSeconds(CMTimeSubtract(sourceTime, _diagnosticWindowItemStart));
        if (!isfinite(itemAdvance)) itemAdvance = 0;
    }
    size_t sourceWidth = _currentPlayerPixelBuffer == NULL ? 0 : CVPixelBufferGetWidth(_currentPlayerPixelBuffer);
    size_t sourceHeight = _currentPlayerPixelBuffer == NULL ? 0 : CVPixelBufferGetHeight(_currentPlayerPixelBuffer);
    if (self.configuration.localDecoderMode == VCAMLocalDecoderModeUpstreamTriple &&
        _tripleVideoRangeFrame != NULL) {
        CVPixelBufferRef triplePixelBuffer = CMSampleBufferGetImageBuffer(_tripleVideoRangeFrame);
        if (triplePixelBuffer != NULL) {
            sourceWidth = CVPixelBufferGetWidth(triplePixelBuffer);
            sourceHeight = CVPixelBufferGetHeight(triplePixelBuffer);
        }
    }
    size_t targetWidth = templateImage == NULL ? 0 : CVPixelBufferGetWidth(templateImage);
    size_t targetHeight = templateImage == NULL ? 0 : CVPixelBufferGetHeight(templateImage);
    double averageRenderMilliseconds = _diagnosticRenders == 0 ? 0 :
        (_diagnosticRenderTotal * 1000.0 / _diagnosticRenders);
    double sourceFrameP95Milliseconds = 0;
    if (_diagnosticSourceFrameIntervalCount > 0) {
        qsort(_diagnosticSourceFrameIntervals, _diagnosticSourceFrameIntervalCount,
              sizeof(_diagnosticSourceFrameIntervals[0]), VCAMCompareDouble);
        NSUInteger p95Index = (NSUInteger)ceil(_diagnosticSourceFrameIntervalCount * 0.95) - 1;
        sourceFrameP95Milliseconds = _diagnosticSourceFrameIntervals[p95Index];
    }
    NSString *decoderMode = self.configuration.localDecoderMode == VCAMLocalDecoderModeUpstreamTriple
        ? @"upstreamTriple" : @"singlePlayer";
    float playbackRate = self.configuration.localDecoderMode == VCAMLocalDecoderModeUpstreamTriple
        ? 1.0f : self.player.rate;
    double sourceFPS = elapsed <= 0 ? 0 : ((double)_diagnosticNewFrames / elapsed);
    VCAMPublishLocalPerformanceSnapshot(@{
        @"decoderMode": decoderMode,
        @"window": @(elapsed),
        @"sourceFrames": @(_diagnosticNewFrames),
        @"sourceFPS": @(sourceFPS),
        @"sourceFrameP95Ms": @(sourceFrameP95Milliseconds),
        @"callbacks": @(_diagnosticCallbacks),
        @"misses": @(_diagnosticMisses),
        @"renderAvgMs": @(averageRenderMilliseconds),
        @"renderMaxMs": @(_diagnosticRenderMaximum * 1000.0),
        @"itemAdvance": @(itemAdvance),
        @"sourceWidth": @(sourceWidth),
        @"sourceHeight": @(sourceHeight),
    });
    VCAMWriteDiagnostic(
        @"[DEBUG-vcamdiag] perf window=%.3f decoderMode=%@ callbacks=%lu newFrames=%lu sourceFrames=%lu sourceFrameP95Ms=%.3f misses=%lu reconfigs=%lu templateSwitches=%lu cacheHits=%lu renders=%lu renderAvgMs=%.3f renderMaxMs=%.3f itemAdvance=%.3f rate=%.2f source=%zux%zu target=%zux%zu templateFormat=0x%08x",
        elapsed, decoderMode, (unsigned long)_diagnosticCallbacks, (unsigned long)_diagnosticNewFrames,
        (unsigned long)_diagnosticNewFrames, sourceFrameP95Milliseconds,
        (unsigned long)_diagnosticMisses, (unsigned long)_diagnosticOutputReconfigurations,
        (unsigned long)_diagnosticTemplateSwitches, (unsigned long)_diagnosticCacheHits,
        (unsigned long)_diagnosticRenders, averageRenderMilliseconds,
        _diagnosticRenderMaximum * 1000.0, itemAdvance, playbackRate,
        sourceWidth, sourceHeight, targetWidth, targetHeight, (unsigned int)templateFormat);

    [self resetDiagnosticWindow];
    _diagnosticWindowStart = now;
    _diagnosticWindowItemStart = sourceTime;
}

- (void)tickDirectPreviewDiagnostics {
    @synchronized (self) {
        if (!self.running || self.playerVideoOutput == nil) return;
        CMTime sourcePTS = kCMTimeInvalid;
        CVPixelBufferRef pixelBuffer = [self copyCurrentPlayerPixelBufferForTemplate:NULL
                                                                            itemTime:&sourcePTS];
        [self emitDiagnosticsForTemplate:NULL
                              sourceTime:sourcePTS
                          renderDuration:0
                                hadFrame:(pixelBuffer != NULL)
                                cacheHit:NO];
        if (pixelBuffer != NULL) CVPixelBufferRelease(pixelBuffer);
    }
}

- (BOOL)rebuildAudioReaderForSampleRate:(Float64)sampleRate
                           channelCount:(UInt32)channelCount
                                  error:(NSError **)error {
    [self.audioReader cancelReading];
    self.audioReader = nil;
    self.audioOutput = nil;
    AVAssetTrack *audioTrack = [[self.asset tracksWithMediaType:AVMediaTypeAudio] firstObject];
    if (audioTrack == nil) return YES;
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:self.asset error:error];
    if (reader == nil) return NO;
    NSMutableDictionary *settings = [@{
        AVFormatIDKey: @(kAudioFormatLinearPCM),
        AVLinearPCMBitDepthKey: @16,
        AVLinearPCMIsFloatKey: @NO,
        AVLinearPCMIsBigEndianKey: @NO,
        AVLinearPCMIsNonInterleaved: @NO,
    } mutableCopy];
    if (sampleRate > 0) settings[AVSampleRateKey] = @(sampleRate);
    if (channelCount > 0) settings[AVNumberOfChannelsKey] = @(channelCount);
    AVAssetReaderTrackOutput *output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:audioTrack
                                                                                  outputSettings:settings];
    output.alwaysCopiesSampleData = NO;
    if (![reader canAddOutput:output]) return NO;
    [reader addOutput:output];
    if (![reader startReading]) return NO;
    self.audioReader = reader;
    self.audioOutput = output;
    self.audioSampleRate = sampleRate;
    self.audioChannelCount = channelCount;
    return YES;
}

- (CMSampleBufferRef)copyVideoSampleForTemplate:(CMSampleBufferRef)templateBuffer {
    @synchronized (self) {
        static NSUInteger vcamFrameLogCounter = 0;
        if ((vcamFrameLogCounter++ % 150) == 0 || vcamFrameLogCounter <= 3) {
            CVImageBufferRef tplImage = templateBuffer == NULL ? NULL : CMSampleBufferGetImageBuffer(templateBuffer);
            [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:@"local copyVideo call=%lu tpl=%zux%zu running=%d", (unsigned long)vcamFrameLogCounter, tplImage == NULL ? 0 : CVPixelBufferGetWidth(tplImage), tplImage == NULL ? 0 : CVPixelBufferGetHeight(tplImage), self.running]];
        }
        if (!self.running) return NULL;
        if (_stillImage != NULL) {
            return [self.renderer copySampleFromCGImage:_stillImage
                                        sourceTransform:CGAffineTransformIdentity
                                               template:templateBuffer
                                          configuration:self.configuration];
        }

        CMTime sourcePTS = kCMTimeInvalid;
        CVPixelBufferRef imageBuffer = self.configuration.localDecoderMode == VCAMLocalDecoderModeUpstreamTriple
            ? [self copyCurrentTriplePixelBufferForTemplate:templateBuffer itemTime:&sourcePTS]
            : [self copyCurrentPlayerPixelBufferForTemplate:templateBuffer itemTime:&sourcePTS];
        if (imageBuffer == NULL) {
            [self emitDiagnosticsForTemplate:templateBuffer sourceTime:sourcePTS
                              renderDuration:0 hadFrame:NO cacheHit:NO];
            return NULL;
        }
        CVImageBufferRef templateImage = CMSampleBufferGetImageBuffer(templateBuffer);
        size_t width = templateImage == NULL ? 0 : CVPixelBufferGetWidth(templateImage);
        size_t height = templateImage == NULL ? 0 : CVPixelBufferGetHeight(templateImage);
        OSType pixelFormat = templateImage == NULL ? 0 : CVPixelBufferGetPixelFormatType(templateImage);
        if (_lastRenderedVideoSample != NULL && CMTIME_IS_VALID(sourcePTS) &&
            CMTIME_IS_VALID(_lastRenderedSourcePTS) && CMTimeCompare(sourcePTS, _lastRenderedSourcePTS) == 0 &&
            width == _lastRenderedWidth && height == _lastRenderedHeight &&
            pixelFormat == _lastRenderedPixelFormat) {
            CMSampleTimingInfo timing = {
                .duration = CMSampleBufferGetDuration(templateBuffer),
                .presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(templateBuffer),
                .decodeTimeStamp = CMSampleBufferGetDecodeTimeStamp(templateBuffer),
            };
            CMSampleBufferRef retimed = NULL;
            CMSampleBufferCreateCopyWithNewTiming(kCFAllocatorDefault, _lastRenderedVideoSample,
                                                  1, &timing, &retimed);
            CVPixelBufferRelease(imageBuffer);
            [self emitDiagnosticsForTemplate:templateBuffer sourceTime:sourcePTS
                              renderDuration:0 hadFrame:YES cacheHit:YES];
            return retimed;
        }
        CFTimeInterval renderStart = CACurrentMediaTime();
        CMSampleBufferRef rendered = [self.renderer copySampleFromPixelBuffer:imageBuffer
                                                               sourceTransform:self.videoTransform
                                                                      template:templateBuffer
                                                                 configuration:self.configuration];
        CFTimeInterval renderDuration = CACurrentMediaTime() - renderStart;
        if (rendered != NULL) {
            if (_lastRenderedVideoSample != NULL) CFRelease(_lastRenderedVideoSample);
            _lastRenderedVideoSample = NULL;
            CMSampleBufferCreateCopy(kCFAllocatorDefault, rendered, &_lastRenderedVideoSample);
            _lastRenderedSourcePTS = sourcePTS;
            _lastRenderedWidth = width;
            _lastRenderedHeight = height;
            _lastRenderedPixelFormat = pixelFormat;
        }
        CVPixelBufferRelease(imageBuffer);
        [self emitDiagnosticsForTemplate:templateBuffer sourceTime:sourcePTS
                          renderDuration:renderDuration hadFrame:(rendered != NULL) cacheHit:NO];
        return rendered;
    }
}

- (CMSampleBufferRef)copyAudioSampleForTemplate:(CMSampleBufferRef)templateBuffer {
    @synchronized (self) {
        if (!self.running || !self.configuration.replaceAudio || self.audioOutput == nil) return NULL;
        CMAudioFormatDescriptionRef format =
            (CMAudioFormatDescriptionRef)CMSampleBufferGetFormatDescription(templateBuffer);
        const AudioStreamBasicDescription *description =
            format == NULL ? NULL : CMAudioFormatDescriptionGetStreamBasicDescription(format);
        if (description != NULL && description->mFormatID == kAudioFormatLinearPCM &&
            (fabs(description->mSampleRate - self.audioSampleRate) > 0.5 ||
             description->mChannelsPerFrame != self.audioChannelCount)) {
            if (![self rebuildAudioReaderForSampleRate:description->mSampleRate
                                          channelCount:description->mChannelsPerFrame
                                                 error:nil]) {
                return NULL;
            }
        }
        CMSampleBufferRef decoded = [self.audioOutput copyNextSampleBuffer];
        if (decoded == NULL && self.configuration.loopMedia) {
            [self rebuildAudioReaderForSampleRate:self.audioSampleRate
                                     channelCount:self.audioChannelCount
                                            error:nil];
            decoded = [self.audioOutput copyNextSampleBuffer];
        }
        if (decoded == NULL) return NULL;

        CMSampleTimingInfo timing = {
            .duration = CMSampleBufferGetDuration(decoded),
            .presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(templateBuffer),
            .decodeTimeStamp = kCMTimeInvalid,
        };
        CMSampleBufferRef retimed = NULL;
        OSStatus status = CMSampleBufferCreateCopyWithNewTiming(kCFAllocatorDefault, decoded, 1, &timing, &retimed);
        CFRelease(decoded);
        return status == noErr ? retimed : NULL;
    }
}

@end

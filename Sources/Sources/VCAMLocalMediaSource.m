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
static const NSUInteger VCAMVideoCatchUpLimit = 2;
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
    CMSampleBufferRef _currentVideoSample;
    CMTime _currentVideoPTS;
    CMTime _videoMediaStartPTS;
    CFTimeInterval _videoHostStart;
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
    CFTimeInterval _diagnosticLastSourceFrameHostTime;
    double _diagnosticSourceFrameIntervals[256];
    NSUInteger _diagnosticSourceFrameIntervalCount;
    BOOL _readerFirstSampleLogged;
    BOOL _readerFirstFrameLogged;
    BOOL _readerFailureLogged;
    NSUInteger _readerLoopCount;
}
@property(nonatomic, strong) VCAMConfiguration *configuration;
@property(nonatomic, strong) VCAMFrameRenderer *renderer;
@property(nonatomic, strong, nullable) AVURLAsset *asset;
@property(nonatomic, strong, nullable) AVAssetReader *videoReader;
@property(nonatomic, strong, nullable) AVAssetReaderVideoCompositionOutput *videoOutput;
@property(nonatomic, strong, nullable) AVAssetReader *audioReader;
@property(nonatomic, strong, nullable) AVAssetReaderTrackOutput *audioOutput;
@property(nonatomic) Float64 audioSampleRate;
@property(nonatomic) UInt32 audioChannelCount;
@property(nonatomic) BOOL running;
@property(nonatomic) CGAffineTransform videoTransform;
@end

@implementation VCAMLocalMediaSource

- (instancetype)initWithConfiguration:(VCAMConfiguration *)configuration
                              renderer:(VCAMFrameRenderer *)renderer {
    self = [super init];
    if (self) {
        _configuration = configuration;
        _renderer = renderer;
        _videoTransform = CGAffineTransformIdentity;
        _currentVideoPTS = kCMTimeInvalid;
        _videoMediaStartPTS = kCMTimeInvalid;
        _lastRenderedSourcePTS = kCMTimeInvalid;
        _diagnosticWindowItemStart = kCMTimeInvalid;
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
        if (![self startVideoReader:error]) return NO;
        [self rebuildAudioReaderForSampleRate:0 channelCount:0 error:nil];
    }
    self.running = YES;
    [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
        @"local start ok decoder=singleReader still=%d asset=%d reader=%d",
        _stillImage != NULL, self.asset != nil, self.videoReader != nil]];
    return YES;
}

- (void)stop {
    @synchronized (self) {
        [self.videoReader cancelReading];
        [self.audioReader cancelReading];
        self.audioReader = nil;
        self.audioOutput = nil;
        if (_stillImage != NULL) {
            CGImageRelease(_stillImage);
            _stillImage = NULL;
        }
        [self resetVideoPlaybackState];
        VCAMPublishLocalPerformanceSnapshot(@{});
        self.running = NO;
    }
}

- (void)dealloc {
    if (_stillImage != NULL) CGImageRelease(_stillImage);
    [self resetVideoPlaybackState];
}

- (void)resetVideoReaderState {
    [self.videoReader cancelReading];
    if (_currentVideoSample != NULL) CFRelease(_currentVideoSample);
    _currentVideoSample = NULL;
    _currentVideoPTS = kCMTimeInvalid;
    _videoMediaStartPTS = kCMTimeInvalid;
    _videoHostStart = 0;
    self.videoReader = nil;
    self.videoOutput = nil;
}

- (void)resetVideoPlaybackState {
    [self resetVideoReaderState];
    if (_lastRenderedVideoSample != NULL) CFRelease(_lastRenderedVideoSample);
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

- (void)reportVideoReaderFailureWithStatus:(AVAssetReaderStatus)status
                                     error:(NSError *)error {
    if (_readerFailureLogged) return;
    _readerFailureLogged = YES;
    NSString *message = [NSString stringWithFormat:
        @"local reader failed status=%ld error=%@", (long)status,
        error.localizedDescription ?: @"(none)"];
    [VCAMConfiguration appendProcessLog:message];
    VCAMWriteDiagnostic(@"[DEBUG-vcamdiag] %@", message);
}

- (BOOL)startVideoReader:(NSError **)error {
    [self resetVideoPlaybackState];
    [self resetDiagnosticWindow];
    _readerFirstSampleLogged = NO;
    _readerFirstFrameLogged = NO;
    _readerFailureLogged = NO;
    _readerLoopCount = 0;
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
        @"[DEBUG-vcamdiag] asset decoderMode=singleReader natural=%.0fx%.0f transform=[%.3f %.3f %.3f %.3f %.1f %.1f] angle=%.1f configRotation=%ld requestedFps=%ld",
        videoTrack.naturalSize.width, videoTrack.naturalSize.height,
        self.videoTransform.a, self.videoTransform.b, self.videoTransform.c,
        self.videoTransform.d, self.videoTransform.tx, self.videoTransform.ty,
        transformAngle, (long)self.configuration.rotationDegrees,
        (long)self.configuration.preferredFramesPerSecond);
    if (![self rebuildVideoReader:error]) return NO;
    if (![self advanceVideoFrame]) {
        AVAssetReaderStatus status = self.videoReader.status;
        NSError *firstFrameError = self.videoReader.error ?: [NSError
            errorWithDomain:@"VCAMLocalMediaSource"
                       code:5
                   userInfo:@{NSLocalizedDescriptionKey:
                       @"Unable to decode the first video frame"}];
        if (error != NULL) *error = firstFrameError;
        [self reportVideoReaderFailureWithStatus:status error:firstFrameError];
        [self resetVideoReaderState];
        return NO;
    }
    return YES;
}

- (BOOL)rebuildVideoReader:(NSError **)error {
    [self resetVideoReaderState];
    AVAssetTrack *videoTrack = [[self.asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    if (videoTrack == nil) return NO;
    NSError *readerError = nil;
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:self.asset error:&readerError];
    if (reader == nil) {
        if (error != NULL) *error = readerError;
        [self reportVideoReaderFailureWithStatus:AVAssetReaderStatusUnknown
                                          error:readerError];
        return NO;
    }
    AVAssetReaderVideoCompositionOutput *output = [AVAssetReaderVideoCompositionOutput
        assetReaderVideoCompositionOutputWithVideoTracks:@[videoTrack]
                                             videoSettings:@{
                                                 (id)kCVPixelBufferPixelFormatTypeKey:
                                                     @(kCVPixelFormatType_32BGRA),
                                             }];
    // Keep the decoded pixels in source-track geometry. VCAMFrameRenderer is
    // the single owner of preferredTransform plus user rotation/mirroring.
    output.videoComposition = nil;
    output.alwaysCopiesSampleData = NO;
    if (![reader canAddOutput:output]) {
        NSError *outputError = [NSError errorWithDomain:@"VCAMLocalMediaSource" code:3
                                               userInfo:@{NSLocalizedDescriptionKey:
                                                   @"Cannot attach the uncompressed incremental video reader output"}];
        if (error != NULL && *error == nil) {
            *error = outputError;
        }
        [self reportVideoReaderFailureWithStatus:reader.status error:outputError];
        return NO;
    }
    [reader addOutput:output];
    self.videoReader = reader;
    self.videoOutput = output;
    if (![reader startReading]) {
        if (error != NULL && *error == nil) *error = reader.error;
        [self reportVideoReaderFailureWithStatus:reader.status error:reader.error];
        return NO;
    }
    _readerFailureLogged = NO;
    if (_readerLoopCount <= 3 || _readerLoopCount % 50 == 0) {
        [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
            @"local reader ready status=%ld loop=%lu output=%08x outputClass=%@", (long)reader.status,
            (unsigned long)_readerLoopCount, (unsigned int)kCVPixelFormatType_32BGRA,
            NSStringFromClass(output.class)]];
    }
    return YES;
}

- (BOOL)advanceVideoFrame {
    CMSampleBufferRef sample = [self.videoOutput copyNextSampleBuffer];
    if (sample == NULL) {
        AVAssetReaderStatus status = self.videoReader.status;
        if (status == AVAssetReaderStatusFailed || status == AVAssetReaderStatusCancelled) {
            [self reportVideoReaderFailureWithStatus:status error:self.videoReader.error];
        }
        return NO;
    }
    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sample);
    CMFormatDescriptionRef formatDescription = CMSampleBufferGetFormatDescription(sample);
    FourCharCode mediaSubtype = formatDescription == NULL
        ? 0 : CMFormatDescriptionGetMediaSubType(formatDescription);
    if (!_readerFirstSampleLogged) {
        _readerFirstSampleLogged = YES;
        [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
            @"local reader first-sample mediaSubtype=%08x hasImageBuffer=%d hasDataBuffer=%d outputClass=%@ status=%ld",
            (unsigned int)mediaSubtype, pixelBuffer != NULL,
            CMSampleBufferGetDataBuffer(sample) != NULL,
            NSStringFromClass(self.videoOutput.class), (long)self.videoReader.status]];
    }
    if (pixelBuffer == NULL) {
        CFRelease(sample);
        NSError *sampleError = [NSError errorWithDomain:@"VCAMLocalMediaSource" code:4
                                               userInfo:@{NSLocalizedDescriptionKey:
                                                   @"Incremental video reader returned a sample without pixels"}];
        [self reportVideoReaderFailureWithStatus:self.videoReader.status error:sampleError];
        return NO;
    }
    CMTime presentationTime = CMSampleBufferGetPresentationTimeStamp(sample);
    if (!CMTIME_IS_NUMERIC(presentationTime)) {
        presentationTime = CMTIME_IS_NUMERIC(_currentVideoPTS)
            ? CMTimeAdd(_currentVideoPTS, [self durationForCurrentVideoFrame])
            : kCMTimeZero;
    }
    if (_currentVideoSample != NULL) CFRelease(_currentVideoSample);
    _currentVideoSample = sample;
    _currentVideoPTS = presentationTime;
    _diagnosticNewFrames += 1;
    [self recordDiagnosticSourceFrame];
    if (!_readerFirstFrameLogged) {
        _readerFirstFrameLogged = YES;
        Float64 seconds = CMTimeGetSeconds(_currentVideoPTS);
        [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
            @"local reader first-frame pts=%.6f size=%zux%zu format=%08x status=%ld",
            isfinite(seconds) ? seconds : 0,
            CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer),
            (unsigned int)CVPixelBufferGetPixelFormatType(pixelBuffer),
            (long)self.videoReader.status]];
    }
    return YES;
}

- (CMTime)durationForCurrentVideoFrame {
    CMTime duration = _currentVideoSample == NULL ? kCMTimeInvalid
        : CMSampleBufferGetDuration(_currentVideoSample);
    if (!CMTIME_IS_NUMERIC(duration) || CMTimeCompare(duration, kCMTimeZero) <= 0) {
        duration = CMTimeMake(1, (int32_t)MAX(1, self.configuration.preferredFramesPerSecond));
    }
    return duration;
}

- (BOOL)restartVideoReaderAfterEndAtHostTime:(CFTimeInterval)hostTime {
    if (self.videoReader.status != AVAssetReaderStatusCompleted ||
        !self.configuration.loopMedia) return NO;
    _readerLoopCount += 1;
    if (_readerLoopCount <= 3 || _readerLoopCount % 50 == 0) {
        [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
            @"local reader eof loop=%lu", (unsigned long)_readerLoopCount]];
    }
    NSError *error = nil;
    if (![self rebuildVideoReader:&error] || ![self advanceVideoFrame]) {
        [self reportVideoReaderFailureWithStatus:self.videoReader.status error:error ?: self.videoReader.error];
        return NO;
    }
    _videoHostStart = hostTime;
    _videoMediaStartPTS = _currentVideoPTS;
    return YES;
}

- (CVPixelBufferRef)copyCurrentVideoPixelBufferForTemplate:(CMSampleBufferRef)templateBuffer
                                                  itemTime:(CMTime *)itemTimeOut {
    (void)templateBuffer;
    CFTimeInterval now = CACurrentMediaTime();
    if (_currentVideoSample == NULL && ![self advanceVideoFrame] &&
        ![self restartVideoReaderAfterEndAtHostTime:now]) {
        return NULL;
    }
    if (_videoHostStart == 0 || !CMTIME_IS_NUMERIC(_videoMediaStartPTS)) {
        _videoHostStart = now;
        _videoMediaStartPTS = _currentVideoPTS;
    }
    NSUInteger catchUpCount = 0;
    while (catchUpCount < VCAMVideoCatchUpLimit) {
        CMTime nextDuePTS = CMTimeAdd(_currentVideoPTS, [self durationForCurrentVideoFrame]);
        Float64 dueSeconds = CMTimeGetSeconds(CMTimeSubtract(nextDuePTS, _videoMediaStartPTS));
        if (!isfinite(dueSeconds) || now - _videoHostStart + 0.001 < dueSeconds) break;
        if (![self advanceVideoFrame]) {
            [self restartVideoReaderAfterEndAtHostTime:now];
            break;
        }
        catchUpCount += 1;
    }
    if (catchUpCount == VCAMVideoCatchUpLimit) {
        CMTime nextDuePTS = CMTimeAdd(_currentVideoPTS, [self durationForCurrentVideoFrame]);
        Float64 dueSeconds = CMTimeGetSeconds(CMTimeSubtract(nextDuePTS, _videoMediaStartPTS));
        if (isfinite(dueSeconds) && now - _videoHostStart + 0.001 >= dueSeconds) {
            _videoHostStart = now;
            _videoMediaStartPTS = _currentVideoPTS;
        }
    }
    if (itemTimeOut != NULL) *itemTimeOut = _currentVideoPTS;
    CVPixelBufferRef pixelBuffer = _currentVideoSample == NULL ? NULL
        : CMSampleBufferGetImageBuffer(_currentVideoSample);
    return pixelBuffer == NULL ? NULL : CVPixelBufferRetain(pixelBuffer);
}

- (BOOL)hasVideoAsset {
    @synchronized (self) { return self.asset != nil; }
}

- (AVPlayer *)previewPlayer {
    return nil;
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
    CVPixelBufferRef sourcePixelBuffer = _currentVideoSample == NULL ? NULL
        : CMSampleBufferGetImageBuffer(_currentVideoSample);
    size_t sourceWidth = sourcePixelBuffer == NULL ? 0 : CVPixelBufferGetWidth(sourcePixelBuffer);
    size_t sourceHeight = sourcePixelBuffer == NULL ? 0 : CVPixelBufferGetHeight(sourcePixelBuffer);
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
    NSString *decoderMode = @"singleReader";
    float playbackRate = self.videoReader.status == AVAssetReaderStatusReading ? 1.0f : 0.0f;
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
        if (!self.running || self.videoOutput == nil) return;
        CMTime sourcePTS = kCMTimeInvalid;
        CVPixelBufferRef pixelBuffer = [self copyCurrentVideoPixelBufferForTemplate:NULL
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
        CVPixelBufferRef imageBuffer = [self copyCurrentVideoPixelBufferForTemplate:templateBuffer
                                                                            itemTime:&sourcePTS];
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

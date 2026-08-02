#import "VCAMLocalMediaSource.h"
#import <ImageIO/ImageIO.h>
#import <QuartzCore/QuartzCore.h>
#import <fcntl.h>
#import <math.h>
#import <stdarg.h>
#import <unistd.h>

static NSString * const VCAMDiagnosticPath = @"/var/mobile/Library/Preferences/com.codex.vcam.diagnostics.log";

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

@interface VCAMLocalMediaSource () {
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
}
@property(nonatomic, strong) VCAMConfiguration *configuration;
@property(nonatomic, strong) VCAMFrameRenderer *renderer;
@property(nonatomic, strong, nullable) CIImage *stillImage;
@property(nonatomic, strong, nullable) AVURLAsset *asset;
@property(nonatomic, strong, nullable) AVAssetReader *audioReader;
@property(nonatomic, strong, nullable) AVAssetReaderTrackOutput *audioOutput;
@property(nonatomic, strong, nullable) AVPlayerItem *playerItem;
@property(nonatomic, strong, nullable) AVPlayer *player;
@property(nonatomic, strong, nullable) AVPlayerItemVideoOutput *playerVideoOutput;
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
    }
    return self;
}

- (BOOL)start:(NSError **)error {
    NSString *path = self.configuration.mediaPath;
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
    self.stillImage = [CIImage imageWithContentsOfURL:url];
    if (self.stillImage == nil) {
        self.asset = [AVURLAsset URLAssetWithURL:url options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @YES}];
        if (![self startVideoPlayer:error]) {
            return NO;
        }
        [self rebuildAudioReaderForSampleRate:0 channelCount:0 error:nil];
    }
    self.running = YES;
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
        self.player = nil;
        self.playerItem = nil;
        self.playerVideoOutput = nil;
        self.audioReader = nil;
        self.audioOutput = nil;
        [self resetVideoPlaybackState];
        self.running = NO;
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self resetVideoPlaybackState];
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

- (BOOL)hasVideoAsset {
    @synchronized (self) { return self.asset != nil; }
}

- (OSType)desiredPlayerPixelFormatForTemplate:(CMSampleBufferRef)templateBuffer {
    CVImageBufferRef image = templateBuffer == NULL ? NULL : CMSampleBufferGetImageBuffer(templateBuffer);
    OSType requested = image == NULL ? 0 : CVPixelBufferGetPixelFormatType(image);
    switch (requested) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
        case kCVPixelFormatType_32BGRA:
            return requested;
        default:
            return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    }
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
    OSType desiredPixelFormat = [self desiredPlayerPixelFormatForTemplate:templateBuffer];
    if (desiredPixelFormat != self.playerOutputPixelFormat) {
        [self configurePlayerVideoOutputForPixelFormat:desiredPixelFormat];
    }
    CMTime itemTime = [self.playerVideoOutput itemTimeForHostTime:CACurrentMediaTime()];
    if (!CMTIME_IS_VALID(itemTime)) itemTime = self.player.currentTime;
    if ([self.playerVideoOutput hasNewPixelBufferForItemTime:itemTime]) {
        CMTime displayTime = kCMTimeInvalid;
        CVPixelBufferRef newest = [self.playerVideoOutput copyPixelBufferForItemTime:itemTime
                                                                   itemTimeForDisplay:&displayTime];
        if (newest != NULL) {
            _diagnosticNewFrames += 1;
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
    CVImageBufferRef templateImage = CMSampleBufferGetImageBuffer(templateBuffer);
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
    size_t targetWidth = templateImage == NULL ? 0 : CVPixelBufferGetWidth(templateImage);
    size_t targetHeight = templateImage == NULL ? 0 : CVPixelBufferGetHeight(templateImage);
    double averageRenderMilliseconds = _diagnosticRenders == 0 ? 0 :
        (_diagnosticRenderTotal * 1000.0 / _diagnosticRenders);
    VCAMWriteDiagnostic(
        @"[DEBUG-vcamdiag] perf window=%.3f callbacks=%lu newFrames=%lu misses=%lu reconfigs=%lu templateSwitches=%lu cacheHits=%lu renders=%lu renderAvgMs=%.3f renderMaxMs=%.3f itemAdvance=%.3f rate=%.2f source=%zux%zu target=%zux%zu templateFormat=0x%08x",
        elapsed, (unsigned long)_diagnosticCallbacks, (unsigned long)_diagnosticNewFrames,
        (unsigned long)_diagnosticMisses, (unsigned long)_diagnosticOutputReconfigurations,
        (unsigned long)_diagnosticTemplateSwitches, (unsigned long)_diagnosticCacheHits,
        (unsigned long)_diagnosticRenders, averageRenderMilliseconds,
        _diagnosticRenderMaximum * 1000.0, itemAdvance, self.player.rate,
        sourceWidth, sourceHeight, targetWidth, targetHeight, (unsigned int)templateFormat);

    _diagnosticCallbacks = 0;
    _diagnosticNewFrames = 0;
    _diagnosticMisses = 0;
    _diagnosticOutputReconfigurations = 0;
    _diagnosticTemplateSwitches = 0;
    _diagnosticCacheHits = 0;
    _diagnosticRenders = 0;
    _diagnosticRenderTotal = 0;
    _diagnosticRenderMaximum = 0;
    _diagnosticWindowStart = now;
    _diagnosticWindowItemStart = sourceTime;
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
        if (!self.running) return NULL;
        if (self.stillImage != nil) {
            return [self.renderer copySampleFromImage:self.stillImage
                                             template:templateBuffer
                                        configuration:self.configuration];
        }

        CMTime sourcePTS = kCMTimeInvalid;
        CVPixelBufferRef imageBuffer = [self copyCurrentPlayerPixelBufferForTemplate:templateBuffer
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
        CIImage *image = imageBuffer == NULL ? nil : [CIImage imageWithCVImageBuffer:imageBuffer];
        if (image != nil && !CGAffineTransformIsIdentity(self.videoTransform)) {
            image = [image imageByApplyingTransform:self.videoTransform];
        }
        CFTimeInterval renderStart = CACurrentMediaTime();
        CMSampleBufferRef rendered = image == nil ? NULL :
            [self.renderer copySampleFromImage:image template:templateBuffer configuration:self.configuration];
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

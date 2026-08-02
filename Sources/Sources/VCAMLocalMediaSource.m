#import "VCAMLocalMediaSource.h"
#import <ImageIO/ImageIO.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>

@interface VCAMLocalMediaSource () {
    CVPixelBufferRef _currentPlayerPixelBuffer;
    CMTime _currentPlayerItemTime;
    CMSampleBufferRef _lastRenderedVideoSample;
    CMTime _lastRenderedSourcePTS;
    size_t _lastRenderedWidth;
    size_t _lastRenderedHeight;
    OSType _lastRenderedPixelFormat;
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
            if (_currentPlayerPixelBuffer != NULL) CVPixelBufferRelease(_currentPlayerPixelBuffer);
            _currentPlayerPixelBuffer = newest;
            _currentPlayerItemTime = CMTIME_IS_VALID(displayTime) ? displayTime : itemTime;
        }
    }
    if (itemTimeOut != NULL) *itemTimeOut = _currentPlayerItemTime;
    if (_currentPlayerPixelBuffer == NULL) return NULL;
    return CVPixelBufferRetain(_currentPlayerPixelBuffer);
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
        if (imageBuffer == NULL) return NULL;
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
            return retimed;
        }
        CIImage *image = imageBuffer == NULL ? nil : [CIImage imageWithCVImageBuffer:imageBuffer];
        if (image != nil && !CGAffineTransformIsIdentity(self.videoTransform)) {
            image = [image imageByApplyingTransform:self.videoTransform];
        }
        CMSampleBufferRef rendered = image == nil ? NULL :
            [self.renderer copySampleFromImage:image template:templateBuffer configuration:self.configuration];
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

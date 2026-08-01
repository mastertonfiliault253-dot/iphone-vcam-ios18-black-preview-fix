#import "VCAMLocalMediaSource.h"
#import <ImageIO/ImageIO.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>

@interface VCAMLocalMediaSource () {
    CMSampleBufferRef _currentVideoSample;
    CMSampleBufferRef _nextVideoSample;
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
@property(nonatomic, strong, nullable) AVAssetReader *videoReader;
@property(nonatomic, strong, nullable) AVAssetReader *audioReader;
@property(nonatomic, strong, nullable) AVAssetReaderTrackOutput *videoOutput;
@property(nonatomic, strong, nullable) AVAssetReaderTrackOutput *audioOutput;
@property(nonatomic) Float64 audioSampleRate;
@property(nonatomic) UInt32 audioChannelCount;
@property(nonatomic) BOOL running;
@property(nonatomic) CGAffineTransform videoTransform;
@property(nonatomic) CMTime firstVideoPTS;
@property(nonatomic) CFTimeInterval videoPlaybackStartHostTime;
@end

@implementation VCAMLocalMediaSource

- (instancetype)initWithConfiguration:(VCAMConfiguration *)configuration
                              renderer:(VCAMFrameRenderer *)renderer {
    self = [super init];
    if (self) {
        _configuration = configuration;
        _renderer = renderer;
        _videoTransform = CGAffineTransformIdentity;
        _firstVideoPTS = kCMTimeInvalid;
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
        if (![self rebuildVideoReader:error]) {
            return NO;
        }
        [self rebuildAudioReaderForSampleRate:0 channelCount:0 error:nil];
    }
    self.running = YES;
    return YES;
}

- (void)stop {
    @synchronized (self) {
        [self.videoReader cancelReading];
        [self.audioReader cancelReading];
        self.videoReader = nil;
        self.audioReader = nil;
        self.videoOutput = nil;
        self.audioOutput = nil;
        [self resetVideoPlaybackState];
        self.running = NO;
    }
}

- (void)dealloc {
    [self resetVideoPlaybackState];
}

- (void)resetVideoPlaybackState {
    if (_currentVideoSample != NULL) CFRelease(_currentVideoSample);
    if (_nextVideoSample != NULL) CFRelease(_nextVideoSample);
    if (_lastRenderedVideoSample != NULL) CFRelease(_lastRenderedVideoSample);
    _currentVideoSample = NULL;
    _nextVideoSample = NULL;
    _lastRenderedVideoSample = NULL;
    self.firstVideoPTS = kCMTimeInvalid;
    self.videoPlaybackStartHostTime = 0;
    _lastRenderedSourcePTS = kCMTimeInvalid;
    _lastRenderedWidth = 0;
    _lastRenderedHeight = 0;
    _lastRenderedPixelFormat = 0;
}

- (BOOL)hasVideoAsset {
    @synchronized (self) { return self.asset != nil; }
}

- (BOOL)rebuildVideoReader:(NSError **)error {
    [self.videoReader cancelReading];
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

    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:self.asset error:error];
    if (reader == nil) return NO;

    NSDictionary *videoSettings = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    AVAssetReaderTrackOutput *videoOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:videoTrack
                                                                                       outputSettings:videoSettings];
    videoOutput.alwaysCopiesSampleData = NO;
    if (![reader canAddOutput:videoOutput]) return NO;
    [reader addOutput:videoOutput];

    if (![reader startReading]) {
        if (error != NULL && *error == nil) *error = reader.error;
        return NO;
    }
    self.videoReader = reader;
    self.videoOutput = videoOutput;
    return YES;
}

- (CMSampleBufferRef)copyPacedDecodedVideoSample {
    if (_currentVideoSample == NULL) {
        _currentVideoSample = [self.videoOutput copyNextSampleBuffer];
        if (_currentVideoSample == NULL) return NULL;
        self.firstVideoPTS = CMSampleBufferGetPresentationTimeStamp(_currentVideoSample);
        self.videoPlaybackStartHostTime = CACurrentMediaTime();
        _nextVideoSample = [self.videoOutput copyNextSampleBuffer];
    }

    CFTimeInterval elapsed = MAX(0, CACurrentMediaTime() - self.videoPlaybackStartHostTime);
    while (_nextVideoSample != NULL) {
        CMTime nextPTS = CMSampleBufferGetPresentationTimeStamp(_nextVideoSample);
        Float64 nextTime = CMTimeGetSeconds(CMTimeSubtract(nextPTS, self.firstVideoPTS));
        if (!isfinite(nextTime) || nextTime > elapsed) break;
        CFRelease(_currentVideoSample);
        _currentVideoSample = _nextVideoSample;
        _nextVideoSample = [self.videoOutput copyNextSampleBuffer];
    }

    Float64 duration = CMTimeGetSeconds(self.asset.duration);
    if (_nextVideoSample == NULL && self.configuration.loopMedia &&
        isfinite(duration) && duration > 0.001 && elapsed >= duration) {
        if ([self rebuildVideoReader:nil]) return [self copyPacedDecodedVideoSample];
    }

    CMSampleBufferRef copy = NULL;
    CMSampleBufferCreateCopy(kCFAllocatorDefault, _currentVideoSample, &copy);
    return copy;
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

        CMSampleBufferRef decoded = [self copyPacedDecodedVideoSample];
        if (decoded == NULL) return NULL;
        CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(decoded);
        CVImageBufferRef templateImage = CMSampleBufferGetImageBuffer(templateBuffer);
        CMTime sourcePTS = CMSampleBufferGetPresentationTimeStamp(decoded);
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
            CFRelease(decoded);
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
        CFRelease(decoded);
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

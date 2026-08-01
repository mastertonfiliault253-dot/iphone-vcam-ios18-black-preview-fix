#import "VCAMLocalMediaSource.h"
#import <ImageIO/ImageIO.h>
#import <math.h>

@interface VCAMLocalMediaSource ()
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
@end

@implementation VCAMLocalMediaSource

- (instancetype)initWithConfiguration:(VCAMConfiguration *)configuration
                              renderer:(VCAMFrameRenderer *)renderer {
    self = [super init];
    if (self) {
        _configuration = configuration;
        _renderer = renderer;
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
        self.running = NO;
    }
}

- (BOOL)hasVideoAsset {
    @synchronized (self) { return self.asset != nil; }
}

- (BOOL)rebuildVideoReader:(NSError **)error {
    [self.videoReader cancelReading];
    AVAssetTrack *videoTrack = [[self.asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    if (videoTrack == nil) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"VCAMLocalMediaSource"
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey: @"Media contains neither an image nor a video track"}];
        }
        return NO;
    }

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

        CMSampleBufferRef decoded = [self.videoOutput copyNextSampleBuffer];
        if (decoded == NULL && self.configuration.loopMedia) {
            [self rebuildVideoReader:nil];
            decoded = [self.videoOutput copyNextSampleBuffer];
        }
        if (decoded == NULL) return NULL;
        CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(decoded);
        CIImage *image = imageBuffer == NULL ? nil : [CIImage imageWithCVImageBuffer:imageBuffer];
        CMSampleBufferRef rendered = image == nil ? NULL :
            [self.renderer copySampleFromImage:image template:templateBuffer configuration:self.configuration];
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

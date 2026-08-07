#import "VCAMLocalMediaSource.h"
#import "../Core/VCAMConfiguration.h"
#import "../Daemon/VCAMHardwareVideoDecoder.h"
#import <ImageIO/ImageIO.h>
#import <QuartzCore/QuartzCore.h>
#import <libavcodec/avcodec.h>
#import <libavformat/avformat.h>
#import <libavutil/hwcontext.h>
#import <libavutil/intreadwrite.h>
#import <fcntl.h>
#import <math.h>
#import <stdarg.h>
#import <stdlib.h>
#import <unistd.h>

static NSString * const VCAMDiagnosticPath = @"/var/mobile/Library/Preferences/com.codex.vcam.diagnostics.log";
static const NSUInteger VCAMVideoCatchUpLimit = 2;
static const NSUInteger VCAMVideoNonPixelSampleSkipLimit = 32;
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

static CVPixelBufferRef VCAMLocalCopyBGRAFromAVFrame(AVFrame *frame) {
    if (frame == NULL || frame->width <= 0 || frame->height <= 0) return NULL;
    BOOL planar420 = frame->format == AV_PIX_FMT_YUV420P ||
        frame->format == AV_PIX_FMT_YUVJ420P;
    BOOL nv12 = frame->format == AV_PIX_FMT_NV12;
    BOOL planar420p10 = frame->format == AV_PIX_FMT_YUV420P10LE;
    BOOL p010 = frame->format == AV_PIX_FMT_P010LE;
    if (!planar420 && !nv12 && !planar420p10 && !p010) return NULL;
    if (frame->data[0] == NULL || frame->data[1] == NULL ||
        ((planar420 || planar420p10) && frame->data[2] == NULL)) return NULL;

    const int maximumDimension = 1920;
    double scale = MIN(1.0, (double)maximumDimension /
        (double)MAX(frame->width, frame->height));
    int outputWidth = MAX(1, (int)lrint((double)frame->width * scale));
    int outputHeight = MAX(1, (int)lrint((double)frame->height * scale));
    NSDictionary *attributes = @{
        (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
    };
    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn createStatus = CVPixelBufferCreate(kCFAllocatorDefault, (size_t)outputWidth,
                                                (size_t)outputHeight,
                                                kCVPixelFormatType_32BGRA,
                                                (__bridge CFDictionaryRef)attributes,
                                                &pixelBuffer);
    if (createStatus != kCVReturnSuccess) return NULL;
    if (CVPixelBufferLockBaseAddress(pixelBuffer, 0) != kCVReturnSuccess) {
        CVPixelBufferRelease(pixelBuffer);
        return NULL;
    }
    uint8_t *destination = (uint8_t *)CVPixelBufferGetBaseAddress(pixelBuffer);
    size_t destinationStride = CVPixelBufferGetBytesPerRow(pixelBuffer);
    int shift = (planar420p10 || p010) ? 2 : 0;
    BOOL fullRange = frame->format == AV_PIX_FMT_YUVJ420P ||
        frame->color_range == AVCOL_RANGE_JPEG;
    for (int y = 0; y < outputHeight; y++) {
        int sourceY = MIN(frame->height - 1,
                          (int)((int64_t)y * frame->height / outputHeight));
        const uint8_t *luma = frame->data[0] + sourceY * frame->linesize[0];
        const uint8_t *chromaU = frame->data[1] + (sourceY / 2) * frame->linesize[1];
        const uint8_t *chromaV = (planar420 || planar420p10)
            ? frame->data[2] + (sourceY / 2) * frame->linesize[2] : NULL;
        uint8_t *row = destination + (size_t)y * destinationStride;
        for (int x = 0; x < outputWidth; x++) {
            int sourceX = MIN(frame->width - 1,
                              (int)((int64_t)x * frame->width / outputWidth));
            int sampleY;
            int sampleU;
            int sampleV;
            if (planar420 || nv12) {
                sampleY = luma[sourceX];
                if (planar420) {
                    sampleU = chromaU[sourceX / 2];
                    sampleV = chromaV[sourceX / 2];
                } else {
                    sampleU = chromaU[(sourceX / 2) * 2];
                    sampleV = chromaU[(sourceX / 2) * 2 + 1];
                }
            } else {
                sampleY = AV_RL16(luma + sourceX * 2) >> shift;
                if (planar420p10) {
                    sampleU = AV_RL16(chromaU + (sourceX / 2) * 2) >> shift;
                    sampleV = AV_RL16(chromaV + (sourceX / 2) * 2) >> shift;
                } else {
                    sampleU = AV_RL16(chromaU + ((sourceX / 2) * 2) * 2) >> shift;
                    sampleV = AV_RL16(chromaU + (((sourceX / 2) * 2) * 2) + 2) >> shift;
                }
            }
            int c = fullRange ? sampleY : MAX(0, sampleY - 16);
            int d = sampleU - 128;
            int e = sampleV - 128;
            int red = fullRange ? c + ((359 * e + 128) >> 8)
                                : (298 * c + 409 * e + 128) >> 8;
            int green = fullRange ? c - ((88 * d + 183 * e + 128) >> 8)
                                  : (298 * c - 100 * d - 208 * e + 128) >> 8;
            int blue = fullRange ? c + ((454 * d + 128) >> 8)
                                 : (298 * c + 516 * d + 128) >> 8;
            row[x * 4 + 0] = (uint8_t)MAX(0, MIN(255, blue));
            row[x * 4 + 1] = (uint8_t)MAX(0, MIN(255, green));
            row[x * 4 + 2] = (uint8_t)MAX(0, MIN(255, red));
            row[x * 4 + 3] = 255;
        }
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    return pixelBuffer;
}

static CMTime VCAMLocalCMTimeFromAVFrame(AVFrame *frame, AVStream *stream) {
    int64_t pts = frame == NULL ? AV_NOPTS_VALUE : frame->pts;
    if (pts == AV_NOPTS_VALUE && frame != NULL) {
        pts = frame->best_effort_timestamp;
    }
    if (pts == AV_NOPTS_VALUE) return kCMTimeZero;
    AVRational timeBase = stream != NULL && stream->time_base.num > 0 &&
        stream->time_base.den > 0 ? stream->time_base : (AVRational){1, 600};
    double seconds = (double)pts * av_q2d(timeBase);
    if (!isfinite(seconds) || seconds < 0) return kCMTimeZero;
    return CMTimeMakeWithSeconds(seconds, 600);
}

static CMTime VCAMLocalPacketTime(AVPacket *packet, AVStream *stream) {
    if (packet == NULL) return kCMTimeInvalid;
    int64_t pts = packet->pts != AV_NOPTS_VALUE ? packet->pts : packet->dts;
    if (pts == AV_NOPTS_VALUE) return kCMTimeZero;
    AVRational timeBase = stream != NULL ? stream->time_base : (AVRational){1, 600};
    double seconds = (double)pts * av_q2d(timeBase);
    if (!isfinite(seconds) || seconds < 0) seconds = 0;
    return CMTimeMakeWithSeconds(seconds, 600);
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
    BOOL _ffmpegMode;
    BOOL _ffHwaccelMode;
    BOOL _ffEndOfFile;
    BOOL _ffFirstFrameLogged;
    AVFormatContext *_ffFormatContext;
    AVCodecContext *_ffCodecContext;
    AVFrame *_ffFrame;
    AVPacket *_ffPacket;
    int _ffVideoStreamIndex;
    AVStream *_ffVideoStream;
    BOOL _ffUseHardware;
    VCAMHardwareVideoDecoder *_hardwareDecoder;
}
@property(nonatomic, strong) VCAMConfiguration *configuration;
@property(nonatomic, strong) VCAMFrameRenderer *renderer;
@property(nonatomic, strong, nullable) AVURLAsset *asset;
@property(nonatomic, strong, nullable) AVAssetReader *videoReader;
@property(nonatomic, strong, nullable) AVAssetReaderTrackOutput *videoOutput;
@property(nonatomic, strong, nullable) AVAssetReader *audioReader;
@property(nonatomic, strong, nullable) AVAssetReaderTrackOutput *audioOutput;
@property(nonatomic) Float64 audioSampleRate;
@property(nonatomic) UInt32 audioChannelCount;
@property(nonatomic) BOOL running;
@property(nonatomic) CGAffineTransform videoTransform;
- (BOOL)startFFmpegVideoReader:(NSError **)error;
- (BOOL)startFFmpegHwaccelReader:(NSError **)error;
- (void)closeFFmpegReader;
- (BOOL)advanceFFmpegFrame;
- (BOOL)advanceHwaccelFrame;
- (BOOL)publishFFmpegFrame;
- (BOOL)restartFFmpegAfterEndAtHostTime:(CFTimeInterval)hostTime;
@end

static enum AVPixelFormat VCAMLocalSelectHardwarePixelFormat(
    AVCodecContext *context, const enum AVPixelFormat *formats) {
    (void)context;
    for (const enum AVPixelFormat *format = formats; *format != AV_PIX_FMT_NONE; format++) {
        if (*format == AV_PIX_FMT_VIDEOTOOLBOX) return *format;
    }
    return AV_PIX_FMT_NONE;
}

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
    [self closeFFmpegReader];
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
    if ([self advanceVideoFrame]) return YES;

    AVAssetReaderStatus status = self.videoReader.status;
    NSError *firstFrameError = self.videoReader.error ?: [NSError
        errorWithDomain:@"VCAMLocalMediaSource"
                   code:5
               userInfo:@{NSLocalizedDescriptionKey:
                   @"Unable to decode the first video frame"}];
    [self reportVideoReaderFailureWithStatus:status error:firstFrameError];
    [self resetVideoReaderState];
    [VCAMConfiguration appendProcessLog:
        @"local reader failed; switching to FFmpeg software decode"];
    if ([self startFFmpegVideoReader:error]) return YES;
    // The hand-rolled VideoToolbox session needs a valid avcC/hvcC in the
    // container. Some files (or iOS-16.5 asset-reader quirks) only carry
    // parameter sets in-band, so fall back to FFmpeg's own VideoToolbox
    // hwaccel, which assembles the parameter sets from the stream and still
    // decodes on the hardware decoder.
    [VCAMConfiguration appendProcessLog:
        @"local direct-VT failed; switching to FFmpeg videotoolbox hwaccel"];
    if (![self startFFmpegHwaccelReader:error]) return NO;
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
    // Request the native iOS H.264 decode surface instead of BGRA. On iOS 16.5
    // the worker observed an unbounded stream of zero-sample markers for BGRA,
    // while video-range bi-planar output keeps the hardware-friendly decoded
    // CVPixelBuffer contract. VCAMFrameRenderer performs the one required color
    // conversion while applying the source transform and user controls.
    AVAssetReaderTrackOutput *output = [AVAssetReaderTrackOutput
        assetReaderTrackOutputWithTrack:videoTrack
                          outputSettings:@{
                              (id)kCVPixelBufferPixelFormatTypeKey:
                                  @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                          }];
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
            (unsigned long)_readerLoopCount,
            (unsigned int)kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            NSStringFromClass(output.class)]];
    }
    return YES;
}

- (BOOL)advanceVideoFrame {
    if (_ffmpegMode) {
        return _ffHwaccelMode ? [self advanceHwaccelFrame] : [self advanceFFmpegFrame];
    }
    CMSampleBufferRef sample = NULL;
    CVPixelBufferRef pixelBuffer = NULL;
    NSUInteger skippedNonPixelSamples = 0;
    BOOL permanentEmptyMedia = NO;
    while (skippedNonPixelSamples < VCAMVideoNonPixelSampleSkipLimit) {
        sample = [self.videoOutput copyNextSampleBuffer];
        if (sample == NULL) {
            AVAssetReaderStatus status = self.videoReader.status;
            if (status == AVAssetReaderStatusFailed || status == AVAssetReaderStatusCancelled) {
                [self reportVideoReaderFailureWithStatus:status error:self.videoReader.error];
            }
            return NO;
        }

        pixelBuffer = CMSampleBufferGetImageBuffer(sample);
        CMFormatDescriptionRef formatDescription = CMSampleBufferGetFormatDescription(sample);
        FourCharCode mediaSubtype = formatDescription == NULL
            ? 0 : CMFormatDescriptionGetMediaSubType(formatDescription);
        CFTypeRef emptyMediaAttachment = CMGetAttachment(
            sample, kCMSampleBufferAttachmentKey_EmptyMedia, NULL);
        CFTypeRef permanentEmptyMediaAttachment = CMGetAttachment(
            sample, kCMSampleBufferAttachmentKey_PermanentEmptyMedia, NULL);
        BOOL emptyMedia = emptyMediaAttachment != NULL &&
            CFGetTypeID(emptyMediaAttachment) == CFBooleanGetTypeID() &&
            CFBooleanGetValue((CFBooleanRef)emptyMediaAttachment);
        permanentEmptyMedia = permanentEmptyMediaAttachment != NULL &&
            CFGetTypeID(permanentEmptyMediaAttachment) == CFBooleanGetTypeID() &&
            CFBooleanGetValue((CFBooleanRef)permanentEmptyMediaAttachment);
        CMItemCount sampleCount = CMSampleBufferGetNumSamples(sample);
        BOOL dataReady = CMSampleBufferDataIsReady(sample);
        if (!_readerFirstSampleLogged) {
            _readerFirstSampleLogged = YES;
            [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
                @"local reader first-sample mediaSubtype=%08x hasImageBuffer=%d hasDataBuffer=%d emptyMedia=%d permanentEmptyMedia=%d numSamples=%ld dataReady=%d outputClass=%@ status=%ld",
                (unsigned int)mediaSubtype, pixelBuffer != NULL,
                CMSampleBufferGetDataBuffer(sample) != NULL, emptyMedia,
                permanentEmptyMedia, (long)sampleCount, dataReady,
                NSStringFromClass(self.videoOutput.class), (long)self.videoReader.status]];
        }
        if (pixelBuffer != NULL) break;

        skippedNonPixelSamples += 1;
        [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
            @"local reader skipped non-pixel sample count=%lu mediaSubtype=%08x emptyMedia=%d permanentEmptyMedia=%d numSamples=%ld dataReady=%d status=%ld",
            (unsigned long)skippedNonPixelSamples, (unsigned int)mediaSubtype,
            emptyMedia, permanentEmptyMedia, (long)sampleCount, dataReady,
            (long)self.videoReader.status]];
        CFRelease(sample);
        sample = NULL;
        if (permanentEmptyMedia) break;
    }

    if (sample == NULL || pixelBuffer == NULL) {
        if (sample != NULL) CFRelease(sample);
        NSError *sampleError = [NSError errorWithDomain:@"VCAMLocalMediaSource" code:4
                                               userInfo:@{NSLocalizedDescriptionKey:
                                                   permanentEmptyMedia
                                                       ? @"Incremental video reader reached a permanent empty-media marker"
                                                       : @"Incremental video reader exceeded the non-pixel sample limit"}];
        [self reportVideoReaderFailureWithStatus:self.videoReader.status error:sampleError];
        [self.videoReader cancelReading];
        self.videoOutput = nil;
        self.videoReader = nil;
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

- (BOOL)startFFmpegHwaccelReader:(NSError **)error {
    NSString *path = self.configuration.mediaPath;
    AVFormatContext *format = NULL;
    int openResult = avformat_open_input(&format, path.fileSystemRepresentation, NULL, NULL);
    if (openResult != 0) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"VCAMLocalMediaSource" code:12
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         @"FFmpeg could not open the local video (hwaccel)"}];
        }
        return NO;
    }
    if (avformat_find_stream_info(format, NULL) < 0) {
        avformat_close_input(&format);
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"VCAMLocalMediaSource" code:13
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         @"FFmpeg could not read local stream info (hwaccel)"}];
        }
        return NO;
    }
    int videoIndex = av_find_best_stream(format, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (videoIndex < 0) {
        avformat_close_input(&format);
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"VCAMLocalMediaSource" code:14
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         @"FFmpeg found no local video stream (hwaccel)"}];
        }
        return NO;
    }
    AVStream *stream = format->streams[videoIndex];
    const AVCodec *decoder = avcodec_find_decoder(stream->codecpar->codec_id);
    if (decoder == NULL) {
        avformat_close_input(&format);
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"VCAMLocalMediaSource" code:15
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         @"No local video decoder available (hwaccel)"}];
        }
        return NO;
    }
    AVCodecContext *codecContext = avcodec_alloc_context3(decoder);
    if (codecContext == NULL ||
        avcodec_parameters_to_context(codecContext, stream->codecpar) < 0) {
        avcodec_free_context(&codecContext);
        avformat_close_input(&format);
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"VCAMLocalMediaSource" code:16
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         @"Could not configure local video decoder (hwaccel)"}];
        }
        return NO;
    }
    codecContext->err_recognition = AV_EF_CAREFUL;
    codecContext->thread_count = 1;
    codecContext->get_format = VCAMLocalSelectHardwarePixelFormat;
    AVBufferRef *hardwareDevice = NULL;
    if (av_hwdevice_ctx_create(&hardwareDevice, AV_HWDEVICE_TYPE_VIDEOTOOLBOX,
                               NULL, NULL, 0) < 0 ||
        (codecContext->hw_device_ctx = av_buffer_ref(hardwareDevice)) == NULL) {
        av_buffer_unref(&hardwareDevice);
        avcodec_free_context(&codecContext);
        avformat_close_input(&format);
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"VCAMLocalMediaSource" code:17
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         @"VideoToolbox device unavailable for local video"}];
        }
        return NO;
    }
    av_buffer_unref(&hardwareDevice);
    if (avcodec_open2(codecContext, decoder, NULL) < 0) {
        avcodec_free_context(&codecContext);
        avformat_close_input(&format);
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"VCAMLocalMediaSource" code:18
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         @"Could not open local hardware decoder"}];
        }
        return NO;
    }
    _ffFormatContext = format;
    _ffVideoStreamIndex = videoIndex;
    _ffVideoStream = stream;
    _ffCodecContext = codecContext;
    _ffPacket = av_packet_alloc();
    _ffFrame = av_frame_alloc();
    if (_ffPacket == NULL || _ffFrame == NULL) {
        [self closeFFmpegReader];
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"VCAMLocalMediaSource" code:19
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         @"Out of memory for local hardware decoder"}];
        }
        return NO;
    }
    _ffmpegMode = YES;
    _ffHwaccelMode = YES;
    _ffEndOfFile = NO;
    _ffFirstFrameLogged = NO;
    [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
        @"local hwaccel ready size=%dx%d codec=%s",
        stream->codecpar->width, stream->codecpar->height,
        avcodec_get_name(stream->codecpar->codec_id)]];
    if (![self advanceHwaccelFrame]) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"VCAMLocalMediaSource" code:20
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         @"Unable to decode the first video frame (hwaccel)"}];
        }
        [self closeFFmpegReader];
        return NO;
    }
    return YES;
}

- (BOOL)advanceHwaccelFrame {
    if (!_ffmpegMode || !_ffHwaccelMode || _ffCodecContext == NULL) return NO;
    while (YES) {
        int readResult = av_read_frame(_ffFormatContext, _ffPacket);
        if (readResult < 0) {
            if (readResult == AVERROR_EOF && self.configuration.loopMedia) {
                if (av_seek_frame(_ffFormatContext, _ffVideoStreamIndex, 0,
                                  AVSEEK_FLAG_BACKWARD) < 0) return NO;
                avcodec_flush_buffers(_ffCodecContext);
                _ffEndOfFile = NO;
                continue;
            }
            if (readResult == AVERROR_EOF) _ffEndOfFile = YES;
            return NO;
        }
        if (_ffPacket->stream_index != _ffVideoStreamIndex) {
            av_packet_unref(_ffPacket);
            continue;
        }
        int sendResult = avcodec_send_packet(_ffCodecContext, _ffPacket);
        av_packet_unref(_ffPacket);
        if (sendResult < 0 && sendResult != AVERROR(EAGAIN)) {
            static volatile int localHwaccelSendFailures = 0;
            int failureCount = __sync_add_and_fetch(&localHwaccelSendFailures, 1);
            if (failureCount <= 4) {
                [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
                    @"local hwaccel send_packet failed error=%d", sendResult]];
            }
            continue;
        }
        while (YES) {
            int receiveResult = avcodec_receive_frame(_ffCodecContext, _ffFrame);
            if (receiveResult == AVERROR(EAGAIN)) break;
            if (receiveResult < 0) break;
            if (_ffFrame->format == AV_PIX_FMT_VIDEOTOOLBOX &&
                _ffFrame->data[3] != NULL) {
                CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)_ffFrame->data[3];
                CMTime pts = VCAMLocalCMTimeFromAVFrame(_ffFrame, _ffVideoStream);
                CVPixelBufferRef retained = CVPixelBufferRetain(pixelBuffer);
                CMVideoFormatDescriptionRef format = NULL;
                if (CMVideoFormatDescriptionCreateForImageBuffer(
                        kCFAllocatorDefault, retained, &format) == noErr) {
                    CMSampleTimingInfo timing = {
                        .duration = CMTimeMake(1, (int32_t)MAX(1, self.configuration.preferredFramesPerSecond)),
                        .presentationTimeStamp = pts,
                        .decodeTimeStamp = kCMTimeInvalid,
                    };
                    CMSampleBufferRef sample = NULL;
                    if (CMSampleBufferCreateForImageBuffer(
                            kCFAllocatorDefault, retained, true, NULL, NULL,
                            format, &timing, &sample) == noErr) {
                        if (_currentVideoSample != NULL) CFRelease(_currentVideoSample);
                        _currentVideoSample = sample;
                        _currentVideoPTS = pts;
                        _diagnosticNewFrames += 1;
                        [self recordDiagnosticSourceFrame];
                        if (!_ffFirstFrameLogged) {
                            _ffFirstFrameLogged = YES;
                            [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
                                @"local hwaccel first-frame pts=%.6f size=%zux%zu",
                                CMTimeGetSeconds(pts),
                                CVPixelBufferGetWidth(retained),
                                CVPixelBufferGetHeight(retained)]];
                        }
                        CFRelease(format);
                        CVPixelBufferRelease(retained);
                        av_frame_unref(_ffFrame);
                        return YES;
                    }
                    CFRelease(format);
                }
                CVPixelBufferRelease(retained);
            }
            av_frame_unref(_ffFrame);
        }
    }
}

- (BOOL)startFFmpegVideoReader:(NSError **)error {
    NSString *path = self.configuration.mediaPath;
    AVFormatContext *format = NULL;
    int openResult = avformat_open_input(&format, path.fileSystemRepresentation, NULL, NULL);
    if (openResult != 0) {
        [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
            @"local ffmpeg open failed code=%d error=%s", openResult,
            av_err2str(openResult)]];
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"VCAMLocalMediaSource" code:6
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         @"FFmpeg could not open the local video"}];
        }
        return NO;
    }
    if (avformat_find_stream_info(format, NULL) < 0) {
        avformat_close_input(&format);
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"VCAMLocalMediaSource" code:7
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         @"FFmpeg could not read local stream info"}];
        }
        return NO;
    }
    int videoIndex = av_find_best_stream(format, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (videoIndex < 0) {
        avformat_close_input(&format);
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"VCAMLocalMediaSource" code:8
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         @"FFmpeg found no local video stream"}];
        }
        return NO;
    }
    AVStream *stream = format->streams[videoIndex];
    VCAMHardwareVideoDecoder *decoder = [[VCAMHardwareVideoDecoder alloc]
        initWithCodecParameters:stream->codecpar];
    NSError *decoderError = nil;
    if (decoder == nil || ![decoder start:&decoderError]) {
        [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
            @"local hardware decoder unavailable error=%@",
            decoderError.localizedDescription ?: @"(init failed)"]];
        avformat_close_input(&format);
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"VCAMLocalMediaSource" code:9
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         @"VideoToolbox could not decode the local video"}];
        }
        return NO;
    }
    _ffFormatContext = format;
    _ffVideoStreamIndex = videoIndex;
    _ffVideoStream = stream;
    _ffPacket = av_packet_alloc();
    _hardwareDecoder = decoder;
    _ffmpegMode = YES;
    _ffEndOfFile = NO;
    _ffFirstFrameLogged = NO;
    double fps = stream->avg_frame_rate.num > 0 && stream->avg_frame_rate.den > 0
        ? av_q2d(stream->avg_frame_rate) : 0.0;
    [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
        @"local hardware ready size=%dx%d fps=%.2f codec=%s",
        stream->codecpar->width, stream->codecpar->height, fps,
        avcodec_get_name(stream->codecpar->codec_id)]];
    if (![self advanceFFmpegFrame]) {
        [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
            @"local hardware first-frame failed width=%d height=%d eof=%d",
            stream->codecpar->width, stream->codecpar->height, _ffEndOfFile ? 1 : 0]];
        NSError *decodeError = [NSError errorWithDomain:@"VCAMLocalMediaSource" code:11
                                               userInfo:@{NSLocalizedDescriptionKey:
                                                   @"Unable to decode the first video frame (hardware)"}];
        if (error != NULL) *error = decodeError;
        [self resetVideoReaderState];
        return NO;
    }
    return YES;
}

- (void)closeFFmpegReader {
    _hardwareDecoder = nil;
    if (_ffFormatContext != NULL) {
        avformat_close_input(&_ffFormatContext);
        _ffFormatContext = NULL;
    }
    if (_ffCodecContext != NULL) {
        avcodec_free_context(&_ffCodecContext);
        _ffCodecContext = NULL;
    }
    if (_ffFrame != NULL) {
        av_frame_free(&_ffFrame);
        _ffFrame = NULL;
    }
    if (_ffPacket != NULL) {
        av_packet_free(&_ffPacket);
        _ffPacket = NULL;
    }
    _ffVideoStream = NULL;
    _ffVideoStreamIndex = -1;
    _ffmpegMode = NO;
    _ffHwaccelMode = NO;
    _ffEndOfFile = NO;
    _ffFirstFrameLogged = NO;
}

- (BOOL)advanceFFmpegFrame {
    if (!_ffmpegMode || _hardwareDecoder == nil) return NO;
    while (YES) {
        CMTime outputPts = kCMTimeInvalid;
        CVPixelBufferRef output = [_hardwareDecoder copyNextOutputFrame:&outputPts];
        if (output != NULL) {
            BOOL published = [self publishHardwareFrame:output pts:outputPts];
            CVPixelBufferRelease(output);
            return published;
        }
        if (_ffEndOfFile) return NO;
        int readResult = av_read_frame(_ffFormatContext, _ffPacket);
        if (readResult < 0) {
            if (readResult == AVERROR_EOF) {
                [_hardwareDecoder flush];
                _ffEndOfFile = YES;
                continue;
            }
            return NO;
        }
        if (_ffPacket->stream_index == _ffVideoStreamIndex) {
            CMTime pts = VCAMLocalPacketTime(_ffPacket, _ffVideoStream);
            [_hardwareDecoder decodePacket:_ffPacket->data
                                    length:(size_t)_ffPacket->size
                          presentationTime:pts
                                decodeTime:kCMTimeInvalid
                                  duration:kCMTimeInvalid];
        }
        av_packet_unref(_ffPacket);
    }
}

- (BOOL)publishHardwareFrame:(CVPixelBufferRef)pixelBuffer pts:(CMTime)pts {
    if (pixelBuffer == NULL) return NO;
    CMVideoFormatDescriptionRef format = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault,
                                                     pixelBuffer, &format) != noErr) {
        return NO;
    }
    CMSampleTimingInfo timing = {
        .duration = CMTimeMake(1, (int32_t)MAX(1, self.configuration.preferredFramesPerSecond)),
        .presentationTimeStamp = pts,
        .decodeTimeStamp = kCMTimeInvalid,
    };
    CMSampleBufferRef sample = NULL;
    OSStatus status = CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer,
                                                         true, NULL, NULL, format,
                                                         &timing, &sample);
    CFRelease(format);
    if (status != noErr || sample == NULL) return NO;
    if (_currentVideoSample != NULL) CFRelease(_currentVideoSample);
    _currentVideoSample = sample;
    _currentVideoPTS = pts;
    _diagnosticNewFrames += 1;
    [self recordDiagnosticSourceFrame];
    if (!_ffFirstFrameLogged) {
        _ffFirstFrameLogged = YES;
        [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
            @"local hardware first-frame pts=%.6f size=%zux%zu format=%08x",
            CMTimeGetSeconds(pts), CVPixelBufferGetWidth(pixelBuffer),
            CVPixelBufferGetHeight(pixelBuffer),
            (unsigned int)CVPixelBufferGetPixelFormatType(pixelBuffer)]];
    }
    return YES;
}

- (BOOL)publishFFmpegFrame {
    CVPixelBufferRef pixelBuffer = NULL;
    if (_ffUseHardware && _ffFrame->format == AV_PIX_FMT_VIDEOTOOLBOX &&
        _ffFrame->data[3] != NULL) {
        pixelBuffer = CVPixelBufferRetain((CVPixelBufferRef)_ffFrame->data[3]);
    } else {
        pixelBuffer = VCAMLocalCopyBGRAFromAVFrame(_ffFrame);
    }
    if (pixelBuffer == NULL) {
        [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
            @"local ffmpeg unsupported frame format=%d width=%d height=%d",
            _ffFrame->format, _ffFrame->width, _ffFrame->height]];
    }
    CMTime pts = VCAMLocalCMTimeFromAVFrame(_ffFrame, _ffVideoStream);
    av_frame_unref(_ffFrame);
    if (pixelBuffer == NULL) return NO;
    CMVideoFormatDescriptionRef format = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault,
                                                     pixelBuffer, &format) != noErr) {
        CVPixelBufferRelease(pixelBuffer);
        return NO;
    }
    CMSampleTimingInfo timing = {
        .duration = CMTimeMake(1, (int32_t)MAX(1, self.configuration.preferredFramesPerSecond)),
        .presentationTimeStamp = pts,
        .decodeTimeStamp = kCMTimeInvalid,
    };
    CMSampleBufferRef sample = NULL;
    OSStatus status = CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer,
                                                         true, NULL, NULL, format,
                                                         &timing, &sample);
    CFRelease(format);
    CVPixelBufferRelease(pixelBuffer);
    if (status != noErr || sample == NULL) return NO;
    if (_currentVideoSample != NULL) CFRelease(_currentVideoSample);
    _currentVideoSample = sample;
    _currentVideoPTS = pts;
    _diagnosticNewFrames += 1;
    [self recordDiagnosticSourceFrame];
    if (!_ffFirstFrameLogged) {
        _ffFirstFrameLogged = YES;
        CVPixelBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sample);
        [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
            @"local ffmpeg first-frame pts=%.6f size=%zux%zu format=BGRA",
            CMTimeGetSeconds(pts), CVPixelBufferGetWidth(imageBuffer),
            CVPixelBufferGetHeight(imageBuffer)]];
    }
    return YES;
}

- (BOOL)restartFFmpegAfterEndAtHostTime:(CFTimeInterval)hostTime {
    if (!_ffmpegMode || !_ffEndOfFile || !self.configuration.loopMedia) return NO;
    if (av_seek_frame(_ffFormatContext, _ffVideoStreamIndex, 0, AVSEEK_FLAG_BACKWARD) < 0) {
        return NO;
    }
    [_hardwareDecoder flush];
    if (_ffHwaccelMode && _ffCodecContext != NULL) {
        avcodec_flush_buffers(_ffCodecContext);
    }
    _ffEndOfFile = NO;
    [VCAMConfiguration appendProcessLog:@"local hardware eof loop"];
    if (![self advanceVideoFrame]) return NO;
    _videoHostStart = hostTime;
    _videoMediaStartPTS = _currentVideoPTS;
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
    if (_ffmpegMode) return [self restartFFmpegAfterEndAtHostTime:hostTime];
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

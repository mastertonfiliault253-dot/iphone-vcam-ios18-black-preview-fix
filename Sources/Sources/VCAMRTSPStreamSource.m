#import "VCAMRTSPStreamSource.h"
#import "../Daemon/VCAMHardwareVideoDecoder.h"
#import "../Daemon/VCAMPixelConverter.h"
#import "../Shared/VCAMSharedFrame.h"
#import <QuartzCore/QuartzCore.h>
#import <errno.h>
#import <math.h>
#import <stdarg.h>
#import <stdio.h>
#import <stdlib.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/error.h>
#include <libavutil/hwcontext.h>
#include <libavutil/mem.h>

static NSDictionary<NSString *, id> *VCAMRTSPPerformance;
static volatile int gFFmpegDiagnosticCount = 0;
static char gFFmpegLastMessage[1024] = {0};
static int gFFmpegLastMessageCount = 0;

static void VCAMFFmpegDiagnosticLog(void *context, int level,
                                    const char *format, va_list arguments) {
    BOOL decoderClass = NO;
    if (context != NULL) {
        AVClass *cls = *(AVClass **)context;
        if (cls != NULL && cls->class_name != NULL) {
            const char *name = cls->class_name;
            if (strstr(name, "videotoolbox") != NULL ||
                strstr(name, "h264") != NULL ||
                strstr(name, "VDA") != NULL) {
                decoderClass = YES;
            }
        }
    }
    if (!decoderClass && level > AV_LOG_ERROR) return;
    if (level > AV_LOG_VERBOSE) return;
    char message[1024] = {0};
    vsnprintf(message, sizeof(message), format, arguments);
    size_t length = strlen(message);
    while (length > 0 && (message[length - 1] == '\n' || message[length - 1] == '\r')) {
        message[--length] = '\0';
    }
    if (length == 0) return;
    if (strcmp(message, gFFmpegLastMessage) == 0) {
        gFFmpegLastMessageCount += 1;
        if (gFFmpegLastMessageCount > 5) {
            if (gFFmpegLastMessageCount == 6) {
                fprintf(stderr, "[DEBUG-vtff] (further identical messages suppressed)\n");
                fflush(stderr);
            }
            return;
        }
    } else {
        strncpy(gFFmpegLastMessage, message, sizeof(gFFmpegLastMessage) - 1);
        gFFmpegLastMessageCount = 0;
    }
    int count = __sync_add_and_fetch(&gFFmpegDiagnosticCount, 1);
    if (count <= 3000) {
        NSString *line = [NSString stringWithFormat:
            @"[DEBUG-vtff] level=%d %@", level,
            [NSString stringWithUTF8String:message] ?: @"(invalid utf8)"];
        fprintf(stderr, "%s\n", line.UTF8String);
        fflush(stderr);
        [VCAMConfiguration appendProcessLog:line];
    }
}

NSDictionary<NSString *, id> *VCAMRTSPPerformanceSnapshot(void) {
    @synchronized ([VCAMRTSPStreamSource class]) {
        return [VCAMRTSPPerformance copy] ?: @{};
    }
}

static void VCAMPublishRTSPPerformance(NSDictionary<NSString *, id> *snapshot) {
    @synchronized ([VCAMRTSPStreamSource class]) {
        VCAMRTSPPerformance = [snapshot copy];
    }
}

static NSString *VCAMFFmpegErrorDescription(int result) {
    char buffer[AV_ERROR_MAX_STRING_SIZE] = {0};
    if (av_strerror(result, buffer, sizeof(buffer)) != 0) return [NSString stringWithFormat:@"%d", result];
    return [NSString stringWithFormat:@"%d (%s)", result, buffer];
}

static int VCAMCompareRTSPInterval(const void *left, const void *right) {
    double a = *(const double *)left;
    double b = *(const double *)right;
    return (a > b) - (a < b);
}

static CMTime VCAMPacketTime(AVPacket *packet, AVStream *stream) {
    if (packet == NULL) return kCMTimeInvalid;
    int64_t pts = packet->pts != AV_NOPTS_VALUE ? packet->pts : packet->dts;
    if (pts == AV_NOPTS_VALUE) return kCMTimeInvalid;
    AVRational timeBase = stream != NULL ? stream->time_base : (AVRational){1, 90000};
    double seconds = (double)pts * av_q2d(timeBase);
    if (!isfinite(seconds)) return kCMTimeInvalid;
    return CMTimeMakeWithSeconds(seconds, 600);
}

static CMTime VCAMPacketDuration(AVPacket *packet, AVStream *stream) {
    if (packet == NULL || packet->duration <= 0) return kCMTimeInvalid;
    AVRational timeBase = stream != NULL ? stream->time_base : (AVRational){1, 90000};
    double seconds = (double)packet->duration * av_q2d(timeBase);
    return isfinite(seconds) && seconds > 0
        ? CMTimeMakeWithSeconds(seconds, 600) : kCMTimeInvalid;
}

static enum AVPixelFormat VCAMRequestVideoToolboxFormat(AVCodecContext *context,
                                                           const enum AVPixelFormat *formats) {
    (void)context;
    for (const enum AVPixelFormat *format = formats; *format != AV_PIX_FMT_NONE; format++) {
        if (*format == AV_PIX_FMT_VIDEOTOOLBOX) return *format;
    }
    return *formats;
}

static AVCodecParameters *VCAMCopyCodecParametersWithPacketExtradata(
    const AVCodecParameters *source, const AVPacket *packet) {
    if (source == NULL || packet == NULL || packet->data == NULL ||
        packet->size <= 0) return NULL;
    AVCodecParameters *copy = avcodec_parameters_alloc();
    if (copy == NULL) return NULL;
    if (avcodec_parameters_copy(copy, source) < 0) {
        avcodec_parameters_free(&copy);
        return NULL;
    }
    av_freep(&copy->extradata);
    copy->extradata = av_mallocz((size_t)packet->size + AV_INPUT_BUFFER_PADDING_SIZE);
    if (copy->extradata == NULL) {
        avcodec_parameters_free(&copy);
        return NULL;
    }
    memcpy(copy->extradata, packet->data, (size_t)packet->size);
    copy->extradata_size = packet->size;
    return copy;
}

@interface VCAMRTSPStreamSource () {
    CVPixelBufferRef _latestPixelBuffer;
    CFTimeInterval _latestFrameHostTime;
    uint64_t _latestFrameSequence;
    uint64_t _lastDisplayFrameSequence;
    uint64_t _lastRenderedFrameSequence;
    CMSampleBufferRef _lastRenderedSample;
    size_t _lastRenderedWidth;
    size_t _lastRenderedHeight;
    OSType _lastRenderedPixelFormat;
    CFTimeInterval _diagnosticWindowStart;
    CFTimeInterval _diagnosticLastFrameTime;
    NSUInteger _diagnosticFrames;
    NSUInteger _diagnosticHardwareFrames;
    BOOL _loggedFirstHardwareFrame;
    BOOL _loggedFirstSoftwareFrame;
    double _diagnosticFrameIntervals[256];
    NSUInteger _diagnosticFrameIntervalCount;
    AVFrame *_pendingSoftwareFrame;
    BOOL _softwareConversionScheduled;
}
@property(nonatomic, strong) VCAMConfiguration *configuration;
@property(nonatomic, strong) VCAMFrameRenderer *renderer;
@property(nonatomic, strong, nullable) NSURL *streamURL;
@property(nonatomic, copy) NSString *streamName;
@property(nonatomic, strong) dispatch_queue_t decodeQueue;
@property(nonatomic, strong) dispatch_queue_t conversionQueue;
@property(nonatomic) BOOL running;
@property(nonatomic) BOOL usesRTSPTransport;
- (BOOL)decodeOneFFmpegSession;
@end

@implementation VCAMRTSPStreamSource

- (instancetype)initWithConfiguration:(VCAMConfiguration *)configuration
                              renderer:(VCAMFrameRenderer *)renderer {
    self = [super init];
    if (self) {
        _configuration = configuration;
        _renderer = renderer;
        BOOL isHLS = configuration.sourceKind == VCAMSourceKindHLS;
        _streamURL = isHLS ? configuration.hlsURL : configuration.rtspURL;
        _streamName = isHLS ? @"hls" : @"rtsp";
        _usesRTSPTransport = !isHLS;
        _decodeQueue = dispatch_queue_create("com.codex.vcam.stream.decode", DISPATCH_QUEUE_SERIAL);
        _conversionQueue = dispatch_queue_create("com.codex.vcam.stream.convert", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (BOOL)start:(NSError **)error {
    NSString *scheme = self.streamURL.scheme.lowercaseString;
    BOOL validScheme = self.usesRTSPTransport
        ? [scheme isEqualToString:@"rtsp"]
        : ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]);
    if (self.streamURL == nil || !validScheme) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"VCAMRTSPStreamSource" code:1
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         [NSString stringWithFormat:@"%@ URL is missing or invalid",
                                          self.streamName.uppercaseString]}];
        }
        return NO;
    }
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        avformat_network_init();
        av_log_set_callback(VCAMFFmpegDiagnosticLog);
    });
    self.running = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.decodeQueue, ^{ [weakSelf decodeReconnectLoop]; });
    return YES;
}

- (void)configureOpenOptions:(AVDictionary **)options {
    if (self.usesRTSPTransport) {
        // MediaMTX documents interleaved TCP as the most versatile client
        // transport. Forcing TCP already makes prefer_tcp redundant.
        av_dict_set(options, "rtsp_transport", "tcp", 0);
        av_dict_set(options, "allowed_media_types", "video", 0);
        av_dict_set(options, "timeout", "10000000", 0);
    } else {
        av_dict_set(options, "rw_timeout", "3000000", 0);
    }
}

- (void)stop {
    self.running = NO;
    @synchronized (self) {
        if (_latestPixelBuffer != NULL) CVPixelBufferRelease(_latestPixelBuffer);
        if (_lastRenderedSample != NULL) CFRelease(_lastRenderedSample);
        _latestPixelBuffer = NULL;
        _lastRenderedSample = NULL;
        _latestFrameHostTime = 0;
        _latestFrameSequence = 0;
        _lastDisplayFrameSequence = 0;
        _lastRenderedFrameSequence = 0;
        if (_pendingSoftwareFrame != NULL) av_frame_free(&_pendingSoftwareFrame);
    }
}

- (void)drainLatestSoftwareFrames {
    while (YES) {
        AVFrame *frame = NULL;
        @synchronized (self) {
            if (!self.running || _pendingSoftwareFrame == NULL) {
                _softwareConversionScheduled = NO;
                return;
            }
            frame = _pendingSoftwareFrame;
            _pendingSoftwareFrame = NULL;
        }

        @autoreleasepool {
            CVPixelBufferRef pixelBuffer = VCAMCopyNV12FromAVFrame(frame);
            if (pixelBuffer == NULL) {
                pixelBuffer = [self copyBGRAFromSoftwareFrame:frame];
            }
            if (pixelBuffer != NULL) {
                [self acceptDecodedPixelBuffer:pixelBuffer hardware:NO];
                CVPixelBufferRelease(pixelBuffer);
            } else {
                static dispatch_once_t conversionFailureToken;
                dispatch_once(&conversionFailureToken, ^{
                    [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
                        @"%@ software conversion failed format=%d size=%dx%d",
                        self.streamName, frame->format, frame->width, frame->height]];
                });
            }
        }
        av_frame_free(&frame);
    }
}

- (BOOL)enqueueLatestSoftwareFrame:(AVFrame *)frame {
    AVFrame *snapshot = frame == NULL ? NULL : av_frame_clone(frame);
    if (snapshot == NULL) return NO;
    BOOL scheduleConversion = NO;
    @synchronized (self) {
        if (!self.running) {
            av_frame_free(&snapshot);
            return NO;
        }
        if (_pendingSoftwareFrame != NULL) av_frame_free(&_pendingSoftwareFrame);
        _pendingSoftwareFrame = snapshot;
        if (!_softwareConversionScheduled) {
            _softwareConversionScheduled = YES;
            scheduleConversion = YES;
        }
    }
    if (scheduleConversion) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(self.conversionQueue, ^{ [weakSelf drainLatestSoftwareFrames]; });
    }
    return YES;
}

- (void)dealloc {
    [self stop];
}

- (void)decodeReconnectLoop {
    NSUInteger consecutiveFailures = 0;
    while (self.running) {
        BOOL producedFrame = NO;
        @autoreleasepool {
            producedFrame = [self decodeOneSession];
        }
        if (!self.running) break;
        if (producedFrame) {
            consecutiveFailures = 0;
            [NSThread sleepForTimeInterval:0.5];
            continue;
        }
        // An unreachable or rejecting stream endpoint used to make vcamd
        // reconnect as fast as FFmpeg failed (fixed 0.5s loop), exhausting
        // backboardd wakeups and wedging the display on device. Back off
        // exponentially with a hard cap so the pipeline stays quiet while
        // the source is offline.
        NSUInteger backoffSeconds = MIN(10U, 1U << MIN(consecutiveFailures, 4U));
        consecutiveFailures = MIN(consecutiveFailures + 1, 16U);
        [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
            @"%@ reconnect backing off %lu s", self.streamName,
            (unsigned long)backoffSeconds]];
        for (NSUInteger step = 0; step < backoffSeconds && self.running; step++) {
            [NSThread sleepForTimeInterval:1.0];
        }
    }
}

- (void)acceptDecodedPixelBuffer:(CVPixelBufferRef)pixelBuffer hardware:(BOOL)hardware {
    CVPixelBufferRetain(pixelBuffer);
    // Tag the decode class so the publisher can fold it into the shared-frame
    // metadata and the panel can display the hardware/software decoder state.
    CVBufferSetAttachment(pixelBuffer, CFSTR("com.codex.vcam.decodeHardware"),
                          hardware ? kCFBooleanTrue : kCFBooleanFalse,
                          kCVAttachmentMode_ShouldPropagate);
    CFTimeInterval now = CACurrentMediaTime();
    NSDictionary<NSString *, id> *snapshot = nil;
    BOOL logFirstHardwareFrame = NO;
    BOOL logFirstSoftwareFrame = NO;
    uint64_t firstHardwareSequence = 0;
    @synchronized (self) {
        if (!self.running) {
            CVPixelBufferRelease(pixelBuffer);
            return;
        }
        if (_latestPixelBuffer != NULL) CVPixelBufferRelease(_latestPixelBuffer);
        _latestPixelBuffer = pixelBuffer;
        _latestFrameHostTime = now;
        _latestFrameSequence += 1;
        _diagnosticFrames += 1;
        if (hardware) {
            _diagnosticHardwareFrames += 1;
            if (!_loggedFirstHardwareFrame) {
                _loggedFirstHardwareFrame = YES;
                logFirstHardwareFrame = YES;
                firstHardwareSequence = _latestFrameSequence;
            }
        } else if (!_loggedFirstSoftwareFrame) {
            _loggedFirstSoftwareFrame = YES;
            logFirstSoftwareFrame = YES;
        }
        if (_diagnosticLastFrameTime > 0 && _diagnosticFrameIntervalCount < 256) {
            _diagnosticFrameIntervals[_diagnosticFrameIntervalCount++] =
                (now - _diagnosticLastFrameTime) * 1000.0;
        }
        _diagnosticLastFrameTime = now;
        if (_diagnosticWindowStart == 0) _diagnosticWindowStart = now;
        CFTimeInterval elapsed = now - _diagnosticWindowStart;
        if (elapsed >= 1.0) {
            double p95Milliseconds = 0;
            if (_diagnosticFrameIntervalCount > 0) {
                qsort(_diagnosticFrameIntervals, _diagnosticFrameIntervalCount,
                      sizeof(_diagnosticFrameIntervals[0]), VCAMCompareRTSPInterval);
                NSUInteger p95Index = (NSUInteger)ceil(_diagnosticFrameIntervalCount * 0.95) - 1;
                p95Milliseconds = _diagnosticFrameIntervals[p95Index];
            }
            snapshot = @{
                @"source": self.streamName,
                @"sourceFPS": @((double)_diagnosticFrames / elapsed),
                @"sourceFrameP95Ms": @(p95Milliseconds),
                @"sourceWidth": @(CVPixelBufferGetWidth(pixelBuffer)),
                @"sourceHeight": @(CVPixelBufferGetHeight(pixelBuffer)),
                @"sourcePixelFormat": @(CVPixelBufferGetPixelFormatType(pixelBuffer)),
                @"hardwareFrames": @(_diagnosticHardwareFrames),
                @"frameSequence": @(_latestFrameSequence),
            };
            _diagnosticWindowStart = now;
            _diagnosticFrames = 0;
            _diagnosticHardwareFrames = 0;
            _diagnosticFrameIntervalCount = 0;
        }
    }
    if (logFirstHardwareFrame) {
        [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
            @"%@ hardware first-frame size=%zux%zu format=%08x sequence=%llu",
            self.streamName, CVPixelBufferGetWidth(pixelBuffer),
            CVPixelBufferGetHeight(pixelBuffer),
            (unsigned int)CVPixelBufferGetPixelFormatType(pixelBuffer),
            (unsigned long long)firstHardwareSequence]];
    }
    if (logFirstSoftwareFrame) {
        [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
            @"%@ first software pixel buffer format=%08x size=%zux%zu",
            self.streamName,
            (unsigned int)CVPixelBufferGetPixelFormatType(pixelBuffer),
            CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer)]];
    }
    if (snapshot != nil) VCAMPublishRTSPPerformance(snapshot);
}

- (CVPixelBufferRef)copyBGRAFromSoftwareFrame:(AVFrame *)frame {
    return VCAMCopyBGRAFromAVFrame(frame);
}

- (BOOL)decodeOneHardwareSession {
    AVFormatContext *formatContext = NULL;
    AVDictionary *options = NULL;
    int videoStream = -1;
    AVStream *stream = NULL;
    BOOL producedFrame = NO;
    BOOL firstFrameProduced = NO;
    CFAbsoluteTime sessionStart = 0;
    CFAbsoluteTime keyPacketAt = 0;
    BOOL receivedKeyPacket = NO;
    CMTime timelineOrigin = kCMTimeInvalid;
    VCAMHardwareVideoDecoder *decoder = nil;
    NSError *decoderError = nil;
    AVPacket *packet = NULL;
    NSString *urlString = self.streamURL.absoluteString;
    [self configureOpenOptions:&options];
    int openResult = avformat_open_input(&formatContext, urlString.UTF8String, NULL, &options);
    if (openResult < 0) {
        [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
            @"%@ direct-VT input open failed error=%@", self.streamName,
            VCAMFFmpegErrorDescription(openResult)]];
        goto cleanup;
    }
    int streamInfoResult = avformat_find_stream_info(formatContext, NULL);
    if (streamInfoResult < 0) {
        [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
            @"%@ direct-VT stream probe failed error=%@", self.streamName,
            VCAMFFmpegErrorDescription(streamInfoResult)]];
        goto cleanup;
    }
    videoStream = av_find_best_stream(formatContext, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (videoStream < 0) goto cleanup;
    stream = formatContext->streams[videoStream];
    if (stream->codecpar->extradata_size > 0) {
        decoder = [[VCAMHardwareVideoDecoder alloc]
            initWithCodecParameters:stream->codecpar];
        if (decoder == nil || ![decoder start:&decoderError]) {
            [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
                @"%@ direct-VT unavailable codec=%s extradata=%d error=%@", self.streamName,
                avcodec_get_name(stream->codecpar->codec_id),
                stream->codecpar->extradata_size,
                decoderError.localizedDescription ?: @"(init failed)"]];
            goto cleanup;
        }
    }
    packet = av_packet_alloc();
    if (packet == NULL) {
        [decoder stop];
        goto cleanup;
    }
    if (decoder != nil) {
        [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
            @"%@ hardware session codec=%s source=%dx%d", self.streamName,
            avcodec_get_name(stream->codecpar->codec_id),
            stream->codecpar->width, stream->codecpar->height]];
    } else {
        [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
            @"%@ direct-VT waiting for in-band parameter sets codec=%s", self.streamName,
            avcodec_get_name(stream->codecpar->codec_id)]];
    }
    // Opening the RTSP input and probing stream info can take several seconds.
    // Start the first-frame budget only after VideoToolbox is ready, otherwise
    // a mid-GOP P frame can consume the entire budget before the next IDR.
    sessionStart = CFAbsoluteTimeGetCurrent();
    while (self.running && av_read_frame(formatContext, packet) >= 0) {
        if (packet->stream_index == videoStream) {
            CMTime pts = VCAMPacketTime(packet, stream);
            BOOL isKeyFrame = (packet->flags & AV_PKT_FLAG_KEY) != 0;
            if (!receivedKeyPacket && !isKeyFrame) {
                // A session can join in the middle of a GOP. Feeding those
                // dependent pictures poisons VideoToolbox with missing-reference
                // errors before the first IDR arrives. The format description
                // already owns the SDP parameter sets, so wait for the IDR.
                if (CFAbsoluteTimeGetCurrent() - sessionStart > 10.0) {
                    [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
                        @"%@ direct-VT key frame timed out; falling back to FFmpeg hwaccel",
                        self.streamName]];
                    av_packet_unref(packet);
                    break;
                }
                av_packet_unref(packet);
                continue;
            }
            if (isKeyFrame && !receivedKeyPacket) {
                if (decoder == nil) {
                    AVCodecParameters *inBandParameters =
                        VCAMCopyCodecParametersWithPacketExtradata(stream->codecpar, packet);
                    decoder = [[VCAMHardwareVideoDecoder alloc]
                        initWithCodecParameters:inBandParameters];
                    avcodec_parameters_free(&inBandParameters);
                    if (decoder == nil || ![decoder start:&decoderError]) {
                        [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
                            @"%@ direct-VT in-band parameter setup failed codec=%s packet=%d error=%@",
                            self.streamName, avcodec_get_name(stream->codecpar->codec_id),
                            packet->size,
                            decoderError.localizedDescription ?: @"(init failed)"]];
                        av_packet_unref(packet);
                        break;
                    }
                    [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
                        @"%@ direct-VT using in-band parameter sets packet=%d", self.streamName,
                        packet->size]];
                    [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
                        @"%@ hardware session codec=%s source=%dx%d", self.streamName,
                        avcodec_get_name(stream->codecpar->codec_id),
                        stream->codecpar->width, stream->codecpar->height]];
                }
                receivedKeyPacket = YES;
                keyPacketAt = CFAbsoluteTimeGetCurrent();
                timelineOrigin = pts;
            }
            if (CMTIME_IS_NUMERIC(pts) && CMTIME_IS_NUMERIC(timelineOrigin)) {
                pts = CMTimeSubtract(pts, timelineOrigin);
            }
            [decoder decodePacket:packet->data
                           length:(size_t)packet->size
                 presentationTime:pts
                       decodeTime:kCMTimeInvalid
                         duration:VCAMPacketDuration(packet, stream)
                       isKeyFrame:isKeyFrame];
            CVPixelBufferRef output = NULL;
            CMTime outputPts = kCMTimeInvalid;
            while ((output = [decoder copyNextOutputFrame:&outputPts])) {
                [self acceptDecodedPixelBuffer:output hardware:YES];
                CVPixelBufferRelease(output);
                producedFrame = YES;
                firstFrameProduced = YES;
            }
            // A direct-VT session that opens but cannot produce a frame must
            // not block the pipeline forever (e.g. in-band-only parameter
            // sets). Give it a bounded first-frame window, then let the
            // FFmpeg hwaccel fallback take over.
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            BOOL keyFrameDecodeTimedOut = receivedKeyPacket && now - keyPacketAt > 2.0;
            if (!firstFrameProduced && keyFrameDecodeTimedOut) {
                [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
                    @"%@ direct-VT first frame timed out; falling back to FFmpeg hwaccel",
                    self.streamName]];
                break;
            }
        }
        av_packet_unref(packet);
    }
    [decoder flush];
    CVPixelBufferRef output = NULL;
    CMTime outputPts = kCMTimeInvalid;
    while ((output = [decoder copyNextOutputFrame:&outputPts])) {
        [self acceptDecodedPixelBuffer:output hardware:YES];
        CVPixelBufferRelease(output);
        producedFrame = YES;
    }
    [decoder stop];
cleanup:
    av_dict_free(&options);
    av_packet_free(&packet);
    avformat_close_input(&formatContext);
    return producedFrame;
}

- (BOOL)decodeOneSession {
    // Try the direct VideoToolbox session first. Its samples carry only slice
    // NALs (parameter sets live in the CMVideoFormatDescription), which is
    // what iOS VideoToolbox requires — feeding SPS/PPS into VT, as FFmpeg's
    // hwaccel does, is rejected with -12909 on device. Fall back to FFmpeg's
    // auto-hwaccel (which degrades to software on iOS) when direct VT cannot
    // produce frames.
    BOOL produced = [self decodeOneHardwareSession];
    if (produced || !self.running) {
        fprintf(stderr, "vcam direct-VT session produced=%d running=%d\n",
                produced, self.running);
        fflush(stderr);
        return produced;
    }
    fprintf(stderr, "vcam direct-VT session produced=0; falling back to FFmpeg hwaccel\n");
    fflush(stderr);
    return [self decodeOneFFmpegSession];
}

- (BOOL)consumeFFmpegFrame:(AVFrame *)decodedFrame
        loggedSoftwareFrame:(BOOL *)loggedSoftwareFrame
        loggedHardwareFrame:(BOOL *)loggedHardwareFrame
         loggedCorruptFrame:(BOOL *)loggedCorruptFrame {
    // CoreVideo exposes BT.2020 NCL metadata but no distinct constant-luminance
    // transport contract. Publishing CL as NCL changes the decoded colors, so
    // fail this frame instead of silently claiming a faithful conversion.
    if (decodedFrame->colorspace == AVCOL_SPC_BT2020_CL) {
        static dispatch_once_t unsupportedColorToken;
        dispatch_once(&unsupportedColorToken, ^{
            [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
                @"%@ BT.2020 constant-luminance frame rejected", self.streamName]];
        });
        return NO;
    }
    if ((decodedFrame->flags & AV_FRAME_FLAG_CORRUPT) != 0 ||
        decodedFrame->decode_error_flags != 0) {
        if (loggedCorruptFrame != NULL && !*loggedCorruptFrame) {
            *loggedCorruptFrame = YES;
            [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
                @"%@ corrupt decoded frame dropped flags=%d decodeErrors=%d",
                self.streamName, decodedFrame->flags, decodedFrame->decode_error_flags]];
        }
        return NO;
    }
    if (decodedFrame->format == AV_PIX_FMT_VIDEOTOOLBOX &&
        decodedFrame->data[3] != NULL) {
        // Zero-copy hardware frame: data[3] is the CVPixelBufferRef owned by
        // the VideoToolbox hwaccel.
        if (loggedHardwareFrame != NULL && !*loggedHardwareFrame) {
            *loggedHardwareFrame = YES;
            fprintf(stderr, "vcam HARDWARE frame size=%dx%d\n",
                    decodedFrame->width, decodedFrame->height);
            fflush(stderr);
        }
        [self acceptDecodedPixelBuffer:(CVPixelBufferRef)decodedFrame->data[3]
                              hardware:YES];
        return YES;
    }
    if (loggedSoftwareFrame != NULL && !*loggedSoftwareFrame) {
        *loggedSoftwareFrame = YES;
        NSString *line = [NSString stringWithFormat:
            @"%@ software frame format=%d size=%dx%d lines=%d,%d,%d",
            self.streamName, decodedFrame->format, decodedFrame->width, decodedFrame->height,
            decodedFrame->linesize[0], decodedFrame->linesize[1], decodedFrame->linesize[2]];
        fprintf(stderr, "vcam SOFTWARE frame %s\n", line.UTF8String ?: "(nil)");
        fflush(stderr);
        [VCAMConfiguration appendProcessLog:line];
    }
    return [self enqueueLatestSoftwareFrame:decodedFrame];
}

- (BOOL)decodeOneFFmpegSession {
    AVFormatContext *formatContext = NULL;
    AVCodecContext *codecContext = NULL;
    AVPacket *packet = NULL;
    AVFrame *frame = NULL;
    AVDictionary *options = NULL;
    int videoStream = -1;
    AVStream *stream = NULL;
    const AVCodec *decoder = NULL;
    BOOL producedFrame = NO;
    BOOL loggedSoftwareFrame = NO;
    BOOL loggedHardwareFrame = NO;
    BOOL loggedCorruptFrame = NO;
    BOOL loggedReceiveFailure = NO;
    BOOL loggedSendFailure = NO;
    NSString *sessionLine = nil;
    AVBufferRef *hwDeviceRef = NULL;
    NSUInteger videoPacketsWithoutFrame = 0;
    NSUInteger consecutiveSendFailures = 0;
    NSString *urlString = self.streamURL.absoluteString;
    const char *url = urlString.UTF8String;

    gFFmpegDiagnosticCount = 0;
    fprintf(stderr, "vcam rtsp session start url=%s\n",
            urlString.UTF8String ?: "(nil)");
    fflush(stderr);
    [self configureOpenOptions:&options];
    // Keep FFmpeg's normal RTP reordering and H.264 reference buffering. The
    // former low-latency combination (nobuffer/low_delay/reorder_queue_size=0)
    // could display error-concealed inter frames after a delayed packet.
    int openResult = avformat_open_input(&formatContext, url, NULL, &options);
    if (openResult < 0) {
        [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
            @"%@ FFmpeg input open failed error=%@", self.streamName,
            VCAMFFmpegErrorDescription(openResult)]];
        goto cleanup;
    }
    int streamInfoResult = avformat_find_stream_info(formatContext, NULL);
    if (streamInfoResult < 0) {
        [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
            @"%@ FFmpeg stream probe failed error=%@", self.streamName,
            VCAMFFmpegErrorDescription(streamInfoResult)]];
        goto cleanup;
    }

    videoStream = av_find_best_stream(formatContext, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (videoStream < 0) goto cleanup;
    stream = formatContext->streams[videoStream];
    decoder = avcodec_find_decoder(stream->codecpar->codec_id);
    if (decoder == NULL) goto cleanup;
    char extraHex[65] = {0};
    int extraBytes = MIN(32, stream->codecpar->extradata_size);
    for (int index = 0; index < extraBytes; index++) {
        snprintf(extraHex + index * 2, 3, "%02x", stream->codecpar->extradata[index]);
    }
    sessionLine = [NSString stringWithFormat:
        @"%@ session decoder=%s codec=%d source=%dx%d format=%d extradata=%d extra=%@",
        self.streamName, decoder->name ?: "(unknown)", stream->codecpar->codec_id,
        stream->codecpar->width, stream->codecpar->height, stream->codecpar->format,
        stream->codecpar->extradata_size,
        [NSString stringWithUTF8String:extraHex]];
    fprintf(stderr, "vcam %s\n", sessionLine.UTF8String ?: "(nil)");
    fflush(stderr);
    [VCAMConfiguration appendProcessLog:sessionLine];
    codecContext = avcodec_alloc_context3(decoder);
    if (codecContext == NULL || avcodec_parameters_to_context(codecContext, stream->codecpar) < 0) goto cleanup;
    fprintf(stderr, "vcam extradata first bytes: %02x %02x %02x %02x %02x %02x %02x %02x size=%d\n",
            codecContext->extradata_size > 0 ? codecContext->extradata[0] : 0,
            codecContext->extradata_size > 1 ? codecContext->extradata[1] : 0,
            codecContext->extradata_size > 2 ? codecContext->extradata[2] : 0,
            codecContext->extradata_size > 3 ? codecContext->extradata[3] : 0,
            codecContext->extradata_size > 4 ? codecContext->extradata[4] : 0,
            codecContext->extradata_size > 5 ? codecContext->extradata[5] : 0,
            codecContext->extradata_size > 6 ? codecContext->extradata[6] : 0,
            codecContext->extradata_size > 7 ? codecContext->extradata[7] : 0,
            codecContext->extradata_size);
    fflush(stderr);

    codecContext->err_recognition = AV_EF_CAREFUL;
    // Automatic hardware acceleration: requesting AV_PIX_FMT_VIDEOTOOLBOX in
    // get_format makes libavcodec activate the internal videotoolbox hwaccel
    // (enabled in build-ffmpeg-ios.sh) without a manual hw_device_ctx — that
    // API fails on iOS. Hardware frames arrive as AV_PIX_FMT_VIDEOTOOLBOX
    // with a CVPixelBufferRef in data[3]; if VideoToolbox rejects the stream
    // (missing SPS/PPS, unsupported profile) the decoder falls back to
    // software formats transparently.
    codecContext->get_format = VCAMRequestVideoToolboxFormat;
    codecContext->hwaccel_flags = AV_HWACCEL_FLAG_ALLOW_PROFILE_MISMATCH |
        AV_HWACCEL_FLAG_ALLOW_HIGH_DEPTH;
    codecContext->thread_count = 1;
    // The internal videotoolbox_vld hwaccel requires a hw_device_ctx even
    // though VideoToolbox has no selectable device; pass NULL device.
    int hwResult = av_hwdevice_ctx_create(&hwDeviceRef,
                                          AV_HWDEVICE_TYPE_VIDEOTOOLBOX,
                                          NULL, NULL, 0);
    if (hwResult >= 0 && hwDeviceRef != NULL) {
        codecContext->hw_device_ctx = av_buffer_ref(hwDeviceRef);
        fprintf(stderr, "vcam VIDEOTOOLBOX hw_device_ctx created\n");
        fflush(stderr);
    } else {
        char hwError[AV_ERROR_MAX_STRING_SIZE] = {0};
        av_strerror(hwResult, hwError, sizeof(hwError));
        fprintf(stderr, "vcam VIDEOTOOLBOX hw_device_ctx failed error=%d (%s)\n",
                hwResult, hwError);
        fflush(stderr);
    }
    if (avcodec_open2(codecContext, decoder, NULL) < 0) {
        fprintf(stderr, "vcam avcodec_open2 FAILED\n");
        fflush(stderr);
        goto cleanup;
    }
    fprintf(stderr, "vcam hwaccel=%s pix_fmt=%d sw_pix_fmt=%d\n",
            codecContext->hwaccel != NULL ? codecContext->hwaccel->name : "NONE",
            codecContext->pix_fmt, codecContext->sw_pix_fmt);
    fflush(stderr);

    packet = av_packet_alloc();
    frame = av_frame_alloc();
    if (packet == NULL || frame == NULL) goto cleanup;

    int dumpedPacketCount = 0;
    while (self.running && av_read_frame(formatContext, packet) >= 0) {
        if (packet->stream_index == videoStream) {
            if (dumpedPacketCount < 8) {
                dumpedPacketCount += 1;
                char nalList[96] = {0};
                int nalLen = 0;
                for (int i = 0; i + 3 < packet->size && nalLen < 88; i++) {
                    if (packet->data[i] == 0 && packet->data[i + 1] == 0 &&
                        (packet->data[i + 2] == 1 ||
                         (packet->data[i + 2] == 0 && packet->data[i + 3] == 1))) {
                        int sc = packet->data[i + 2] == 1 ? 3 : 4;
                        if (i + sc < packet->size) {
                            int t = packet->data[i + sc] & 0x1F;
                            nalLen += snprintf(nalList + nalLen, sizeof(nalList) - (size_t)nalLen, "%d,", t);
                        }
                    }
                }
                fprintf(stderr, "vcam packet#%d size=%d nals=[%s]\n",
                        dumpedPacketCount, packet->size, nalList);
                fflush(stderr);
            }
            videoPacketsWithoutFrame += 1;
            int sendResult = AVERROR(EAGAIN);
            BOOL restartSession = NO;
            while (self.running) {
                sendResult = avcodec_send_packet(codecContext, packet);
                if (sendResult != AVERROR(EAGAIN)) break;

                // EAGAIN means the decoder still owns output for an earlier
                // packet. Drain one frame, then retry this exact packet; never
                // unref/drop a compressed H.264 packet before it is accepted.
                int receiveResult = avcodec_receive_frame(codecContext, frame);
                if (receiveResult >= 0) {
                    if ([self consumeFFmpegFrame:frame
                             loggedSoftwareFrame:&loggedSoftwareFrame
                              loggedHardwareFrame:&loggedHardwareFrame
                             loggedCorruptFrame:&loggedCorruptFrame]) {
                        producedFrame = YES;
                        videoPacketsWithoutFrame = 0;
                    }
                    av_frame_unref(frame);
                    continue;
                }
                // Decoder made no progress retrying this packet — typically a
                // mid-GOP join before the first IDR (missing reference frame).
                // Do not tear the session down here: keep reading and let the
                // next IDR reset the decoder. The stall counter below handles
                // genuinely dead sessions.
                if (!loggedReceiveFailure) {
                    loggedReceiveFailure = YES;
                    [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
                        @"%@ decoder made no progress while retrying packet error=%@",
                        self.streamName, VCAMFFmpegErrorDescription(receiveResult)]];
                }
                break;
            }
            if (sendResult >= 0) {
                consecutiveSendFailures = 0;
                while (self.running) {
                    int receiveResult = avcodec_receive_frame(codecContext, frame);
                    if (receiveResult < 0) {
                        if (receiveResult != AVERROR(EAGAIN)) {
                            // A non-IDR frame without a reference (mid-GOP
                            // join) fails hardware decode with INVALIDDATA.
                            // Keep reading instead of reconnecting so the
                            // next IDR can reset the decoder.
                            if (!loggedReceiveFailure) {
                                loggedReceiveFailure = YES;
                                [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
                                    @"%@ receive_frame error=%@; continuing to next IDR",
                                    self.streamName,
                                    VCAMFFmpegErrorDescription(receiveResult)]];
                            }
                        }
                        break;
                    }
                    if ([self consumeFFmpegFrame:frame
                             loggedSoftwareFrame:&loggedSoftwareFrame
                              loggedHardwareFrame:&loggedHardwareFrame
                             loggedCorruptFrame:&loggedCorruptFrame]) {
                        producedFrame = YES;
                        videoPacketsWithoutFrame = 0;
                    }
                    av_frame_unref(frame);
                }
            } else if (sendResult != AVERROR(EAGAIN)) {
                if (!loggedSendFailure) {
                    loggedSendFailure = YES;
                    [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
                        @"%@ send_packet failed error=%@", self.streamName,
                        VCAMFFmpegErrorDescription(sendResult)]];
                }
                // A single bad packet (mid-GOP join, delayed RTP, transient
                // parameter mismatch) must not tear down a healthy session.
                // Skip it and keep reading; only reconnect after a long run
                // of failures that cannot self-heal.
                consecutiveSendFailures += 1;
                if (consecutiveSendFailures >= 200) {
                    restartSession = YES;
                }
            }
            // A publisher restart can leave either decoder consuming packets
            // without producing frames after this session previously worked.
            // Reconnect so FFmpeg rebuilds SDP/extradata and codec state.
            if (videoPacketsWithoutFrame >= 300) {
                [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
                    @"%@ decoder stalled packets=300; reconnecting",
                    self.streamName]];
                av_packet_unref(packet);
                break;
            }
            if (restartSession) {
                av_packet_unref(packet);
                break;
            }
        }
        av_packet_unref(packet);
    }
cleanup:
    av_dict_free(&options);
    av_packet_free(&packet);
    av_frame_free(&frame);
    avcodec_free_context(&codecContext);
    av_buffer_unref(&hwDeviceRef);
    avformat_close_input(&formatContext);
    return producedFrame;
}

- (CVPixelBufferRef)copyNativePixelBufferForSurface {
    CVPixelBufferRef pixelBuffer = NULL;
    @synchronized (self) {
        if (!self.running || _latestPixelBuffer == NULL ||
            CACurrentMediaTime() - _latestFrameHostTime >= 3.5) {
            return NULL;
        }
        OSType format = CVPixelBufferGetPixelFormatType(_latestPixelBuffer);
        if (format != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
            format != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange &&
            format != kCVPixelFormatType_32BGRA) return NULL;
        pixelBuffer = CVPixelBufferRetain(_latestPixelBuffer);
    }
    return pixelBuffer;
}

- (CMSampleBufferRef)copyDirectPreviewSample {
    CVPixelBufferRef pixelBuffer = NULL;
    uint64_t sequence = 0;
    @synchronized (self) {
        if (!self.running || _latestPixelBuffer == NULL ||
            CACurrentMediaTime() - _latestFrameHostTime >= 3.5 ||
            _latestFrameSequence == _lastDisplayFrameSequence) {
            return NULL;
        }
        pixelBuffer = CVPixelBufferRetain(_latestPixelBuffer);
        sequence = _latestFrameSequence;
        _lastDisplayFrameSequence = sequence;
    }

    CMVideoFormatDescriptionRef format = NULL;
    CMSampleBufferRef sample = NULL;
    CMSampleTimingInfo timing = {
        .duration = CMTimeMake(1, (int32_t)MAX(1, self.configuration.preferredFramesPerSecond)),
        .presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock()),
        .decodeTimeStamp = kCMTimeInvalid,
    };
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &format) == noErr) {
        CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, true, NULL, NULL,
                                           format, &timing, &sample);
    }
    if (sample != NULL) {
        CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, true);
        if (attachments != NULL && CFArrayGetCount(attachments) > 0) {
            CFMutableDictionaryRef attachment =
                (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
            CFDictionarySetValue(attachment, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
        }
    }
    if (format != NULL) CFRelease(format);
    CVPixelBufferRelease(pixelBuffer);
    return sample;
}

- (CMSampleBufferRef)copyVideoSampleForTemplate:(CMSampleBufferRef)templateBuffer {
    CVPixelBufferRef pixelBuffer = NULL;
    uint64_t sequence = 0;
    @synchronized (self) {
        if (self.running && _latestPixelBuffer != NULL &&
            CACurrentMediaTime() - _latestFrameHostTime < 3.5) {
            pixelBuffer = CVPixelBufferRetain(_latestPixelBuffer);
            sequence = _latestFrameSequence;
        }
    }
    if (pixelBuffer == NULL) return NULL;
    CVImageBufferRef templateImage = CMSampleBufferGetImageBuffer(templateBuffer);
    size_t width = templateImage == NULL ? 0 : CVPixelBufferGetWidth(templateImage);
    size_t height = templateImage == NULL ? 0 : CVPixelBufferGetHeight(templateImage);
    OSType pixelFormat = templateImage == NULL ? 0 : CVPixelBufferGetPixelFormatType(templateImage);
    @synchronized (self) {
        if (_lastRenderedSample != NULL && sequence == _lastRenderedFrameSequence &&
            width == _lastRenderedWidth && height == _lastRenderedHeight &&
            pixelFormat == _lastRenderedPixelFormat) {
            CMSampleTimingInfo timing = {
                .duration = CMSampleBufferGetDuration(templateBuffer),
                .presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(templateBuffer),
                .decodeTimeStamp = CMSampleBufferGetDecodeTimeStamp(templateBuffer),
            };
            CMSampleBufferRef retimed = NULL;
            CMSampleBufferCreateCopyWithNewTiming(kCFAllocatorDefault, _lastRenderedSample,
                                                   1, &timing, &retimed);
            CVPixelBufferRelease(pixelBuffer);
            return retimed;
        }
    }
    CMSampleBufferRef sample = [self.renderer copySampleFromPixelBuffer:pixelBuffer
                                                               template:templateBuffer
                                                          configuration:self.configuration];
    if (sample != NULL) {
        @synchronized (self) {
            if (_lastRenderedSample != NULL) CFRelease(_lastRenderedSample);
            _lastRenderedSample = NULL;
            CMSampleBufferCreateCopy(kCFAllocatorDefault, sample, &_lastRenderedSample);
            _lastRenderedFrameSequence = sequence;
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

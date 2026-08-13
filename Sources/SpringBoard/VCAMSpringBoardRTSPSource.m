#import "VCAMSpringBoardRTSPSource.h"
#import "../Core/VCAMConfiguration.h"
#import "../Daemon/VCAMHardwareVideoDecoder.h"

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/dict.h>
#include <libavutil/time.h>

/// FFmpeg is a C library; network errors are expected during reconnects and
/// must never abort the SpringBoard process.
void VCAMSpringBoardRTSPIgnoreLog(void *context, int level, const char *format,
                                  va_list arguments) {
    (void)context;
    (void)level;
    (void)format;
    (void)arguments;
}

__attribute__((unused))
static CMTime VCAMRTSPSourcePacketTime(AVPacket *packet, AVStream *stream) {
    if (packet == NULL || stream == NULL) return kCMTimeInvalid;
    if (packet->pts == AV_NOPTS_VALUE) return kCMTimeInvalid;
    AVRational timeBase = stream->time_base;
    if (timeBase.num <= 0 || timeBase.den <= 0) return kCMTimeInvalid;
    double seconds = (double)packet->pts * (double)timeBase.num /
                     (double)timeBase.den;
    if (!isfinite(seconds) || seconds < 0) return kCMTimeInvalid;
    return CMTimeMakeWithSeconds(seconds, 600);
}

@interface VCAMSpringBoardRTSPSource ()
@property(nonatomic) BOOL running;
@property(nonatomic) NSUInteger decodedFrames;
@property(nonatomic) NSUInteger transportFailures;
@property(nonatomic, copy, nullable) NSString *lastError;
@end

@implementation VCAMSpringBoardRTSPSource {
    NSURL *_url;
    dispatch_queue_t _queue;
    VCAMSpringBoardRTSPFrameHandler _frameHandler;
    NSUInteger _reconnectAttempt;
}

- (instancetype)initWithURL:(NSURL *)url {
    self = [super init];
    if (self) {
        _url = [url copy];
        _queue = dispatch_queue_create("com.codex.vcam.springboard.rtsp",
                                       DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)startWithFrameHandler:(VCAMSpringBoardRTSPFrameHandler)handler {
    if (self.running) return;
    self.running = YES;
    self.lastError = nil;
    _frameHandler = [handler copy];
    _reconnectAttempt = 0;
    __weak typeof(self) weakSelf = self;
    dispatch_async(_queue, ^{
        [weakSelf runReaderLoop];
    });
}

- (void)stop {
    self.running = NO;
}

- (void)runReaderLoop {
    av_log_set_callback(VCAMSpringBoardRTSPIgnoreLog);
    while (self.running) {
        if (![self readOnce]) {
            self.transportFailures += 1;
            NSUInteger delay = MIN((NSUInteger)15, (NSUInteger)1 << MIN(_reconnectAttempt, (NSUInteger)4));
            _reconnectAttempt += 1;
            [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
                @"springboard RTSP reconnect attempt=%lu delay=%lus error=%@",
                (unsigned long)_reconnectAttempt, (unsigned long)delay,
                self.lastError ?: @"(none)"]];
            for (NSUInteger i = 0; i < delay && self.running; i++) {
                [NSThread sleepForTimeInterval:1.0];
            }
        } else {
            _reconnectAttempt = 0;
        }
    }
    [VCAMConfiguration appendProcessLog:@"springboard RTSP source stopped"];
}

/// One open/decode/publish cycle. Returns NO when the stream could not be
/// opened (retryable) — the loop above backs off and reconnects.
- (BOOL)readOnce {
    AVFormatContext *format = NULL;
    AVDictionary *options = NULL;
    av_dict_set(&options, "rtsp_transport", "tcp", 0);
    av_dict_set(&options, "stimeout", "5000000", 0);
    int openStatus = avformat_open_input(&format, _url.absoluteString.UTF8String,
                                         NULL, &options);
    av_dict_free(&options);
    if (openStatus < 0) {
        self.lastError = [NSString stringWithFormat:@"open failed status=%d", openStatus];
        [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
            @"springboard RTSP open failed status=%d url=%@", openStatus, _url]];
        return NO;
    }
    if (avformat_find_stream_info(format, NULL) < 0) {
        self.lastError = @"stream info failed";
        avformat_close_input(&format);
        return NO;
    }
    int videoStream = av_find_best_stream(format, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (videoStream < 0) {
        self.lastError = @"no video stream";
        avformat_close_input(&format);
        return NO;
    }
    AVStream *stream = format->streams[videoStream];
    AVCodecParameters *codecParameters = stream->codecpar;
    if (codecParameters == NULL ||
        (codecParameters->codec_id != AV_CODEC_ID_H264 &&
         codecParameters->codec_id != AV_CODEC_ID_HEVC)) {
        self.lastError = [NSString stringWithFormat:@"unsupported codec id=%d",
                          codecParameters ? codecParameters->codec_id : -1];
        avformat_close_input(&format);
        return NO;
    }
    [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
        @"springboard RTSP session codec=%s size=%dx%d",
        avcodec_get_name(codecParameters->codec_id),
        codecParameters->width, codecParameters->height]];

    AVPacket *packet = av_packet_alloc();
    if (packet == NULL) {
        avformat_close_input(&format);
        return NO;
    }
    // The VideoToolbox session, all decodePacket calls, the output drain and
    // the frame handler run exclusively on the main queue. The demux thread
    // only reads packets and hands clones to the main queue, so no
    // CVPixelBuffer ever crosses a thread boundary.
    __block VCAMHardwareVideoDecoder *decoder = nil;
    __block BOOL decoderStarted = NO;
    __block BOOL decodedAny = NO;
    __block int64_t sessionStart = av_gettime_relative();
    __weak typeof(self) weakSelf = self;
    VCAMSpringBoardRTSPFrameHandler handler = _frameHandler;
    dispatch_semaphore_t drainGate = dispatch_semaphore_create(4);
    while (self.running && av_read_frame(format, packet) >= 0) {
        if (packet->stream_index != videoStream) {
            av_packet_unref(packet);
            continue;
        }
        BOOL isKeyFrame = (packet->flags & AV_PKT_FLAG_KEY) != 0;
        if (!decoderStarted && !isKeyFrame) {
            if (av_gettime_relative() - sessionStart > 10000000LL) {
                self.lastError = @"key frame timeout";
                [VCAMConfiguration appendProcessLog:
                    @"springboard RTSP key frame timeout; reconnecting"];
                av_packet_unref(packet);
                break;
            }
            av_packet_unref(packet);
            continue;
        }
        AVPacket *clone = av_packet_clone(packet);
        av_packet_unref(packet);
        if (clone == NULL) continue;
        dispatch_semaphore_wait(drainGate, DISPATCH_TIME_FOREVER);
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            AVPacket *packetClone = clone;
            if (strongSelf == nil || !strongSelf.running) {
                av_packet_free(&packetClone);
                dispatch_semaphore_signal(drainGate);
                return;
            }
            if (!decoderStarted) {
                decoder = [[VCAMHardwareVideoDecoder alloc]
                    initWithCodecParameters:codecParameters];
                NSError *decoderError = nil;
                if (decoder == nil || ![decoder start:&decoderError]) {
                    strongSelf.lastError =
                        decoderError.localizedDescription ?: @"decoder init failed";
                    [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
                        @"springboard RTSP decoder start failed error=%@",
                        strongSelf.lastError]];
                    av_packet_free(&packetClone);
                    dispatch_semaphore_signal(drainGate);
                    return;
                }
                decoderStarted = YES;
                [VCAMConfiguration appendProcessLog:
                    @"springboard RTSP decoder started (direct VideoToolbox)"];
            }
            CMTime pts = VCAMRTSPSourcePacketTime(packetClone, stream);
            [decoder decodePacket:packetClone->data
                           length:(size_t)packetClone->size
                 presentationTime:pts
                       decodeTime:kCMTimeInvalid
                         duration:kCMTimeInvalid
                       isKeyFrame:(packetClone->flags & AV_PKT_FLAG_KEY) != 0];
            av_packet_free(&packetClone);
            // Drain decoded frames and deliver synchronously on the main
            // queue, so the buffer lives and dies on one thread.
            CVPixelBufferRef frame = NULL;
            CMTime framePts = kCMTimeInvalid;
            while ((frame = [decoder copyNextOutputFrame:&framePts]) != NULL) {
                decodedAny = YES;
                strongSelf.decodedFrames += 1;
                if (handler != nil) {
                    uint32_t width = (uint32_t)CVPixelBufferGetWidth(frame);
                    uint32_t height = (uint32_t)CVPixelBufferGetHeight(frame);
                    handler(frame, framePts, width, height);
                }
                CVPixelBufferRelease(frame);
            }
            dispatch_semaphore_signal(drainGate);
        });
    }
    dispatch_semaphore_wait(drainGate, DISPATCH_TIME_FOREVER);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (decoder != nil) [decoder stop];
        decoder = nil;
        decoderStarted = NO;
    });
    av_packet_free(&packet);
    avformat_close_input(&format);
    if (!decodedAny && self.lastError == nil) self.lastError = @"stream ended";
    return decodedAny;
}

@end

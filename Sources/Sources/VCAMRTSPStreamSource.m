#import "VCAMRTSPStreamSource.h"
#import <QuartzCore/QuartzCore.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/error.h>
#include <libavutil/hwcontext.h>

static enum AVPixelFormat VCAMSelectHardwarePixelFormat(AVCodecContext *context,
                                                         const enum AVPixelFormat *formats) {
    (void)context;
    for (const enum AVPixelFormat *format = formats; *format != AV_PIX_FMT_NONE; format++) {
        if (*format == AV_PIX_FMT_VIDEOTOOLBOX) return *format;
    }
    return AV_PIX_FMT_NONE;
}

@interface VCAMRTSPStreamSource () {
    CVPixelBufferRef _latestPixelBuffer;
    CFTimeInterval _latestFrameHostTime;
}
@property(nonatomic, strong) VCAMConfiguration *configuration;
@property(nonatomic, strong) VCAMFrameRenderer *renderer;
@property(nonatomic, strong) dispatch_queue_t decodeQueue;
@property(nonatomic) BOOL running;
@end

@implementation VCAMRTSPStreamSource

- (instancetype)initWithConfiguration:(VCAMConfiguration *)configuration
                              renderer:(VCAMFrameRenderer *)renderer {
    self = [super init];
    if (self) {
        _configuration = configuration;
        _renderer = renderer;
        _decodeQueue = dispatch_queue_create("com.codex.vcam.rtsp.decode", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (BOOL)start:(NSError **)error {
    NSURL *url = self.configuration.rtspURL;
    if (url == nil || ![url.scheme.lowercaseString isEqualToString:@"rtsp"]) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"VCAMRTSPStreamSource" code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"RTSP URL is missing or invalid"}];
        }
        return NO;
    }
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ avformat_network_init(); });
    self.running = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.decodeQueue, ^{ [weakSelf decodeReconnectLoop]; });
    return YES;
}

- (void)stop {
    self.running = NO;
    @synchronized (self) {
        if (_latestPixelBuffer != NULL) CVPixelBufferRelease(_latestPixelBuffer);
        _latestPixelBuffer = NULL;
        _latestFrameHostTime = 0;
    }
}

- (void)dealloc {
    [self stop];
}

- (void)decodeReconnectLoop {
    while (self.running) {
        @autoreleasepool {
            [self decodeOneSession];
        }
        if (!self.running) break;
        [NSThread sleepForTimeInterval:0.5];
    }
}

- (void)decodeOneSession {
    AVFormatContext *formatContext = NULL;
    AVCodecContext *codecContext = NULL;
    AVBufferRef *hardwareDevice = NULL;
    AVPacket *packet = NULL;
    AVFrame *frame = NULL;
    AVDictionary *options = NULL;
    int videoStream = -1;
    AVStream *stream = NULL;
    const AVCodec *decoder = NULL;
    NSString *urlString = self.configuration.rtspURL.absoluteString;
    const char *url = urlString.UTF8String;

    av_dict_set(&options, "rtsp_transport", "tcp", 0);
    av_dict_set(&options, "rtsp_flags", "prefer_tcp", 0);
    av_dict_set(&options, "fflags", "nobuffer", 0);
    av_dict_set(&options, "flags", "low_delay", 0);
    av_dict_set(&options, "reorder_queue_size", "0", 0);
    av_dict_set(&options, "timeout", "3000000", 0);

    if (avformat_open_input(&formatContext, url, NULL, &options) < 0) goto cleanup;
    if (avformat_find_stream_info(formatContext, NULL) < 0) goto cleanup;

    videoStream = av_find_best_stream(formatContext, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (videoStream < 0) goto cleanup;
    stream = formatContext->streams[videoStream];
    decoder = avcodec_find_decoder(stream->codecpar->codec_id);
    if (decoder == NULL) goto cleanup;
    codecContext = avcodec_alloc_context3(decoder);
    if (codecContext == NULL || avcodec_parameters_to_context(codecContext, stream->codecpar) < 0) goto cleanup;

    codecContext->get_format = VCAMSelectHardwarePixelFormat;
    codecContext->flags |= AV_CODEC_FLAG_LOW_DELAY;
    codecContext->thread_count = 1;
    if (av_hwdevice_ctx_create(&hardwareDevice, AV_HWDEVICE_TYPE_VIDEOTOOLBOX,
                               NULL, NULL, 0) < 0) {
        goto cleanup;
    }
    codecContext->hw_device_ctx = av_buffer_ref(hardwareDevice);
    if (codecContext->hw_device_ctx == NULL || avcodec_open2(codecContext, decoder, NULL) < 0) goto cleanup;

    packet = av_packet_alloc();
    frame = av_frame_alloc();
    if (packet == NULL || frame == NULL) goto cleanup;

    while (self.running && av_read_frame(formatContext, packet) >= 0) {
        if (packet->stream_index == videoStream && avcodec_send_packet(codecContext, packet) >= 0) {
            while (self.running && avcodec_receive_frame(codecContext, frame) >= 0) {
                if (frame->format == AV_PIX_FMT_VIDEOTOOLBOX && frame->data[3] != NULL) {
                    CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)frame->data[3];
                    CVPixelBufferRetain(pixelBuffer);
                    @synchronized (self) {
                        if (_latestPixelBuffer != NULL) CVPixelBufferRelease(_latestPixelBuffer);
                        _latestPixelBuffer = pixelBuffer;
                        _latestFrameHostTime = CACurrentMediaTime();
                    }
                }
                av_frame_unref(frame);
            }
        }
        av_packet_unref(packet);
    }

cleanup:
    av_dict_free(&options);
    av_packet_free(&packet);
    av_frame_free(&frame);
    av_buffer_unref(&hardwareDevice);
    avcodec_free_context(&codecContext);
    avformat_close_input(&formatContext);
}

- (CMSampleBufferRef)copyVideoSampleForTemplate:(CMSampleBufferRef)templateBuffer {
    CVPixelBufferRef pixelBuffer = NULL;
    @synchronized (self) {
        if (self.running && _latestPixelBuffer != NULL &&
            CACurrentMediaTime() - _latestFrameHostTime < 3.5) {
            pixelBuffer = CVPixelBufferRetain(_latestPixelBuffer);
        }
    }
    if (pixelBuffer == NULL) return NULL;
    CIImage *image = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    CMSampleBufferRef sample = [self.renderer copySampleFromImage:image
                                                         template:templateBuffer
                                                    configuration:self.configuration];
    CVPixelBufferRelease(pixelBuffer);
    return sample;
}

- (CMSampleBufferRef)copyAudioSampleForTemplate:(CMSampleBufferRef)templateBuffer {
    (void)templateBuffer;
    return NULL;
}

@end

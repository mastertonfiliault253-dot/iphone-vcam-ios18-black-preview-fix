#import "VCAMRTSPStreamSource.h"
#import "../Daemon/VCAMHardwareVideoDecoder.h"
#import "../Daemon/VCAMPixelConverter.h"
#import "../Shared/VCAMSharedFrame.h"
#import "../Shared/VCAMSurfaceBroker.h"
#import <QuartzCore/QuartzCore.h>
#import <errno.h>
#import <math.h>
#import <stdarg.h>
#import <stdio.h>
#import <stdlib.h>

#include <dispatch/dispatch.h>
#include <stdatomic.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/error.h>

static NSDictionary<NSString *, id> *VCAMRTSPPerformance;
static volatile int gFFmpegDiagnosticCount = 0;
static char gFFmpegLastMessage[1024] = {0};
static int gFFmpegLastMessageCount = 0;
// RTSP prefers remote hardware decode: vcamd demuxes and pushes compressed
// access units to the SpringBoard service (the E9 case shows the daemon
// context cannot run VideoToolbox itself). When no peer is available, the
// in-daemon direct-VT decoder is the second choice; sessions that start a
// VT session but never yield a decoded frame (the historical -12780
// device-level failure mode) set this flag so later reconnects go straight
// to software instead of retrying hardware in a loop within this process.
static volatile int gVCAMRTSPHardwareSessionsDisabled = 0;
// Set after a remote hardware session fails (unreachable, rejected or
// zero-frame) so reconnects stop paying the remote retry cost in-process.
static volatile int gVCAMRTSPRemoteHardwareDisabled = 0;
// Mirrors the broker's remote-decoder peer registration events.
static _Atomic(int) gVCAMRTSPRemotePeerAvailable = 0;

// Beyond this age the last decoded frame counts as lost and the source
// reports no video. Same window as VCAMOBSStreamSource.
static const CFTimeInterval VCAMStaleFrameSeconds = 3.5;

static void VCAMFFmpegDiagnosticLog(void *context, int level,
                                    const char *format, va_list arguments) {
    BOOL decoderClass = NO;
    if (context != NULL) {
        AVClass *cls = *(AVClass **)context;
        if (cls != NULL && cls->class_name != NULL) {
            const char *name = cls->class_name;
            if (strstr(name, "h264") != NULL || strstr(name, "hevc") != NULL) {
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
                fprintf(stderr, "[ffmpeg] (further identical messages suppressed)\n");
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
            @"[ffmpeg] level=%d %@", level,
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

static CMTime VCAMRTSPPacketTime(AVPacket *packet, AVStream *stream) {
    if (packet == NULL) return kCMTimeInvalid;
    int64_t pts = packet->pts != AV_NOPTS_VALUE ? packet->pts : packet->dts;
    if (pts == AV_NOPTS_VALUE) return kCMTimeZero;
    AVRational timeBase = stream != NULL ? stream->time_base : (AVRational){1, 600};
    double seconds = (double)pts * av_q2d(timeBase);
    if (!isfinite(seconds) || seconds < 0) seconds = 0;
    return CMTimeMakeWithSeconds(seconds, 600);
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
    BOOL _loggedFirstDecodedFrame;
    double _diagnosticFrameIntervals[256];
    NSUInteger _diagnosticFrameIntervalCount;
    AVFrame *_pendingSoftwareFrame;
    BOOL _softwareConversionScheduled;
    // Remote hardware decode state. SpringBoard resizes and publishes each
    // decoded frame into the shared-frame ring buffer itself (the device
    // rejects IOSurfaceCreate for non-GUI processes, docs E9/E10, and the
    // ring buffer file is writable by both sides), so no frame buffers and
    // no pixel payloads live here anymore: the daemon only counts
    // completion events for flow control and diagnostics.
    // All fields are guarded by @synchronized(self).
    int remoteWidth;
    int remoteHeight;
    dispatch_semaphore_t remoteAckSemaphore;
    dispatch_semaphore_t remoteWindowSemaphore;
    BOOL remoteAckArrived;
    BOOL remoteAckAccepted;
    uint64_t remoteActiveEpoch;
    NSUInteger remoteAUsSent;
    NSUInteger remoteFramesReceived;
    // AU credit reclaimed on decode/transport failures: an access unit that
    // never yields a frame (e.g. the server cannot import its IOSurface)
    // must still release its flow-control slot or the window gate deadlocks
    // at VCAMRTSPRemoteMaxOutstanding and the session never reaches the
    // zero-frame fallback.
    NSUInteger remoteFailures;
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

static int VCAMRTSPInterruptWhenStopped(void *opaque) {
    VCAMRTSPStreamSource *source =
        (__bridge VCAMRTSPStreamSource *)opaque;
    return source == nil || !source.running;
}

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
        remoteAckSemaphore = dispatch_semaphore_create(0);
        remoteWindowSemaphore = dispatch_semaphore_create(0);
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
    // Route remote-decoder protocol events into this instance (daemon-only
    // broker role). The handler runs on the broker's serial queue.
    __weak typeof(self) weakEventSelf = self;
    VCAMSurfaceBrokerSetRemoteDecoderEventHandler(
        ^(VCAMRemoteDecoderEvent event, uint64_t epoch,
          const VCAMRemoteDecoderFramePayload *payload) {
            VCAMRTSPStreamSource *target = weakEventSelf;
            if (target == nil) return;
            [target handleRemoteDecoderEvent:event epoch:epoch
                                     payload:payload];
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
        remoteActiveEpoch = 0;
        remoteAUsSent = 0;
        remoteFramesReceived = 0;
        remoteFailures = 0;
        remoteWidth = 0;
        remoteHeight = 0;
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
            producedFrame = [self decodeOneFFmpegSession];
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

- (void)acceptDecodedPixelBuffer:(CVPixelBufferRef)pixelBuffer
                        hardware:(BOOL)hardware {
    CVPixelBufferRetain(pixelBuffer);
    // Tag the decoded frame with its real decode path so the panel reports
    // the truth for both the direct-VT and FFmpeg software pipelines.
    CVBufferSetAttachment(pixelBuffer, CFSTR("com.codex.vcam.decodeHardware"),
                          hardware ? kCFBooleanTrue : kCFBooleanFalse,
                          kCVAttachmentMode_ShouldPropagate);
    CFTimeInterval now = CACurrentMediaTime();
    NSDictionary<NSString *, id> *snapshot = nil;
    BOOL logFirstDecodedFrame = NO;
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
        if (!_loggedFirstDecodedFrame) {
            _loggedFirstDecodedFrame = YES;
            logFirstDecodedFrame = YES;
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
                @"frameSequence": @(_latestFrameSequence),
            };
            _diagnosticWindowStart = now;
            _diagnosticFrames = 0;
            _diagnosticFrameIntervalCount = 0;
        }
    }
    if (logFirstDecodedFrame) {
        [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
            @"%@ first %@ pixel buffer format=%08x size=%zux%zu",
            self.streamName, hardware ? @"hardware" : @"software",
            (unsigned int)CVPixelBufferGetPixelFormatType(pixelBuffer),
            CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer)]];
    }
    if (snapshot != nil) {
        VCAMPublishRTSPPerformance(snapshot);
        // The snapshot only feeds the panel; mirror a one-line per-second
        // summary to the process log so source throughput on real hardware
        // can be compared across decode paths without opening the UI
        // (same shape as the local-media perf line).
        [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
            @"[DEBUG-vcamdiag] rtsp perf hardware=%d fps=%.2f p95Ms=%.3f size=%llu,%llu frameSequence=%llu",
            (int)hardware,
            [snapshot[@"sourceFPS"] doubleValue],
            [snapshot[@"sourceFrameP95Ms"] doubleValue],
            [snapshot[@"sourceWidth"] unsignedLongLongValue],
            [snapshot[@"sourceHeight"] unsignedLongLongValue],
            [snapshot[@"frameSequence"] unsignedLongLongValue]]];
    }
}

- (CVPixelBufferRef)copyBGRAFromSoftwareFrame:(AVFrame *)frame {
    return VCAMCopyBGRAFromAVFrame(frame);
}

- (BOOL)consumeFFmpegFrame:(AVFrame *)decodedFrame
        loggedSoftwareFrame:(BOOL *)loggedSoftwareFrame
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

// Remote hardware decode: demux stays here, VideoToolbox runs in the
// injected SpringBoard process (docs VIDEOTOOLBOX case E9). Broker events
// arrive on the broker's serial queue; the session loop below is the only
// consumer of the wrapped frames.
enum {
    VCAMRTSPRemoteMaxOutstanding = 4,
};

- (void)handleRemoteDecoderEvent:(VCAMRemoteDecoderEvent)event
                           epoch:(uint64_t)epoch
                          payload:(const VCAMRemoteDecoderFramePayload * _Nullable)
                              payload {
    switch (event) {
        case VCAMRemoteDecoderEventPeerAvailable:
            atomic_store_explicit(&gVCAMRTSPRemotePeerAvailable, 1,
                                  memory_order_release);
            return;
        case VCAMRemoteDecoderEventPeerLost:
            atomic_store_explicit(&gVCAMRTSPRemotePeerAvailable, 0,
                                  memory_order_release);
            break;
        case VCAMRemoteDecoderEventOpenAccepted:
        case VCAMRemoteDecoderEventOpenRejected: {
            @synchronized (self) {
                if (epoch == remoteActiveEpoch && !remoteAckArrived) {
                    remoteAckArrived = YES;
                    remoteAckAccepted =
                        event == VCAMRemoteDecoderEventOpenAccepted;
                }
            }
            dispatch_semaphore_signal(remoteAckSemaphore);
            return;
        }
        case VCAMRemoteDecoderEventFailure:
            break;
        case VCAMRemoteDecoderEventFrame: {
            if (payload == NULL) return;
            int width = 0, height = 0;
            @synchronized (self) {
                if (epoch == remoteActiveEpoch) {
                    width = remoteWidth;
                    height = remoteHeight;
                }
            }
            if (width <= 0 || height <= 0 ||
                (int)payload->width != width ||
                (int)payload->height != height) {
                // An unreadable completion proves no published frame for the
                // AU that owes this event, and the field comment above is
                // explicit: AUs that never yield a frame must still reclaim
                // their flow-control credit, or the window gate deadlocks at
                // VCAMRTSPRemoteMaxOutstanding and the session never reaches
                // the zero-frame fallback.
                @synchronized (self) {
                    if (epoch == remoteActiveEpoch) remoteFailures += 1;
                }
                dispatch_semaphore_signal(remoteWindowSemaphore);
                return;
            }
            // SpringBoard has already resized the frame into the fixed
            // shared-frame canvas and written it into the mmap ring buffer
            // in its own process, so the completion event only releases one
            // flow-control credit and drives the first/perf diagnostics.
            @synchronized (self) {
                if (epoch != remoteActiveEpoch || !self.running) return;
                remoteFramesReceived += 1;
            }
            [self noteRemoteHardwareFrameCompletionWidth:width height:height];
            dispatch_semaphore_signal(remoteWindowSemaphore);
            return;
        }
    }
    // PeerLost/Failure for the active session: unblock both waits so the
    // session loop can fall back immediately instead of timing out. Count
    // the failed access unit against its flow-control credit too, otherwise
    // a stream that fails every import (surface import errors) would keep
    // the window gate permanently full.
    @synchronized (self) {
        if (epoch == remoteActiveEpoch || event == VCAMRemoteDecoderEventPeerLost) {
            remoteFailures += 1;
            if (!remoteAckArrived) {
                remoteAckArrived = YES;
                remoteAckAccepted = NO;
            }
        }
    }
    dispatch_semaphore_signal(remoteAckSemaphore);
    dispatch_semaphore_signal(remoteWindowSemaphore);
}

// Diagnostics for the direct-publish remote path: the pixels were written
// into the shared ring buffer by SpringBoard itself, so the first-frame and
// analyzer-facing perf lines are emitted from the completion event. The
// session dimensions stand in for the decoded pixel buffer and the stored
// canvas format (video-range NV12) for the buffer's pixel format; the line
// shapes stay identical to acceptDecodedPixelBuffer's.
- (void)noteRemoteHardwareFrameCompletionWidth:(int)width height:(int)height {
    CFAbsoluteTime now = CACurrentMediaTime();
    BOOL logFirstDecodedFrame = NO;
    NSDictionary *snapshot = nil;
    @synchronized (self) {
        _latestFrameHostTime = now;
        _latestFrameSequence += 1;
        _diagnosticFrames += 1;
        if (!_loggedFirstDecodedFrame) {
            _loggedFirstDecodedFrame = YES;
            logFirstDecodedFrame = YES;
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
                @"sourceWidth": @(width),
                @"sourceHeight": @(height),
                @"sourcePixelFormat": @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                @"frameSequence": @(_latestFrameSequence),
            };
            _diagnosticWindowStart = now;
            _diagnosticFrames = 0;
            _diagnosticFrameIntervalCount = 0;
        }
    }
    if (logFirstDecodedFrame) {
        [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
            @"%@ first %@ pixel buffer format=%08x size=%zux%zu",
            self.streamName, @"hardware",
            (unsigned int)kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            (size_t)width, (size_t)height]];
    }
    if (snapshot != nil) {
        VCAMPublishRTSPPerformance(snapshot);
        // The snapshot only feeds the panel; mirror a one-line per-second
        // summary to the process log so source throughput on real hardware
        // can be compared across decode paths without opening the UI
        // (same shape as the local-media perf line).
        [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
            @"[DEBUG-vcamdiag] rtsp perf hardware=%d fps=%.2f p95Ms=%.3f size=%llu,%llu frameSequence=%llu",
            1,
            [snapshot[@"sourceFPS"] doubleValue],
            [snapshot[@"sourceFrameP95Ms"] doubleValue],
            [snapshot[@"sourceWidth"] unsignedLongLongValue],
            [snapshot[@"sourceHeight"] unsignedLongLongValue],
            [snapshot[@"frameSequence"] unsignedLongLongValue]]];
    }
}

// Drains one RTSP session through the SpringBoard-hosted hardware decoder.
// Returns YES when at least one frame was published. Any failure (no peer,
// rejected/late open-ack, transport loss, zero-frame stall) returns NO so
// the caller falls back to the in-daemon paths.
- (BOOL)decodePacketsWithRemoteDecode:(AVPacket *)packet
                       formatContext:(AVFormatContext *)formatContext
                         videoStream:(int)videoStreamIndex
                              stream:(AVStream *)stream
                               codec:(const char *)codecName
                        parameterData:(const uint8_t *)parameterData
                            extraSize:(int)extraSize
                                width:(int)width
                               height:(int)height {
    uint64_t epoch = 0;
    do {
        arc4random_buf(&epoch, sizeof(epoch));
    } while (epoch == 0);
    @synchronized (self) {
        remoteAckArrived = NO;
        remoteAckAccepted = NO;
        remoteActiveEpoch = epoch;
        remoteAUsSent = 0;
        remoteFramesReceived = 0;
        remoteFailures = 0;
        remoteWidth = width;
        remoteHeight = height;
    }
    if (!VCAMSurfaceBrokerPushRemoteDecoderOpen(
            epoch, codecName, width, height, parameterData,
            (size_t)extraSize)) {
        @synchronized (self) { remoteActiveEpoch = 0; }
        return NO;
    }
    // The ack semaphore is instance-persistent and a mach event from the
    // previous session (a late open-ack or a PeerLost tail signal) can leave
    // it signalled with no ack ever arriving for this epoch. Treat only
    // remoteAckArrived as evidence and consume residual signals by looping:
    // a bare semaphore hit let a stale count read as "rejected", which fell
    // to the software decoder and permanently disabled remote decode for the
    // process (self-cpu ~97%).
    BOOL ackArrived = NO;
    @synchronized (self) { ackArrived = remoteAckArrived; }
    CFAbsoluteTime ackDeadline = CACurrentMediaTime() + 3.0;
    while (!ackArrived) {
        CFAbsoluteTime remaining = ackDeadline - CACurrentMediaTime();
        if (remaining <= 0) break;
        if (dispatch_semaphore_wait(remoteAckSemaphore,
                dispatch_time(DISPATCH_TIME_NOW,
                              (int64_t)(remaining * NSEC_PER_SEC))) != 0) {
            break;
        }
        @synchronized (self) { ackArrived = remoteAckArrived; }
    }
    if (!ackArrived) {
        [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
            @"%@ remote hardware decode open timed out", self.streamName]];
        VCAMSurfaceBrokerEndRemoteDecoderSession(epoch);
        @synchronized (self) { remoteActiveEpoch = 0; }
        return NO;
    }
    @synchronized (self) {
        if (!remoteAckAccepted) {
            [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
                @"%@ remote hardware decode rejected", self.streamName]];
            remoteActiveEpoch = 0;
        }
    }
    @synchronized (self) {
        if (remoteActiveEpoch != epoch) {
            VCAMSurfaceBrokerEndRemoteDecoderSession(epoch);
            return NO;
        }
    }

    BOOL producedFrame = NO;
    BOOL waitingForKeyFrame = YES;
    NSUInteger remotePacketsWithoutFrame = 0;
    NSUInteger lastFramesReceived = 0;
    while (self.running && av_read_frame(formatContext, packet) >= 0) {
        if (packet->stream_index == videoStreamIndex) {
            BOOL isKeyFrame = (packet->flags & AV_PKT_FLAG_KEY) != 0;
            if (waitingForKeyFrame && !isKeyFrame) {
                av_packet_unref(packet);
                continue;
            }
            waitingForKeyFrame = NO;
            // Flow control: keep at most VCAMRTSPRemoteMaxOutstanding
            // access units unclaimed by the SpringBoard decoder so a slow
            // decoder backpressures the RTSP socket instead of the queue.
            while (self.running) {
                NSUInteger outstanding = 0;
                @synchronized (self) {
                    if (remoteActiveEpoch != epoch) outstanding = 0;
                    else {
                        NSUInteger claimed = remoteFramesReceived + remoteFailures;
                        outstanding = remoteAUsSent > claimed
                            ? remoteAUsSent - claimed : 0;
                    }
                }
                if (outstanding < VCAMRTSPRemoteMaxOutstanding) break;
                if (dispatch_semaphore_wait(remoteWindowSemaphore,
                        dispatch_time(DISPATCH_TIME_NOW,
                                      (int64_t)(500 * NSEC_PER_MSEC))) != 0) {
                    @synchronized (self) {
                        if (remoteActiveEpoch != epoch) {
                            av_packet_unref(packet);
                            goto remoteLoopEnd;
                        }
                    }
                }
            }
            CMTime presentationTime = VCAMRTSPPacketTime(packet, stream);
            if (!VCAMSurfaceBrokerPushRemoteDecoderAU(
                    epoch, packet->data, (size_t)packet->size,
                    CMTimeGetSeconds(presentationTime), isKeyFrame)) {
                [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
                    @"%@ remote hardware decode transport lost",
                    self.streamName]];
                av_packet_unref(packet);
                break;
            }
            remotePacketsWithoutFrame += 1;
            @synchronized (self) { remoteAUsSent += 1; }
            // Completions land on the broker queue; any growth of the
            // completion counter since the previous packet proves the
            // decoder is producing published frames.
            NSUInteger received = 0;
            @synchronized (self) { received = remoteFramesReceived; }
            if (received != lastFramesReceived) {
                producedFrame = YES;
                remotePacketsWithoutFrame = 0;
                lastFramesReceived = received;
            }
            if (remotePacketsWithoutFrame >= 300) {
                [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
                    @"%@ remote hardware decoder produced no frames packets=300; ending session",
                    self.streamName]];
                break;
            }
        }
        av_packet_unref(packet);
    }
remoteLoopEnd:
    @synchronized (self) {
        if (remoteFramesReceived != lastFramesReceived) producedFrame = YES;
    }
    VCAMSurfaceBrokerEndRemoteDecoderSession(epoch);
    @synchronized (self) {
        if (remoteActiveEpoch == epoch) remoteActiveEpoch = 0;
    }
    return producedFrame;
}

// Drains one RTSP session through a direct VTDecompressionSession. Returns
// YES when at least one frame was published. A session that never produces
// a frame (the historical -12780 device-level failure mode) returns NO so
// the caller can fall back to the FFmpeg software decoder.
- (BOOL)decodePacketsWithHardwareSession:(VCAMHardwareVideoDecoder *)hardwareDecoder
                                 packet:(AVPacket *)packet
                        formatContext:(AVFormatContext *)formatContext
                          videoStream:(int)videoStreamIndex
                               stream:(AVStream *)stream {
    BOOL producedFrame = NO;
    BOOL waitingForKeyFrame = YES;
    NSUInteger hardwarePacketsWithoutFrame = 0;
    while (self.running && av_read_frame(formatContext, packet) >= 0) {
        if (packet->stream_index == videoStreamIndex) {
            BOOL isKeyFrame = (packet->flags & AV_PKT_FLAG_KEY) != 0;
            // Joining mid-GOP without reference frames only ever yields
            // recoverable ReferenceMissing errors; wait for the first IDR.
            if (waitingForKeyFrame && !isKeyFrame) {
                av_packet_unref(packet);
                continue;
            }
            waitingForKeyFrame = NO;
            [hardwareDecoder decodePacket:packet->data
                                   length:(size_t)packet->size
                         presentationTime:VCAMRTSPPacketTime(packet, stream)
                               decodeTime:kCMTimeInvalid
                                 duration:kCMTimeInvalid
                               isKeyFrame:isKeyFrame];
            hardwarePacketsWithoutFrame += 1;
            CVPixelBufferRef output = NULL;
            CMTime outputPts = kCMTimeInvalid;
            while ((output = [hardwareDecoder copyNextOutputFrame:&outputPts]) != NULL) {
                [self acceptDecodedPixelBuffer:output hardware:YES];
                CVPixelBufferRelease(output);
                producedFrame = YES;
                hardwarePacketsWithoutFrame = 0;
            }
            // Same stall window as the software path: a VT session that keeps
            // accepting packets without any output ends the session for the
            // caller to evaluate and fall back.
            if (hardwarePacketsWithoutFrame >= 300) {
                [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
                    @"%@ hardware decoder produced no frames packets=300; ending session",
                    self.streamName]];
                break;
            }
        }
        av_packet_unref(packet);
    }
    return producedFrame;
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
    BOOL loggedCorruptFrame = NO;
    BOOL loggedReceiveFailure = NO;
    BOOL loggedSendFailure = NO;
    NSString *sessionLine = nil;
    NSUInteger videoPacketsWithoutFrame = 0;
    NSUInteger consecutiveSendFailures = 0;
    NSString *urlString = self.streamURL.absoluteString;
    const char *url = urlString.UTF8String;

    gFFmpegDiagnosticCount = 0;
    fprintf(stderr, "vcam rtsp session start url=%s\n",
            urlString.UTF8String ?: "(nil)");
    fflush(stderr);
    [self configureOpenOptions:&options];
    formatContext = avformat_alloc_context();
    if (formatContext == NULL) goto cleanup;
    formatContext->interrupt_callback.callback = VCAMRTSPInterruptWhenStopped;
    formatContext->interrupt_callback.opaque = (__bridge void *)self;
    // Keep FFmpeg's normal RTP reordering and H.264 reference buffering. The
    // former low-latency combination (nobuffer/low_delay/reorder_queue_size=0)
    // could display error-concealed inter frames after a delayed packet.
    int openResult = avformat_open_input(&formatContext, url, NULL, &options);
    if (openResult < 0) {
        if (self.running) {
            [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
                @"%@ FFmpeg input open failed error=%@", self.streamName,
                VCAMFFmpegErrorDescription(openResult)]];
        }
        goto cleanup;
    }
    int streamInfoResult = avformat_find_stream_info(formatContext, NULL);
    if (streamInfoResult < 0) {
        if (self.running) {
            [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
                @"%@ FFmpeg stream probe failed error=%@", self.streamName,
                VCAMFFmpegErrorDescription(streamInfoResult)]];
        }
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

    // Preferred path: push the demuxed access units to the SpringBoard
    // remote decoder (VideoToolbox only works from an app process; E9).
    const char *remoteCodecName = NULL;
    if (stream->codecpar->codec_id == AV_CODEC_ID_H264) {
        remoteCodecName = "h264";
    } else if (stream->codecpar->codec_id == AV_CODEC_ID_HEVC) {
        remoteCodecName = "hevc";
    }
    // The SpringBoard peer usually registers long before this source exists,
    // so the PeerAvailable event was delivered with no handler attached.
    // Consult the broker's live state as well; the atomic flag still tracks
    // mid-session peer loss.
    BOOL remotePeerReady =
        atomic_load_explicit(&gVCAMRTSPRemotePeerAvailable,
                             memory_order_acquire) == 1 ||
        VCAMSurfaceBrokerRemoteDecoderPeerAvailable();
    if (gVCAMRTSPRemoteHardwareDisabled == 0 && remoteCodecName != NULL &&
        remotePeerReady &&
        stream->codecpar->extradata != NULL &&
        stream->codecpar->extradata_size > 0) {
        AVPacket *remotePacket = av_packet_alloc();
        BOOL remoteProduced = NO;
        if (remotePacket != NULL) {
            remoteProduced = [self decodePacketsWithRemoteDecode:remotePacket
                                                  formatContext:formatContext
                                                    videoStream:videoStream
                                                         stream:stream
                                                          codec:remoteCodecName
                                                  parameterData:stream->codecpar->extradata
                                                      extraSize:stream->codecpar->extradata_size
                                                          width:stream->codecpar->width
                                                         height:stream->codecpar->height];
            av_packet_free(&remotePacket);
        }
        if (remoteProduced) {
            producedFrame = YES;
            goto cleanup;
        }
        if (self.running) {
            gVCAMRTSPRemoteHardwareDisabled = 1;
            [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
                @"%@ remote hardware decode disabled; trying in-daemon paths",
                self.streamName]];
        }
    }

    // Second choice: decode the demuxed packets through the direct-VT decoder
    // that local media playback already uses in production. FFmpeg's
    // VideoToolbox hwaccel wrapper historically produced zero frames on RTSP,
    // so this path bypasses it; init failure or a zero-frame session falls
    // through to the FFmpeg software decoder below.
    if (gVCAMRTSPHardwareSessionsDisabled == 0 &&
        (stream->codecpar->codec_id == AV_CODEC_ID_H264 ||
         stream->codecpar->codec_id == AV_CODEC_ID_HEVC) &&
        stream->codecpar->extradata != NULL && stream->codecpar->extradata_size > 0) {
        VCAMVideoCodecType codecType =
            stream->codecpar->codec_id == AV_CODEC_ID_H264 ?
                VCAMVideoCodecTypeH264 : VCAMVideoCodecTypeHEVC;
        VCAMHardwareVideoDecoder *hardwareDecoder =
            [[VCAMHardwareVideoDecoder alloc]
                initWithCodecType:codecType
                   parameterData:stream->codecpar->extradata
                          length:(size_t)stream->codecpar->extradata_size
                           width:stream->codecpar->width
                          height:stream->codecpar->height];
        NSError *hardwareError = nil;
        if (hardwareDecoder != nil && [hardwareDecoder start:&hardwareError]) {
            AVPacket *hardwarePacket = av_packet_alloc();
            BOOL hardwareProduced = NO;
            if (hardwarePacket != NULL) {
                hardwareProduced = [self decodePacketsWithHardwareSession:hardwareDecoder
                                                                  packet:hardwarePacket
                                                         formatContext:formatContext
                                                           videoStream:videoStream
                                                                stream:stream];
                av_packet_free(&hardwarePacket);
            }
            [hardwareDecoder stop];
            if (hardwareProduced) {
                producedFrame = YES;
                goto cleanup;
            }
            // A started VT session that never produced a frame: stop paying
            // the hardware retry cost for the rest of this process.
            if (self.running) {
                gVCAMRTSPHardwareSessionsDisabled = 1;
                [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
                    @"%@ hardware decode disabled; using FFmpeg software decoder",
                    self.streamName]];
            }
        } else {
            [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
                @"%@ hardware decoder unavailable error=%@", self.streamName,
                hardwareError.localizedDescription ?: @"(init failed)"]];
        }
    }

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
    // This is the software fallback: reached only when the direct-VT decoder
    // above was unavailable or produced a zero-frame session (the historical
    // iOS 16 -12780 device-level failure mode). FFmpeg's VideoToolbox
    // hwaccel wrapper remains avoided.
    codecContext->thread_count = 0;
    if (avcodec_open2(codecContext, decoder, NULL) < 0) {
        fprintf(stderr, "vcam avcodec_open2 FAILED\n");
        fflush(stderr);
        goto cleanup;
    }
    fprintf(stderr, "vcam software decoder ready pix_fmt=%d threads=%d\n",
            codecContext->pix_fmt, codecContext->thread_count);
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
                            // A non-IDR frame without a reference can fail
                            // after joining a stream mid-GOP.
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
            // A publisher restart can leave the decoder consuming packets
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
    avformat_close_input(&formatContext);
    return producedFrame;
}

- (CMSampleBufferRef)copyDirectPreviewSample {
    CVPixelBufferRef pixelBuffer = NULL;
    uint64_t sequence = 0;
    @synchronized (self) {
        if (!self.running || _latestPixelBuffer == NULL ||
            CACurrentMediaTime() - _latestFrameHostTime >= VCAMStaleFrameSeconds ||
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
            CACurrentMediaTime() - _latestFrameHostTime < VCAMStaleFrameSeconds) {
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

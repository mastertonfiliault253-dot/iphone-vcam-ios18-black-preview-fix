#import "VCAMOBSStreamSource.h"
#import <ImageIO/ImageIO.h>
#import <QuartzCore/QuartzCore.h>

static const NSUInteger VCAMPacketHeaderLength = 16;
// Same stale-frame window as VCAMRTSPStreamSource: beyond this the pushed
// frame is treated as lost and the source reports no video.
static const CFTimeInterval VCAMStaleFrameSeconds = 3.5;

@interface VCAMOBSStreamSource () <NSURLSessionDelegate>
@property(nonatomic, strong) VCAMConfiguration *configuration;
@property(nonatomic, strong) VCAMFrameRenderer *renderer;
@property(nonatomic, strong, nullable) NSURLSession *session;
@property(nonatomic, strong, nullable) NSURLSessionWebSocketTask *task;
@property(nonatomic, strong, nullable) NSData *latestJPEG;
@property(nonatomic) CFTimeInterval latestFrameHostTime;
@property(nonatomic) BOOL running;
@property(nonatomic) NSUInteger connectionGeneration;
@end

@implementation VCAMOBSStreamSource {
    // Decoded-image cache: OBS pushes frames far slower than the camera
    // graph pulls them, so re-JPEG-decoding the same bytes on every pull
    // wasted CPU (the RTSP source already caches its last rendered sample).
    CGImageRef _cachedImage;
    CFTimeInterval _cachedFrameHostTime;
}

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
    if (self.configuration.obsWebSocketURL == nil) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"VCAMOBSStreamSource"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"OBS WebSocket URL is missing or invalid"}];
        }
        return NO;
    }
    NSURLSessionConfiguration *sessionConfiguration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    sessionConfiguration.timeoutIntervalForRequest = 5.0;
    self.session = [NSURLSession sessionWithConfiguration:sessionConfiguration delegate:self delegateQueue:nil];
    self.running = YES;
    [self connect];
    return YES;
}

- (void)stop {
    self.running = NO;
    self.connectionGeneration += 1;
    [self.task cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
    [self.session invalidateAndCancel];
    self.task = nil;
    self.session = nil;
    @synchronized (self) {
        self.latestJPEG = nil;
        self.latestFrameHostTime = 0;
    }
}

- (void)connect {
    if (!self.running || self.session == nil) return;
    self.connectionGeneration += 1;
    NSUInteger generation = self.connectionGeneration;
    [self.task cancelWithCloseCode:NSURLSessionWebSocketCloseCodeGoingAway reason:nil];
    self.task = [self.session webSocketTaskWithURL:self.configuration.obsWebSocketURL];
    [self.task resume];
    [self receiveNextMessageForGeneration:generation];
}

- (void)receiveNextMessageForGeneration:(NSUInteger)generation {
    if (!self.running) return;
    __weak typeof(self) weakSelf = self;
    [self.task receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (self == nil || !self.running || generation != self.connectionGeneration) return;
        if (error == nil && message.type == NSURLSessionWebSocketMessageTypeData) {
            [self acceptPacket:message.data];
        }
        if (error == nil) {
            [self receiveNextMessageForGeneration:generation];
        } else {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                           dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                if (self.running && generation == self.connectionGeneration) [self connect];
            });
        }
    }];
}

- (void)acceptPacket:(NSData *)packet {
    if (packet.length <= VCAMPacketHeaderLength) return;
    const uint8_t *bytes = packet.bytes;
    if (memcmp(bytes, "VCAM", 4) != 0 || bytes[4] != 1) return;
    const uint8_t kind = bytes[5];
    if (kind == 1) {
        NSData *jpeg = [packet subdataWithRange:NSMakeRange(VCAMPacketHeaderLength,
                                                            packet.length - VCAMPacketHeaderLength)];
        @synchronized (self) {
            self.latestJPEG = jpeg;
            self.latestFrameHostTime = CACurrentMediaTime();
        }
    }
}

- (CMSampleBufferRef)copyVideoSampleForTemplate:(CMSampleBufferRef)templateBuffer {
    CGImageRef image = [self copyLatestImage];
    if (image == NULL) return NULL;
    CMSampleBufferRef sample = [self.renderer copySampleFromCGImage:image
                                                    sourceTransform:CGAffineTransformIdentity
                                                           template:templateBuffer
                                                      configuration:self.configuration];
    CGImageRelease(image);
    return sample;
}

- (CGImageRef)copyLatestImage {
    NSData *jpeg = nil;
    CFTimeInterval stamp = 0;
    @synchronized (self) {
        if (self.running &&
            CACurrentMediaTime() - self.latestFrameHostTime < VCAMStaleFrameSeconds) {
            jpeg = self.latestJPEG;
            stamp = self.latestFrameHostTime;
        }
    }
    if (jpeg.length == 0) return NULL;
    CGImageRef cached = NULL;
    @synchronized (self) {
        if (_cachedImage != NULL && _cachedFrameHostTime == stamp) {
            cached = CGImageRetain(_cachedImage);
        }
    }
    if (cached != NULL) return cached;
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)jpeg, NULL);
    if (source == NULL) return NULL;
    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    CFRelease(source);
    if (image == NULL) return NULL;
    @synchronized (self) {
        if (_cachedImage != NULL) CGImageRelease(_cachedImage);
        _cachedImage = image;  // cache owns one reference
        _cachedFrameHostTime = stamp;
    }
    return CGImageRetain(image);
}

- (void)dealloc {
    if (_cachedImage != NULL) {
        CGImageRelease(_cachedImage);
        _cachedImage = NULL;
    }
}

- (CMSampleBufferRef)copyAudioSampleForTemplate:(CMSampleBufferRef)templateBuffer {
    return NULL;
}

@end

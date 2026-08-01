#import "VCAMOBSStreamSource.h"

static const NSUInteger VCAMPacketHeaderLength = 16;

@interface VCAMOBSStreamSource () <NSURLSessionDelegate>
@property(nonatomic, strong) VCAMConfiguration *configuration;
@property(nonatomic, strong) VCAMFrameRenderer *renderer;
@property(nonatomic, strong, nullable) NSURLSession *session;
@property(nonatomic, strong, nullable) NSURLSessionWebSocketTask *task;
@property(nonatomic, strong, nullable) NSData *latestJPEG;
@property(nonatomic) BOOL running;
@property(nonatomic) NSUInteger connectionGeneration;
@end

@implementation VCAMOBSStreamSource

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
    @synchronized (self) { self.latestJPEG = nil; }
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
        @synchronized (self) { self.latestJPEG = jpeg; }
    }
}

- (CMSampleBufferRef)copyVideoSampleForTemplate:(CMSampleBufferRef)templateBuffer {
    NSData *jpeg = nil;
    @synchronized (self) { jpeg = self.latestJPEG; }
    if (jpeg.length == 0) return NULL;
    CIImage *image = [CIImage imageWithData:jpeg];
    return image == nil ? NULL : [self.renderer copySampleFromImage:image
                                                           template:templateBuffer
                                                      configuration:self.configuration];
}

- (CMSampleBufferRef)copyAudioSampleForTemplate:(CMSampleBufferRef)templateBuffer {
    return NULL;
}

@end

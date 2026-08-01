#import "VCAMAssetWriterRecorder.h"

@interface VCAMAssetWriterRecorder ()
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, strong, nullable) AVAssetWriter *writer;
@property(nonatomic, strong, nullable) AVAssetWriterInput *videoInput;
@property(nonatomic, copy, nullable) NSURL *outputURL;
@property(nonatomic) BOOL accepting;
@end

@implementation VCAMAssetWriterRecorder

- (instancetype)init {
    self = [super init];
    if (self) _queue = dispatch_queue_create("com.codex.vcam.asset-writer", DISPATCH_QUEUE_SERIAL);
    return self;
}

- (void)start {
    dispatch_sync(self.queue, ^{
        [self.writer cancelWriting];
        self.writer = nil;
        self.videoInput = nil;
        NSString *name = [NSString stringWithFormat:@"vcam-%@.mov", NSUUID.UUID.UUIDString];
        self.outputURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];
        [NSFileManager.defaultManager removeItemAtURL:self.outputURL error:nil];
        self.accepting = YES;
    });
}

- (void)appendVideoSample:(CMSampleBufferRef)sample {
    if (sample == NULL) return;
    CFRetain(sample);
    dispatch_async(self.queue, ^{
        @autoreleasepool {
            if (!self.accepting) {
                CFRelease(sample);
                return;
            }
            if (self.writer == nil && ![self configureWriterForSample:sample]) {
                self.accepting = NO;
                CFRelease(sample);
                return;
            }
            if (self.writer.status == AVAssetWriterStatusWriting && self.videoInput.readyForMoreMediaData) {
                [self.videoInput appendSampleBuffer:sample];
            }
            CFRelease(sample);
        }
    });
}

- (BOOL)configureWriterForSample:(CMSampleBufferRef)sample {
    CVImageBufferRef image = CMSampleBufferGetImageBuffer(sample);
    if (image == NULL) return NO;
    NSError *error = nil;
    AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:self.outputURL
                                                     fileType:AVFileTypeQuickTimeMovie
                                                        error:&error];
    if (writer == nil) return NO;
    NSInteger width = CVPixelBufferGetWidth(image);
    NSInteger height = CVPixelBufferGetHeight(image);
    NSDictionary *settings = @{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @(width),
        AVVideoHeightKey: @(height),
        AVVideoCompressionPropertiesKey: @{
            AVVideoAverageBitRateKey: @(MAX(2 * 1000 * 1000, width * height * 4)),
            AVVideoExpectedSourceFrameRateKey: @30,
            AVVideoMaxKeyFrameIntervalKey: @60,
        },
    };
    AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                                                    outputSettings:settings];
    input.expectsMediaDataInRealTime = YES;
    if (![writer canAddInput:input]) return NO;
    [writer addInput:input];
    if (![writer startWriting]) return NO;
    [writer startSessionAtSourceTime:CMSampleBufferGetPresentationTimeStamp(sample)];
    self.writer = writer;
    self.videoInput = input;
    return YES;
}

- (NSURL *)finishAndWait:(NSTimeInterval)timeout {
    __block AVAssetWriter *writer;
    __block NSURL *url;
    dispatch_sync(self.queue, ^{
        self.accepting = NO;
        writer = self.writer;
        url = self.outputURL;
        [self.videoInput markAsFinished];
    });
    if (writer == nil) return nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    [writer finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(semaphore); }];
    long result = dispatch_semaphore_wait(semaphore,
                                          dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)));
    if (result != 0 || writer.status != AVAssetWriterStatusCompleted) return nil;
    return url;
}

@end

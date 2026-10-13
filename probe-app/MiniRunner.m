#import "MiniRunner.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CMTime.h>
#import <stdio.h>

// Apple 官方 AVCam 示例的最小子集：默认前置设备 + High preset + videoDataOutput，
// delegate 回调在主队列（Apple 示例的常见写法），不触碰 ProbeRunner 的任何设施。
@interface MiniRunner () <AVCaptureVideoDataOutputSampleBufferDelegate>
@property(nonatomic, strong) AVCaptureSession *session;
@property(nonatomic, assign) NSInteger frames;
@property(nonatomic, assign) NSInteger drops;
@property(nonatomic, copy) NSString *logPath;
@end

static MiniRunner *gMini;

@implementation MiniRunner

+ (void)startWithDurationSeconds:(NSInteger)seconds {
    if (gMini) { return; }
    gMini = [MiniRunner new];
    [gMini runForSeconds:seconds];
}

- (instancetype)init {
    self = [super init];
    if (self) { _logPath = @"/var/mobile/Media/VCAM/mini.log"; }
    return self;
}

- (void)log:(NSString *)line {
    FILE *f = fopen(self.logPath.UTF8String, "a");
    if (f) { fprintf(f, "%s\n", line.UTF8String); fclose(f); }
    NSLog(@"[vcam-mini] %@", line);
}

- (void)runForSeconds:(NSInteger)seconds {
    [self log:[NSString stringWithFormat @"start pid=%d", (int)getpid()]];
    AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera
                                                                mediaType:AVMediaTypeVideo
                                                                 position:AVCaptureDevicePositionFront];
    if (!device) { [self log:@"NO front device"]; gMini = nil; return; }
    NSError *error = nil;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
    self.session = [AVCaptureSession new];
    self.session.sessionPreset = AVCaptureSessionPresetHigh;
    if (input && [self.session canAddInput:input]) { [self.session addInput:input]; }
    else { [self log:[NSString stringWithFormat:@"input fail %@", error]]; gMini = nil; return; }
    AVCaptureVideoDataOutput *output = [AVCaptureVideoDataOutput new];
    output.videoSettings = @{ (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA) };
    if ([self.session canAddOutput:output]) { [self.session addOutput:output]; }
    [output setSampleBufferDelegate:self queue:dispatch_get_main_queue()];
    [self log:[NSString stringWithFormat:@"configured inputs=%lu outputs=%lu preset=high",
               (unsigned long)self.session.inputs.count, (unsigned long)self.session.outputs.count]];
    [self.session startRunning];
    [self log:[NSString stringWithFormat:@"startRunning isRunning=%d running=%d",
               (int)self.session.isRunning, (int)[NSThread isMainThread]]];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, seconds * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        [self.session stopRunning];
        [self log:[NSString stringWithFormat:@"finish frames=%ld drops=%ld",
                   (long)self.frames, (long)self.drops]];
        gMini = nil;
    });
    // 2s 心跳：证明主队列活着且能报状态
    for (int t = 2; t <= seconds; t += 2) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, t * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            [self log:[NSString stringWithFormat:@"tick t=%d frames=%ld isRunning=%d",
                       t, (long)self.frames, (int)self.session.isRunning]];
        });
    }
}

- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    self.frames++;
    if (self.frames <= 3 || self.frames % 30 == 0) {
        CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        [self log:[NSString stringWithFormat:@"frame %ld pts=%.3f",
                   (long)self.frames, CMTimeGetSeconds(pts)]];
    }
}

- (void)captureOutput:(AVCaptureOutput *)output
    didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer
         fromConnection:(AVCaptureConnection *)connection {
    self.drops++;
}

@end

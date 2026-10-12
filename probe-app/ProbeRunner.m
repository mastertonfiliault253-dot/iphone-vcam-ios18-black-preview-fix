// 原生检测采集引擎。对应 docs/kyc/DETECTION-PLAN-NATIVE-APP-ZH.md §2。
// 只读设备与相机，不改 vcam 产品路径。所有可判读信号 dump 成 JSON，深度分析在主机侧。
#import "ProbeRunner.h"
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMotion/CoreMotion.h>
#import <ImageIO/ImageIO.h>
#import <ifaddrs.h>
#import <arpa/inet.h>
#import <sys/utsname.h>
#import <mach-o/dyld.h>
#import <sys/sysctl.h>
#import <math.h>
#include <stdlib.h>
#include <limits.h>

static const int kLowPhaseSeconds = 35;
static const int kHighPhaseSeconds = 8;
static const int kPhotoAtSecond = 3;

static NSString *tmpPathNamed(NSString *name) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:name];
}

@interface ProbeRunner () <AVCaptureVideoDataOutputSampleBufferDelegate,
                          AVCapturePhotoCaptureDelegate,
                          AVCaptureMetadataOutputObjectsDelegate> {
    // 各 phase 实际出帧宽高（从首帧 CVPixelBuffer 记录）。array 不能做 property，用 ivar。
    int _capturedW[2];
    int _capturedH[2];
}
@property(nonatomic, copy) NSString *baseURL;
@property(nonatomic, copy) void (^progress)(NSString *);
@property(nonatomic, copy) void (^completion)(void);

@property(nonatomic, strong) AVCaptureSession *session;
@property(nonatomic, strong) AVCaptureDevice *frontDevice;
@property(nonatomic, strong) AVCaptureVideoDataOutput *videoOutput;
@property(nonatomic, strong) AVCapturePhotoOutput *photoOutput;
@property(nonatomic, strong) dispatch_queue_t sampleQueue;
@property(nonatomic, strong) dispatch_queue_t sessionQueue;  // 文档要求会话增删/启停在专用串行队列
@property(nonatomic, strong) CMMotionManager *motion;
@property(nonatomic, strong) NSMutableArray *motionSamples;  // {t,gx,gy,gz,ax,ay,az}
@property(nonatomic, strong) NSLock *motionLock;

@property(nonatomic, strong) AVAssetWriter *writer;
@property(nonatomic, strong) AVAssetWriterInput *writerInput;
@property(nonatomic, copy) NSString *currentFile;
@property(nonatomic, assign) int phase;             // 0 low, 1 high, -1 recording off
@property(nonatomic, assign) int phaseFrames;
@property(nonatomic, strong) NSOperationQueue *motionQueue;
@property(nonatomic, assign) int faceFramesThisPhase;
@property(nonatomic, assign) int totalFaceObjects;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray *> *attachments;  // phase-scoped

@property(nonatomic, strong) NSMutableDictionary *report;
@property(nonatomic, strong) NSMutableArray *uploadedFiles;
@property(nonatomic, assign) BOOL photoCaptured;
@property(nonatomic, assign) BOOL photoOutputSupported;
@property(nonatomic, assign) BOOL metaOutputSupported;
@property(nonatomic, assign) BOOL videoOutputSupported;
@property(nonatomic, assign) BOOL reportMinimal;
@property(nonatomic, assign) CFAbsoluteTime startClock;
@end

@implementation ProbeRunner

- (instancetype)init {
    if ((self = [super init])) {
        _motionLock = [[NSLock alloc] init];
        _motionSamples = [NSMutableArray array];
        _uploadedFiles = [NSMutableArray array];
        _report = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)log:(NSString *)line {
    if (self.progress) { self.progress(line); }
}

#pragma mark - entry

- (void)runWithBaseURL:(NSString *)baseURL
              progress:(void (^)(NSString *))progress
            completion:(void (^)(void))completion {
    self.baseURL = baseURL;
    self.progress = progress;
    self.completion = completion;
    self.startClock = CFAbsoluteTimeGetCurrent();

    [self log:[NSString stringWithFormat:@"env %@\n", [self collectEnvironment] ? @"ok" : @"fail"]];
    [self collectMeta];

    __weak ProbeRunner *me = self;
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL videoGranted) {
        if (!videoGranted) { [me failWith:@"camera permission denied"]; return; }
        [me setupCameraAndRun];
    }];
}

- (void)failWith:(NSString *)reason {
    self.report[@"error"] = reason;
    [self log:[NSString stringWithFormat:@"ERROR %@\n", reason]];
    [self uploadReport];
    if (self.completion) { self.completion(); }
}

#pragma mark - environment

static BOOL pathExists(NSString *p) {
    return [[NSFileManager defaultManager] fileExistsAtPath:p];
}

- (BOOL)collectEnvironment {
    struct utsname u;
    NSString *machine = @"?", *release = @"?";
    if (uname(&u) == 0) { machine = @(u.machine); release = @(u.release); }

    NSMutableArray *dyldSuspicious = [NSMutableArray array];
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        NSString *name = @(_dyld_get_image_name(i));
        for (NSString *sig in @[@"substrate", @"ellekit", @"fishhook", @"libsub",
                                @"substitute", @"TweakInject", @"Shadow", @"hookkit",
                                @"VCAM", @"libcy", @"cycript", @"substitute.dylib"]) {
            if ([name rangeOfString:sig options:NSCaseInsensitiveSearch].location != NSNotFound) {
                [dyldSuspicious addObject:name];
                break;
            }
        }
    }

    NSDictionary *jbPaths = @{
        @"/var/jb": @(pathExists(@"/var/jb")),
        @"/var/jb/Applications/Sileo.app": @(pathExists(@"/var/jb/Applications/Sileo.app")),
        @"/var/jb/usr/lib/TweakInject": @(pathExists(@"/var/jb/usr/lib/TweakInject")),
        @"/var/jb/usr/lib/libsubstrate.dylib": @(pathExists(@"/var/jb/usr/lib/libsubstrate.dylib")),
        @"/var/jb/var/lib/dpkg/status": @(pathExists(@"/var/jb/var/lib/dpkg/status")),
        @"/var/jb/usr/sbin/frida": @(pathExists(@"/var/jb/usr/sbin/frida")),
        @"/bin/bash": @(pathExists(@"/bin/bash")),
        @"/Applications/Cydia.app": @(pathExists(@"/Applications/Cydia.app")),
    };

    NSMutableDictionary *canOpen = [NSMutableDictionary dictionary];
    for (NSString *scheme in @[@"sileo://", @"cydia://", @"mobilesubstrate://"]) {
        canOpen[scheme] = @([[UIApplication sharedApplication] canOpenURL:[NSURL URLWithString:scheme]]);
    }

    NSMutableArray *nets = [NSMutableArray array];
    struct ifaddrs *ifa = NULL;
    if (getifaddrs(&ifa) == 0) {
        for (struct ifaddrs *it = ifa; it; it = it->ifa_next) {
            if (it->ifa_addr && it->ifa_addr->sa_family == AF_INET) {
                char buf[INET_ADDRSTRLEN] = {0};
                struct sockaddr_in *sa = (struct sockaddr_in *)it->ifa_addr;
                inet_ntop(AF_INET, &sa->sin_addr, buf, sizeof(buf));
                [nets addObject:@{@"name": @(it->ifa_name), @"ipv4": @(buf)}];
            }
        }
        freeifaddrs(ifa);
    }

    self.report[@"environment"] = @{
        @"dyldCount": @(n),
        @"dyldSuspicious": dyldSuspicious,
        @"jbPaths": jbPaths,
        @"canOpenURL": canOpen,
        @"network": nets,
        @"machine": machine,
        @"systemRelease": release,
    };
    return YES;
}

- (void)collectMeta {
    struct utsname u;
    uname(&u);
    NSString *appVer = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";
    self.report[@"meta"] = [@{
        @"flow": @"native_probe",
        @"started": @([NSDate date].timeIntervalSince1970),
        @"machine": @(u.machine),
        @"systemRelease": @(u.release),
        @"appVersion": appVer,
    } mutableCopy];
}

#pragma mark - camera

// 严格按 Apple 文档标准配置采集会话（AVCaptureSession 类文档 + AVCam 参考实现）：
// - 设备经 AVCaptureDeviceDiscoverySession 枚举（iOS 10+ 文档标准入口）；
// - addInput/addOutput 包在 beginConfiguration/commitConfiguration 中；
// - startRunning 是阻塞调用，放专用串行 sessionQueue（类文档明确要求不阻塞主队列）；
// - 分辨率经 device.formats（AVCaptureDeviceFormat）+ activeFormat 显式选择
//   （文档："some specialized options require directly setting the capture device's activeFormat"；
//    此前编译失败是我误写了 AVCaptureFormat/supportedAVCaptureFormats 这类不存在的名字）。
- (void)setupCameraAndRun {
    self.sessionQueue = dispatch_queue_create("vcam.probe.session", DISPATCH_QUEUE_SERIAL);
    dispatch_async(self.sessionQueue, ^{ [self configureAndStartSession]; });
}

- (AVCaptureDeviceFormat *)pickFormatNearWidth:(int)w height:(int)h {
    AVCaptureDeviceFormat *best = nil;
    long long bestScore = LLONG_MAX;
    for (AVCaptureDeviceFormat *f in self.frontDevice.formats) {
        if (![f.mediaType isEqualToString:AVMediaTypeVideo]) { continue; }
        CMFormatDescriptionRef fd = f.formatDescription;
        if (!fd) { continue; }
        CMVideoDimensions d = CMFormatDescriptionGetDimensions(fd);
        if (d.width <= 0 || d.height <= 0) { continue; }
        BOOL fpsOk = NO;
        for (AVFrameRateRange *r in f.videoSupportedFrameRateRanges) {
            if (r.maxFrameRate >= 24) { fpsOk = YES; break; }
        }
        if (!fpsOk) { continue; }
        long long score = llabs((long long)d.width - w) + llabs((long long)d.height - h);
        if (score == 0) { return f; }
        if (score < bestScore) { bestScore = score; best = f; }
    }
    return best;
}

- (void)applyFormat:(AVCaptureDeviceFormat *)fmt label:(NSString *)label {
    if (!fmt) {
        [self log:[NSString stringWithFormat:@"format %s: no match, keep device default\n", label.UTF8String]];
        return;
    }
    NSError *lockErr = nil;
    if (![self.frontDevice lockForConfiguration:&lockErr]) {
        [self log:[NSString stringWithFormat:@"format %s lock fail: %@\n", label.UTF8String, lockErr]];
        return;
    }
    @try {
        self.frontDevice.activeFormat = fmt;
    } @catch (NSException *e) {
        [self log:[NSString stringWithFormat:@"format %s exception: %@\n", label.UTF8String(), e.reason]];
    } @finally {
        [self.frontDevice unlockForConfiguration];
    }
    CMVideoDimensions d = CMFormatDescriptionGetDimensions(fmt.formatDescription);
    ((NSMutableDictionary *)self.report)[@"appliedFormat"] = [@{
        label: [NSString stringWithFormat:@"%dx%d", d.width, d.height],
    } mutableCopy];
    [self log:[NSString stringWithFormat:@"format %s -> %dx%d\n", label.UTF8String, d.width, d.height]];
}

- (void)configureAndStartSession {
    self.session = [[AVCaptureSession alloc] init];
    AVCaptureDeviceDiscoverySession *disc =
        [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInWideAngleCamera]
                                                            mediaType:AVMediaTypeVideo
                                                             position:AVCaptureDevicePositionFront];
    self.frontDevice = disc.devices.firstObject;
    if (!self.frontDevice) {
        disc = [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInWideAngleCamera]
                                                                    mediaType:AVMediaTypeVideo
                                                                     position:AVCaptureDevicePositionUnspecified];
        self.frontDevice = disc.devices.firstObject;
    }
    if (!self.frontDevice) {
        self.frontDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    }
    if (!self.frontDevice) { [self failWith:@"no camera device"]; return; }

    NSError *err = nil;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:self.frontDevice error:&err];
    if (!input) { [self failWith:[NSString stringWithFormat:@"input: %@", err]]; return; }

    // 文档标准：多项增删用 beginConfiguration/commitConfiguration 成对提交。
    [self.session beginConfiguration];
    [self.session addInput:input];

    BOOL minimal = [[NSUserDefaults standardUserDefaults] boolForKey:@"probeMinimal"];
    self.reportMinimal = minimal;
    if (!minimal) {
        self.photoOutput = [[AVCapturePhotoOutput alloc] init];
        self.photoOutputSupported = [self.session canAddOutput:self.photoOutput];
        if (self.photoOutputSupported) { [self.session addOutput:self.photoOutput]; }

        AVCaptureMetadataOutput *meta = [[AVCaptureMetadataOutput alloc] init];
        self.metaOutputSupported = [self.session canAddOutput:meta];
        if (self.metaOutputSupported) {
            [self.session addOutput:meta];
            [meta setMetadataObjectsDelegate:self queue:dispatch_get_main_queue()];
            if ([meta.availableMetadataObjectTypes containsObject:AVMetadataObjectTypeFace]) {
                meta.metadataObjectTypes = @[AVMetadataObjectTypeFace];
            }
        }
    }

    self.sampleQueue = dispatch_queue_create("vcam.probe.samples", DISPATCH_QUEUE_SERIAL);
    self.videoOutput = [[AVCaptureVideoDataOutput alloc] init];
    self.videoOutput.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey:
        @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)};
    self.videoOutput.alwaysDiscardsLateVideoFrames = YES;
    [self.videoOutput setSampleBufferDelegate:self queue:self.sampleQueue];
    self.videoOutputSupported = [self.session canAddOutput:self.videoOutput];
    if (self.videoOutputSupported) { [self.session addOutput:self.videoOutput]; }

    // 低档先选 640x480（近似取最接近档）；随后阶段切换用 applyFormat。
    [self applyFormat:[self pickFormatNearWidth:640 height:480] label:@"low"];
    [self.session commitConfiguration];

    [self.session startRunning];  // 文档要求：阻塞调用，本处已在专用串行队列上
    // 启动 2s 后自检会话状态：定位零帧问题在会话层还是管线层（诊断数据入报告）。
    __weak ProbeRunner *weakMe = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), self.sampleQueue, ^{
        ProbeRunner *me = weakMe;
        if (!me) { return; }
        me.report[@"cameraSessionDiag"] = [@{
            @"isRunning": @(me.session.isRunning),
            @"isInterrupted": @(me.session.isInterrupted),
            @"inputs": @(me.session.inputs.count),
            @"outputs": @(me.session.outputs.count),
            @"preset": me.session.sessionPreset ?: @"?",
        } mutableCopy];
        [me log:[NSString stringWithFormat:@"diag isRunning=%d in=%lu out=%lu\n",
                 (int)me.session.isRunning, (unsigned long)me.session.inputs.count,
                 (unsigned long)me.session.outputs.count]];
        if (me.session.inputs.count && !me.session.isRunning) {
            [me log:@"session not running despite input — retry startRunning\n"];
            [me.session startRunning];
        }
    });
    // 5s 无任何帧 → 记一条诊断信号（结合 Safari 同机对照可定位层级）。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), self.sampleQueue, ^{
        ProbeRunner *me = weakMe;
        if (me && me.phaseFrames == 0) {
            [me log:@"NO FRAMES after 5s\n"];
            ((NSMutableDictionary *)me.report)[@"noFramesAfter5s"] = @YES;
        }
    });
    self.phase = 0;
    self.phaseFrames = 0;
    self.attachments = [NSMutableDictionary dictionary];

    [self startMotion];
    [self log:@"camera running, waiting for first frame\n"];

    // torch: 前置通常无 torch，supported=false 如实记录。
    BOOL hasTorch = self.frontDevice.hasTorch;
    self.report[@"camera"] = [@{
        @"frontCamera": @{
            @"hasTorch": @(hasTorch),
            @"position": self.frontDevice.position == AVCaptureDevicePositionFront ? @"front" : @"other",
        },
        @"sessions": [NSMutableArray array],
        @"torch": [@{@"supported": @(hasTorch)} mutableCopy],
        @"photoOutputSupported": @(self.photoOutputSupported),
        @"metaOutputSupported": @(self.metaOutputSupported),
        @"videoOutputSupported": @(self.videoOutputSupported),
        @"minimalMode": @(self.reportMinimal),
        @"photo": [NSMutableDictionary dictionary],
    } mutableCopy];

    __weak ProbeRunner *me = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kPhotoAtSecond * NSEC_PER_SEC), self.sampleQueue, ^{
        [me captureProbePhoto];
    });
    if (hasTorch) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), self.sampleQueue, ^{ [me setTorch:YES]; });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), self.sampleQueue, ^{ [me setTorch:NO]; });
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kLowPhaseSeconds * NSEC_PER_SEC)),
                   self.sampleQueue, ^{ [me finishLowPhase]; });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)((kLowPhaseSeconds + kHighPhaseSeconds + 2) * NSEC_PER_SEC)),
                   self.sampleQueue, ^{ [me finishProbe]; });
}

- (void)startMotion {
    self.motion = [[CMMotionManager alloc] init];
    self.motion.deviceMotionUpdateInterval = 1.0 / 50.0;
    // toQueue: 需要 NSOperationQueue（不是 dispatch_queue）；单串行队列保证采样有序。
    self.motionQueue = [[NSOperationQueue alloc] init];
    self.motionQueue.maxConcurrentOperationCount = 1;
    [self.motion startDeviceMotionUpdatesUsingReferenceFrame:CMAttitudeReferenceFrameXArbitraryZVertical
                                                   toQueue:self.motionQueue
                                             withHandler:^(CMDeviceMotion *m, NSError *e) {
        (void)e;
        if (!m) { return; }
        double t = CFAbsoluteTimeGetCurrent() - self.startClock;
        [self.motionLock lock];
        [self.motionSamples addObject:@{
            @"t": @(round(t * 10000) / 10000),
            @"gx": @(round(m.rotationRate.x * 10000) / 10000),
            @"gy": @(round(m.rotationRate.y * 10000) / 10000),
            @"gz": @(round(m.rotationRate.z * 10000) / 10000),
            @"ax": @(round(m.gravity.x * 10000) / 10000),
            @"ay": @(round(m.gravity.y * 10000) / 10000),
            @"az": @(round(m.gravity.z * 10000) / 10000),
        }];
        [self.motionLock unlock];
    }];
}

- (void)setTorch:(BOOL)on {
    if (!self.frontDevice.hasTorch) { return; }
    [self.frontDevice lockForConfiguration:nil];
    self.frontDevice.torchMode = on ? AVCaptureTorchModeOn : AVCaptureTorchModeOff;
    [self.frontDevice unlockForConfiguration];
    [(NSMutableDictionary *)self.report[@"camera"][@"torch"] addEntriesFromDictionary:@{@"cycled": @YES}];
}

#pragma mark - sample buffer

- (void)captureOutput:(AVCaptureOutput *)out
  didOutputSampleBuffer:(CMSampleBufferRef)sb
         fromConnection:(AVCaptureConnection *)conn {
    if (self.phase < 0) { return; }
    if (!self.writerInput) { [self startWriterForSampleBuffer:sb]; }
    if (self.writerInput && self.writerInput.readyForMoreMediaData) {
        [self.writerInput appendSampleBuffer:sb];
    }

    self.phaseFrames++;
    if (self.phaseFrames == 1) {
        CVImageBufferRef pb = CMSampleBufferGetImageBuffer(sb);
        size_t w = pb ? CVPixelBufferGetWidth(pb) : 0;
        size_t h = pb ? CVPixelBufferGetHeight(pb) : 0;
        [self log:[NSString stringWithFormat:@"phase%d first frame %zux%zu\n", self.phase, w, h]];
    }
    [self recordAttachments:sb];
}

- (void)startWriterForSampleBuffer:(CMSampleBufferRef)sb {
    CVImageBufferRef pb = CMSampleBufferGetImageBuffer(sb);
    if (!pb) { return; }
    size_t w = CVPixelBufferGetWidth(pb);
    size_t h = CVPixelBufferGetHeight(pb);
    if (self.phase >= 0 && self.phase < 2) { _capturedW[self.phase] = (int)w; _capturedH[self.phase] = (int)h; }
    NSString *name = [NSString stringWithFormat:@"probe_phase%d_%zux%zu.mp4", self.phase, w, h];
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    NSError *err = nil;
    self.writer = [AVAssetWriter assetWriterWithURL:[NSURL fileURLWithPath:path]
                                           fileType:AVFileTypeMPEG4 error:&err];
    if (!self.writer) { [self log:[NSString stringWithFormat:@"writer fail %@\n", err]]; return; }
    NSDictionary *settings = @{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @(w),
        AVVideoHeightKey: @(h),
        AVVideoCompressionPropertiesKey: @{
            AVVideoAverageBitRateKey: @(w >= 1920 ? 8000000 : 3000000),
            AVVideoMaxKeyFrameIntervalKey: @(30),
        },
    };
    self.writerInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:settings];
    self.writerInput.expectsMediaDataInRealTime = YES;
    if ([self.writer canAddInput:self.writerInput]) { [self.writer addInput:self.writerInput]; }
    self.currentFile = name;
    self.phaseFrames = 0;
    self.faceFramesThisPhase = 0;
    self.attachments = [NSMutableDictionary dictionary];
}

- (void)recordAttachments:(CMSampleBufferRef)sb {
    CVImageBufferRef pb = CMSampleBufferGetImageBuffer(sb);
    if (!pb) { return; }
    // 传感器 attachment（ExposureTime/ISO 等）挂在 ShouldPropagate 模式；
    // CVBufferGetAttachments 为 iOS 2.0+ 公开 API（主工程同源用 kCVAttachmentMode_*）。
    CFDictionaryRef atts = CVBufferGetAttachments(pb, kCVAttachmentMode_ShouldPropagate);
    if (!atts) { return; }
    CFIndex count = CFDictionaryGetCount(atts);
    if (count <= 0) { return; }
    const void **keys = (const void **)malloc(sizeof(void *) * (size_t)count);
    const void **vals = (const void **)malloc(sizeof(void *) * (size_t)count);
    if (!keys || !vals) { free(keys); free(vals); return; }
    CFDictionaryGetKeysAndValues(atts, keys, vals);
    for (CFIndex i = 0; i < count; i++) {
        CFTypeRef key = keys[i], val = vals[i];
        if (!key || !val || CFGetTypeID(key) != CFStringGetTypeID()) { continue; }
        NSString *ks = (__bridge NSString *)key;
        double number = NAN;
        if (CFGetTypeID(val) == CFNumberGetTypeID()) {
            if (!CFNumberGetValue((CFNumberRef)val, kCFNumberDoubleType, &number)) { continue; }
        } else if (CFGetTypeID(val) == CFBooleanGetTypeID()) {
            number = CFBooleanGetValue((CFBooleanRef)val) ? 1 : 0;
        } else {
            continue;
        }
        NSMutableArray *arr = self.attachments[ks];
        if (!arr) { arr = [NSMutableArray array]; self.attachments[ks] = arr; }
        [arr addObject:@(number)];
    }
    free(keys);
    free(vals);
}

- (void)metadataOutput:(AVCaptureMetadataOutput *)out
  didOutputMetadataObjects:(NSArray *)objects
          fromConnection:(AVCaptureConnection *)conn {
    int faces = 0;
    for (AVMetadataObject *o in objects) {
        if ([o isKindOfClass:AVMetadataFaceObject.class]) { faces++; }
    }
    if (faces > 0) { self.faceFramesThisPhase++; self.totalFaceObjects += faces; }
}

#pragma mark - photo

- (void)captureProbePhoto {
    if (!self.photoOutput) {
        if (!self.photoCaptured) {
            self.photoCaptured = YES;
            ((NSMutableDictionary *)self.report[@"camera"][@"photo"])[@"skipped"] = @"no photo output (minimal mode or unsupported)";
        }
        return;
    }
    if (self.photoCaptured) { return; }
    if (self.phaseFrames < 1) {  // 首帧未到就 capturePhoto 会抛 NSException（真机崩溃已证）
        [self log:@"photo deferred: no frame yet\n"];
        __weak ProbeRunner *me = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), self.sampleQueue, ^{
            [me captureProbePhoto];
        });
        return;
    }
    self.photoCaptured = YES;
    AVCapturePhotoSettings *s = [AVCapturePhotoSettings photoSettings];
    @try {
        [self.photoOutput capturePhotoWithSettings:s delegate:self];
    } @catch (NSException *e) {
        NSMutableDictionary *pr = (NSMutableDictionary *)self.report[@"camera"][@"photo"];
        pr[@"saved"] = @NO;
        pr[@"error"] = [NSString stringWithFormat:@"%@: %@", e.name, e.reason];
        [self log:[NSString stringWithFormat:@"photo exception: %@\n", e.reason]];
    }
}

- (void)photoOutput:(AVCapturePhotoOutput *)out
    didFinishProcessingPhoto:(AVCapturePhoto *)photo
                       error:(NSError *)error {
    NSMutableDictionary *photoReport = (NSMutableDictionary *)self.report[@"camera"][@"photo"];
    if (error || !photo) { photoReport[@"saved"] = @NO; photoReport[@"error"] = error.localizedDescription ?: @"none"; return; }
    NSData *data = [photo fileDataRepresentation];
    if (!data) { photoReport[@"saved"] = @NO; return; }
    NSString *name = @"probe_photo.jpg";
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
    [data writeToFile:path atomically:YES];
    [self uploadFile:path name:name];

    NSDictionary *props = nil;
    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (src) {
        CFDictionaryRef p = CGImageSourceCopyPropertiesAtIndex(src, 0, NULL);
        props = p ? (__bridge_transfer NSDictionary *)p : nil;
        CFRelease(src);
    }
    NSMutableDictionary *flat = [NSMutableDictionary dictionary];
    __block int keyCount = 0;
    for (NSString *section in props.allKeys) {
        id v = props[section];
        if ([v isKindOfClass:NSDictionary.class]) {
            for (NSString *k in ((NSDictionary *)v).allKeys) {
                id kv = ((NSDictionary *)v)[k];
                if ([kv isKindOfClass:NSValue.class] || [kv isKindOfClass:NSString.class]) {
                    flat[[NSString stringWithFormat:@"%@.%@", section, k]] = kv;
                    keyCount++;
                }
            }
        }
    }
    // 维度从 ImageIO 属性顶层取（resolvedSettings.dimensions 在该 SDK 头中不可用）。
    int pw = [props[(id)kCGImagePropertyPixelWidth] intValue];
    int ph = [props[(id)kCGImagePropertyPixelHeight] intValue];
    photoReport[@"saved"] = @YES;
    photoReport[@"width"] = @(pw);
    photoReport[@"height"] = @(ph);
    photoReport[@"exifKeyCount"] = @(keyCount);
    photoReport[@"exif"] = flat;
    [self log:[NSString stringWithFormat:@"photo %dx%d exifKeys=%d\n", pw, ph, keyCount]];
}

#pragma mark - phases

- (void)finishLowPhase {
    [self finalizeCurrentSessionWithLabel:@"low"];
    // 文档标准：运行中经 lockForConfiguration + activeFormat 切到最接近 1920x1080 的格式；
    // 实际出帧维度以首帧实测为准（capturedW/H）。
    AVCaptureDeviceFormat *hi = [self pickFormatNearWidth:1920 height:1080];
    dispatch_async(self.sessionQueue, ^{ [self applyFormat:hi label:@"high"]; });
    self.phase = 1;
    self.writerInput = nil;
    self.writer = nil;
}

- (void)finalizeCurrentSessionWithLabel:(NSString *)label {
    if (!self.writer) { return; }
    AVAssetWriterInput *input = self.writerInput;
    [input markAsFinished];
    AVAssetWriter *writer = self.writer;
    NSString *file = self.currentFile;
    NSMutableDictionary *summary = [self sessionSummaryWithLabel:label];
    [(NSMutableArray *)self.report[@"camera"][@"sessions"] addObject:summary];
    __weak ProbeRunner *me = self;
    [writer finishWritingWithCompletionHandler:^{
        if (file) { [me uploadFile:tmpPathNamed(file) name:file]; }
        [me log:[NSString stringWithFormat:@"wrote %@ frames=%d status=%ld\n", file,
                 (int)[summary[@"frames"] integerValue], (long)writer.status]];
    }];
    self.writer = nil;
    self.writerInput = nil;
}

- (void)finishProbe {
    self.phase = -1;
    [self finalizeCurrentSessionWithLabel:@"high"];
    dispatch_async(self.sessionQueue, ^{ [self.session stopRunning]; });
    [self.motion stopDeviceMotionUpdates];
    [self computeMotionStats];
    [self selfVerdicts];
    self.report[@"meta"][@"finished"] = @([NSDate date].timeIntervalSince1970);
    [self uploadReport];
    if (self.completion) { self.completion(); }
}

- (NSMutableDictionary *)sessionSummaryWithLabel:(NSString *)label {
    int w = 0, h = 0;
    if (self.phase >= 0 && self.phase < 2) { w = _capturedW[self.phase]; h = _capturedH[self.phase]; }
    NSMutableDictionary *s = [@{
        @"label": label,
        @"capturedW": @(w),
        @"capturedH": @(h),
        @"frames": @(self.phaseFrames),
        @"faceFrames": @(self.faceFramesThisPhase),
    } mutableCopy];
    NSMutableDictionary *stats = [NSMutableDictionary dictionary];
    for (NSString *key in self.attachments.allKeys) {
        NSArray *vals = self.attachments[key];
        if (vals.count < 2) { continue; }
        double sum = 0, mn = HUGE_VAL, mx = -HUGE_VAL;
        for (NSNumber *v in vals) {
            double d = v.doubleValue;
            sum += d; mn = MIN(mn, d); mx = MAX(mx, d);
        }
        double mean = sum / vals.count, vs = 0;
        for (NSNumber *v in vals) { double d = v.doubleValue - mean; vs += d * d; }
        stats[key] = @{@"n": @(vals.count), @"min": @(round(mn*1e6)/1e6), @"max": @(round(mx*1e6)/1e6),
                       @"mean": @(round(mean*1e6)/1e6), @"sd": @(round(sqrt(vs/vals.count)*1e6)/1e6)};
    }
    s[@"attachmentStats"] = stats;
    s[@"attachmentKeys"] = self.attachments.allKeys;
    return s;
}

- (void)computeMotionStats {
    [self.motionLock lock];
    NSArray *samples = [self.motionSamples copy];
    [self.motionLock unlock];
    double gsx = 0;
    double gs[3] = {0,0,0}, as[3] = {0,0,0}, gm[3] = {0,0,0}, am[3] = {0,0,0};
    for (NSDictionary *m in samples) {
        NSArray *gk = @[@"gx", @"gy", @"gz"], *ak = @[@"ax", @"ay", @"az"];
        for (int i = 0; i < 3; i++) { gm[i] += [m[gk[i]] doubleValue]; am[i] += [m[ak[i]] doubleValue]; }
    }
    size_t cnt = samples.count ?: 1;
    for (int i = 0; i < 3; i++) { gm[i] /= cnt; am[i] /= cnt; }
    for (NSDictionary *m in samples) {
        NSArray *gk = @[@"gx", @"gy", @"gz"], *ak = @[@"ax", @"ay", @"az"];
        for (int i = 0; i < 3; i++) {
            double dg = [m[gk[i]] doubleValue] - gm[i]; gs[i] += dg * dg;
            double da = [m[ak[i]] doubleValue] - am[i]; as[i] += da * da;
        }
    }
    for (int i = 0; i < 3; i++) { gs[i] = sqrt(gs[i]/cnt); as[i] = sqrt(as[i]/cnt); }
    gsx = gs[0]+gs[1]+gs[2];
    self.report[@"motion"] = @{
        @"sampleCount": @(samples.count),
        @"gyroStdev": @[@(gs[0]), @(gs[1]), @(gs[2])],
        @"gravityStdev": @[@(as[0]), @(as[1]), @(as[2])],
        @"activity": gsx > 0.02 ? @"moving" : @"static",
        @"samples": samples,
    };
}

- (void)selfVerdicts {
    NSMutableArray *items = [NSMutableArray array];
    NSDictionary *env = self.report[@"environment"];
    [items addObject:@{@"name": @"jb_visible_to_app",
                       @"status": [@YES isEqualToValue:env[@"jbPaths"][@"/var/jb"]] ? @"RISK" : @"PASS",
                       @"detail": @"rootless /var/jb 从 App 进程可见即可能被检测"}];
    NSInteger suspicious = [env[@"dyldSuspicious"] count];
    [items addObject:@{@"name": @"dyld_hooked", @"status": suspicious > 0 ? @"RISK" : @"PASS",
                       @"detail": [NSString stringWithFormat:@"%ld injected images", (long)suspicious]}];
    NSArray *sessions = self.report[@"camera"][@"sessions"];
    for (NSDictionary *s in sessions) {
        NSDictionary *att = s[@"attachmentStats"];
        BOOL hasExposure = NO;
        for (NSString *k in att.allKeys) {
            if ([k rangeOfString:@"xposure"].location != NSNotFound ||
                [k rangeOfString:@"ISO"].location != NSNotFound) { hasExposure = YES; }
        }
        [items addObject:@{@"name": [NSString stringWithFormat:@"per_frame_exposure_%@", s[@"label"]],
                           @"status": hasExposure ? @"PASS" : @"RISK",
                           @"detail": hasExposure ? @"有逐帧曝光/ISO attachment（真实传感器特征）"
                                                   : @"无逐帧曝光参数（注入流常见破绽）"}];
        double frames = [s[@"frames"] doubleValue];
        double faces = [s[@"faceFrames"] doubleValue];
        if (frames > 0) {
            [items addObject:@{@"name": [NSString stringWithFormat:@"face_meta_%@", s[@"label"]],
                               @"status": faces/frames > 0.5 ? @"PASS" : @"RISK",
                               @"detail": [NSString stringWithFormat:@"faceMeta=%.0f%%", 100*faces/frames]}];
        }
    }
    self.report[@"items"] = items;
}

#pragma mark - upload

- (void)uploadFile:(NSString *)path name:(NSString *)name {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) { return; }
    NSString *url = [NSString stringWithFormat:@"%@/upload?name=%@", self.baseURL, name];
    [self postURL:url data:data label:name success:^{
        [self.uploadedFiles addObject:name];
    }];
}

- (void)uploadReport {
    self.report[@"uploads"] = self.uploadedFiles;
    NSError *e = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:self.report options:0 error:&e];
    if (!json) { [self log:[NSString stringWithFormat:@"json fail %@\n", e]]; return; }
    [self postURL:[self.baseURL stringByAppendingString:@"/report"] data:json label:@"report" success:nil];
}

- (void)postURL:(NSString *)urlString data:(NSData *)data label:(NSString *)label success:(void (^)(void))success {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    req.HTTPMethod = @"POST";
    req.HTTPBody = data;
    req.timeoutInterval = 15;
    NSURLSessionDataTask *t = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *resp, NSURLResponse *r, NSError *e) {
            (void)resp; (void)r;
            if (e) { [self log:[NSString stringWithFormat:@"upload FAIL %@: %@\n", label, e.localizedDescription]]; }
            else if (success) { success(); [self log:[NSString stringWithFormat:@"uploaded %@ (%lu B)\n", label, (unsigned long)data.length]]; }
        }];
    [t resume];
}

@end

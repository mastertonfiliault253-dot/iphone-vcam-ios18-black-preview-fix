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
    self.report[@"meta"] = @{
        @"flow": @"native_probe",
        @"started": @([NSDate date].timeIntervalSince1970),
        @"machine": @(u.machine),
        @"systemRelease": @(u.release),
        @"appVersion": appVer,
    };
}

#pragma mark - camera

- (void)setupCameraAndRun {
    self.session = [[AVCaptureSession alloc] init];
    // 用 sessionPreset 而非 device.activeFormat：后者及 supportedAVCaptureFormats/AVCaptureFormat
    // 在 theos 自带的 iPhoneOS SDK 头里不公开（CI 编译报错核实），preset 是确定可用的公开 API。
    if ([self.session canSetSessionPreset:AVCaptureSessionPreset640x480]) {
        self.session.sessionPreset = AVCaptureSessionPreset640x480;
    }
    self.frontDevice = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera
                                                        mediaType:AVMediaTypeVideo
                                                         position:AVCaptureDevicePositionFront];
    if (!self.frontDevice) {
        self.frontDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    }
    if (!self.frontDevice) { [self failWith:@"no camera device"]; return; }

    NSError *err = nil;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:self.frontDevice error:&err];
    if (!input) { [self failWith:[NSString stringWithFormat:@"input: %@", err]]; return; }
    [self.session addInput:input];

    self.photoOutput = [[AVCapturePhotoOutput alloc] init];
    if ([self.session canAddOutput:self.photoOutput]) { [self.session addOutput:self.photoOutput]; }

    AVCaptureMetadataOutput *meta = [[AVCaptureMetadataOutput alloc] init];
    if ([self.session canAddOutput:meta]) {
        [self.session addOutput:meta];
        [meta setMetadataObjectsDelegate:self queue:dispatch_get_main_queue()];
        if ([meta.availableMetadataObjectTypes containsObject:AVMetadataObjectTypeFace]) {
            meta.metadataObjectTypes = @[AVMetadataObjectTypeFace];
        }
    }

    self.sampleQueue = dispatch_queue_create("vcam.probe.samples", DISPATCH_QUEUE_SERIAL);
    self.videoOutput = [[AVCaptureVideoDataOutput alloc] init];
    self.videoOutput.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey:
        @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)};
    self.videoOutput.alwaysDiscardsLateVideoFrames = YES;
    [self.videoOutput setSampleBufferDelegate:self queue:self.sampleQueue];
    if ([self.session canAddOutput:self.videoOutput]) { [self.session addOutput:self.videoOutput]; }

    [self.session startRunning];
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
    if (!self.photoOutput || self.photoCaptured) { return; }
    self.photoCaptured = YES;
    AVCapturePhotoSettings *s = [AVCapturePhotoSettings photoSettings];
    [self.photoOutput capturePhotoWithSettings:s delegate:self];
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
    // 切到高档继续 phase 1；维度以首帧实测为准（见 capturedW/H）。
    if ([self.session canSetSessionPreset:AVCaptureSessionPreset1920x1080]) {
        self.session.sessionPreset = AVCaptureSessionPreset1920x1080;
    }
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
    [self.session stopRunning];
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
    double gsx = 0, asx = 0;
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
        completionHandler:(__unused NSData *resp, __unused NSURLResponse *r, NSError *e) {
            if (e) { [self log:[NSString stringWithFormat:@"upload FAIL %@: %@\n", label, e.localizedDescription]]; }
            else if (success) { success(); [self log:[NSString stringWithFormat:@"uploaded %@ (%lu B)\n", label, (unsigned long)data.length]]; }
        }];
    [t resume];
}

@end

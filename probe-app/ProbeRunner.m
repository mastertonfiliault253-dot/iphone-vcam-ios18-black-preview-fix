// 原生检测采集引擎。对应 docs/kyc/DETECTION-PLAN-NATIVE-APP-ZH.md §2。
// 只读设备与相机，不改 vcam 产品路径。所有可判读信号 dump 成 JSON，深度分析在主机侧。
#import "ProbeRunner.h"
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreMotion/CoreMotion.h>
#import <Vision/Vision.h>
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
                          AVCaptureMetadataOutputObjectsDelegate,
                          AVCaptureDepthDataOutputDelegate> {
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

// —— 扩展收集（全部经 16.5 SDK 头逐一核实成员名）——
@property(nonatomic, strong) AVCaptureDepthDataOutput *depthOutput;
@property(nonatomic, assign) BOOL depthOutputSupported;
@property(nonatomic, strong) dispatch_queue_t visionQueue;
@property(nonatomic, strong) CMAltimeter *altimeter;
@property(nonatomic, assign) BOOL altimeterAvailable;
@property(nonatomic, strong) NSMutableArray *altimeterSamples;  // {t,altitudeM,pressureKPa}
@property(nonatomic, strong) NSMutableArray *faceSamples;       // {t,id,w,h[,yaw,roll]} 仅 sampleQueue
@property(nonatomic, strong) NSMutableArray *visionSamples;     // {t,n,qual[,lm]} 仅 visionQueue（@synchronized）
@property(nonatomic, strong) NSMutableArray *exposureSamples;   // {t,exposureUs,iso} 仅 sampleQueue
@property(nonatomic, strong) NSDictionary *maxPhotoDimsSnapshot;
@property(nonatomic, strong) NSDictionary *trueDepthInfo;
@property(nonatomic, strong) NSDictionary *sensorRangesSnapshot;
@property(nonatomic, assign) int depthFramesTotal;
@property(nonatomic, assign) int depthDroppedTotal;
@property(nonatomic, assign) double depthFirstTs, depthLastTs;
@property(nonatomic, assign) int depthW, depthH;
@property(nonatomic, copy) NSString *depthTypeStr;

@property(nonatomic, strong) AVAssetWriter *writer;
@property(nonatomic, strong) AVAssetWriterInput *writerInput;
@property(nonatomic, copy) NSString *currentFile;
@property(nonatomic, assign) int phase;             // 0 low, 1 high, -1 recording off
@property(nonatomic, assign) int phaseFrames;
// 零帧定位：didDrop 计数与会话通知事件（RuntimeError/Interrupted）——
// 若帧被管线丢弃或会话被打断/报错，此前在报告里完全不可见。
@property(nonatomic, assign) int droppedVideoFrames;
@property(nonatomic, strong) NSMutableArray *sessionEvents;
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
        _altimeterSamples = [NSMutableArray array];
        _faceSamples = [NSMutableArray array];
        _visionSamples = [NSMutableArray array];
        _exposureSamples = [NSMutableArray array];
        _sessionEvents = [NSMutableArray array];
        _visionQueue = dispatch_queue_create("vcam.probe.vision", DISPATCH_QUEUE_SERIAL);
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
    // 自身可执行文件路径（本 App 名叫 VCAMDetectProbe，会被 "VCAM" 签名误命中）。
    NSString *selfImage = [[NSBundle mainBundle] executablePath] ?: @"";
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        NSString *name = @(_dyld_get_image_name(i));
        if (selfImage.length && [name isEqualToString:selfImage]) { continue; }
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
        // 扩展收集：IDFV / 屏幕亮度 / 气压计可用性 / 音频路由快照。
        @"identifierForVendor": [[UIDevice currentDevice] identifierForVendor].UUIDString ?: @"none",
        @"screenBrightness": @(UIScreen.mainScreen.brightness),
        @"barometerAvailable": @([CMAltimeter isRelativeAltitudeAvailable]),
        @"audio": [self collectAudioRoute],
    };
    return YES;
}

// AVAudioSession.currentRoute 快照（iOS 4+ 公开 API；portName/transportType 已废弃但本 target 允许）。
- (NSDictionary *)collectAudioRoute {
    NSMutableDictionary *a = [NSMutableDictionary dictionary];
    @try {
        AVAudioSession *as = [AVAudioSession sharedInstance];
        NSMutableArray *ins = [NSMutableArray array], *outs = [NSMutableArray array];
        // 注意：16.5 SDK 头中 AVAudioSessionPortDescription 只有 portType/portName
        // （transportType 未声明——本地编译实证），只记这两个。
        for (AVAudioSessionPortDescription *p in as.currentRoute.inputs) {
            [ins addObject:@{@"type": p.portType ?: @"?", @"name": p.portName ?: @""}];
        }
        for (AVAudioSessionPortDescription *p in as.currentRoute.outputs) {
            [outs addObject:@{@"type": p.portType ?: @"?", @"name": p.portName ?: @""}];
        }
        a[@"inputs"] = ins;
        a[@"outputs"] = outs;
        a[@"category"] = as.category ?: @"?";
        a[@"mode"] = as.mode ?: @"?";
        a[@"inputChannels"] = @(as.inputNumberOfChannels);
        a[@"outputVolume"] = @(round(as.outputVolume * 1000) / 1000);
    } @catch (NSException *e) {
        a[@"error"] = [NSString stringWithFormat:@"%@: %@", e.name, e.reason ?: @""];
    }
    return a;
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
        // 16.5 SDK 头中该 C 函数名为 CMVideoFormatDescriptionGetDimensions（iOS 4+）；
        // CMFormatDescriptionGetDimensions 在 theos 所用 SDK 未声明（CI 两轮编译错实证）。
        CMVideoDimensions d = CMVideoFormatDescriptionGetDimensions(fd);
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
    // 合并写入（此前整字典覆盖导致 low 档记录被 high 档冲掉）。
    NSMutableDictionary *af = nil;
    id prev = ((NSMutableDictionary *)self.report)[@"appliedFormat"];
    if ([prev isKindOfClass:NSMutableDictionary.class]) { af = prev; }
    else { af = [NSMutableDictionary dictionary]; ((NSMutableDictionary *)self.report)[@"appliedFormat"] = af; }
    if (!fmt) {
        af[label] = @"no-match";
        [self log:[NSString stringWithFormat:@"format %s: no match, keep device default\n", label.UTF8String]];
        return;
    }
    NSError *lockErr = nil;
    if (![self.frontDevice lockForConfiguration:&lockErr]) {
        af[label] = @"lock-fail";
        [self log:[NSString stringWithFormat:@"format %s lock fail: %@\n", label.UTF8String, lockErr]];
        return;
    }
    @try {
        self.frontDevice.activeFormat = fmt;
    } @catch (NSException *e) {
        af[label] = [NSString stringWithFormat:@"exception:%@", e.reason ?: e.name];
        [self log:[NSString stringWithFormat:@"format %s exception: %@\n", label.UTF8String, e.reason]];
    } @finally {
        [self.frontDevice unlockForConfiguration];
    }
    CMVideoDimensions d = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription);
    af[label] = [NSString stringWithFormat:@"%dx%d", d.width, d.height];
    [self log:[NSString stringWithFormat:@"format %s -> %dx%d\n", label.UTF8String, d.width, d.height]];
    [self recordMaxPhotoDimensionsForFormat:fmt];
}

// AVCaptureDeviceFormat.supportedMaxPhotoDimensions（iOS 16）+ AVCapturePhotoOutput.maxPhotoDimensions
// 文档要求"startRunning 前设置"；把支持档位与生效档位都记入报告（KYC 高分辨率证件采集能力信号）。
- (void)recordMaxPhotoDimensionsForFormat:(AVCaptureDeviceFormat *)fmt {
    NSMutableArray *list = [NSMutableArray array];
    CMVideoDimensions biggest = {0, 0};
    if (@available(iOS 16.0, *)) {  // supportedMaxPhotoDimensions/maxPhotoDimensions 均 iOS 16.0
        for (NSValue *v in fmt.supportedMaxPhotoDimensions) {
            CMVideoDimensions md = {0, 0};
            [v getValue:&md];
            [list addObject:[NSString stringWithFormat:@"%dx%d", md.width, md.height]];
            if ((long long)md.width * md.height > (long long)biggest.width * biggest.height) { biggest = md; }
        }
        if (biggest.width > 0 && self.photoOutput) {
            @try {
                self.photoOutput.maxPhotoDimensions = biggest;
            } @catch (NSException *e) {
                [self log:[NSString stringWithFormat:@"maxPhotoDimensions exception: %@\n", e.reason]];
            }
        }
    }
    self.maxPhotoDimsSnapshot = @{
        @"supported": list,
        @"applied": [NSString stringWithFormat:@"%dx%d", biggest.width, biggest.height],
    };
}

// 传感器能力范围（KYC 曝光动态类检测的基准）：全部为 AVCaptureDevice/Format 公开只读属性。
// 注：min/maxExposureDuration、min/maxISO 挂在 AVCaptureDeviceFormat（activeFormat）上，
// 不是 AVCaptureDevice（16.5 SDK 头 2643-2673 行实证归属）。
// videoMaxFrameRate 在 16.5 SDK 头已移除（改用 videoSupportedFrameRateRanges 的 max，文档同此指引）；
// minFrameDuration/maxFrameDuration 也不在该头——按 range 与 exposureDuration 表达。
- (NSDictionary *)collectSensorRanges {
    AVCaptureDeviceFormat *af = self.frontDevice.activeFormat;
    double maxFPS = 0;
    NSMutableArray *ranges = [NSMutableArray array];
    for (AVFrameRateRange *r in af.videoSupportedFrameRateRanges) {
        maxFPS = MAX(maxFPS, r.maxFrameRate);
        [ranges addObject:@{@"minFPS": @(r.minFrameRate), @"maxFPS": @(r.maxFrameRate)}];
    }
    return @{
        @"minExposureMs": @(round(CMTimeGetSeconds(af.minExposureDuration) * 1e5) / 100.0),
        @"maxExposureMs": @(round(CMTimeGetSeconds(af.maxExposureDuration) * 1e5) / 100.0),
        @"minISO": @(round((double)af.minISO * 10) / 10.0),
        @"maxISO": @(round((double)af.maxISO * 10) / 10.0),
        @"activeMaxFPS": @(maxFPS),
        @"frameRateRanges": ranges,
        // 视场角/像素合并/HDR 能力是设备指纹与画面真实性交叉核对的常用信号。
        @"videoFieldOfView": @(round((double)af.videoFieldOfView * 100) / 100),
        @"videoBinned": @(af.isVideoBinned),
        @"videoHDRSupported": @(af.isVideoHDRSupported),
    };
}

- (void)configureAndStartSession {
    self.session = [[AVCaptureSession alloc] init];
    // 零帧定位：会话级错误/打断事件只存在于这些通知里，不注册就完全不可见。
    // selector 内统一 dispatch 到 sampleQueue 改 sessionEvents（与 report 同一线程）。
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(onSessionNote:)
               name:AVCaptureSessionRuntimeErrorNotification object:self.session];
    [nc addObserver:self selector:@selector(onSessionNote:)
               name:AVCaptureSessionWasInterruptedNotification object:self.session];
    [nc addObserver:self selector:@selector(onSessionNote:)
               name:AVCaptureSessionInterruptionEndedNotification object:self.session];
    [nc addObserver:self selector:@selector(onSessionNote:)
               name:AVCaptureSessionDidStartRunningNotification object:self.session];
    [nc addObserver:self selector:@selector(onSessionNote:)
               name:AVCaptureSessionDidStopRunningNotification object:self.session];
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

    // 扩展收集：前置各 device type 可用性（3D 深度通道对 KYC liveness 是硬缺失项）。
    // 注：16.5 SDK 头没有 discoverySession.supportedDeviceTypes（本地编译实证），
    // 改为逐类型建 DiscoverySession 探测。
    NSMutableDictionary *typePresent = [NSMutableDictionary dictionary];
    for (AVCaptureDeviceType t in @[AVCaptureDeviceTypeBuiltInWideAngleCamera,
                                    AVCaptureDeviceTypeBuiltInTrueDepthCamera,
                                    AVCaptureDeviceTypeBuiltInDualCamera,
                                    AVCaptureDeviceTypeBuiltInDualWideCamera,
                                    AVCaptureDeviceTypeBuiltInTripleCamera]) {
        AVCaptureDeviceDiscoverySession *d2 =
            [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[t]
                                                                  mediaType:AVMediaTypeVideo
                                                                   position:AVCaptureDevicePositionFront];
        typePresent[t] = @(d2.devices.count > 0);
    }
    self.trueDepthInfo = @{
        @"frontTrueDepthPresent": typePresent[AVCaptureDeviceTypeBuiltInTrueDepthCamera] ?: @NO,
        @"frontTypesPresent": typePresent,
    };

    self.sampleQueue = dispatch_queue_create("vcam.probe.samples", DISPATCH_QUEUE_SERIAL);

    BOOL minimal = [[NSUserDefaults standardUserDefaults] boolForKey:@"probeMinimal"];
    // simple=1：不锁 activeFormat、保持会话默认 preset——单独测
    // "InputPriority+锁小档"是否是 iOS 18 原生路径零帧的配置原因。
    BOOL simple = [[NSUserDefaults standardUserDefaults] boolForKey:@"probeSimple"];
    self.reportMinimal = minimal;
    ((NSMutableDictionary *)self.report)[@"simpleMode"] = @(simple);
    if (!minimal) {
        self.photoOutput = [[AVCapturePhotoOutput alloc] init];
        self.photoOutputSupported = [self.session canAddOutput:self.photoOutput];
        if (self.photoOutputSupported) { [self.session addOutput:self.photoOutput]; }

        AVCaptureMetadataOutput *meta = [[AVCaptureMetadataOutput alloc] init];
        self.metaOutputSupported = [self.session canAddOutput:meta];
        if (self.metaOutputSupported) {
            [self.session addOutput:meta];
            // 人脸样本数组与帧样本共用 sampleQueue，避免跨线程改 report。
            [meta setMetadataObjectsDelegate:self queue:self.sampleQueue];
            if ([meta.availableMetadataObjectTypes containsObject:AVMetadataObjectTypeFace]) {
                meta.metadataObjectTypes = @[AVMetadataObjectTypeFace];
            }
        }

        // 扩展收集：深度通道可用性。wide-angle 前置通常 canAddOutput=NO（如实记 false）；
        // delegate 方法签名 depthDataOutput:didOutputDepthData:timestamp:connection:（SDK 头核实）。
        AVCaptureDepthDataOutput *depth = [[AVCaptureDepthDataOutput alloc] init];
        depth.alwaysDiscardsLateDepthData = YES;
        self.depthOutputSupported = [self.session canAddOutput:depth];
        if (self.depthOutputSupported) {
            self.depthOutput = depth;
            [self.session addOutput:depth];
            [depth setDelegate:self callbackQueue:self.sampleQueue];
        }
    }

    self.videoOutput = [[AVCaptureVideoDataOutput alloc] init];
    self.videoOutput.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey:
        @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)};
    self.videoOutput.alwaysDiscardsLateVideoFrames = YES;
    [self.videoOutput setSampleBufferDelegate:self queue:self.sampleQueue];
    self.videoOutputSupported = [self.session canAddOutput:self.videoOutput];
    if (self.videoOutputSupported) { [self.session addOutput:self.videoOutput]; }

    // 低档先选 640x480（近似取最接近档）；随后阶段切换用 applyFormat。
    // simple 模式跳过格式锁定（会话 preset 保持默认），见上方注释。
    if (!simple) {
        [self applyFormat:[self pickFormatNearWidth:640 height:480] label:@"low"];
    }
    self.sensorRangesSnapshot = [self collectSensorRanges];
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
            @"framesSoFar": @(me.phaseFrames),
            @"droppedSoFar": @(me.droppedVideoFrames),
            @"eventsSoFar": @(me.sessionEvents.count),
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
    self.droppedVideoFrames = 0;
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
        @"depthOutputSupported": @(self.depthOutputSupported),
        @"minimalMode": @(self.reportMinimal),
        @"sessionEvents": self.sessionEvents,  // 会话通知实时收集，报告上传时序列化
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
    [self startAltimeter];
}

// 扩展收集：CMAltimeter 相对高度/气压（iOS 8+；可用性已判断，iPhone 上通常可用）。
// 与视频流矛盾检测相关：设备静止但 IMU/气压噪声应仍非零（真实设备特征）。
- (void)startAltimeter {
    if (![CMAltimeter isRelativeAltitudeAvailable]) { return; }
    self.altimeterAvailable = YES;
    self.altimeter = [[CMAltimeter alloc] init];
    [self.altimeter startRelativeAltitudeUpdatesToQueue:self.motionQueue
                                              withHandler:^(CMAltitudeData *d, NSError *e) {
        (void)e;
        if (!d) { return; }
        double t = CFAbsoluteTimeGetCurrent() - self.startClock;
        @synchronized (self.altimeterSamples) {
            if (self.altimeterSamples.count < 40) {
                [self.altimeterSamples addObject:@{
                    @"t": @(round(t * 10000) / 10000),
                    @"altitudeM": d.relativeAltitude ?: @0,
                    @"pressureKPa": d.pressure ?: @0,
                }];
            }
        }
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

    // 扩展收集：低频采样设备实时曝光状态（AE 活跃变化的直接证据）。
    if ((self.phaseFrames - 1) % 30 == 0 && self.exposureSamples.count < 60) {
        [self sampleDeviceExposure];
    }
    // 扩展收集：Vision 人脸捕获质量+关键点（每 5 帧一次，异步不阻塞帧队列）。
    if ((self.phaseFrames - 1) % 5 == 0 && self.visionSamples.count < 120) {
        CFRetain(sb);
        __weak ProbeRunner *me = self;
        dispatch_async(self.visionQueue, ^{
            [me runVisionOnSample:sb];
            CFRelease(sb);
        });
    }
}

// 零帧定位关键：帧被管线丢弃时 didOutput 不会调用，只有这里可见
// （AVCaptureVideoDataOutput.h:261，iOS 6+）。
- (void)captureOutput:(AVCaptureOutput *)output
  didDropSampleBuffer:(CMSampleBufferRef)sb
       fromConnection:(AVCaptureConnection *)connection {
    if (output != self.videoOutput || self.phase < 0) { return; }
    self.droppedVideoFrames++;
    if (self.droppedVideoFrames == 1) {
        [self log:@"first video sample DROPPED\n"];
    }
}

// 会话级错误/打断/起止事件收集（名称均经 16.5 SDK 头 AVCaptureSession.h 核实）。
- (void)onSessionNote:(NSNotification *)note {
    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
    entry[@"event"] = note.name;
    entry[@"t"] = @(round((CFAbsoluteTimeGetCurrent() - self.startClock) * 10000) / 10000);
    NSError *err = note.userInfo[AVCaptureSessionErrorKey];
    if (err) {
        entry[@"errDomain"] = err.domain ?: @"?";
        entry[@"errCode"] = @(err.code);
        entry[@"errDesc"] = err.localizedDescription ?: @"?";
    }
    id reason = note.userInfo[AVCaptureSessionInterruptionReasonKey];
    if (reason) { entry[@"reason"] = reason; }
    [self log:[NSString stringWithFormat:@"session event: %@ reason=%@ err=%@\n",
               note.name, entry[@"reason"] ?: @"-", entry[@"errDesc"] ?: @"-"]];
    // report/sessionEvents 只在 sampleQueue 上改（与帧回调同一串行队列）。
    __weak ProbeRunner *me = self;
    dispatch_async(self.sampleQueue ?: dispatch_get_main_queue(), ^{
        [me.sessionEvents addObject:entry];
    });
}

// device.exposureDuration / ISO（iOS 8/7 公开只读属性）：正在进行的自动曝光状态。
- (void)sampleDeviceExposure {
    double durUs = CMTimeGetSeconds(self.frontDevice.exposureDuration) * 1e6;
    [self.exposureSamples addObject:@{
        @"t": @(round((CFAbsoluteTimeGetCurrent() - self.startClock) * 10000) / 10000),
        @"exposureUs": @(round(durUs * 100) / 100.0),
        @"iso": @(round((double)self.frontDevice.ISO * 10) / 10.0),
    }];
}

// VNDetectFaceCaptureQualityRequest（iOS 13）+ VNDetectFaceLandmarksRequest（iOS 11）：
// 供应商 deepfake/质量检测最常用的现成信号源。faceCaptureQuality 为 NSNumber（SDK 头核实）。
- (void)runVisionOnSample:(CMSampleBufferRef)sb {
    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCMSampleBuffer:sb options:@{}];
    VNDetectFaceCaptureQualityRequest *quality = [[VNDetectFaceCaptureQualityRequest alloc] init];
    VNDetectFaceLandmarksRequest *landmarks = [[VNDetectFaceLandmarksRequest alloc] init];
    NSError *err = nil;
    if (![handler performRequests:@[quality, landmarks] error:&err]) {
        @synchronized (self.visionSamples) {
            if (self.visionSamples.count < 3) {
                [self.visionSamples addObject:@{@"error": err.localizedDescription ?: @"vision failed"}];
            }
        }
        return;
    }
    NSMutableArray *quals = [NSMutableArray array];
    for (VNFaceObservation *o in quality.results) {
        // faceCaptureQuality 是 NSNumber(可空)；confidence 是 float（VNConfidence），不能直接 ?:。
        NSNumber *q = o.faceCaptureQuality;
        [quals addObject:q ?: @(o.confidence)];
    }
    NSMutableDictionary *entry = [@{
        @"t": @(round((CFAbsoluteTimeGetCurrent() - self.startClock) * 10000) / 10000),
        @"n": @(quality.results.count),
        @"qual": quals,
    } mutableCopy];
    VNFaceObservation *lo = landmarks.results.firstObject;
    if (lo.landmarks) {
        VNFaceLandmarks2D *lm = lo.landmarks;
        NSMutableDictionary *regions = [NSMutableDictionary dictionary];
        for (NSArray *pair in @[@[@"faceContour", lm.faceContour], @[@"leftEye", lm.leftEye],
                                @[@"rightEye", lm.rightEye], @[@"nose", lm.nose],
                                @[@"outerLips", lm.outerLips], @[@"innerLips", lm.innerLips]]) {
            VNFaceLandmarkRegion2D *r = pair[1];
            regions[pair[0]] = r ? @(r.pointCount) : @0;
        }
        entry[@"lm"] = regions;
    }
    @synchronized (self.visionSamples) {
        [self.visionSamples addObject:entry];
    }
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
        if ([o isKindOfClass:AVMetadataFaceObject.class]) {
            faces++;
            // 扩展收集：faceID（跨帧跟踪）、yaw/roll（姿态角）。读取 yawAngle/rollAngle 前
            // 必须先判断 has*（头文件明确：为 NO 时读取抛 NSGenericException）。
            if (self.faceSamples.count < 150) {
                AVMetadataFaceObject *f = (AVMetadataFaceObject *)o;
                NSMutableDictionary *d = [@{
                    @"t": @(round((CFAbsoluteTimeGetCurrent() - self.startClock) * 10000) / 10000),
                    @"id": @(f.faceID),
                    @"w": @(round(f.bounds.size.width * 1000) / 1000),
                    @"h": @(round(f.bounds.size.height * 1000) / 1000),
                } mutableCopy];
                if (f.hasYawAngle) { d[@"yaw"] = @(round(f.yawAngle * 100) / 100); }
                if (f.hasRollAngle) { d[@"roll"] = @(round(f.rollAngle * 100) / 100); }
                [self.faceSamples addObject:d];
            }
        }
    }
    if (faces > 0) { self.faceFramesThisPhase++; self.totalFaceObjects += faces; }
}

#pragma mark - depth output

- (void)depthDataOutput:(AVCaptureDepthDataOutput *)output
     didOutputDepthData:(AVDepthData *)depthData
              timestamp:(CMTime)timestamp
             connection:(AVCaptureConnection *)connection {
    (void)output; (void)connection;
    self.depthFramesTotal++;
    double ts = CMTimeGetSeconds(timestamp);
    if (self.depthFirstTs <= 0) { self.depthFirstTs = ts; }
    self.depthLastTs = ts;
    CVPixelBufferRef map = depthData.depthDataMap;
    if (map) {
        self.depthW = (int)CVPixelBufferGetWidth(map);
        self.depthH = (int)CVPixelBufferGetHeight(map);
    }
    if (!self.depthTypeStr) {
        OSType t4 = depthData.depthDataType;
        char cc[5] = {(char)((t4 >> 24) & 0xFF), (char)((t4 >> 16) & 0xFF),
                      (char)((t4 >> 8) & 0xFF), (char)(t4 & 0xFF), 0};
        self.depthTypeStr = [NSString stringWithCString:cc encoding:NSASCIIStringEncoding];
    }
}

- (void)depthDataOutput:(AVCaptureDepthDataOutput *)output
     didDropDepthData:(AVDepthData *)depthData
            timestamp:(CMTime)timestamp
           connection:(AVCaptureConnection *)connection
               reason:(AVCaptureOutputDataDroppedReason)reason {
    (void)output; (void)depthData; (void)timestamp; (void)connection; (void)reason;
    self.depthDroppedTotal++;
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
    // 扩展收集：resolvedSettings（iOS 10）。16.5 SDK 头确认该类可用成员为
    // photoDimensions/previewDimensions/embeddedThumbnailDimensions/uniqueID/flashEnabled/
    // expectedPhotoCount/photoProcessingTimeRange（无 ISO/曝光时长——那些在 device/attachment 侧采）。
    AVCaptureResolvedPhotoSettings *rs = photo.resolvedSettings;
    if (rs) {
        @try {
            photoReport[@"resolved"] = @{
                @"uniqueID": @(rs.uniqueID),
                @"photoDims": [NSString stringWithFormat:@"%dx%d",
                               rs.photoDimensions.width, rs.photoDimensions.height],
                @"previewDims": [NSString stringWithFormat:@"%dx%d",
                                 rs.previewDimensions.width, rs.previewDimensions.height],
                @"thumbDims": [NSString stringWithFormat:@"%dx%d",
                               rs.embeddedThumbnailDimensions.width, rs.embeddedThumbnailDimensions.height],
                @"flashEnabled": @(rs.isFlashEnabled),
                @"expectedPhotoCount": @(rs.expectedPhotoCount),
                @"processingStartMs": @(round(CMTimeGetSeconds(rs.photoProcessingTimeRange.start) * 1000)),
                @"processingDurMs": @(round(CMTimeGetSeconds(rs.photoProcessingTimeRange.duration) * 1000)),
            };
        } @catch (NSException *e) {
            photoReport[@"resolvedError"] = [NSString stringWithFormat:@"%@: %@", e.name, e.reason ?: @""];
        }
    }
    [self log:[NSString stringWithFormat:@"photo %dx%d exifKeys=%d\n", pw, ph, keyCount]];
}

#pragma mark - phases

- (void)finishLowPhase {
    [self finalizeCurrentSessionWithLabel:@"low"];
    // 文档标准：运行中经 lockForConfiguration + activeFormat 切到最接近 1920x1080 的格式；
    // 实际出帧维度以首帧实测为准（capturedW/H）。
    AVCaptureDeviceFormat *hi = [self pickFormatNearWidth:1920 height:1080];
    if (![[NSUserDefaults standardUserDefaults] boolForKey:@"probeSimple"]) {
        dispatch_async(self.sessionQueue, ^{ [self applyFormat:hi label:@"high"]; });
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
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self finalizeCurrentSessionWithLabel:@"high"];
    dispatch_async(self.sessionQueue, ^{ [self.session stopRunning]; });
    [self.motion stopDeviceMotionUpdates];
    if (self.altimeter) { [self.altimeter stopRelativeAltitudeUpdates]; }
    [self aggregateExtendedSamples];
    [self computeMotionStats];
    [self selfVerdicts];
    self.report[@"meta"][@"finished"] = @([NSDate date].timeIntervalSince1970);
    [self uploadReport];
    if (self.completion) { self.completion(); }
}

// 把运行期在各队列收集的扩展样本汇总进报告（finishProbe 在 sampleQueue 上，帧队列已停）。
- (void)aggregateExtendedSamples {
    NSMutableDictionary *cam = ([self.report[@"camera"] isKindOfClass:NSMutableDictionary.class]
                                ? (NSMutableDictionary *)self.report[@"camera"] : nil);
    if (cam) {
        @synchronized (self.visionSamples) { cam[@"visionSamples"] = [self.visionSamples copy]; }
    cam[@"droppedVideo"] = @(self.droppedVideoFrames);
    cam[@"sessionEventsCount"] = @(self.sessionEvents.count);
        cam[@"faceSamples"] = [self.faceSamples copy];
        cam[@"exposureSamples"] = [self.exposureSamples copy];
        if (self.maxPhotoDimsSnapshot) { cam[@"maxPhotoDims"] = self.maxPhotoDimsSnapshot; }
        if (self.trueDepthInfo) { cam[@"trueDepth"] = self.trueDepthInfo; }
        if (self.sensorRangesSnapshot) { cam[@"sensorRanges"] = self.sensorRangesSnapshot; }
        cam[@"depth"] = @{
            @"frames": @(self.depthFramesTotal),
            @"dropped": @(self.depthDroppedTotal),
            @"w": @(self.depthW),
            @"h": @(self.depthH),
            @"firstTs": @(self.depthFirstTs),
            @"lastTs": @(self.depthLastTs),
            @"type": self.depthTypeStr ?: @"",
        };
    }
    @synchronized (self.altimeterSamples) {
        self.report[@"altimeter"] = @{
            @"available": @(self.altimeterAvailable),
            @"samples": [self.altimeterSamples copy],
        };
    }
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
    NSDictionary *cam = self.report[@"camera"];
    NSInteger faceDet = [cam[@"faceSamples"] count];
    [items addObject:@{@"name": @"face_meta_detailed",
                       @"status": faceDet > 0 ? @"PASS" : @"RISK",
                       @"detail": [NSString stringWithFormat:@"faceID/yaw/roll 样本 %ld 条", (long)faceDet]}];
    NSInteger visionN = [cam[@"visionSamples"] count];
    [items addObject:@{@"name": @"vision_face_quality",
                       @"status": visionN > 0 ? @"PASS" : @"RISK",
                       @"detail": [NSString stringWithFormat:@"Vision 质量/关键点样本 %ld 条", (long)visionN]}];
    NSInteger expN = [cam[@"exposureSamples"] count];
    [items addObject:@{@"name": @"sensor_exposure_sampling",
                       @"status": expN > 0 ? @"PASS" : @"RISK",
                       @"detail": [NSString stringWithFormat:@"实时曝光/ISO 采样 %ld 条", (long)expN]}];
    BOOL tdPresent = [cam[@"trueDepth"][@"frontTrueDepthPresent"] boolValue];
    NSInteger depthFrames = [cam[@"depth"][@"frames"] integerValue];
    [items addObject:@{@"name": @"depth_channel",
                       @"status": tdPresent && depthFrames > 0 ? @"PASS" : @"NA",
                       @"detail": [NSString stringWithFormat:@"TrueDepth=%d depthFrames=%ld",
                                   (int)tdPresent, (long)depthFrames]}];
    NSInteger baroN = [self.report[@"altimeter"][@"samples"] count];
    [items addObject:@{@"name": @"barometer",
                       @"status": baroN > 0 ? @"PASS" : @"NA",
                       @"detail": [NSString stringWithFormat:@"气压样本 %ld 条", (long)baroN]}];
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

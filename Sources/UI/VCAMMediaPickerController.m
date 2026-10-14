#import "VCAMMediaPickerController.h"
#import "VCAMControlPanelViewController.h"
#import "VCAMSharedFramePreviewView.h"
#import <PhotosUI/PhotosUI.h>
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <errno.h>
#import <limits.h>
#import <math.h>
#import <notify.h>
#import <dlfcn.h>
#import <stdlib.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <unistd.h>
#import "../Core/VCAMConfiguration.h"

static const NSInteger VCAMWindowDiscoveryRetryCount = 240;
static const NSInteger VCAMFloatingDotTag = 0x5643414D;
static const int64_t VCAMOnlineMediaMaximumBytes = 2LL * 1024LL * 1024LL * 1024LL;
static const int64_t VCAMOnlineMediaReserveBytes = 256LL * 1024LL * 1024LL;
static const void *VCAMGestureTagKey = &VCAMGestureTagKey;
static const void *VCAMFloatingButtonKey = &VCAMFloatingButtonKey;
static const void *VCAMStatusIndicatorKey = &VCAMStatusIndicatorKey;
static NSString *const VCAMFloatingWindowIdentifier = @"com.codex.vcam.floatingDot";
static BOOL VCAMPickerUIStarted = NO;

static void VCAMPickerConfigurationChanged(CFNotificationCenterRef center, void *observer, CFStringRef name,
                                           const void *object, CFDictionaryRef userInfo) {
    (void)center; (void)name; (void)object; (void)userInfo;
    VCAMMediaPickerController *controller = (__bridge VCAMMediaPickerController *)observer;
    dispatch_async(dispatch_get_main_queue(), ^{ [controller performSelector:@selector(configurationDidChange)]; });
}

static const char *const VCAMAppForegroundStateNotification =
    "com.codex.vcam/app.foreground-state";
static int VCAMAppForegroundStateToken = NOTIFY_TOKEN_INVALID;

// —— 小白点状态权威化（消灭 G 轮误报）——
// 模式开关的权威源是 cameracaptured 经 notifyd 发布的 virtual-mode 状态
// （Sources/Shared/VCAMSharedFrame.m 的 VCAMPublishRequestedActiveState），
// 不再用"帧新鲜度"反推开关。帧新鲜度只区分绿/橙：
// 灰=虚拟模式关；橙=开但流不新鲜（正是 G 轮被误报掩盖的状态）；绿=开且新鲜。
static int VCAMVirtualModeActiveToken = NOTIFY_TOKEN_INVALID;
static int VCAMVirtualModeReadyToken = NOTIFY_TOKEN_INVALID;

static BOOL VCAMPublishedVirtualModeActive(void) {
    if (VCAMVirtualModeActiveToken == NOTIFY_TOKEN_INVALID ||
        VCAMVirtualModeReadyToken == NOTIFY_TOKEN_INVALID) {
        int modeToken = NOTIFY_TOKEN_INVALID;
        int readyToken = NOTIFY_TOKEN_INVALID;
        if (notify_register_check("com.codex.vcam.ios18.virtual-mode.state",
                                  &modeToken) != NOTIFY_STATUS_OK ||
            notify_register_check("com.codex.vcam.ios18.virtual-mode.ready.state",
                                  &readyToken) != NOTIFY_STATUS_OK) {
            return NO;  // 注册失败下轮重试；未发布 ready 时虚拟模式本就不可用
        }
        VCAMVirtualModeActiveToken = modeToken;
        VCAMVirtualModeReadyToken = readyToken;
    }
    uint64_t ready = 0;
    uint64_t active = 0;
    if (notify_get_state(VCAMVirtualModeReadyToken, &ready) != NOTIFY_STATUS_OK ||
        ready == 0) {
        return NO;
    }
    if (notify_get_state(VCAMVirtualModeActiveToken, &active) != NOTIFY_STATUS_OK) {
        return NO;
    }
    return active != 0;
}

static void VCAMPickerAppForegroundChanged(CFNotificationCenterRef center, void *observer,
                                           CFStringRef name, const void *object,
                                           CFDictionaryRef userInfo);

// —— 路线 2：屏幕色采样器（与小白点同宿主=SpringBoard，零 App 注入）——
// KYC"三色活体"用屏幕颜色改变环境光；该信号不经过任何相机 API，相机侧不可观测。
// SpringBoard 进程可以用 CARenderServerRenderDisplay 把当前显示渲染进全屏 CALayer，
// 取其 contents 缩采样求平均色，经 notifyd 低频发布给 cameracaptured 合成链做染色。
// 只在"虚拟模式开 && 三色调光开关开"时运行（0.5s 采样、32×32 缩采样）。
// 状态编码 state = (tick<<32) | (1<<31) | (r<<16) | (g<<8) | b：每次发布 tick+1，
// 相机侧以 tick 新鲜度判断采样器是否存活（2s 未推进=无数据，不染色）。
static int VCAMScreenTintStateToken = NOTIFY_TOKEN_INVALID;
static uint64_t VCAMScreenTintPublishTick = 0;
static BOOL VCAMScreenTintCleared = YES;

static void VCAMPublishScreenTintSample(int r, int g, int b) {
    if (VCAMScreenTintStateToken == NOTIFY_TOKEN_INVALID &&
        notify_register_check("com.codex.vcam.ios18.screen-tint.state",
                              &VCAMScreenTintStateToken) != NOTIFY_STATUS_OK) {
        return;
    }
    VCAMScreenTintPublishTick += 1;
    uint64_t encoded = (VCAMScreenTintPublishTick << 32) | (1ull << 31) |
                       ((uint64_t)(r & 0xFF) << 16) | ((uint64_t)(g & 0xFF) << 8) |
                       (uint64_t)(b & 0xFF);
    notify_set_state(VCAMScreenTintStateToken, encoded);
    VCAMScreenTintCleared = NO;
}

static void VCAMClearScreenTintState(void) {
    if (VCAMScreenTintStateToken == NOTIFY_TOKEN_INVALID || VCAMScreenTintCleared) return;
    notify_set_state(VCAMScreenTintStateToken, 0);
    VCAMScreenTintCleared = YES;
}

// 把当前显示抓进缓存的全屏 CALayer 并 32×32 缩采样求平均 RGB。
// 失败（符号缺失/contents 为空）返回 NO 并给出原因，由调用方限频记日志。
static BOOL VCAMSampleDisplayAverageRGB(int *rgbOut, NSString **failureReasonOut) {
    typedef void (*VCARRRenderDisplayIMP)(int, CFStringRef, CALayer *, int, int);
    static VCARRRenderDisplayIMP renderDisplay;
    static dispatch_once_t lookupToken;
    dispatch_once(&lookupToken, ^{
        renderDisplay =
            (VCARRRenderDisplayIMP)dlsym(RTLD_DEFAULT, "CARenderServerRenderDisplay");
    });
    if (renderDisplay == NULL) {
        if (failureReasonOut) *failureReasonOut = @"CARenderServerRenderDisplay missing";
        return NO;
    }
    CGSize pixels = CGSizeMake(UIScreen.mainScreen.bounds.size.width * UIScreen.mainScreen.scale,
                               UIScreen.mainScreen.bounds.size.height * UIScreen.mainScreen.scale);
    static CALayer *captureLayer;
    if (captureLayer == nil ||
        captureLayer.frame.size.width != pixels.width ||
        captureLayer.frame.size.height != pixels.height) {
        captureLayer = [CALayer layer];
        captureLayer.frame = CGRectMake(0, 0, pixels.width, pixels.height);
    }
    renderDisplay(0x34B, CFSTR("LCD"), captureLayer, 0, 0);  // 0x34B = kCGSServiceForDisplay
    CGImageRef displayImage = (CGImageRef)captureLayer.contents;
    if (displayImage == NULL) {
        if (failureReasonOut) *failureReasonOut = @"display layer empty";
        return NO;
    }
    enum { kSampleSide = 32 };
    unsigned char buffer[kSampleSide * kSampleSide * 4] = {0};
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(buffer, kSampleSide, kSampleSide, 8,
                                                 kSampleSide * 4, colorSpace,
                                                 kCGImageAlphaPremultipliedLast);
    if (colorSpace) CGColorSpaceRelease(colorSpace);
    if (context == NULL) {
        if (failureReasonOut) *failureReasonOut = @"bitmap context failed";
        return NO;
    }
    CGContextDrawImage(context, CGRectMake(0, 0, kSampleSide, kSampleSide), displayImage);
    CGContextRelease(context);
    unsigned long long sums[3] = {0};
    for (int i = 0; i < kSampleSide * kSampleSide; i++) {
        sums[0] += buffer[i * 4];
        sums[1] += buffer[i * 4 + 1];
        sums[2] += buffer[i * 4 + 2];
    }
    rgbOut[0] = (int)(sums[0] / (kSampleSide * kSampleSide));
    rgbOut[1] = (int)(sums[1] / (kSampleSide * kSampleSide));
    rgbOut[2] = (int)(sums[2] / (kSampleSide * kSampleSide));
    return YES;
}

static BOOL VCAMEnsureAppForegroundStateToken(void) {
    if (VCAMAppForegroundStateToken != NOTIFY_TOKEN_INVALID) return YES;
    return notify_register_check(VCAMAppForegroundStateNotification,
                                 &VCAMAppForegroundStateToken) == NOTIFY_STATUS_OK;
}

static BOOL VCAMForegroundAppIsAlive(void) {
    if (!VCAMEnsureAppForegroundStateToken()) return NO;
    uint64_t foregroundPID = 0;
    if (notify_get_state(VCAMAppForegroundStateToken, &foregroundPID) != NOTIFY_STATUS_OK ||
        foregroundPID == 0) return NO;
    errno = 0;
    if (foregroundPID <= INT_MAX &&
        (kill((pid_t)foregroundPID, 0) == 0 || errno == EPERM)) return YES;
    notify_set_state(VCAMAppForegroundStateToken, 0);
    return NO;
}

static void VCAMPickerPostAppActive(BOOL foreground) {
    if (!VCAMEnsureAppForegroundStateToken()) return;
    uint64_t currentState = 0;
    if (notify_get_state(VCAMAppForegroundStateToken, &currentState) != NOTIFY_STATUS_OK) return;
    uint64_t nextState = foreground ? (uint64_t)getpid()
        : (currentState == (uint64_t)getpid() ? 0 : currentState);
    if (nextState == currentState) return;
    if (notify_set_state(VCAMAppForegroundStateToken, nextState) == NOTIFY_STATUS_OK) {
        notify_post(VCAMAppForegroundStateNotification);
    }
}

static BOOL VCAMIsSupportedMediaExtension(NSString *extension) {
    static NSSet<NSString *> *extensions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        extensions = [NSSet setWithArray:
            @[@"mov", @"mp4", @"m4v", @"png", @"jpg", @"jpeg", @"heic", @"heif"]];
    });
    return [extensions containsObject:extension.lowercaseString ?: @""];
}

static int64_t VCAMAvailableImportantStorageBytes(void) {
    NSNumber *available = nil;
    [[NSURL fileURLWithPath:NSTemporaryDirectory()] getResourceValue:&available
        forKey:NSURLVolumeAvailableCapacityForImportantUsageKey error:nil];
    return available.longLongValue;
}

static NSString *VCAMConcreteProviderTypeIdentifier(NSItemProvider *provider, UTType *mediaKind) {
    NSString *fallbackIdentifier = nil;
    NSString *supportedIdentifier = nil;
    NSString *preferredExtension = provider.suggestedName.pathExtension.lowercaseString;
    for (NSString *identifier in provider.registeredTypeIdentifiers) {
        UTType *registeredType = [UTType typeWithIdentifier:identifier];
        if (registeredType == nil || ![registeredType conformsToType:mediaKind]) continue;
        if (fallbackIdentifier == nil) fallbackIdentifier = identifier;
        NSString *extension = registeredType.preferredFilenameExtension.lowercaseString;
        if (!VCAMIsSupportedMediaExtension(extension)) continue;
        if (supportedIdentifier == nil) supportedIdentifier = identifier;
        if (preferredExtension.length > 0 &&
            [extension isEqualToString:preferredExtension]) return identifier;
    }
    return supportedIdentifier ?: fallbackIdentifier ?: mediaKind.identifier;
}

static NSString *VCAMNormalizedMediaName(NSString *suggestedName,
                                         NSURL *temporaryURL,
                                         NSString *typeIdentifier) {
    NSString *extension = temporaryURL.pathExtension.lowercaseString;
    UTType *mediaType = [UTType typeWithIdentifier:typeIdentifier];
    if (!VCAMIsSupportedMediaExtension(extension)) {
        extension = mediaType.preferredFilenameExtension.lowercaseString;
    }
    if (!VCAMIsSupportedMediaExtension(extension)) {
        extension = suggestedName.pathExtension.lowercaseString;
    }

    NSString *baseName = suggestedName.lastPathComponent.stringByDeletingPathExtension;
    if (baseName.length == 0) {
        baseName = temporaryURL.lastPathComponent.stringByDeletingPathExtension;
    }
    if (baseName.length == 0) baseName = @"selected";
    return VCAMIsSupportedMediaExtension(extension)
        ? [baseName stringByAppendingPathExtension:extension]
        : (suggestedName.lastPathComponent ?: temporaryURL.lastPathComponent ?: @"selected.mov");
}

@interface VCAMMediaPickerController () <PHPickerViewControllerDelegate,
                                          UIDocumentPickerDelegate,
                                          NSURLSessionDownloadDelegate,
                                          VCAMControlPanelDelegate,
                                          UIGestureRecognizerDelegate>
@property(nonatomic, strong, nullable) UIButton *button;
@property(nonatomic, weak, nullable) VCAMControlPanelViewController *panel;
@property(nonatomic, weak, nullable) UIWindow *gestureWindow;
@property(nonatomic, strong, nullable) UIWindow *floatingWindow;
@property(nonatomic) NSInteger remainingWindowRetries;
@property(nonatomic) BOOL started;
@property(nonatomic) BOOL lastKnownLockedState;
@property(nonatomic) BOOL hostResignedActive;
@property(nonatomic) NSUInteger mediaSelectionGeneration;
@property(atomic, strong, nullable) NSURLSession *onlineDownloadSession;
@property(atomic, strong, nullable) NSURLSessionDownloadTask *onlineDownloadTask;
@property(atomic) NSUInteger onlineDownloadGeneration;
@property(atomic, copy, nullable) NSString *onlineDownloadLimitError;
- (void)installButtonWhenWindowIsReady;
- (void)presentStreamChooser;
- (BOOL)applyStreamURL:(NSURL *)url;
- (void)rememberStreamURL:(NSString *)urlString;
- (void)removeStreamURL:(NSString *)urlString;
- (void)presentStreamManager;
- (void)presentEditDeleteForStreamURL:(NSString *)urlString;
- (void)promptForLiveStreamReplacingURL:(NSString *)replacingURL;
- (nullable NSString *)currentStreamURLFromValues:(NSDictionary *)values;
@end

static void VCAMPickerAppForegroundChanged(CFNotificationCenterRef center, void *observer,
                                           CFStringRef name, const void *object,
                                           CFDictionaryRef userInfo) {
    (void)center; (void)object; (void)userInfo;
    VCAMMediaPickerController *controller = (__bridge VCAMMediaPickerController *)observer;
    (void)name;
    BOOL foregroundAppActive = VCAMForegroundAppIsAlive();
    dispatch_async(dispatch_get_main_queue(), ^{
        controller.hostResignedActive = foregroundAppActive;
        [controller installButtonWhenWindowIsReady];
    });
}

@implementation VCAMMediaPickerController

+ (instancetype)sharedController {
    static VCAMMediaPickerController *controller;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ controller = [VCAMMediaPickerController new]; });
    return controller;
}

- (void)startControlUI {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (VCAMPickerUIStarted) return;
        VCAMPickerUIStarted = YES;
        self.started = YES;
        self.remainingWindowRetries = VCAMWindowDiscoveryRetryCount;
        [VCAMConfiguration appendProcessLog:
            [NSString stringWithFormat:@"springboard-client startControlUI host=%@ started=1",
                NSProcessInfo.processInfo.processName ?: @"(unknown)"]];
        NSNotificationCenter *notifications = NSNotificationCenter.defaultCenter;
        [notifications addObserver:self selector:@selector(applicationDidBecomeActive:)
                              name:UIApplicationDidBecomeActiveNotification object:nil];
        [notifications addObserver:self selector:@selector(applicationWillResignActive:)
                              name:UIApplicationWillResignActiveNotification object:nil];
        [notifications addObserver:self selector:@selector(keyWindowDidChange:)
                              name:UIWindowDidBecomeKeyNotification object:nil];
        [notifications addObserver:self selector:@selector(applicationDidBecomeActive:)
                              name:UISceneDidActivateNotification object:nil];
        [notifications addObserver:self selector:@selector(applicationWillResignActive:)
                              name:UISceneWillDeactivateNotification object:nil];
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        (__bridge const void *)self,
                                        VCAMPickerConfigurationChanged,
                                        CFSTR("com.codex.vcam/preferences.changed"), NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        if ([self isSpringBoardHost]) {
            VCAMEnsureAppForegroundStateToken();
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                            (__bridge const void *)self,
                                            VCAMPickerAppForegroundChanged,
                                            CFSTR("com.codex.vcam/app.foreground-state"),
                                            NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
            VCAMPickerAppForegroundChanged(NULL, (__bridge void *)self, NULL, NULL, NULL);
            [self startScreenTintSampler];
        }
        [self installButtonWhenWindowIsReady];
        [self startStatusRefresh];
        if (![self isSpringBoardHost] &&
            UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
            VCAMPickerPostAppActive(YES);
        }
    });
}

// 屏幕色采样循环（仅 SpringBoard 宿主）：0.5s 一次；开关/模式不满足时发布
// 一次"清零"（valid=0）后空转，不重复写。诊断日志只在色变跳变或 30s 心跳时写。
- (void)startScreenTintSampler {
    static const NSTimeInterval sampleInterval = 0.5;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(sampleInterval * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!VCAMPickerUIStarted || !self.started) return;
        if ([self isSpringBoardHost]) {
            BOOL enabled = [[VCAMConfiguration currentValues][@"screenTintEnabled"] boolValue];
            if (enabled && VCAMPublishedVirtualModeActive()) {
                int rgb[3] = {0, 0, 0};
                NSString *failureReason = nil;
                if (VCAMSampleDisplayAverageRGB(rgb, &failureReason)) {
                    VCAMPublishScreenTintSample(rgb[0], rgb[1], rgb[2]);
                    static int lastLoggedRGB[3] = {-1, -1, -1};
                    static CFAbsoluteTime lastSampleLoggedAt = 0;
                    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
                    int delta = abs(rgb[0] - lastLoggedRGB[0]) +
                                abs(rgb[1] - lastLoggedRGB[1]) +
                                abs(rgb[2] - lastLoggedRGB[2]);
                    if (delta > 24 || now - lastSampleLoggedAt > 30.0) {
                        lastLoggedRGB[0] = rgb[0];
                        lastLoggedRGB[1] = rgb[1];
                        lastLoggedRGB[2] = rgb[2];
                        lastSampleLoggedAt = now;
                        [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
                            @"screen-tint sample rgb=%d,%d,%d", rgb[0], rgb[1], rgb[2]]];
                    }
                } else {
                    static CFAbsoluteTime lastFailureLoggedAt = 0;
                    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
                    if (now - lastFailureLoggedAt > 30.0) {
                        lastFailureLoggedAt = now;
                        [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
                            @"screen-tint sampler unavailable reason=%@",
                            failureReason ?: @"unknown"]];
                    }
                    VCAMClearScreenTintState();
                }
            } else {
                VCAMClearScreenTintState();
            }
        }
        [self startScreenTintSampler];
    });
}

- (void)startStatusRefresh {
    static const NSTimeInterval refreshInterval = 2.0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(refreshInterval * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!VCAMPickerUIStarted || !self.started) return;
        // Refresh only the tiny stream indicator. The dot itself is installed
        // on notifications/config changes; re-installing it every second
        // caused duplicate dots and gesture/panel races.
        [self updateFloatingStatusIndicator];
        if ([self isSpringBoardHost]) {
            BOOL foregroundAppActive = VCAMForegroundAppIsAlive();
            if (foregroundAppActive != self.hostResignedActive) {
                self.hostResignedActive = foregroundAppActive;
                [self installButtonWhenWindowIsReady];
            }
            BOOL locked = ![self isSpringBoardUnlocked];
            if (locked != self.lastKnownLockedState) {
                self.lastKnownLockedState = locked;
                [self installButtonWhenWindowIsReady];
            }
        }
        [self startStatusRefresh];
    });
}

- (void)configurationDidChange {
    self.remainingWindowRetries = VCAMWindowDiscoveryRetryCount;
    [self installButtonWhenWindowIsReady];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    (void)notification;
    self.hostResignedActive = NO;
    if (![self isSpringBoardHost]) VCAMPickerPostAppActive(YES);
    [VCAMConfiguration appendProcessLog:
        [NSString stringWithFormat:@"ui became-active host=%@",
            NSProcessInfo.processInfo.processName ?: @"(unknown)"]];
    self.remainingWindowRetries = VCAMWindowDiscoveryRetryCount;
    [self installButtonWhenWindowIsReady];
}

- (void)keyWindowDidChange:(NSNotification *)notification {
    (void)notification;
    // A window becoming key (system alert, text input, etc.) must not clear
    // the background flag; only real application/scene activation does.
    self.remainingWindowRetries = VCAMWindowDiscoveryRetryCount;
    [self installButtonWhenWindowIsReady];
}

- (void)applicationWillResignActive:(NSNotification *)notification {
    (void)notification;
    self.hostResignedActive = YES;
    if (![self isSpringBoardHost]) VCAMPickerPostAppActive(NO);
    [VCAMConfiguration appendProcessLog:
        [NSString stringWithFormat:@"ui resign-active host=%@",
            NSProcessInfo.processInfo.processName ?: @"(unknown)"]];
    // When an injected app (Camera, browser) comes to the foreground,
    // SpringBoard must hide its own floating dot so the device never shows
    // two dots. The app's own controller shows the dot for its process.
    [self installButtonWhenWindowIsReady];
}

- (nullable UIWindow *)keySceneWindow {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        for (UIWindow *window in windowScene.windows) {
            if (window.isKeyWindow && !window.hidden) return window;
        }
    }
    return nil;
}

- (nullable UIWindow *)springBoardHomeWindow {
    if (![self isSpringBoardHost]) return nil;
    Class iconControllerClass = NSClassFromString(@"SBIconController");
    SEL sharedSelector = NSSelectorFromString(@"sharedInstance");
    if (iconControllerClass != Nil && [iconControllerClass respondsToSelector:sharedSelector]) {
        id iconController = ((id (*)(id, SEL))objc_msgSend)(iconControllerClass, sharedSelector);
        SEL viewSelector = NSSelectorFromString(@"view");
        if ([iconController respondsToSelector:viewSelector]) {
            UIView *view = ((id (*)(id, SEL))objc_msgSend)(iconController, viewSelector);
            if ([view isKindOfClass:UIView.class] && view.window != nil) return view.window;
        }
    }
    SEL windowsSelector = NSSelectorFromString(@"windows");
    NSArray<UIWindow *> *legacyWindows = [UIApplication.sharedApplication respondsToSelector:windowsSelector]
        ? ((id (*)(id, SEL))objc_msgSend)(UIApplication.sharedApplication, windowsSelector) : @[];
    for (UIWindow *window in legacyWindows) {
        if (!window.hidden && window.windowLevel == UIWindowLevelNormal && window.rootViewController != nil) return window;
    }
    return nil;
}

- (nullable UIWindow *)cameraWindow {
    UIWindow *springBoardWindow = [self springBoardHomeWindow];
    if (springBoardWindow != nil) return springBoardWindow;
    UIWindow *anyKeyWindow = nil;
    UIWindow *anyVisibleWindow = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        BOOL active = scene.activationState == UISceneActivationStateForegroundActive ||
                      scene.activationState == UISceneActivationStateForegroundInactive;
        for (UIWindow *window in windowScene.windows) {
            if (window == nil || window.hidden ||
                [window.accessibilityIdentifier isEqualToString:VCAMFloatingWindowIdentifier]) continue;
            if (window.isKeyWindow) {
                if (active) return window;
                if (anyKeyWindow == nil) anyKeyWindow = window;
            }
            if (anyVisibleWindow == nil && window.rootViewController != nil &&
                window.windowLevel >= UIWindowLevelNormal) anyVisibleWindow = window;
        }
    }
    if (anyKeyWindow != nil) return anyKeyWindow;
    if (anyVisibleWindow != nil) return anyVisibleWindow;
    return [self keySceneWindow];
}

- (NSArray<UIWindow *> *)allVisibleWindows {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    SEL windowsSelector = NSSelectorFromString(@"windows");
    NSArray *legacyWindows = [UIApplication.sharedApplication respondsToSelector:windowsSelector]
        ? ((id (*)(id, SEL))objc_msgSend)(UIApplication.sharedApplication, windowsSelector) : @[];
    for (UIWindow *window in legacyWindows) {
        NSNumber *key = @((unsigned long)(__bridge void *)window);
        if (window == nil || [seen containsObject:key]) continue;
        [seen addObject:key];
        [windows addObject:window];
    }
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            NSNumber *key = @((unsigned long)(__bridge void *)window);
            if (window == nil || [seen containsObject:key]) continue;
            [seen addObject:key];
            [windows addObject:window];
        }
    }
    return windows;
}

- (nullable UIWindow *)floatingDotWindow {
    if (self.floatingWindow != nil) return self.floatingWindow;
    // Adopt an existing floating window (created by an earlier controller
    // instance in this process, e.g. after a duplicate dylib load) instead of
    // stacking a second dot. All controller instances then share one window.
    for (UIWindow *candidate in [self allVisibleWindows]) {
        if ([candidate.accessibilityIdentifier isEqualToString:VCAMFloatingWindowIdentifier]) {
            if (candidate.rootViewController == nil) {
                UIViewController *rootController = [UIViewController new];
                rootController.view.backgroundColor = UIColor.clearColor;
                candidate.rootViewController = rootController;
            }
            self.floatingWindow = candidate;
            return candidate;
        }
    }
    UIWindowScene *windowScene = [self cameraWindow].windowScene;
    UIWindow *window = windowScene != nil
        ? [[UIWindow alloc] initWithWindowScene:windowScene]
        : [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, 52.0, 52.0)];
    window.frame = CGRectMake(0, 0, 52.0, 52.0);
    window.accessibilityIdentifier = VCAMFloatingWindowIdentifier;
    // Keep the dot above presented sheets/pickers so it can toggle the panel,
    // but below system alerts, Control Center and the lock screen.
    window.windowLevel = UIWindowLevelStatusBar + 1.0;
    window.backgroundColor = UIColor.clearColor;
    UIViewController *rootController = [UIViewController new];
    rootController.view.backgroundColor = UIColor.clearColor;
    window.rootViewController = rootController;
    window.hidden = YES;
    self.floatingWindow = window;
    return window;
}

- (UIButton *)makeFloatingButton {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.tag = VCAMFloatingDotTag;
    button.accessibilityLabel = @"打开 VCAM 控制面板";
    button.backgroundColor = UIColor.clearColor;
    UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(4.0, 4.0, 44.0, 44.0)];
    dot.userInteractionEnabled = NO;
    dot.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.5];
    dot.layer.cornerRadius = 22.0;
    dot.layer.borderWidth = 1.0;
    dot.layer.borderColor = [UIColor colorWithWhite:0.35 alpha:0.45].CGColor;
    dot.layer.shadowColor = UIColor.blackColor.CGColor;
    dot.layer.shadowOpacity = 0.35;
    dot.layer.shadowRadius = 4.0;
    dot.layer.shadowOffset = CGSizeMake(0, 1);
    [button addSubview:dot];
    UIView *statusIndicator = [[UIView alloc] initWithFrame:CGRectMake(34.0, 4.0, 10.0, 10.0)];
    statusIndicator.layer.cornerRadius = 5.0;
    statusIndicator.layer.borderWidth = 1.0;
    statusIndicator.layer.borderColor = UIColor.whiteColor.CGColor;
    statusIndicator.backgroundColor = [UIColor colorWithWhite:0.55 alpha:0.5];
    statusIndicator.userInteractionEnabled = NO;
    statusIndicator.accessibilityIdentifier = @"com.codex.vcam.streamIndicator";
    [button addSubview:statusIndicator];
    objc_setAssociatedObject(button, VCAMStatusIndicatorKey, statusIndicator,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    button.layer.shadowColor = UIColor.blackColor.CGColor;
    UITapGestureRecognizer *singleTap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                               action:@selector(showSourceMenu:)];
    singleTap.numberOfTapsRequired = 1;
    singleTap.numberOfTouchesRequired = 1;
    [button addGestureRecognizer:singleTap];
    UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                               action:@selector(toggleFloatingButton:)];
    doubleTap.numberOfTapsRequired = 2;
    doubleTap.numberOfTouchesRequired = 1;
    [button addGestureRecognizer:doubleTap];
    [singleTap requireGestureRecognizerToFail:doubleTap];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                          action:@selector(dragButton:)];
    pan.maximumNumberOfTouches = 1;
    [button addGestureRecognizer:pan];
    return button;
}

- (UIButton *)floatingButton {
    if (self.floatingWindow == nil) return nil;
    UIButton *button = objc_getAssociatedObject(self.floatingWindow,
                                                VCAMFloatingButtonKey);
    if (button != nil) return button;
    button = [self makeFloatingButton];
    objc_setAssociatedObject(self.floatingWindow, VCAMFloatingButtonKey, button,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return button;
}

- (UITapGestureRecognizer *)makeThreeFingerToggleRecognizer {
    UITapGestureRecognizer *toggle = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                            action:@selector(toggleFloatingButton:)];
    objc_setAssociatedObject(toggle, VCAMGestureTagKey, @(VCAMFloatingDotTag),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    toggle.numberOfTouchesRequired = 3;
    toggle.numberOfTapsRequired = 2;
    toggle.cancelsTouchesInView = NO;
    toggle.delegate = self;
    return toggle;
}

- (void)installGestureOnWindowIfNeeded:(UIWindow *)window {
    if (window == nil) return;
    for (UIGestureRecognizer *recognizer in [window.gestureRecognizers copy]) {
        NSNumber *gestureTag = objc_getAssociatedObject(recognizer, VCAMGestureTagKey);
        if ([gestureTag integerValue] == VCAMFloatingDotTag) return;
    }
    UITapGestureRecognizer *toggle = [self makeThreeFingerToggleRecognizer];
    [window addGestureRecognizer:toggle];
    [VCAMConfiguration appendProcessLog:
        [NSString stringWithFormat:@"springboard-client gesture installed on window=%@ bounds=%@",
            window, NSStringFromCGRect(window.bounds)]];
}

- (void)removeLegacyFloatingDots {
    // Defense in depth against a duplicate controller instance leaving a
    // second dot behind (for example after a re-injection with a different
    // dylib path). Only our own floating window may keep the button.
    for (UIWindow *window in [self allVisibleWindows]) {
        if (window == self.floatingWindow) continue;
        if ([window.accessibilityIdentifier isEqualToString:VCAMFloatingWindowIdentifier]) {
            window.hidden = YES;
        }
        for (UIView *view in [window.subviews copy]) {
            if (view != [self floatingButton] && view.tag == VCAMFloatingDotTag) {
                [view removeFromSuperview];
            }
        }
    }
}

- (NSString *)floatingPositionIdentifier {
    NSString *bundle = NSBundle.mainBundle.bundleIdentifier;
    return bundle.length > 0 ? bundle : NSProcessInfo.processInfo.processName;
}

- (BOOL)isSpringBoardHost {
    return [NSProcessInfo.processInfo.processName.lowercaseString isEqualToString:@"springboard"];
}

- (BOOL)isSpringBoardUnlocked {
    if (![self isSpringBoardHost]) return YES;
    Class managerClass = NSClassFromString(@"SBLockScreenManager");
    SEL sharedSelector = NSSelectorFromString(@"sharedInstance");
    SEL lockedSelector = NSSelectorFromString(@"isUILocked");
    if (managerClass == Nil || ![managerClass respondsToSelector:sharedSelector]) return YES;
    id manager = ((id (*)(id, SEL))objc_msgSend)(managerClass, sharedSelector);
    if (![manager respondsToSelector:lockedSelector]) return YES;
    return !((BOOL (*)(id, SEL))objc_msgSend)(manager, lockedSelector);
}

- (BOOL)isFloatingButtonVisibleForValues:(NSDictionary<NSString *, id> *)values {
    NSDictionary *visibility = values[@"floatingButtonVisibility"];
    NSNumber *saved = [visibility isKindOfClass:NSDictionary.class]
        ? visibility[@"global"] : nil;
    if (saved == nil && [visibility isKindOfClass:NSDictionary.class]) {
        saved = visibility[[self floatingPositionIdentifier]];
    }
    return saved == nil ? YES : saved.boolValue;
}

- (nullable NSValue *)savedFloatingButtonCenterForWindow:(UIWindow *)window {
    NSDictionary *positions = [VCAMConfiguration currentValues][@"floatingButtonPositions"];
    NSDictionary *position = [positions isKindOfClass:NSDictionary.class]
        ? positions[[self floatingPositionIdentifier]] : nil;
    if (![position isKindOfClass:NSDictionary.class]) return nil;
    CGFloat x = [position[@"x"] doubleValue];
    CGFloat y = [position[@"y"] doubleValue];
    if (x <= 0 || x >= 1 || y <= 0 || y >= 1) return nil;
    CGFloat width = CGRectGetWidth(window.bounds);
    CGFloat height = CGRectGetHeight(window.bounds);
    if (width <= 0 || height <= 0) return nil;
    // Older builds saved the button's fixed (26,26) center instead of the
    // floating window center, pinning every host to the top-left on restart.
    CGFloat legacyTopLeftX = 26.0 / width;
    CGFloat legacyTopLeftY = 26.0 / height;
    if (fabs(x - legacyTopLeftX) < 0.005 && fabs(y - legacyTopLeftY) < 0.005) return nil;
    return [NSValue valueWithCGPoint:CGPointMake(x * width, y * height)];
}

- (void)saveFloatingButtonPositionInWindow:(UIWindow *)window {
    if (self.button == nil || CGRectGetWidth(window.bounds) <= 0 || CGRectGetHeight(window.bounds) <= 0) return;
    NSMutableDictionary *positions =
        [[VCAMConfiguration currentValues][@"floatingButtonPositions"] mutableCopy] ?: [NSMutableDictionary dictionary];
    positions[[self floatingPositionIdentifier]] = @{
        @"x": @(self.floatingWindow.center.x / CGRectGetWidth(window.bounds)),
        @"y": @(self.floatingWindow.center.y / CGRectGetHeight(window.bounds)),
    };
    [self updatePreferences:@{@"floatingButtonPositions": positions}];
}

- (void)installButtonWhenWindowIsReady {
    NSAssert(NSThread.isMainThread, @"VCAM picker UI must run on the main thread");
    UIWindow *window = [self cameraWindow];
    if (window == nil) {
        if (self.remainingWindowRetries-- > 0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [self installButtonWhenWindowIsReady]; });
        }
        // The periodic SpringBoard refresh keeps polling if retries run out.
        return;
    }
    UIWindow *floatingWindow = [self floatingDotWindow];
    if (floatingWindow.windowScene == nil && window.windowScene != nil) {
        floatingWindow.windowScene = window.windowScene;
    }
    // Three-finger double-tap must work regardless of which window is on top.
    // Install on the host window and the floating window only; installing on
    // every visible window each second caused gesture conflicts.
    [self installGestureOnWindowIfNeeded:window];
    [self installGestureOnWindowIfNeeded:floatingWindow];
    UIWindow *keyWindow = [self keySceneWindow];
    if (keyWindow != nil && keyWindow != window && keyWindow != floatingWindow) {
        [self installGestureOnWindowIfNeeded:keyWindow];
    }
    [self removeLegacyFloatingDots];

    UIButton *button = [self floatingButton];
    self.button = button;
    if (button == nil) return;

    UIView *floatingContentView = floatingWindow.rootViewController.view;
    if (button.superview != floatingContentView) {
        [button removeFromSuperview];
        button.frame = floatingContentView.bounds;
        floatingWindow.frame = CGRectMake(10.0, CGRectGetMidY(window.bounds) - 26.0, 52.0, 52.0);
        NSValue *savedCenter = [self savedFloatingButtonCenterForWindow:window];
        if (savedCenter != nil) floatingWindow.center = savedCenter.CGPointValue;
        [floatingContentView addSubview:button];
    }
    NSDictionary *values = [VCAMConfiguration currentValues];
    BOOL locked = [self isSpringBoardHost] && ![self isSpringBoardUnlocked];
    BOOL panelOpen = self.panel != nil || [self panelIsPresented];
    // SpringBoard must not render its dot above a foreground injected app
    // (duplicate dots), and the dot must not hover over the open panel and
    // eat control taps.
    // SpringBoard can report Active even while an injected app is in the
    // foreground, so the resign-active notifications drive the visibility.
    // 全局悬浮点开关（缺省 YES）：注入 filter 已收缩为仅 SpringBoard，
    // 全局点必须在前台 App 上也保持可见，所有软件才有悬浮窗；
    // hostInactive 强制视为 NO。面板打开（panelOpen）与锁屏（locked）
    // 的抑制保持不变。显式写 floatingDotGlobal=false 才回到旧行为。
    BOOL floatingDotGlobal = [self isSpringBoardHost] &&
        (![values[@"floatingDotGlobal"] isKindOfClass:NSNumber.class] ||
         [values[@"floatingDotGlobal"] boolValue]);
    BOOL hostInactive = !floatingDotGlobal && (self.hostResignedActive ||
        ([self isSpringBoardHost] &&
         UIApplication.sharedApplication.applicationState != UIApplicationStateActive));
    BOOL visible = [self isFloatingButtonVisibleForValues:values] &&
        !locked && !panelOpen && !hostInactive;
    floatingWindow.hidden = !visible;
    button.hidden = NO;
    [floatingContentView bringSubviewToFront:button];
    [VCAMConfiguration appendProcessLog:
        [NSString stringWithFormat:@"springboard-client installButton host=%@ hostWindow=%@ floatingWindow=%@ hidden=%d frame=%@",
            NSProcessInfo.processInfo.processName ?: @"(unknown)",
            window, floatingWindow, floatingWindow.hidden ? 1 : 0,
            NSStringFromCGRect(floatingWindow.frame)]];
}

- (void)updateFloatingStatusIndicator {
    UIButton *button = [self floatingButton];
    UIView *indicator = button == nil ? nil
        : objc_getAssociatedObject(button, VCAMStatusIndicatorKey);
    if (indicator == nil || indicator.superview == nil) return;
    if (!VCAMPublishedVirtualModeActive()) {
        indicator.backgroundColor = [UIColor colorWithWhite:0.55 alpha:1.0];
        return;
    }
    NSDictionary *stream = [VCAMSharedFramePreviewView streamingStatus];
    BOOL receiving = [stream[@"receiving"] boolValue];
    indicator.backgroundColor = receiving
        ? [UIColor colorWithRed:0.20 green:0.85 blue:0.35 alpha:1.0]
        : [UIColor colorWithRed:0.98 green:0.65 blue:0.15 alpha:1.0];
}

- (void)toggleFloatingButton:(UITapGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateRecognized || UIAccessibilityIsVoiceOverRunning()) return;
    static CFTimeInterval lastToggleHostTime = 0;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - lastToggleHostTime < 0.6) {
        [VCAMConfiguration appendProcessLog:
            @"ui three-finger toggle ignored as duplicate"];
        return;
    }
    lastToggleHostTime = now;
    [VCAMConfiguration appendProcessLog:
        [NSString stringWithFormat:@"ui three-finger toggle fired host=%@ touches=%lu taps=%lu",
            NSProcessInfo.processInfo.processName ?: @"(unknown)",
            (unsigned long)recognizer.numberOfTouches,
            (unsigned long)recognizer.numberOfTapsRequired]];
    NSDictionary *values = [VCAMConfiguration currentValues];
    NSMutableDictionary *visibility = [values[@"floatingButtonVisibility"] mutableCopy]
        ?: [NSMutableDictionary dictionary];
    BOOL currentlyVisible = [self isFloatingButtonVisibleForValues:values];
    visibility[@"global"] = @(!currentlyVisible);
    if (![self updatePreferences:@{@"floatingButtonVisibility": visibility}]) {
        [self showMessage:@"主屏配置服务不可用" error:YES];
        return;
    }
    [self configurationDidChange];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    NSNumber *gestureTag = objc_getAssociatedObject(gestureRecognizer, VCAMGestureTagKey);
    NSNumber *otherTag = objc_getAssociatedObject(otherGestureRecognizer, VCAMGestureTagKey);
    return gestureTag.integerValue == VCAMFloatingDotTag ||
        otherTag.integerValue == VCAMFloatingDotTag;
}

- (void)dragButton:(UIPanGestureRecognizer *)recognizer {
    UIWindow *floatingWindow = self.floatingWindow;
    UIWindow *window = [self cameraWindow];
    if (floatingWindow == nil || window == nil) return;
    CGPoint translation = [recognizer translationInView:floatingWindow];
    CGPoint center = CGPointMake(floatingWindow.center.x + translation.x,
                                 floatingWindow.center.y + translation.y);
    [recognizer setTranslation:CGPointZero inView:floatingWindow];
    UIEdgeInsets safe = window.safeAreaInsets;
    CGFloat radius = 26.0;
    center.x = MAX(safe.left + radius + 4, MIN(CGRectGetWidth(window.bounds) - safe.right - radius - 4, center.x));
    center.y = MAX(safe.top + radius + 4, MIN(CGRectGetHeight(window.bounds) - safe.bottom - radius - 4, center.y));
    floatingWindow.center = center;
    if (recognizer.state == UIGestureRecognizerStateEnded ||
        recognizer.state == UIGestureRecognizerStateCancelled) {
        [self saveFloatingButtonPositionInWindow:window];
    }
}

- (nullable UIViewController *)presentingViewController {
    UIViewController *controller = [self cameraWindow].rootViewController;
    while (controller.presentedViewController != nil) controller = controller.presentedViewController;
    if ([controller isKindOfClass:UINavigationController.class]) {
        controller = ((UINavigationController *)controller).visibleViewController;
    }
    if ([controller isKindOfClass:UITabBarController.class]) {
        controller = ((UITabBarController *)controller).selectedViewController;
    }
    return controller;
}

- (NSDictionary<NSString *, NSString *> *)currentStatus {
    NSDictionary *values = [VCAMConfiguration currentValues];
    BOOL enabled = [values[@"enabled"] boolValue];
    NSString *source = [values[@"source"] lowercaseString] ?: @"camera";
    BOOL staticImage = enabled && [source isEqualToString:@"local"] &&
        !VCAMMediaPathIsVideo(values[@"mediaPath"]);
    NSString *sourceTitle = @"真实相机（未替换）";
    NSString *detail = @"vcamd 未发布替换画面；真实相机保持可用";
    if (enabled && [source isEqualToString:@"local"]) {
        NSString *file = [values[@"mediaPath"] lastPathComponent] ?: @"本地媒体";
        sourceTitle = [NSString stringWithFormat:@"本地图片/视频：%@", file];
        detail = @"";
    } else if (enabled && [source isEqualToString:@"obs"]) {
        sourceTitle = @"OBS WebSocket 已启用";
        detail = values[@"obsWebSocketURL"] ?: @"未设置地址";
    } else if (enabled && [source isEqualToString:@"hls"]) {
        sourceTitle = @"HLS 原生播放已启用";
        detail = values[@"hlsURL"] ?: @"未配置地址";
    } else if (enabled && [source isEqualToString:@"rtsp"]) {
        sourceTitle = @"RTSP 软件解码已启用";
        detail = values[@"rtspURL"] ?: @"未设置地址";
    }
    NSInteger rotation = [values[@"rotationDegrees"] integerValue] % 360;
    NSString *mode = [values[@"contentMode"] lowercaseString] ?: @"fill";
    NSDictionary *modeNames = @{@"fit": @"完整显示", @"fill": @"裁切填满", @"stretch": @"拉伸"};
    NSDictionary *streamStatus = [VCAMSharedFramePreviewView streamingStatus];
    detail = [detail stringByAppendingFormat:@"\n旋转：%ld°", (long)rotation];
    if (staticImage) {
        detail = [detail stringByAppendingString:@"\n静态图片"];
    } else {
        detail = [detail stringByAppendingFormat:@" · 实测：%.1f fps",
                  [streamStatus[@"fps"] doubleValue]];
    }
    NSString *streamText = nil;
    if (staticImage) {
        streamText = @"已加载静态图片";
        if (![streamStatus[@"receiving"] boolValue]) streamText = @"静态图片未就绪";
    } else if ([streamStatus[@"receiving"] boolValue]) {
        NSString *playbackKind = @"原始帧";
        if ([source isEqualToString:@"rtsp"]) {
            playbackKind = @"FFmpeg 软件解码";
        } else if ([source isEqualToString:@"hls"] ||
                   [source isEqualToString:@"local"]) {
            // AVPlayer does not expose a public per-playback hardware-decoder
            // verdict on iOS 16. Do not turn native playback into a false
            // hardware/software claim in the user-visible status.
            playbackKind = @"系统原生播放";
        }
        streamText = [NSString stringWithFormat:@"已收到推流（%@，%.0f ms 前）",
            playbackKind, [streamStatus[@"ageMs"] doubleValue]];
    } else {
        streamText = @"未收到推流";
    }
    return @{
        @"source": sourceTitle,
        @"detail": detail,
        @"mirror": [values[@"mirrorHorizontally"] boolValue] ? @"开启" : @"关闭",
        @"loop": values[@"loopMedia"] == nil || [values[@"loopMedia"] boolValue] ? @"开启" : @"关闭",
        @"screenTint": [values[@"screenTintEnabled"] boolValue] ? @"开启" : @"关闭",
        @"contentMode": modeNames[mode] ?: @"裁切填满",
        @"stream": streamText,
    };
}

- (void)showSourceMenu:(UIButton *)sender {
    (void)sender;
    if (self.panel != nil) {
        [self dismissPanelThen:nil];
        return;
    }
    UIViewController *presenter = [self presentingViewController];
    UIViewController *presented = presenter.presentedViewController;
    if ([presented isKindOfClass:VCAMControlPanelViewController.class]) {
        // The panel can outlive the weak reference if it was presented from
        // another controller instance; adopt and dismiss it so a second dot
        // tap always closes the panel.
        self.panel = (VCAMControlPanelViewController *)presented;
        [self dismissPanelThen:nil];
        return;
    }
    [self presentPanel];
}

- (BOOL)panelIsPresented {
    UIViewController *presenter = [self cameraWindow].rootViewController;
    while (presenter.presentedViewController != nil) {
        presenter = presenter.presentedViewController;
        if ([presenter isKindOfClass:VCAMControlPanelViewController.class]) {
            return YES;
        }
    }
    return NO;
}

- (void)presentPanel {
    [self presentPanelWithRemainingRetries:10];
}

- (void)presentPanelWithRemainingRetries:(NSInteger)remainingRetries {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.panel != nil) return;
        UIViewController *presenter = [self presentingViewController];
        if (presenter == nil || presenter.presentedViewController != nil) {
            // The picker/document sheet may still be dismissing when the
            // import completes; retry briefly so the panel reliably reopens
            // instead of silently failing and forcing another dot tap.
            if (remainingRetries > 0) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                             (int64_t)(0.25 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    [self presentPanelWithRemainingRetries:remainingRetries - 1];
                });
            }
            return;
        }
        VCAMControlPanelViewController *panel = [[VCAMControlPanelViewController alloc]
            initWithStatus:[self currentStatus]];
        panel.delegate = self;
        self.panel = panel;
        [presenter presentViewController:panel
                                animated:!UIAccessibilityIsReduceMotionEnabled()
                              completion:nil];
        if (presenter.presentedViewController == panel) {
            // Keep the panel unobstructed: park (hide) the floating dot while
            // the panel is open. The panel closes via its X button, scrim tap,
            // or a dot tap once the panel is dismissed.
            self.floatingWindow.hidden = YES;
        }
    });
}

- (void)dismissPanelThen:(dispatch_block_t)completion {
    VCAMControlPanelViewController *panel = self.panel;
    self.panel = nil;
    if (panel.presentingViewController != nil) {
        [panel dismissViewControllerAnimated:!UIAccessibilityIsReduceMotionEnabled()
                                  completion:^{
            [self installButtonWhenWindowIsReady];
            if (completion != nil) completion();
        }];
    } else if (completion != nil) {
        [self installButtonWhenWindowIsReady];
        completion();
    } else {
        [self installButtonWhenWindowIsReady];
    }
}

- (void)controlPanelDidRequestClose:(VCAMControlPanelViewController *)panel {
    (void)panel;
    [self dismissPanelThen:nil];
}

- (void)controlPanelDidRequestPhotoLibrary:(VCAMControlPanelViewController *)panel {
    (void)panel;
    [self presentMediaPicker];
}

- (void)controlPanelDidRequestDocument:(VCAMControlPanelViewController *)panel {
    (void)panel;
    [self presentDocumentPicker];
}

- (void)controlPanelDidRequestOnlineVideo:(VCAMControlPanelViewController *)panel {
    (void)panel;
    [self promptForOnlineVideo];
}

- (void)controlPanelDidRequestLiveStream:(VCAMControlPanelViewController *)panel {
    (void)panel;
    [self presentStreamChooser];
}

- (void)controlPanelDidRequestClockwiseRotation:(VCAMControlPanelViewController *)panel {
    (void)panel;
    [self rotateClockwise];
}

- (void)controlPanelDidRequestCounterClockwiseRotation:(VCAMControlPanelViewController *)panel {
    (void)panel;
    [self rotateCounterClockwise];
}

- (void)controlPanelDidRequestMirrorToggle:(VCAMControlPanelViewController *)panel {
    (void)panel;
    [self toggleMirror];
}

- (void)controlPanelDidRequestContentModeCycle:(VCAMControlPanelViewController *)panel {
    (void)panel;
    [self cycleContentMode];
}

- (void)controlPanelDidRequestLoopToggle:(VCAMControlPanelViewController *)panel {
    (void)panel;
    [self toggleLoopPlayback];
}

- (void)controlPanelDidRequestScreenTintToggle:(VCAMControlPanelViewController *)panel {
    (void)panel;
    [self toggleScreenTint];
}

- (void)controlPanelDidRequestEnableVirtualCamera:(VCAMControlPanelViewController *)panel {
    (void)panel;
    [self enableVirtualCamera];
    [self.panel updateStatus:[self currentStatus]];
}

- (void)controlPanelDidRequestRestoreCamera:(VCAMControlPanelViewController *)panel {
    (void)panel;
    [self restoreRealCamera];
    [self.panel updateStatus:[self currentStatus]];
}

- (void)controlPanelDidRequestStatusRefresh:(VCAMControlPanelViewController *)panel {
    (void)panel;
    if (self.panel != nil) {
        [self.panel updateStatus:[self currentStatus]];
    }
}

- (void)presentMediaPicker {
    PHPickerConfiguration *configuration = [[PHPickerConfiguration alloc] init];
    configuration.filter = [PHPickerFilter anyFilterMatchingSubfilters:
        @[PHPickerFilter.imagesFilter, PHPickerFilter.videosFilter]];
    configuration.selectionLimit = 1;
    // Images are requested as UIImage objects below and flattened to JPEG.
    // This avoids handing an iOS 18 Photos HEIF/proxy representation directly
    // to ImageIO, which can decode as black even when Photos displays it.
    configuration.preferredAssetRepresentationMode =
        PHPickerConfigurationAssetRepresentationModeCompatible;
    PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:configuration];
    picker.delegate = self;
    [[self presentingViewController] presentViewController:picker animated:YES completion:nil];
}

- (void)presentDocumentPicker {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[UTTypeImage, UTTypeMovie] asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [[self presentingViewController] presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)controller;
    NSURL *url = urls.firstObject;
    if (url == nil) return;
    NSUInteger generation = [self beginMediaSelection];
    NSString *suggestedName = url.lastPathComponent;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [self importMediaFromURL:url suggestedName:suggestedName
                     generation:generation];
    });
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    PHPickerResult *result = results.firstObject;
    if (result == nil) return;
    NSItemProvider *provider = result.itemProvider;
    BOOL isMovie = [provider hasItemConformingToTypeIdentifier:UTTypeMovie.identifier];
    NSString *mediaType = isMovie ? VCAMConcreteProviderTypeIdentifier(provider, UTTypeMovie)
        : ([provider hasItemConformingToTypeIdentifier:UTTypeImage.identifier]
            ? VCAMConcreteProviderTypeIdentifier(provider, UTTypeImage) : nil);
    if (mediaType == nil) {
        [self showMessage:@"无法读取所选图片或视频" error:YES];
        return;
    }
    NSUInteger generation = [self beginMediaSelection];
    NSString *suggestedName = provider.suggestedName;
    if (!isMovie) {
        [provider loadObjectOfClass:UIImage.class completionHandler:^(id<NSItemProviderReading> object,
                                                                       NSError *error) {
            UIImage *image = [object isKindOfClass:UIImage.class] ? (UIImage *)object : nil;
            if (image == nil || error != nil) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (generation == self.mediaSelectionGeneration) {
                        [self showMessage:error.localizedDescription ?: @"读取相册图片失败" error:YES];
                    }
                });
                return;
            }

            CGSize pixelSize = image.CGImage == NULL
                ? CGSizeMake(image.size.width * MAX(image.scale, 1.0),
                             image.size.height * MAX(image.scale, 1.0))
                : CGSizeMake(CGImageGetWidth(image.CGImage), CGImageGetHeight(image.CGImage));
            if (pixelSize.width < 1.0 || pixelSize.height < 1.0) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (generation == self.mediaSelectionGeneration) {
                        [self showMessage:@"相册图片没有有效像素" error:YES];
                    }
                });
                return;
            }

            UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
            format.scale = 1.0;
            format.opaque = YES;
            UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc]
                initWithSize:pixelSize format:format];
            UIImage *normalized = [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
                [image drawInRect:(CGRect){CGPointZero, pixelSize}];
            }];
            NSData *data = UIImageJPEGRepresentation(normalized, 0.95);
            NSError *writeError = nil;
            NSURL *temporaryURL = [NSURL fileURLWithPath:[NSTemporaryDirectory()
                stringByAppendingPathComponent:[NSString stringWithFormat:
                    @"vcam-photo-%@.jpg", NSUUID.UUID.UUIDString]]];
            if (data.length == 0 || ![data writeToURL:temporaryURL
                                              options:NSDataWritingAtomic
                                                error:&writeError]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (generation == self.mediaSelectionGeneration) {
                        [self showMessage:writeError.localizedDescription ?: @"转换相册图片失败" error:YES];
                    }
                });
                return;
            }

            // The broker copies the file synchronously; remove the app-local
            // staging file after the import request has completed.
            [self importMediaFromURL:temporaryURL suggestedName:@"selected.jpg"
                           generation:generation];
            [[NSFileManager defaultManager] removeItemAtURL:temporaryURL error:nil];
        }];
        return;
    }
    [provider loadFileRepresentationForTypeIdentifier:mediaType completionHandler:^(NSURL *url, NSError *error) {
        if (url == nil || error != nil) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation == self.mediaSelectionGeneration) {
                    [self showMessage:error.localizedDescription ?: @"读取相册媒体失败" error:YES];
                }
            });
            return;
        }
        NSString *normalizedName = VCAMNormalizedMediaName(suggestedName, url, mediaType);
        // The item-provider URL expires when this callback returns. Import it
        // synchronously here, then commit UI/configuration on the main queue.
        [self importMediaFromURL:url suggestedName:normalizedName
                     generation:generation];
    }];
}

- (void)promptForOnlineVideo {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"在线源下载"
                                                                   message:@"输入图片或 MOV、MP4、M4V 的 HTTPS/HTTP 直链"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"https://example.com/media.mp4";
        field.keyboardType = UIKeyboardTypeURL;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"下载" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSURL *url = [NSURL URLWithString:alert.textFields.firstObject.text ?: @""];
        if (![@[@"http", @"https"] containsObject:url.scheme.lowercaseString]) {
            [self showMessage:@"请输入有效的 HTTP 或 HTTPS 地址" error:YES];
            return;
        }
        [self downloadOnlineVideo:url];
    }]];
    [[self presentingViewController] presentViewController:alert animated:YES completion:nil];
}

- (void)downloadOnlineVideo:(NSURL *)url {
    NSAssert(NSThread.isMainThread, @"online media selection requires main thread");
    NSUInteger generation = [self beginMediaSelection];
    self.button.enabled = NO;
    self.button.alpha = 0.62;
    [self.button setImage:[UIImage systemImageNamed:@"arrow.down.circle.fill"] forState:UIControlStateNormal];
    self.button.accessibilityLabel = @"VCAM 正在下载在线视频";
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, @"开始下载在线视频");
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.timeoutIntervalForRequest = 30.0;
    configuration.timeoutIntervalForResource = 600.0;
    self.onlineDownloadGeneration = generation;
    self.onlineDownloadLimitError = nil;
    self.onlineDownloadSession = [NSURLSession sessionWithConfiguration:configuration
                                                               delegate:self
                                                          delegateQueue:nil];
    self.onlineDownloadTask = [self.onlineDownloadSession downloadTaskWithURL:url];
    [self.onlineDownloadTask resume];
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    (void)bytesWritten;
    if (session != self.onlineDownloadSession ||
        downloadTask != self.onlineDownloadTask) return;
    int64_t available = VCAMAvailableImportantStorageBytes();
    BOOL sizeExceeded = totalBytesWritten > VCAMOnlineMediaMaximumBytes ||
        totalBytesExpectedToWrite > VCAMOnlineMediaMaximumBytes;
    int64_t remaining = !sizeExceeded &&
        totalBytesExpectedToWrite > totalBytesWritten
        ? totalBytesExpectedToWrite - totalBytesWritten : 0;
    BOOL storageExceeded = available <= 0 ||
        available < VCAMOnlineMediaReserveBytes + remaining;
    if (!sizeExceeded && !storageExceeded) return;
    self.onlineDownloadLimitError = sizeExceeded
        ? @"在线媒体超过 2 GiB 上限"
        : @"设备剩余空间不足，下载已停止";
    [downloadTask cancel];
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location {
    if (session != self.onlineDownloadSession ||
        downloadTask != self.onlineDownloadTask) return;
    NSUInteger generation = self.onlineDownloadGeneration;
    NSString *name = downloadTask.response.suggestedFilename ?:
        downloadTask.originalRequest.URL.lastPathComponent;
    // The temporary download URL expires after this callback.
    [self importMediaFromURL:location suggestedName:name generation:generation];
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    if (session != self.onlineDownloadSession || task != self.onlineDownloadTask) return;
    NSUInteger generation = self.onlineDownloadGeneration;
    NSString *limitError = self.onlineDownloadLimitError;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (generation != self.mediaSelectionGeneration) return;
        self.button.enabled = YES;
        self.button.alpha = 1.0;
        [self.button setImage:[UIImage systemImageNamed:@"video.fill"]
                     forState:UIControlStateNormal];
        self.button.accessibilityLabel = @"打开 VCAM 控制面板";
        if (error != nil) {
            [self showMessage:limitError ?: error.localizedDescription ?: @"在线源下载失败"
                        error:YES];
        }
        self.onlineDownloadTask = nil;
        [self.onlineDownloadSession finishTasksAndInvalidate];
        self.onlineDownloadSession = nil;
        self.onlineDownloadLimitError = nil;
    });
}

- (void)presentStreamChooser {
    NSDictionary *values = [VCAMConfiguration currentValues];
    NSArray *saved = values[@"savedStreams"];
    if (![saved isKindOfClass:NSArray.class] || saved.count == 0) {
        [self promptForLiveStream];
        return;
    }
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"已保存的直播流"
                                                                   message:@"点选即可切换，或输入新地址"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *entry in saved) {
        if (![entry isKindOfClass:NSString.class] || entry.length == 0) continue;
        NSURL *url = [NSURL URLWithString:entry];
        if (url == nil) continue;
        [sheet addAction:[UIAlertAction actionWithTitle:entry style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [self applyStreamURL:url];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"＋ 输入新地址" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [self promptForLiveStream];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"管理已保存" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [self presentStreamManager];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [[self presentingViewController] presentViewController:sheet animated:YES completion:nil];
}

- (BOOL)applyStreamURL:(NSURL *)url {
    if (url == nil) return NO;
    NSString *scheme = url.scheme.lowercaseString;
    BOOL isWebSocket = [@[@"ws", @"wss"] containsObject:scheme];
    BOOL isRTSP = [scheme isEqualToString:@"rtsp"];
    BOOL isHLS = [@[@"http", @"https"] containsObject:scheme];
    if (!isWebSocket && !isRTSP && !isHLS) {
        [self showMessage:@"直播流地址必须以 ws://、wss://、rtsp:// 或 http(s):// 开头" error:YES];
        return NO;
    }
    [self beginMediaSelection];
    NSMutableDictionary *updates = [@{@"enabled": @YES, @"rotationDegrees": @0, @"mirrorHorizontally": @NO} mutableCopy];
    NSString *urlString = url.absoluteString ?: @"";
    if (isRTSP) {
        updates[@"source"] = @"rtsp";
        updates[@"rtspURL"] = urlString;
    } else if (isHLS) {
        updates[@"source"] = @"hls";
        updates[@"hlsURL"] = urlString;
    } else {
        updates[@"source"] = @"obs";
        updates[@"obsWebSocketURL"] = urlString;
    }
    if (![self updatePreferences:updates]) {
        [self showMessage:@"直播流配置写入失败" error:YES];
        return NO;
    }
    [self rememberStreamURL:urlString];
    [self postConfigurationChanged];
    [self presentPanel];
    return YES;
}

- (void)rememberStreamURL:(NSString *)urlString {
    if (urlString.length == 0) return;
    NSDictionary *values = [VCAMConfiguration currentValues];
    NSArray *existing = values[@"savedStreams"];
    if (![existing isKindOfClass:NSArray.class]) existing = @[];
    NSMutableArray *saved = [existing mutableCopy];
    NSUInteger index = [saved indexOfObject:urlString];
    if (index != NSNotFound) [saved removeObjectAtIndex:index];
    [saved insertObject:urlString atIndex:0];
    while (saved.count > 24) [saved removeLastObject];
    [self updatePreferences:@{@"savedStreams": saved}];
}

- (void)removeStreamURL:(NSString *)urlString {
    if (urlString.length == 0) return;
    NSDictionary *values = [VCAMConfiguration currentValues];
    NSArray *existing = values[@"savedStreams"];
    if (![existing isKindOfClass:NSArray.class]) return;
    NSMutableArray *saved = [existing mutableCopy];
    [saved removeObject:urlString];
    [self updatePreferences:@{@"savedStreams": saved}];
    [self postConfigurationChanged];
}

- (void)presentStreamManager {
    NSDictionary *values = [VCAMConfiguration currentValues];
    NSArray *saved = values[@"savedStreams"];
    if (![saved isKindOfClass:NSArray.class] || saved.count == 0) {
        [self showMessage:@"暂无已保存的直播流" error:NO];
        return;
    }
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"管理已保存直播流"
                                                                   message:@"点选地址可编辑或删除"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *entry in saved) {
        if (![entry isKindOfClass:NSString.class] || entry.length == 0) continue;
        [sheet addAction:[UIAlertAction actionWithTitle:entry style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [self presentEditDeleteForStreamURL:entry];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [[self presentingViewController] presentViewController:sheet animated:YES completion:nil];
}

- (void)presentEditDeleteForStreamURL:(NSString *)urlString {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:urlString
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"编辑" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [self promptForLiveStreamReplacingURL:urlString];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        [self removeStreamURL:urlString];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [[self presentingViewController] presentViewController:sheet animated:YES completion:nil];
}

- (void)promptForLiveStream {
    [self promptForLiveStreamReplacingURL:nil];
}

- (void)promptForLiveStreamReplacingURL:(NSString *)replacingURL {
    NSDictionary *values = [VCAMConfiguration currentValues];
    NSString *initial = replacingURL.length > 0 ? replacingURL : [self currentStreamURLFromValues:values];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"输入直播流"
                                                                   message:@"输入 ws:// 电脑桥接、rtsp:// 手机直连，或 http(s):// HLS 地址"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = initial ?: @"";
        field.keyboardType = UIKeyboardTypeURL;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"启用" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSURL *url = [NSURL URLWithString:alert.textFields.firstObject.text ?: @""];
        if (![self applyStreamURL:url]) return;
        if (replacingURL.length > 0 && ![url.absoluteString isEqualToString:replacingURL]) {
            [self removeStreamURL:replacingURL];
        }
    }]];
    [[self presentingViewController] presentViewController:alert animated:YES completion:nil];
}

- (nullable NSString *)currentStreamURLFromValues:(NSDictionary *)values {
    NSString *source = [values[@"source"] lowercaseString];
    if ([source isEqualToString:@"rtsp"]) return values[@"rtspURL"];
    if ([source isEqualToString:@"hls"]) return values[@"hlsURL"];
    if ([source isEqualToString:@"obs"]) return values[@"obsWebSocketURL"];
    return nil;
}

- (NSUInteger)beginMediaSelection {
    NSAssert(NSThread.isMainThread, @"media selection generation requires main thread");
    [self.onlineDownloadTask cancel];
    [self.onlineDownloadSession invalidateAndCancel];
    self.onlineDownloadTask = nil;
    self.onlineDownloadSession = nil;
    self.onlineDownloadLimitError = nil;
    self.mediaSelectionGeneration += 1;
    if (self.mediaSelectionGeneration == 0) self.mediaSelectionGeneration = 1;
    // Superseding an in-flight online download must not leave the shared dot
    // disabled when that stale completion is intentionally ignored.
    self.button.enabled = YES;
    self.button.alpha = 1.0;
    [self.button setImage:[UIImage systemImageNamed:@"video.fill"]
                 forState:UIControlStateNormal];
    self.button.accessibilityLabel = @"打开 VCAM 控制面板";
    return self.mediaSelectionGeneration;
}

- (NSInteger)preferredFramesPerSecondForMediaPath:(NSString *)path {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path]
                                            options:nil];
    AVAssetTrack *videoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    float nominalFrameRate = videoTrack.nominalFrameRate;
    return nominalFrameRate >= 50.0f ? 60 :
        (nominalFrameRate >= 28.0f ? 30 : (nominalFrameRate >= 20.0f ? 24 : 30));
}

- (void)importMediaFromURL:(NSURL *)temporaryURL
             suggestedName:(nullable NSString *)suggestedName
                generation:(NSUInteger)generation {
    NSError *error = nil;
    NSString *destinationPath = [VCAMConfiguration importMediaAtURL:temporaryURL
                                                      suggestedName:suggestedName
                                                              error:&error];
    NSInteger preferredFramesPerSecond = destinationPath.length > 0
        ? [self preferredFramesPerSecondForMediaPath:destinationPath] : 30;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (generation != self.mediaSelectionGeneration) return;
        if (destinationPath.length == 0) {
            [self showMessage:error.localizedDescription error:YES];
            return;
        }
        [self activateImportedMediaAtPath:destinationPath
                 preferredFramesPerSecond:preferredFramesPerSecond
                              generation:generation];
    });
}

- (void)activateImportedMediaAtPath:(NSString *)destinationPath
           preferredFramesPerSecond:(NSInteger)preferredFramesPerSecond
                        generation:(NSUInteger)generation {
    NSAssert(NSThread.isMainThread, @"media activation requires main thread");
    if (generation != self.mediaSelectionGeneration) return;
    NSURL *destinationURL = [NSURL fileURLWithPath:destinationPath];
    if (![self updatePreferences:@{@"source": @"local", @"enabled": @YES,
                                  @"mediaPath": destinationURL.path, @"loopMedia": @YES,
                                  @"replaceAudio": @NO,
                                  @"rotationDegrees": @0,
                                  @"mirrorHorizontally": @NO,
                                  @"localDecoderMode": @"single",
                                  @"preferredFramesPerSecond": @(preferredFramesPerSecond)}]) {
        [self showMessage:@"媒体已复制，但 VCAM 配置写入失败" error:YES];
        return;
    }
    [self postConfigurationChanged];
    [self presentPanel];
}

- (void)rotateClockwise { [self changeRotationBy:90]; }
- (void)rotateCounterClockwise { [self changeRotationBy:270]; }

- (void)changeRotationBy:(NSInteger)delta {
    NSDictionary *values = [VCAMConfiguration currentValues];
    NSInteger rotationDegrees = ([values[@"rotationDegrees"] integerValue] + delta) % 360;
    if (![self updatePreferences:@{@"rotationDegrees": @(rotationDegrees)}]) return;
    [self postConfigurationChanged];
    [self.panel updateStatus:[self currentStatus]];
}

- (void)toggleMirror {
    NSDictionary *values = [VCAMConfiguration currentValues];
    BOOL enabled = ![values[@"mirrorHorizontally"] boolValue];
    if (![self updatePreferences:@{@"mirrorHorizontally": @(enabled)}]) return;
    [self postConfigurationChanged];
    [self.panel updateStatus:[self currentStatus]];
}

- (void)toggleLoopPlayback {
    NSDictionary *values = [VCAMConfiguration currentValues];
    BOOL current = values[@"loopMedia"] == nil ? YES : [values[@"loopMedia"] boolValue];
    BOOL enabled = !current;
    if (![self updatePreferences:@{@"loopMedia": @(enabled)}]) return;
    [self postConfigurationChanged];
    [self.panel updateStatus:[self currentStatus]];
}

// 三色调光开关（路线 2 的用户入口）：写 screenTintEnabled 偏好并经既有镜像通道
// 同步到 cameracaptured 可读目录；采色器与相机侧染色都读同一权威值。
- (void)toggleScreenTint {
    NSDictionary *values = [VCAMConfiguration currentValues];
    BOOL enabled = ![values[@"screenTintEnabled"] boolValue];
    if (![self updatePreferences:@{@"screenTintEnabled": @(enabled)}]) return;
    [self postConfigurationChanged];
    [self.panel updateStatus:[self currentStatus]];
}

- (void)cycleContentMode {
    NSDictionary *values = [VCAMConfiguration currentValues];
    NSString *current = [values[@"contentMode"] lowercaseString] ?: @"fill";
    NSString *next = [current isEqualToString:@"fill"] ? @"fit" :
                     ([current isEqualToString:@"fit"] ? @"stretch" : @"fill");
    if (![self updatePreferences:@{@"contentMode": next}]) return;
    [self postConfigurationChanged];
    [self.panel updateStatus:[self currentStatus]];
}

- (void)enableVirtualCamera {
    NSDictionary<NSString *, id> *values = [VCAMConfiguration currentValues];
    NSString *configuredSource = [values[@"source"] isKindOfClass:NSString.class]
        ? [values[@"source"] lowercaseString] : nil;
    NSString *rtspURL = [values[@"rtspURL"] isKindOfClass:NSString.class] ? values[@"rtspURL"] : nil;
    NSString *obsURL = [values[@"obsWebSocketURL"] isKindOfClass:NSString.class]
        ? values[@"obsWebSocketURL"] : nil;
    NSString *hlsURL = [values[@"hlsURL"] isKindOfClass:NSString.class] ? values[@"hlsURL"] : nil;
    NSString *mediaPath = [values[@"mediaPath"] isKindOfClass:NSString.class] ? values[@"mediaPath"] : nil;
    BOOL hasRTSP = [rtspURL.lowercaseString hasPrefix:@"rtsp://"];
    BOOL hasOBS = [obsURL.lowercaseString hasPrefix:@"ws://"] ||
        [obsURL.lowercaseString hasPrefix:@"wss://"];
    BOOL hasHLS = [hlsURL.lowercaseString hasPrefix:@"http://"] ||
        [hlsURL.lowercaseString hasPrefix:@"https://"];
    BOOL hasLocalMedia = mediaPath.length > 0;
    NSString *source = nil;
    if ([configuredSource isEqualToString:@"hls"] && hasHLS) {
        source = @"hls";
    } else if ([configuredSource isEqualToString:@"rtsp"] && hasRTSP) {
        source = @"rtsp";
    } else if ([configuredSource isEqualToString:@"obs"] && hasOBS) {
        source = @"obs";
    } else if ([configuredSource isEqualToString:@"local"] && hasLocalMedia) {
        source = @"local";
    } else {
        if (hasHLS) {
            source = @"hls";
        } else if ([rtspURL.lowercaseString hasPrefix:@"rtsp://"]) {
            source = @"rtsp";
        } else if ([obsURL.lowercaseString hasPrefix:@"ws://"] ||
                   [obsURL.lowercaseString hasPrefix:@"wss://"]) {
            source = @"obs";
        } else if (mediaPath.length > 0) {
            source = @"local";
        }
    }
    if (source.length == 0) {
        [self showMessage:@"请先选择本地媒体或配置 OBS/RTSP 直播源" error:YES];
        return;
    }

    if (![self updatePreferences:@{@"enabled": @YES, @"source": source}]) {
        [self showMessage:@"启用虚拟相机失败" error:YES];
        return;
    }
    [self postConfigurationChanged];
    [self showMessage:@"虚拟相机已启用" error:NO];
}

- (void)restoreRealCamera {
    if (![self updatePreferences:@{@"enabled": @NO}]) {
        [self showMessage:@"恢复真实相机失败" error:YES];
        return;
    }
    [self postConfigurationChanged];
    [self showMessage:@"已恢复真实相机" error:NO];
}

- (BOOL)updatePreferences:(NSDictionary<NSString *, id> *)changes {
    return [VCAMConfiguration updateValues:changes];
}

- (void)postConfigurationChanged {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.codex.vcam/preferences.changed"),
                                         NULL, NULL, true);
}

- (void)showMessage:(NSString *)message error:(BOOL)isError {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *presenter = [self presentingViewController];
        if (presenter == nil || [presenter isKindOfClass:UIAlertController.class]) return;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:isError ? @"VCAM 错误" : @"VCAM"
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [presenter presentViewController:alert animated:YES completion:nil];
    });
}

@end

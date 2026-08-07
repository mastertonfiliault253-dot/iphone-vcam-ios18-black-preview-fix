#import "VCAMMediaPickerController.h"
#import "VCAMControlPanelViewController.h"
#import "VCAMSharedFramePreviewView.h"
#import <PhotosUI/PhotosUI.h>
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "../Core/VCAMConfiguration.h"

static const NSInteger VCAMWindowDiscoveryRetryCount = 240;
static const NSInteger VCAMFloatingDotTag = 0x5643414D;
static const void *VCAMGestureTagKey = &VCAMGestureTagKey;
static const void *VCAMFloatingButtonKey = &VCAMFloatingButtonKey;
static NSString *const VCAMFloatingWindowIdentifier = @"com.codex.vcam.floatingDot";
static BOOL VCAMPickerUIStarted = NO;

static void VCAMPickerConfigurationChanged(CFNotificationCenterRef center, void *observer, CFStringRef name,
                                           const void *object, CFDictionaryRef userInfo) {
    (void)center; (void)name; (void)object; (void)userInfo;
    VCAMMediaPickerController *controller = (__bridge VCAMMediaPickerController *)observer;
    dispatch_async(dispatch_get_main_queue(), ^{ [controller performSelector:@selector(configurationDidChange)]; });
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

static NSString *VCAMConcreteProviderTypeIdentifier(NSItemProvider *provider, UTType *mediaKind) {
    NSString *fallbackIdentifier = nil;
    for (NSString *identifier in provider.registeredTypeIdentifiers) {
        UTType *registeredType = [UTType typeWithIdentifier:identifier];
        if (registeredType == nil || ![registeredType conformsToType:mediaKind]) continue;
        if (fallbackIdentifier == nil) fallbackIdentifier = identifier;
        if (VCAMIsSupportedMediaExtension(registeredType.preferredFilenameExtension)) {
            return identifier;
        }
    }
    return fallbackIdentifier ?: mediaKind.identifier;
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
                                          VCAMControlPanelDelegate,
                                          UIGestureRecognizerDelegate>
@property(nonatomic, strong, nullable) UIButton *button;
@property(nonatomic, weak, nullable) VCAMControlPanelViewController *panel;
@property(nonatomic, weak, nullable) UIWindow *gestureWindow;
@property(nonatomic, strong, nullable) UIWindow *floatingWindow;
@property(nonatomic) NSInteger remainingWindowRetries;
@property(nonatomic) BOOL started;
@end

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
        [notifications addObserver:self selector:@selector(applicationDidBecomeActive:)
                              name:UIWindowDidBecomeKeyNotification object:nil];
        [notifications addObserver:self selector:@selector(applicationDidBecomeActive:)
                              name:UISceneDidActivateNotification object:nil];
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        (__bridge const void *)self,
                                        VCAMPickerConfigurationChanged,
                                        CFSTR("com.codex.vcam/preferences.changed"), NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        [self installButtonWhenWindowIsReady];
        if ([self isSpringBoardHost]) [self startPeriodicRefresh];
    });
}

- (void)startPeriodicRefresh {
    static const NSTimeInterval refreshInterval = 1.0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(refreshInterval * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!VCAMPickerUIStarted || !self.started) return;
        // SpringBoard may not post active/key-window notifications when the
        // lock screen is dismissed, so re-evaluate the floating button on a
        // slow cadence. This keeps the dot from staying hidden forever after
        // an unlock and re-homes the gesture if the key window changes.
        [self installButtonWhenWindowIsReady];
        [self startPeriodicRefresh];
    });
}

- (void)configurationDidChange {
    self.remainingWindowRetries = VCAMWindowDiscoveryRetryCount;
    [self installButtonWhenWindowIsReady];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    (void)notification;
    self.remainingWindowRetries = VCAMWindowDiscoveryRetryCount;
    [self installButtonWhenWindowIsReady];
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
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive ||
            ![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        for (UIWindow *window in windowScene.windows) {
            if (window.isKeyWindow && !window.hidden && window.windowLevel == UIWindowLevelNormal) return window;
        }
        for (UIWindow *window in windowScene.windows) {
            if (!window.hidden && window.windowLevel == UIWindowLevelNormal && window.rootViewController != nil) return window;
        }
    }
    return nil;
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
    dot.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.88];
    dot.layer.cornerRadius = 22.0;
    dot.layer.borderWidth = 1.0;
    dot.layer.borderColor = [UIColor colorWithWhite:0.35 alpha:0.45].CGColor;
    dot.layer.shadowColor = UIColor.blackColor.CGColor;
    dot.layer.shadowOpacity = 0.35;
    dot.layer.shadowRadius = 4.0;
    dot.layer.shadowOffset = CGSizeMake(0, 1);
    [button addSubview:dot];
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
        ? visibility[[self floatingPositionIdentifier]] : nil;
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
    return [NSValue valueWithCGPoint:CGPointMake(x * CGRectGetWidth(window.bounds),
                                                 y * CGRectGetHeight(window.bounds))];
}

- (void)saveFloatingButtonPositionInWindow:(UIWindow *)window {
    if (self.button == nil || CGRectGetWidth(window.bounds) <= 0 || CGRectGetHeight(window.bounds) <= 0) return;
    NSMutableDictionary *positions =
        [[VCAMConfiguration currentValues][@"floatingButtonPositions"] mutableCopy] ?: [NSMutableDictionary dictionary];
    positions[[self floatingPositionIdentifier]] = @{
        @"x": @(self.button.center.x / CGRectGetWidth(window.bounds)),
        @"y": @(self.button.center.y / CGRectGetHeight(window.bounds)),
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

    // Three-finger double-tap must work regardless of which window is on top.
    // Install on every visible window and re-evaluate on the periodic refresh.
    for (UIWindow *candidate in [self allVisibleWindows]) {
        [self installGestureOnWindowIfNeeded:candidate];
    }

    UIWindow *floatingWindow = [self floatingDotWindow];
    if (floatingWindow.windowScene == nil && window.windowScene != nil) {
        floatingWindow.hidden = YES;
        self.floatingWindow = nil;
        floatingWindow = [self floatingDotWindow];
    }
    [self removeLegacyFloatingDots];

    UIButton *button = [self floatingButton];
    self.button = button;
    if (button == nil) return;

    if (button.superview != floatingWindow) {
        [button removeFromSuperview];
        button.frame = floatingWindow.bounds;
        floatingWindow.frame = CGRectMake(10.0, CGRectGetMidY(window.bounds) - 26.0, 52.0, 52.0);
        NSValue *savedCenter = [self savedFloatingButtonCenterForWindow:window];
        if (savedCenter != nil) floatingWindow.center = savedCenter.CGPointValue;
        [floatingWindow addSubview:button];
    }
    NSDictionary *values = [VCAMConfiguration currentValues];
    BOOL locked = [self isSpringBoardHost] && ![self isSpringBoardUnlocked];
    BOOL visible = [self isFloatingButtonVisibleForValues:values] && !locked;
    floatingWindow.hidden = !visible;
    button.hidden = NO;
    [floatingWindow bringSubviewToFront:button];
    [VCAMConfiguration appendProcessLog:
        [NSString stringWithFormat:@"springboard-client installButton host=%@ hostWindow=%@ floatingWindow=%@ hidden=%d frame=%@",
            NSProcessInfo.processInfo.processName ?: @"(unknown)",
            window, floatingWindow, floatingWindow.hidden ? 1 : 0,
            NSStringFromCGRect(floatingWindow.frame)]];
}

- (void)toggleFloatingButton:(UITapGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateRecognized || UIAccessibilityIsVoiceOverRunning()) return;
    NSDictionary *values = [VCAMConfiguration currentValues];
    NSMutableDictionary *visibility = [values[@"floatingButtonVisibility"] mutableCopy]
        ?: [NSMutableDictionary dictionary];
    BOOL currentlyVisible = [self isFloatingButtonVisibleForValues:values];
    visibility[[self floatingPositionIdentifier]] = @(!currentlyVisible);
    if (![self updatePreferences:@{@"floatingButtonVisibility": visibility}]) {
        [self showMessage:@"主屏配置服务不可用" error:YES];
        return;
    }
    [self configurationDidChange];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    (void)gestureRecognizer; (void)otherGestureRecognizer;
    return YES;
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
    NSString *sourceTitle = @"真实相机（未替换）";
    NSString *detail = @"vcamd 未发布替换画面；真实相机保持可用";
    if (enabled && [source isEqualToString:@"local"]) {
        NSString *file = [values[@"mediaPath"] lastPathComponent] ?: @"本地媒体";
        sourceTitle = [NSString stringWithFormat:@"本地图片/视频：%@", file];
        detail = @"vcamd 按需解码并发布最新帧";
    } else if (enabled && [source isEqualToString:@"obs"]) {
        sourceTitle = @"OBS WebSocket 已启用";
        detail = values[@"obsWebSocketURL"] ?: @"未设置地址";
    } else if (enabled && [source isEqualToString:@"rtsp"]) {
        sourceTitle = @"RTSP 直连已启用";
        detail = values[@"rtspURL"] ?: @"未设置地址";
    }
    NSInteger rotation = [values[@"rotationDegrees"] integerValue] % 360;
    NSString *mode = [values[@"contentMode"] lowercaseString] ?: @"fill";
    NSDictionary *modeNames = @{@"fit": @"完整显示", @"fill": @"裁切填满", @"stretch": @"拉伸"};
    detail = [detail stringByAppendingFormat:@"\n旋转：%ld° · 输出：%@fps", (long)rotation,
              values[@"preferredFramesPerSecond"] ?: @30];
    NSDictionary *streamStatus = [VCAMSharedFramePreviewView streamingStatus];
    NSString *streamText = nil;
    if ([streamStatus[@"receiving"] boolValue]) {
        streamText = [NSString stringWithFormat:@"已收到推流（%.0f ms 前）",
            [streamStatus[@"ageMs"] doubleValue]];
    } else {
        streamText = @"未收到推流";
    }
    return @{
        @"source": sourceTitle,
        @"detail": detail,
        @"mirror": [values[@"mirrorHorizontally"] boolValue] ? @"开启" : @"关闭",
        @"loop": values[@"loopMedia"] == nil || [values[@"loopMedia"] boolValue] ? @"开启" : @"关闭",
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
    [self presentPanel];
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
    });
}

- (void)dismissPanelThen:(dispatch_block_t)completion {
    VCAMControlPanelViewController *panel = self.panel;
    self.panel = nil;
    if (panel.presentingViewController != nil) {
        [panel dismissViewControllerAnimated:!UIAccessibilityIsReduceMotionEnabled() completion:completion];
    } else if (completion != nil) {
        completion();
    }
}

- (void)controlPanelDidRequestClose:(VCAMControlPanelViewController *)panel {
    (void)panel;
    [self dismissPanelThen:nil];
}

- (void)controlPanelDidRequestPhotoLibrary:(VCAMControlPanelViewController *)panel {
    (void)panel;
    [self dismissPanelThen:^{ [self presentMediaPicker]; }];
}

- (void)controlPanelDidRequestDocument:(VCAMControlPanelViewController *)panel {
    (void)panel;
    [self dismissPanelThen:^{ [self presentDocumentPicker]; }];
}

- (void)controlPanelDidRequestOnlineVideo:(VCAMControlPanelViewController *)panel {
    (void)panel;
    [self dismissPanelThen:^{ [self promptForOnlineVideo]; }];
}

- (void)controlPanelDidRequestLiveStream:(VCAMControlPanelViewController *)panel {
    (void)panel;
    [self dismissPanelThen:^{ [self promptForLiveStream]; }];
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

- (void)controlPanelDidRequestEnableVirtualCamera:(VCAMControlPanelViewController *)panel {
    (void)panel;
    [self dismissPanelThen:^{ [self enableVirtualCamera]; }];
}

- (void)controlPanelDidRequestRestoreCamera:(VCAMControlPanelViewController *)panel {
    (void)panel;
    [self dismissPanelThen:^{ [self restoreRealCamera]; }];
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
    configuration.preferredAssetRepresentationMode = PHPickerConfigurationAssetRepresentationModeCurrent;
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
    if (url != nil) [self installMediaFromTemporaryURL:url suggestedName:url.lastPathComponent];
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    PHPickerResult *result = results.firstObject;
    if (result == nil) return;
    NSItemProvider *provider = result.itemProvider;
    NSString *mediaType = [provider hasItemConformingToTypeIdentifier:UTTypeMovie.identifier]
        ? VCAMConcreteProviderTypeIdentifier(provider, UTTypeMovie)
        : ([provider hasItemConformingToTypeIdentifier:UTTypeImage.identifier]
            ? VCAMConcreteProviderTypeIdentifier(provider, UTTypeImage) : nil);
    if (mediaType == nil) {
        [self showMessage:@"无法读取所选图片或视频" error:YES];
        return;
    }
    NSString *suggestedName = provider.suggestedName;
    [provider loadFileRepresentationForTypeIdentifier:mediaType completionHandler:^(NSURL *url, NSError *error) {
        if (url == nil || error != nil) {
            [self showMessage:error.localizedDescription ?: @"读取相册媒体失败" error:YES];
            return;
        }
        NSString *normalizedName = VCAMNormalizedMediaName(suggestedName, url, mediaType);
        [self installMediaFromTemporaryURL:url suggestedName:normalizedName];
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
    dispatch_async(dispatch_get_main_queue(), ^{
        self.button.enabled = NO;
        self.button.alpha = 0.62;
        [self.button setImage:[UIImage systemImageNamed:@"arrow.down.circle.fill"] forState:UIControlStateNormal];
        self.button.accessibilityLabel = @"VCAM 正在下载在线视频";
        UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, @"开始下载在线视频");
    });
    NSURLSessionDownloadTask *task = [NSURLSession.sharedSession downloadTaskWithURL:url
        completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.button.enabled = YES;
            self.button.alpha = 1.0;
            [self.button setImage:[UIImage systemImageNamed:@"video.fill"] forState:UIControlStateNormal];
            self.button.accessibilityLabel = @"打开 VCAM 控制面板";
        });
        if (location == nil || error != nil) {
            [self showMessage:error.localizedDescription ?: @"在线源下载失败" error:YES];
            return;
        }
        NSString *name = response.suggestedFilename ?: url.lastPathComponent;
        [self installMediaFromTemporaryURL:location suggestedName:name];
    }];
    [task resume];
}

- (void)promptForLiveStream {
    NSDictionary *values = [VCAMConfiguration currentValues];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"输入直播流"
                                                                   message:@"输入 ws:// 电脑桥接地址，或 rtsp:// 手机直连地址"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = values[@"rtspURL"] ?: values[@"obsWebSocketURL"] ?: @"rtsp://192.168.2.1:8554/live";
        field.keyboardType = UIKeyboardTypeURL;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"启用" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSURL *url = [NSURL URLWithString:alert.textFields.firstObject.text ?: @""];
        NSString *scheme = url.scheme.lowercaseString;
        BOOL isWebSocket = [@[@"ws", @"wss"] containsObject:scheme];
        BOOL isRTSP = [scheme isEqualToString:@"rtsp"];
        if (!isWebSocket && !isRTSP) {
            [self showMessage:@"直播流地址必须以 ws://、wss:// 或 rtsp:// 开头" error:YES];
            return;
        }
        NSDictionary *updates = isRTSP ?
            @{@"source": @"rtsp", @"enabled": @YES, @"rtspURL": url.absoluteString} :
            @{@"source": @"obs", @"enabled": @YES, @"obsWebSocketURL": url.absoluteString};
        if (![self updatePreferences:updates]) {
            [self showMessage:@"直播流配置写入失败" error:YES];
            return;
        }
        [self postConfigurationChanged];
        [self presentPanel];
    }]];
    [[self presentingViewController] presentViewController:alert animated:YES completion:nil];
}

- (void)installMediaFromTemporaryURL:(NSURL *)temporaryURL suggestedName:(nullable NSString *)suggestedName {
    NSError *error = nil;
    NSString *destinationPath = [VCAMConfiguration importMediaAtURL:temporaryURL
                                                      suggestedName:suggestedName
                                                              error:&error];
    if (destinationPath.length == 0) {
        [self showMessage:error.localizedDescription error:YES];
        return;
    }
    NSURL *destinationURL = [NSURL fileURLWithPath:destinationPath];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:destinationURL options:nil];
    AVAssetTrack *videoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    float nominalFrameRate = videoTrack.nominalFrameRate;
    NSInteger preferredFramesPerSecond = nominalFrameRate >= 50.0f ? 60 :
        (nominalFrameRate >= 28.0f ? 30 : (nominalFrameRate >= 20.0f ? 24 : 30));
    if (![self updatePreferences:@{@"source": @"local", @"enabled": @YES,
                                  @"mediaPath": destinationURL.path, @"loopMedia": @YES,
                                  @"replaceAudio": @NO,
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
    NSString *mediaPath = [values[@"mediaPath"] isKindOfClass:NSString.class] ? values[@"mediaPath"] : nil;
    BOOL hasRTSP = [rtspURL.lowercaseString hasPrefix:@"rtsp://"];
    BOOL hasOBS = [obsURL.lowercaseString hasPrefix:@"ws://"] ||
        [obsURL.lowercaseString hasPrefix:@"wss://"];
    BOOL hasLocalMedia = mediaPath.length > 0;
    NSString *source = nil;
    if ([configuredSource isEqualToString:@"rtsp"] && hasRTSP) {
        source = @"rtsp";
    } else if ([configuredSource isEqualToString:@"obs"] && hasOBS) {
        source = @"obs";
    } else if ([configuredSource isEqualToString:@"local"] && hasLocalMedia) {
        source = @"local";
    } else {
        if ([rtspURL.lowercaseString hasPrefix:@"rtsp://"]) {
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

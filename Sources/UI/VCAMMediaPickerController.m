#import "VCAMMediaPickerController.h"
#import "VCAMControlPanelViewController.h"
#import <PhotosUI/PhotosUI.h>
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "../Core/VCAMConfiguration.h"
#import "../Sources/VCAMLocalMediaSource.h"

extern NSDictionary<NSString *, NSNumber *> *VCAMCaptureHookDiagnosticSnapshot(void);

@interface VCAMMediaPickerController () <PHPickerViewControllerDelegate,
                                          UIDocumentPickerDelegate,
                                          VCAMControlPanelDelegate>
@property(nonatomic, strong, nullable) UIButton *button;
@property(nonatomic, weak, nullable) VCAMControlPanelViewController *panel;
@property(nonatomic) NSInteger remainingWindowRetries;
@end

@implementation VCAMMediaPickerController

+ (instancetype)sharedController {
    static VCAMMediaPickerController *controller;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ controller = [VCAMMediaPickerController new]; });
    return controller;
}

- (void)start {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.remainingWindowRetries = 20;
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationDidBecomeActive:)
                                                     name:UIApplicationDidBecomeActiveNotification
                                                   object:nil];
        [self installButtonWhenWindowIsReady];
    });
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    (void)notification;
    self.remainingWindowRetries = 20;
    [self installButtonWhenWindowIsReady];
}

- (nullable UIWindow *)cameraWindow {
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

- (void)installButtonWhenWindowIsReady {
    NSAssert(NSThread.isMainThread, @"VCAM picker UI must run on the main thread");
    UIWindow *window = [self cameraWindow];
    if (window == nil) {
        if (self.remainingWindowRetries-- > 0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [self installButtonWhenWindowIsReady]; });
        }
        return;
    }

    if (self.button == nil) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.accessibilityLabel = @"打开 VCAM 控制面板";
        [button setImage:[UIImage systemImageNamed:@"video.fill"] forState:UIControlStateNormal];
        button.tintColor = UIColor.whiteColor;
        button.backgroundColor = [UIColor colorWithRed:0.08 green:0.28 blue:0.58 alpha:0.92];
        button.layer.cornerRadius = 24.0;
        button.layer.borderWidth = 1.0;
        button.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.65].CGColor;
        button.layer.shadowColor = UIColor.blackColor.CGColor;
        button.layer.shadowOpacity = 0.32;
        button.layer.shadowRadius = 6.0;
        button.layer.shadowOffset = CGSizeMake(0, 2);
        [button addTarget:self action:@selector(showSourceMenu:) forControlEvents:UIControlEventTouchUpInside];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                             action:@selector(dragButton:)];
        pan.maximumNumberOfTouches = 1;
        [button addGestureRecognizer:pan];
        self.button = button;
    }

    if (self.button.superview != window) {
        [self.button removeFromSuperview];
        self.button.frame = CGRectMake(10.0, CGRectGetMidY(window.bounds) - 24.0, 48.0, 48.0);
        self.button.autoresizingMask = UIViewAutoresizingFlexibleRightMargin |
                                       UIViewAutoresizingFlexibleTopMargin |
                                       UIViewAutoresizingFlexibleBottomMargin;
        [window addSubview:self.button];
    }
    [window bringSubviewToFront:self.button];
}

- (void)dragButton:(UIPanGestureRecognizer *)recognizer {
    UIView *button = recognizer.view;
    UIWindow *window = [self cameraWindow];
    if (button == nil || window == nil) return;
    CGPoint translation = [recognizer translationInView:window];
    CGPoint center = CGPointMake(button.center.x + translation.x, button.center.y + translation.y);
    [recognizer setTranslation:CGPointZero inView:window];
    UIEdgeInsets safe = window.safeAreaInsets;
    CGFloat radius = 24.0;
    center.x = MAX(safe.left + radius + 4, MIN(CGRectGetWidth(window.bounds) - safe.right - radius - 4, center.x));
    center.y = MAX(safe.top + radius + 4, MIN(CGRectGetHeight(window.bounds) - safe.bottom - radius - 4, center.y));
    button.center = center;
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
    NSDictionary *values = [NSDictionary dictionaryWithContentsOfFile:[VCAMConfiguration configurationPath]] ?: @{};
    BOOL enabled = [values[@"enabled"] boolValue];
    NSString *source = [values[@"source"] lowercaseString] ?: @"camera";
    NSString *sourceTitle = @"真实相机（未替换）";
    NSString *detail = @"目标：系统相机 Camera";
    if (enabled && [source isEqualToString:@"local"]) {
        NSString *file = [values[@"mediaPath"] lastPathComponent] ?: @"本地媒体";
        sourceTitle = [NSString stringWithFormat:@"本地视频：%@", file];
    } else if (enabled && [source isEqualToString:@"obs"]) {
        sourceTitle = @"直播流已启用";
        detail = [NSString stringWithFormat:@"%@\n目标：系统相机 Camera", values[@"obsWebSocketURL"] ?: @"未设置地址"];
    } else if (enabled && [source isEqualToString:@"rtsp"]) {
        sourceTitle = @"RTSP 直连已启用";
        detail = [NSString stringWithFormat:@"%@\n目标：系统相机 Camera", values[@"rtspURL"] ?: @"未设置地址"];
    }
    NSInteger rotation = [values[@"rotationDegrees"] integerValue] % 360;
    NSString *mode = [values[@"contentMode"] lowercaseString] ?: @"fill";
    NSString *localDecoderMode = [values[@"localDecoderMode"] lowercaseString] ?: @"triple";
    NSDictionary *modeNames = @{@"fit": @"完整显示", @"fill": @"裁切填满", @"stretch": @"拉伸"};
    detail = [detail stringByAppendingFormat:@"\n旋转：%ld° · 输出：%@fps", (long)rotation,
              values[@"preferredFramesPerSecond"] ?: @30];
    if ([source isEqualToString:@"local"]) {
        detail = [detail stringByAppendingFormat:@" · 解码：%@",
                  [localDecoderMode isEqualToString:@"single"] ? @"单路 AVPlayer" : @"原版三路并行"];
        NSDictionary<NSString *, id> *performance = VCAMLocalPlaybackPerformanceSnapshot();
        NSNumber *sourceFPS = performance[@"sourceFPS"];
        if (sourceFPS != nil) {
            detail = [detail stringByAppendingFormat:@"\n实时：%.1f fps · P95 %.1fms · 渲染 %.1f/%.1fms · 丢帧 %@",
                      sourceFPS.doubleValue,
                      [performance[@"sourceFrameP95Ms"] doubleValue],
                      [performance[@"renderAvgMs"] doubleValue],
                      [performance[@"renderMaxMs"] doubleValue],
                      performance[@"misses"] ?: @0];
        } else {
            detail = [detail stringByAppendingString:@"\n实时：等待首个 1 秒性能窗口"];
        }
    }
    NSDictionary<NSString *, NSNumber *> *captureDiagnostics = VCAMCaptureHookDiagnosticSnapshot();
    detail = [detail stringByAppendingFormat:@"\n诊断 Hook：拍照请求 %@ / 回调 %@；录像开始 %@ / 完成 %@",
              captureDiagnostics[@"photoRequest"], captureDiagnostics[@"photoCallback"],
              captureDiagnostics[@"recordingStart"], captureDiagnostics[@"recordingFinish"]];
    detail = [detail stringByAppendingFormat:@"\n录像复制：尝试 %@ / 成功 %@；源存在 %@ / 输出文件 %@；错误 删除%@ 复制%@",
              captureDiagnostics[@"copyAttempt"], captureDiagnostics[@"copySuccess"],
              captureDiagnostics[@"sourceExists"], captureDiagnostics[@"outputIsFileURL"],
              captureDiagnostics[@"removeError"], captureDiagnostics[@"copyError"]];
    detail = [detail stringByAppendingFormat:@"\n大小：源 %@；输出 %@ → %@ 字节",
              captureDiagnostics[@"sourceSize"], captureDiagnostics[@"outputSizeBefore"],
              captureDiagnostics[@"outputSizeAfter"]];
    return @{
        @"source": sourceTitle,
        @"detail": detail,
        @"mirror": [values[@"mirrorHorizontally"] boolValue] ? @"开启" : @"关闭",
        @"audio": [values[@"replaceAudio"] boolValue] ? @"开启" : @"关闭",
        @"loop": values[@"loopMedia"] == nil || [values[@"loopMedia"] boolValue] ? @"开启" : @"关闭",
        @"contentMode": modeNames[mode] ?: @"裁切填满",
        @"localDecoder": [localDecoderMode isEqualToString:@"single"] ? @"单路 AVPlayer" : @"原版三路",
    };
}

- (void)showSourceMenu:(UIButton *)sender {
    (void)sender;
    UIViewController *presenter = [self presentingViewController];
    if (presenter == nil || self.panel != nil) return;
    VCAMControlPanelViewController *panel = [[VCAMControlPanelViewController alloc]
        initWithStatus:[self currentStatus]];
    panel.delegate = self;
    self.panel = panel;
    [presenter presentViewController:panel animated:!UIAccessibilityIsReduceMotionEnabled() completion:nil];
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
    [self dismissPanelThen:^{ [self presentVideoPicker]; }];
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

- (void)controlPanelDidRequestAudioToggle:(VCAMControlPanelViewController *)panel {
    (void)panel;
    [self toggleAudioReplacement];
}

- (void)controlPanelDidRequestContentModeCycle:(VCAMControlPanelViewController *)panel {
    (void)panel;
    [self cycleContentMode];
}

- (void)controlPanelDidRequestLoopToggle:(VCAMControlPanelViewController *)panel {
    (void)panel;
    [self toggleLoopPlayback];
}

- (void)controlPanelDidRequestLocalDecoderToggle:(VCAMControlPanelViewController *)panel {
    (void)panel;
    [self toggleLocalDecoderMode];
}

- (void)controlPanelDidRequestRestoreCamera:(VCAMControlPanelViewController *)panel {
    (void)panel;
    [self dismissPanelThen:^{ [self restoreRealCamera]; }];
}

- (void)controlPanelDidRequestTargetSelector:(VCAMControlPanelViewController *)panel {
    (void)panel;
    [self dismissPanelThen:^{ [self presentTargetSelector]; }];
}

- (void)presentVideoPicker {
    PHPickerConfiguration *configuration = [[PHPickerConfiguration alloc] init];
    configuration.filter = PHPickerFilter.videosFilter;
    configuration.selectionLimit = 1;
    configuration.preferredAssetRepresentationMode = PHPickerConfigurationAssetRepresentationModeCurrent;
    PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:configuration];
    picker.delegate = self;
    [[self presentingViewController] presentViewController:picker animated:YES completion:nil];
}

- (void)presentDocumentPicker {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[UTTypeMovie] asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [[self presentingViewController] presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)controller;
    NSURL *url = urls.firstObject;
    if (url != nil) [self installVideoFromTemporaryURL:url suggestedName:url.lastPathComponent];
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    PHPickerResult *result = results.firstObject;
    if (result == nil) return;
    NSItemProvider *provider = result.itemProvider;
    NSString *movieType = @"public.movie";
    if (![provider hasItemConformingToTypeIdentifier:movieType]) {
        [self showMessage:@"无法读取所选视频" error:YES];
        return;
    }
    NSString *suggestedName = provider.suggestedName;
    [provider loadFileRepresentationForTypeIdentifier:movieType completionHandler:^(NSURL *url, NSError *error) {
        if (url == nil || error != nil) {
            [self showMessage:error.localizedDescription ?: @"读取相册视频失败" error:YES];
            return;
        }
        [self installVideoFromTemporaryURL:url suggestedName:suggestedName];
    }];
}

- (void)promptForOnlineVideo {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"在线源下载"
                                                                   message:@"输入 MOV、MP4 或 M4V 的 HTTPS/HTTP 直链"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"https://example.com/video.mp4";
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
        [self installVideoFromTemporaryURL:location suggestedName:name];
    }];
    [task resume];
}

- (void)promptForLiveStream {
    NSDictionary *values = [NSDictionary dictionaryWithContentsOfFile:[VCAMConfiguration configurationPath]] ?: @{};
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
        [self showMessage:isRTSP ? @"已切换到手机直连 RTSP（TCP + VideoToolbox 硬解）" :
                                      @"已切换到电脑 WebSocket 直播流" error:NO];
    }]];
    [[self presentingViewController] presentViewController:alert animated:YES completion:nil];
}

- (void)installVideoFromTemporaryURL:(NSURL *)temporaryURL suggestedName:(nullable NSString *)suggestedName {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSError *error = nil;
    NSURL *directory = [NSURL fileURLWithPath:[VCAMConfiguration mediaDirectoryPath] isDirectory:YES];
    if (![manager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:&error]) {
        [self showMessage:error.localizedDescription error:YES];
        return;
    }
    NSString *extension = temporaryURL.pathExtension.lowercaseString;
    if (extension.length == 0) extension = suggestedName.pathExtension.lowercaseString;
    if (![@[@"mov", @"mp4", @"m4v"] containsObject:extension]) extension = @"mov";
    NSURL *incomingURL = [directory URLByAppendingPathComponent:
        [NSString stringWithFormat:@".incoming-%@.%@", NSUUID.UUID.UUIDString, extension]];
    NSURL *destinationURL = [directory URLByAppendingPathComponent:
        [NSString stringWithFormat:@"selected.%@", extension]];
    if (![manager copyItemAtURL:temporaryURL toURL:incomingURL error:&error]) {
        [self showMessage:error.localizedDescription error:YES];
        return;
    }
    if ([manager fileExistsAtPath:destinationURL.path]) {
        if (![manager replaceItemAtURL:destinationURL withItemAtURL:incomingURL backupItemName:nil
                               options:0 resultingItemURL:nil error:&error]) {
            [manager removeItemAtURL:incomingURL error:nil];
            [self showMessage:error.localizedDescription error:YES];
            return;
        }
    } else if (![manager moveItemAtURL:incomingURL toURL:destinationURL error:&error]) {
        [manager removeItemAtURL:incomingURL error:nil];
        [self showMessage:error.localizedDescription error:YES];
        return;
    }
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:destinationURL options:nil];
    AVAssetTrack *videoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    float nominalFrameRate = videoTrack.nominalFrameRate;
    NSInteger preferredFramesPerSecond = nominalFrameRate >= 50.0f ? 60 :
        (nominalFrameRate >= 28.0f ? 30 : (nominalFrameRate >= 20.0f ? 24 : 30));
    if (![self updatePreferences:@{@"source": @"local", @"enabled": @YES,
                                  @"mediaPath": destinationURL.path, @"loopMedia": @YES,
                                  @"localDecoderMode": @"triple",
                                  @"preferredFramesPerSecond": @(preferredFramesPerSecond)}]) {
        [self showMessage:@"视频已复制，但 VCAM 配置写入失败" error:YES];
        return;
    }
    [self postConfigurationChanged];
    [self showMessage:@"已切换到所选视频；视频将自动循环播放" error:NO];
}

- (void)rotateClockwise { [self changeRotationBy:90]; }
- (void)rotateCounterClockwise { [self changeRotationBy:270]; }

- (void)changeRotationBy:(NSInteger)delta {
    NSDictionary *values = [NSDictionary dictionaryWithContentsOfFile:[VCAMConfiguration configurationPath]] ?: @{};
    NSInteger rotationDegrees = ([values[@"rotationDegrees"] integerValue] + delta) % 360;
    if (![self updatePreferences:@{@"rotationDegrees": @(rotationDegrees)}]) return;
    [self postConfigurationChanged];
    [self dismissPanelThen:^{
        [self showMessage:[NSString stringWithFormat:@"画面已旋转到 %ld°", (long)rotationDegrees] error:NO];
    }];
}

- (void)toggleMirror {
    NSDictionary *values = [NSDictionary dictionaryWithContentsOfFile:[VCAMConfiguration configurationPath]] ?: @{};
    BOOL enabled = ![values[@"mirrorHorizontally"] boolValue];
    if (![self updatePreferences:@{@"mirrorHorizontally": @(enabled)}]) return;
    [self postConfigurationChanged];
    [self dismissPanelThen:^{ [self showMessage:enabled ? @"镜像已开启" : @"镜像已关闭" error:NO]; }];
}

- (void)toggleAudioReplacement {
    NSDictionary *values = [NSDictionary dictionaryWithContentsOfFile:[VCAMConfiguration configurationPath]] ?: @{};
    BOOL enabled = ![values[@"replaceAudio"] boolValue];
    if (![self updatePreferences:@{@"replaceAudio": @(enabled)}]) return;
    [self postConfigurationChanged];
    [self dismissPanelThen:^{ [self showMessage:enabled ? @"声音替换已开启" : @"声音替换已关闭" error:NO]; }];
}

- (void)toggleLoopPlayback {
    NSDictionary *values = [NSDictionary dictionaryWithContentsOfFile:[VCAMConfiguration configurationPath]] ?: @{};
    BOOL current = values[@"loopMedia"] == nil ? YES : [values[@"loopMedia"] boolValue];
    BOOL enabled = !current;
    if (![self updatePreferences:@{@"loopMedia": @(enabled)}]) return;
    [self postConfigurationChanged];
    [self dismissPanelThen:^{ [self showMessage:enabled ? @"视频循环已开启" : @"视频循环已关闭" error:NO]; }];
}

- (void)toggleLocalDecoderMode {
    NSDictionary *values = [NSDictionary dictionaryWithContentsOfFile:[VCAMConfiguration configurationPath]] ?: @{};
    NSString *current = [values[@"localDecoderMode"] lowercaseString] ?: @"triple";
    NSString *next = [current isEqualToString:@"single"] ? @"triple" : @"single";
    if (![self updatePreferences:@{@"localDecoderMode": next}]) return;
    [self postConfigurationChanged];
    [self dismissPanelThen:^{
        [self showMessage:[next isEqualToString:@"single"] ? @"已切换到单路 AVPlayer" : @"已切换到原版三路并行解码"
                    error:NO];
    }];
}

- (void)cycleContentMode {
    NSDictionary *values = [NSDictionary dictionaryWithContentsOfFile:[VCAMConfiguration configurationPath]] ?: @{};
    NSString *current = [values[@"contentMode"] lowercaseString] ?: @"fill";
    NSString *next = [current isEqualToString:@"fill"] ? @"fit" :
                     ([current isEqualToString:@"fit"] ? @"stretch" : @"fill");
    if (![self updatePreferences:@{@"contentMode": next}]) return;
    [self postConfigurationChanged];
    [self dismissPanelThen:^{ [self showMessage:@"画面填充方式已切换" error:NO]; }];
}

- (void)presentTargetSelector {
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"选择替换软件和进程"
                                                                   message:@"当前安全白名单只包含系统相机。第三方 App 需要按 bundle ID 加入安装包白名单后才能选择。"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [menu addAction:[UIAlertAction actionWithTitle:@"系统相机 Camera（当前）"
                                             style:UIAlertActionStyleDefault handler:nil]];
    [menu addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    UIPopoverPresentationController *popover = menu.popoverPresentationController;
    popover.sourceView = self.button;
    popover.sourceRect = self.button.bounds;
    [[self presentingViewController] presentViewController:menu animated:YES completion:nil];
}

- (void)restoreRealCamera {
    if (![self updatePreferences:@{@"source": @"camera", @"enabled": @NO}]) {
        [self showMessage:@"恢复真实相机失败" error:YES];
        return;
    }
    [self postConfigurationChanged];
    [self showMessage:@"已恢复真实相机" error:NO];
}

- (BOOL)updatePreferences:(NSDictionary<NSString *, id> *)changes {
    NSString *preferencesPath = [VCAMConfiguration configurationPath];
    if (![NSFileManager.defaultManager createDirectoryAtPath:preferencesPath.stringByDeletingLastPathComponent
                                  withIntermediateDirectories:YES attributes:nil error:nil]) return NO;
    NSMutableDictionary<NSString *, id> *preferences =
        [[NSDictionary dictionaryWithContentsOfFile:preferencesPath] mutableCopy] ?: [NSMutableDictionary dictionary];
    [preferences addEntriesFromDictionary:changes];
    return [preferences writeToFile:preferencesPath atomically:YES];
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

#import "VCAMMediaPickerController.h"
#import <PhotosUI/PhotosUI.h>
#import <UIKit/UIKit.h>
#import "../Core/VCAMConfiguration.h"

@interface VCAMMediaPickerController () <PHPickerViewControllerDelegate>
@property(nonatomic, strong, nullable) UIButton *button;
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
            ![scene isKindOfClass:UIWindowScene.class]) {
            continue;
        }
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        for (UIWindow *window in windowScene.windows) {
            if (window.isKeyWindow && !window.hidden && window.windowLevel == UIWindowLevelNormal) {
                return window;
            }
        }
        for (UIWindow *window in windowScene.windows) {
            if (!window.hidden && window.windowLevel == UIWindowLevelNormal && window.rootViewController != nil) {
                return window;
            }
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
        button.translatesAutoresizingMaskIntoConstraints = NO;
        button.accessibilityLabel = @"VCAM media source menu";
        [button setTitle:@"VCAM" forState:UIControlStateNormal];
        [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont boldSystemFontOfSize:12.0];
        button.backgroundColor = [UIColor colorWithRed:0.05 green:0.45 blue:0.95 alpha:0.82];
        button.layer.cornerRadius = 16.0;
        button.layer.borderWidth = 1.0;
        button.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.55].CGColor;
        [button addTarget:self action:@selector(showSourceMenu:) forControlEvents:UIControlEventTouchUpInside];
        self.button = button;
    }

    if (self.button.superview != window) {
        [self.button removeFromSuperview];
        [window addSubview:self.button];
        [NSLayoutConstraint activateConstraints:@[
            [self.button.leadingAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.leadingAnchor constant:10.0],
            [self.button.centerYAnchor constraintEqualToAnchor:window.centerYAnchor constant:-40.0],
            [self.button.widthAnchor constraintEqualToConstant:58.0],
            [self.button.heightAnchor constraintEqualToConstant:32.0],
        ]];
    }
    [window bringSubviewToFront:self.button];
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

- (void)showSourceMenu:(UIButton *)sender {
    (void)sender;
    UIViewController *presenter = [self presentingViewController];
    if (presenter == nil || [presenter isKindOfClass:UIAlertController.class] ||
        [presenter isKindOfClass:PHPickerViewController.class]) {
        return;
    }

    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"VCAM"
                                                                   message:@"选择相机画面来源"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [menu addAction:[UIAlertAction actionWithTitle:@"选择相册视频"
                                             style:UIAlertActionStyleDefault
                                           handler:^(__unused UIAlertAction *action) {
        [self presentVideoPicker];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"恢复真实相机"
                                             style:UIAlertActionStyleDestructive
                                           handler:^(__unused UIAlertAction *action) {
        [self restoreRealCamera];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"取消"
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];
    [presenter presentViewController:menu animated:YES completion:nil];
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
    [provider loadFileRepresentationForTypeIdentifier:movieType
                                    completionHandler:^(NSURL *url, NSError *error) {
        if (url == nil || error != nil) {
            [self showMessage:error.localizedDescription ?: @"读取相册视频失败" error:YES];
            return;
        }
        [self installVideoFromTemporaryURL:url suggestedName:suggestedName];
    }];
}

- (void)installVideoFromTemporaryURL:(NSURL *)temporaryURL suggestedName:(nullable NSString *)suggestedName {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSError *error = nil;
    NSURL *directory = [NSURL fileURLWithPath:[VCAMConfiguration mediaDirectoryPath]
                                  isDirectory:YES];
    if (![manager createDirectoryAtURL:directory
            withIntermediateDirectories:YES
                             attributes:nil
                                  error:&error]) {
        [self showMessage:error.localizedDescription error:YES];
        return;
    }

    NSString *extension = temporaryURL.pathExtension.lowercaseString;
    if (extension.length == 0) extension = suggestedName.pathExtension.lowercaseString;
    NSSet<NSString *> *allowedExtensions = [NSSet setWithArray:@[@"mov", @"mp4", @"m4v"]];
    if (![allowedExtensions containsObject:extension]) extension = @"mov";

    NSString *incomingName = [NSString stringWithFormat:@".incoming-%@.%@", NSUUID.UUID.UUIDString, extension];
    NSURL *incomingURL = [directory URLByAppendingPathComponent:incomingName];
    NSURL *destinationURL = [directory URLByAppendingPathComponent:
        [NSString stringWithFormat:@"selected.%@", extension]];
    if (![manager copyItemAtURL:temporaryURL toURL:incomingURL error:&error]) {
        [self showMessage:error.localizedDescription error:YES];
        return;
    }

    if ([manager fileExistsAtPath:destinationURL.path]) {
        if (![manager replaceItemAtURL:destinationURL
                         withItemAtURL:incomingURL
                        backupItemName:nil
                               options:0
                      resultingItemURL:nil
                                 error:&error]) {
            [manager removeItemAtURL:incomingURL error:nil];
            [self showMessage:error.localizedDescription error:YES];
            return;
        }
    } else if (![manager moveItemAtURL:incomingURL toURL:destinationURL error:&error]) {
        [manager removeItemAtURL:incomingURL error:nil];
        [self showMessage:error.localizedDescription error:YES];
        return;
    }

    if (![self updatePreferences:@{
            @"source": @"local",
            @"enabled": @YES,
            @"mediaPath": destinationURL.path,
            @"loopMedia": @YES,
        }]) {
        [self showMessage:@"视频已复制，但 VCAM 配置写入失败" error:YES];
        return;
    }
    [self postConfigurationChanged];
    [self showMessage:@"已切换到所选视频；视频将自动循环播放" error:NO];
}

- (void)restoreRealCamera {
    if (![self updatePreferences:@{
            @"source": @"camera",
            @"enabled": @NO,
        }]) {
        [self showMessage:@"恢复真实相机失败" error:YES];
        return;
    }
    [self postConfigurationChanged];
    [self showMessage:@"已恢复真实相机" error:NO];
}

- (BOOL)updatePreferences:(NSDictionary<NSString *, id> *)changes {
    NSString *preferencesPath = [VCAMConfiguration configurationPath];
    NSString *parentDirectory = preferencesPath.stringByDeletingLastPathComponent;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:parentDirectory
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil]) {
        return NO;
    }
    NSMutableDictionary<NSString *, id> *preferences =
        [[NSDictionary dictionaryWithContentsOfFile:preferencesPath] mutableCopy];
    if (preferences == nil) preferences = [NSMutableDictionary dictionary];
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

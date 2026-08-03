#import "VCAMInjectionPolicy.h"
#import "VCAMConfiguration.h"

@implementation VCAMInjectionPolicy

+ (VCAMInjectionTarget)currentTarget {
    NSString *bundle = NSBundle.mainBundle.bundleIdentifier.lowercaseString ?: @"";
    NSString *process = NSProcessInfo.processInfo.processName.lowercaseString ?: @"";
    if ([bundle isEqualToString:@"com.apple.camera"] || [process isEqualToString:@"camera"]) {
        return VCAMInjectionTargetCamera;
    }
    if ([bundle isEqualToString:@"com.apple.mobilesafari"] ||
        [bundle isEqualToString:@"com.apple.safariviewservice"] ||
        [process isEqualToString:@"mobilesafari"] ||
        [process isEqualToString:@"safariviewservice"]) {
        return VCAMInjectionTargetSafari;
    }
    if ([bundle isEqualToString:@"com.google.chrome.ios"] || [process containsString:@"chrome"]) {
        return VCAMInjectionTargetChrome;
    }
    if ([bundle containsString:@"com.apple.webkit"] || [process containsString:@"webkit"]) {
        return VCAMInjectionTargetWebKit;
    }
    if ([process isEqualToString:@"mediaserverd"]) return VCAMInjectionTargetMediaServer;
    return VCAMInjectionTargetUnknown;
}

+ (NSString *)preferenceKeyForTarget:(VCAMInjectionTarget)target {
    switch (target) {
        case VCAMInjectionTargetCamera: return @"injectionCameraEnabled";
        case VCAMInjectionTargetSafari: return @"injectionSafariEnabled";
        case VCAMInjectionTargetChrome: return @"injectionChromeEnabled";
        case VCAMInjectionTargetWebKit: return @"injectionWebKitEnabled";
        case VCAMInjectionTargetMediaServer: return @"injectionMediaServerEnabled";
        case VCAMInjectionTargetUnknown: return @"";
    }
}

+ (NSArray<NSString *> *)individualPreferenceKeys {
    return @[@"injectionCameraEnabled", @"injectionSafariEnabled", @"injectionChromeEnabled",
             @"injectionWebKitEnabled", @"injectionMediaServerEnabled"];
}

+ (BOOL)isCurrentProcessEnabledForValues:(NSDictionary<NSString *,id> *)values {
    VCAMInjectionTarget target = self.currentTarget;
    if (target == VCAMInjectionTargetUnknown) return NO;
    if (target != VCAMInjectionTargetMediaServer &&
        [values[@"injectionGlobalEnabled"] boolValue]) return YES;
    NSString *key = [self preferenceKeyForTarget:target];
    if (values[key] == nil) return target == VCAMInjectionTargetCamera;
    return [values[key] boolValue];
}

+ (BOOL)shouldShowControlUIForValues:(NSDictionary<NSString *,id> *)values {
    VCAMInjectionTarget target = self.currentTarget;
    if (target != VCAMInjectionTargetCamera && target != VCAMInjectionTargetSafari &&
        target != VCAMInjectionTargetChrome) return NO;
    return [self isCurrentProcessEnabledForValues:values];
}

+ (BOOL)shouldShowControlUI {
    return [self shouldShowControlUIForValues:[VCAMConfiguration currentValues]];
}

+ (BOOL)isCurrentProcessMediaReplacementEnabledForValues:(NSDictionary<NSString *,id> *)values {
    if (![self isCurrentProcessEnabledForValues:values]) return NO;
    BOOL mediaServerEnabled = [values[@"injectionMediaServerEnabled"] boolValue];
    if (self.currentTarget == VCAMInjectionTargetMediaServer) return mediaServerEnabled;
    return !mediaServerEnabled;
}

+ (BOOL)isCurrentProcessMediaReplacementEnabled {
    return [self isCurrentProcessMediaReplacementEnabledForValues:[VCAMConfiguration currentValues]];
}

+ (BOOL)isCurrentProcessEnabled {
    NSDictionary *values = [VCAMConfiguration currentValues];
    return [self isCurrentProcessEnabledForValues:values];
}

+ (BOOL)isRecognizedTarget { return self.currentTarget != VCAMInjectionTargetUnknown; }

+ (NSString *)displayNameForTarget:(VCAMInjectionTarget)target {
    switch (target) {
        case VCAMInjectionTargetCamera: return @"Camera";
        case VCAMInjectionTargetSafari: return @"Safari";
        case VCAMInjectionTargetChrome: return @"Chrome";
        case VCAMInjectionTargetWebKit: return @"WebKit WebContent";
        case VCAMInjectionTargetMediaServer: return @"mediaserverd";
        case VCAMInjectionTargetUnknown: return @"未知进程";
    }
}

@end

#import "VCAMInjectionPolicy.h"
#import "VCAMConfiguration.h"

@implementation VCAMInjectionPolicy

+ (VCAMInjectionTarget)currentTarget {
    NSString *bundle = NSBundle.mainBundle.bundleIdentifier.lowercaseString ?: @"";
    NSString *process = NSProcessInfo.processInfo.processName.lowercaseString ?: @"";
    if ([process isEqualToString:@"springboard"] || [bundle isEqualToString:@"com.apple.springboard"]) {
        return VCAMInjectionTargetSpringBoard;
    }
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
    if ([bundle isEqualToString:@"com.microsoft.msedge"] ||
        [bundle isEqualToString:@"com.microsoft.edge.ios"] ||
        [process containsString:@"edge"]) {
        return VCAMInjectionTargetEdge;
    }
    if ([bundle isEqualToString:@"org.mozilla.ios.firefox"] || [process containsString:@"firefox"]) {
        return VCAMInjectionTargetFirefox;
    }
    if ([bundle isEqualToString:@"com.google.GoogleMobile"] || [process containsString:@"google"]) {
        return VCAMInjectionTargetGoogle;
    }
    if ([bundle containsString:@"com.apple.webkit"] || [process containsString:@"webkit"]) {
        return VCAMInjectionTargetWebKit;
    }
    if (([process isEqualToString:@"cameracaptured"] || [process isEqualToString:@"mediaserverd"])) return VCAMInjectionTargetMediaServer;
    return VCAMInjectionTargetUnknown;
}

+ (NSString *)preferenceKeyForTarget:(VCAMInjectionTarget)target {
    switch (target) {
        case VCAMInjectionTargetCamera: return @"injectionCameraEnabled";
        case VCAMInjectionTargetSafari: return @"injectionSafariEnabled";
        case VCAMInjectionTargetChrome: return @"injectionChromeEnabled";
        case VCAMInjectionTargetEdge: return @"injectionEdgeEnabled";
        case VCAMInjectionTargetFirefox: return @"injectionFirefoxEnabled";
        case VCAMInjectionTargetGoogle: return @"injectionGoogleEnabled";
        case VCAMInjectionTargetWebKit: return @"injectionWebKitEnabled";
        case VCAMInjectionTargetMediaServer: return @"injectionMediaServerEnabled";
        case VCAMInjectionTargetSpringBoard: return @"";
        case VCAMInjectionTargetUnknown: return @"";
    }
}

+ (NSArray<NSString *> *)individualPreferenceKeys {
    return @[@"injectionCameraEnabled", @"injectionSafariEnabled", @"injectionChromeEnabled",
             @"injectionEdgeEnabled", @"injectionFirefoxEnabled", @"injectionGoogleEnabled", @"injectionWebKitEnabled",
             @"injectionMediaServerEnabled"];
}

+ (BOOL)isCurrentProcessEnabledForValues:(NSDictionary<NSString *,id> *)values {
    VCAMInjectionTarget target = self.currentTarget;
    if (target == VCAMInjectionTargetUnknown) return NO;
    if (target == VCAMInjectionTargetSpringBoard) return YES;
    if ([values[@"injectionGlobalEnabled"] boolValue]) return YES;
    NSString *key = [self preferenceKeyForTarget:target];
    if (values[key] == nil) return [self defaultEnabledForTarget:target];
    return [values[key] boolValue];
}

+ (BOOL)shouldShowControlUIForValues:(NSDictionary<NSString *,id> *)values {
    if (![self supportsControlUIInCurrentProcess]) return NO;
    return [self isCurrentProcessEnabledForValues:values];
}

+ (BOOL)supportsControlUIInCurrentProcess {
    VCAMInjectionTarget target = self.currentTarget;
    return target == VCAMInjectionTargetCamera || target == VCAMInjectionTargetSafari ||
           target == VCAMInjectionTargetChrome || target == VCAMInjectionTargetEdge ||
           target == VCAMInjectionTargetFirefox || target == VCAMInjectionTargetGoogle ||
           target == VCAMInjectionTargetSpringBoard;
}

+ (BOOL)defaultEnabledForTarget:(VCAMInjectionTarget)target {
    switch (target) {
        case VCAMInjectionTargetCamera: return YES;
        case VCAMInjectionTargetSafari: return YES;
        case VCAMInjectionTargetChrome: return YES;
        case VCAMInjectionTargetEdge: return YES;
        case VCAMInjectionTargetFirefox: return YES;
        case VCAMInjectionTargetGoogle: return YES;
        case VCAMInjectionTargetWebKit: return YES;
        case VCAMInjectionTargetMediaServer: return YES;
        case VCAMInjectionTargetSpringBoard: return YES;
        case VCAMInjectionTargetUnknown: return NO;
    }
}

+ (BOOL)shouldShowControlUI {
    return [self shouldShowControlUIForValues:[VCAMConfiguration currentValues]];
}

+ (BOOL)isCurrentProcessMediaReplacementEnabledForValues:(NSDictionary<NSString *,id> *)values {
    if (![self isCurrentProcessEnabledForValues:values]) return NO;
    if (self.currentTarget == VCAMInjectionTargetSpringBoard) return NO;
    if (self.currentTarget != VCAMInjectionTargetCamera && ![values[@"enabled"] boolValue]) return NO;
    id mediaServerValue = values[@"injectionMediaServerEnabled"];
    BOOL mediaServerEnabled = mediaServerValue == nil ? [self defaultEnabledForTarget:VCAMInjectionTargetMediaServer] : [mediaServerValue boolValue];
    if (self.currentTarget == VCAMInjectionTargetMediaServer) return mediaServerEnabled;
    NSString *source = [values[@"source"] lowercaseString];
    BOOL localOwnedByMediaServer = mediaServerEnabled && [source isEqualToString:@"local"];
    if (localOwnedByMediaServer) return NO;
    return YES;
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
        case VCAMInjectionTargetEdge: return @"Edge";
        case VCAMInjectionTargetFirefox: return @"Firefox";
        case VCAMInjectionTargetGoogle: return @"Google";
        case VCAMInjectionTargetWebKit: return @"WebKit WebContent";
        case VCAMInjectionTargetMediaServer: return @"cameracaptured";
        case VCAMInjectionTargetSpringBoard: return @"主屏 SpringBoard";
        case VCAMInjectionTargetUnknown: return @"未知进程";
    }
}

@end

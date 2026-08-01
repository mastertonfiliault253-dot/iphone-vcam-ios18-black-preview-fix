#import "VCAMConfiguration.h"

@interface VCAMConfiguration ()
@property(nonatomic, readwrite) BOOL enabled;
@property(nonatomic, readwrite) BOOL replaceAudio;
@property(nonatomic, readwrite) BOOL loopMedia;
@property(nonatomic, readwrite) BOOL mirrorHorizontally;
@property(nonatomic, readwrite) NSInteger rotationDegrees;
@property(nonatomic, readwrite) VCAMSourceKind sourceKind;
@property(nonatomic, readwrite) VCAMContentMode contentMode;
@property(nonatomic, copy, readwrite, nullable) NSString *mediaPath;
@property(nonatomic, copy, readwrite, nullable) NSString *depthImagePath;
@property(nonatomic, copy, readwrite, nullable) NSString *livePhotoStillPath;
@property(nonatomic, copy, readwrite, nullable) NSString *livePhotoMoviePath;
@property(nonatomic, copy, readwrite) NSDictionary<NSString *, id> *photoMetadata;
@property(nonatomic, copy, readwrite, nullable) NSURL *obsWebSocketURL;
@property(nonatomic, readwrite) NSInteger preferredFramesPerSecond;
@end

@implementation VCAMConfiguration

+ (NSString *)configurationPath {
    // This is user data on the real filesystem, not a jailbreak-owned file.
    // Prefixing it with /var/jb (or a randomized roothide root) is incorrect.
    return @"/var/mobile/Library/Preferences/com.codex.vcam.plist";
}

+ (instancetype)loadCurrent {
    VCAMConfiguration *configuration = [VCAMConfiguration new];
    configuration.enabled = NO;
    configuration.replaceAudio = NO;
    configuration.loopMedia = YES;
    configuration.rotationDegrees = 0;
    configuration.contentMode = VCAMContentModeAspectFill;
    configuration.preferredFramesPerSecond = 30;
    configuration.photoMetadata = @{};

    NSDictionary *values = [NSDictionary dictionaryWithContentsOfFile:self.configurationPath];
    if (![values isKindOfClass:NSDictionary.class]) {
        return configuration;
    }

    configuration.enabled = [values[@"enabled"] boolValue];
    configuration.replaceAudio = [values[@"replaceAudio"] boolValue];
    configuration.loopMedia = values[@"loopMedia"] == nil ? YES : [values[@"loopMedia"] boolValue];
    configuration.mirrorHorizontally = [values[@"mirrorHorizontally"] boolValue];
    configuration.rotationDegrees = [values[@"rotationDegrees"] integerValue] % 360;
    configuration.preferredFramesPerSecond = MAX(1, MIN(60, [values[@"preferredFramesPerSecond"] integerValue] ?: 30));

    NSString *source = [values[@"source"] lowercaseString];
    if ([source isEqualToString:@"local"]) {
        configuration.sourceKind = VCAMSourceKindLocalMedia;
    } else if ([source isEqualToString:@"obs"]) {
        configuration.sourceKind = VCAMSourceKindOBSWebSocket;
    } else {
        configuration.sourceKind = VCAMSourceKindCamera;
    }

    NSString *contentMode = [values[@"contentMode"] lowercaseString];
    if ([contentMode isEqualToString:@"fit"]) {
        configuration.contentMode = VCAMContentModeAspectFit;
    } else if ([contentMode isEqualToString:@"stretch"]) {
        configuration.contentMode = VCAMContentModeStretch;
    }

    NSString *mediaPath = values[@"mediaPath"];
    if ([mediaPath isKindOfClass:NSString.class] && mediaPath.length > 0) {
        configuration.mediaPath = mediaPath;
    }

    NSString *depthImagePath = values[@"depthImagePath"];
    if ([depthImagePath isKindOfClass:NSString.class] && depthImagePath.length > 0) {
        configuration.depthImagePath = depthImagePath;
    }
    NSString *livePhotoStillPath = values[@"livePhotoStillPath"];
    if ([livePhotoStillPath isKindOfClass:NSString.class] && livePhotoStillPath.length > 0) {
        configuration.livePhotoStillPath = livePhotoStillPath;
    }
    NSString *livePhotoMoviePath = values[@"livePhotoMoviePath"];
    if ([livePhotoMoviePath isKindOfClass:NSString.class] && livePhotoMoviePath.length > 0) {
        configuration.livePhotoMoviePath = livePhotoMoviePath;
    }
    NSDictionary *photoMetadata = values[@"photoMetadata"];
    if ([photoMetadata isKindOfClass:NSDictionary.class]) {
        configuration.photoMetadata = photoMetadata;
    }

    NSString *obsURLString = values[@"obsWebSocketURL"];
    NSURL *obsURL = [obsURLString isKindOfClass:NSString.class] ? [NSURL URLWithString:obsURLString] : nil;
    if ([obsURL.scheme.lowercaseString isEqualToString:@"ws"] ||
        [obsURL.scheme.lowercaseString isEqualToString:@"wss"]) {
        configuration.obsWebSocketURL = obsURL;
    }
    return configuration;
}

@end

#import "VCAMConfiguration.h"
#import "VCAMInjectionPolicy.h"

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
@property(nonatomic, copy, readwrite, nullable) NSURL *rtspURL;
@property(nonatomic, readwrite) NSInteger preferredFramesPerSecond;
@property(nonatomic, readwrite) VCAMLocalDecoderMode localDecoderMode;
@end

@implementation VCAMConfiguration

+ (NSString *)storageDirectoryPath {
    static NSString *resolvedPath;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSFileManager *manager = NSFileManager.defaultManager;
        NSMutableArray<NSString *> *basePaths = [NSMutableArray array];
        for (NSNumber *directoryValue in @[@(NSApplicationSupportDirectory), @(NSCachesDirectory)]) {
            NSArray<NSURL *> *urls = [manager URLsForDirectory:directoryValue.unsignedIntegerValue
                                                     inDomains:NSUserDomainMask];
            if (urls.firstObject.path.length > 0) [basePaths addObject:urls.firstObject.path];
        }
        if (NSTemporaryDirectory().length > 0) [basePaths addObject:NSTemporaryDirectory()];

        for (NSString *basePath in [NSOrderedSet orderedSetWithArray:basePaths]) {
            NSString *candidate = [basePath stringByAppendingPathComponent:@"VCAM"];
            NSError *error = nil;
            if (![manager createDirectoryAtPath:candidate
                     withIntermediateDirectories:YES
                                      attributes:nil
                                           error:&error]) {
                continue;
            }
            NSString *probePath = [candidate stringByAppendingPathComponent:@".write-probe"];
            NSData *probe = [@"VCAM" dataUsingEncoding:NSUTF8StringEncoding];
            if ([probe writeToFile:probePath options:NSDataWritingAtomic error:&error]) {
                [manager removeItemAtPath:probePath error:nil];
                resolvedPath = candidate;
                break;
            }
        }
        if (resolvedPath == nil) {
            resolvedPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"VCAM"];
        }
    });
    return resolvedPath;
}

+ (NSString *)configurationPath {
    return @"/var/mobile/Library/Preferences/com.codex.vcam.plist";
}

+ (NSString *)mediaDirectoryPath {
    return @"/var/mobile/Media/VCAM";
}

+ (NSDictionary<NSString *, id> *)currentValues {
    NSDictionary *values = [NSDictionary dictionaryWithContentsOfFile:self.configurationPath];
    if ([values isKindOfClass:NSDictionary.class]) return values;
    NSString *legacyPath = [[self storageDirectoryPath]
        stringByAppendingPathComponent:@"com.codex.vcam.plist"];
    values = [NSDictionary dictionaryWithContentsOfFile:legacyPath];
    return [values isKindOfClass:NSDictionary.class] ? values : @{};
}

+ (instancetype)loadCurrent {
    VCAMConfiguration *configuration = [VCAMConfiguration new];
    configuration.enabled = NO;
    configuration.replaceAudio = NO;
    configuration.loopMedia = YES;
    configuration.rotationDegrees = 0;
    configuration.contentMode = VCAMContentModeAspectFill;
    configuration.preferredFramesPerSecond = 30;
    configuration.localDecoderMode = VCAMLocalDecoderModeSinglePlayer;
    configuration.photoMetadata = @{};

    NSDictionary *values = [self currentValues];
    if (values.count == 0) return configuration;

    configuration.enabled = [values[@"enabled"] boolValue] &&
                            [VCAMInjectionPolicy isCurrentProcessEnabledForValues:values];
    configuration.replaceAudio = [values[@"replaceAudio"] boolValue];
    configuration.loopMedia = values[@"loopMedia"] == nil ? YES : [values[@"loopMedia"] boolValue];
    configuration.mirrorHorizontally = [values[@"mirrorHorizontally"] boolValue];
    configuration.rotationDegrees = [values[@"rotationDegrees"] integerValue] % 360;
    configuration.preferredFramesPerSecond = MAX(1, MIN(60, [values[@"preferredFramesPerSecond"] integerValue] ?: 30));
    NSString *localDecoderMode = [values[@"localDecoderMode"] lowercaseString];
    if ([localDecoderMode isEqualToString:@"triple"] ||
        [localDecoderMode isEqualToString:@"upstreamtriple"]) {
        configuration.localDecoderMode = VCAMLocalDecoderModeUpstreamTriple;
    }

    NSString *source = [values[@"source"] lowercaseString];
    if ([source isEqualToString:@"local"]) {
        configuration.sourceKind = VCAMSourceKindLocalMedia;
    } else if ([source isEqualToString:@"obs"]) {
        configuration.sourceKind = VCAMSourceKindOBSWebSocket;
    } else if ([source isEqualToString:@"rtsp"]) {
        configuration.sourceKind = VCAMSourceKindRTSP;
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
    NSString *rtspURLString = values[@"rtspURL"];
    NSURL *rtspURL = [rtspURLString isKindOfClass:NSString.class] ? [NSURL URLWithString:rtspURLString] : nil;
    if ([rtspURL.scheme.lowercaseString isEqualToString:@"rtsp"]) {
        configuration.rtspURL = rtspURL;
    }
    return configuration;
}

@end

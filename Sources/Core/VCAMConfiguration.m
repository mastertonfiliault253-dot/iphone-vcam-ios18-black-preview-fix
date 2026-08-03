#import "VCAMConfiguration.h"
#import "VCAMInjectionPolicy.h"
#import <arpa/inet.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <unistd.h>

static const uint16_t VCAMConfigurationBrokerPort = 46321;
static const NSUInteger VCAMConfigurationMaximumRequestBytes = 1024 * 1024;
static const uint8_t VCAMConfigurationBrokerUpdateCommand = 1;
static const uint8_t VCAMConfigurationBrokerReadCommand = 2;

static BOOL VCAMReadAll(int descriptor, void *bytes, size_t length) {
    uint8_t *cursor = bytes;
    while (length > 0) {
        ssize_t count = read(descriptor, cursor, length);
        if (count <= 0) return NO;
        cursor += count;
        length -= (size_t)count;
    }
    return YES;
}

static BOOL VCAMWriteAll(int descriptor, const void *bytes, size_t length) {
    const uint8_t *cursor = bytes;
    while (length > 0) {
        ssize_t count = write(descriptor, cursor, length);
        if (count <= 0) return NO;
        cursor += count;
        length -= (size_t)count;
    }
    return YES;
}

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
    return @"/var/mobile/Media/VCAM/com.codex.vcam.plist";
}

+ (NSString *)mediaDirectoryPath {
    return @"/var/mobile/Media/VCAM";
}

+ (NSDictionary<NSString *, id> *)readValuesFromDisk {
    NSDictionary *values = [NSDictionary dictionaryWithContentsOfFile:self.configurationPath];
    if ([values isKindOfClass:NSDictionary.class]) return values;
    values = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.codex.vcam.plist"];
    if ([values isKindOfClass:NSDictionary.class]) return values;
    NSString *legacyPath = [[self storageDirectoryPath]
        stringByAppendingPathComponent:@"com.codex.vcam.plist"];
    values = [NSDictionary dictionaryWithContentsOfFile:legacyPath];
    return [values isKindOfClass:NSDictionary.class] ? values : @{};
}

+ (int)connectedBrokerSocket {
    int descriptor = socket(AF_INET, SOCK_STREAM, 0);
    if (descriptor < 0) return -1;
    int noSignal = 1;
    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, sizeof(noSignal));
    struct timeval timeout = {.tv_sec = 2, .tv_usec = 0};
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    struct sockaddr_in address = {0};
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_port = htons(VCAMConfigurationBrokerPort);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(descriptor, (struct sockaddr *)&address, sizeof(address)) != 0) {
        close(descriptor);
        return -1;
    }
    return descriptor;
}

+ (NSDictionary<NSString *, id> *)copyValuesFromBroker {
    int descriptor = [self connectedBrokerSocket];
    if (descriptor < 0) return @{};
    uint8_t command = VCAMConfigurationBrokerReadCommand;
    uint32_t networkLength = 0;
    BOOL success = VCAMWriteAll(descriptor, &command, sizeof(command)) &&
                   VCAMReadAll(descriptor, &networkLength, sizeof(networkLength));
    NSUInteger length = ntohl(networkLength);
    success = success && length > 0 && length <= VCAMConfigurationMaximumRequestBytes;
    NSMutableData *data = success ? [NSMutableData dataWithLength:length] : nil;
    if (success) success = VCAMReadAll(descriptor, data.mutableBytes, length);
    close(descriptor);
    NSDictionary *values = success ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [values isKindOfClass:NSDictionary.class] ? values : @{};
}

+ (NSDictionary<NSString *, id> *)currentValues {
    NSDictionary *values = [self readValuesFromDisk];
    if (values.count > 0 || self.isWriteBrokerHost) return values;
    return [self copyValuesFromBroker];
}

+ (NSSet<NSString *> *)allowedPreferenceKeys {
    static NSSet<NSString *> *keys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys = [NSSet setWithArray:@[
            @"enabled", @"source", @"mediaPath", @"loopMedia", @"localDecoderMode",
            @"preferredFramesPerSecond", @"rotationDegrees", @"mirrorHorizontally",
            @"replaceAudio", @"contentMode", @"obsWebSocketURL", @"rtspURL",
            @"depthImagePath", @"livePhotoStillPath", @"livePhotoMoviePath", @"photoMetadata",
            @"injectionGlobalEnabled", @"injectionCameraEnabled", @"injectionSafariEnabled",
            @"injectionChromeEnabled", @"injectionWebKitEnabled", @"injectionMediaServerEnabled",
            @"floatingButtonPositions", @"floatingButtonVisibility",
        ]];
    });
    return keys;
}

+ (BOOL)validateChanges:(NSDictionary<NSString *, id> *)changes error:(NSError **)error {
    if (![changes isKindOfClass:NSDictionary.class] || changes.count == 0 ||
        changes.count > self.allowedPreferenceKeys.count) {
        if (error != NULL) *error = [NSError errorWithDomain:@"com.codex.vcam.configuration"
                                                       code:1 userInfo:@{NSLocalizedDescriptionKey: @"配置变更为空或过大"}];
        return NO;
    }
    for (NSString *key in changes) {
        if (![key isKindOfClass:NSString.class] || ![self.allowedPreferenceKeys containsObject:key]) {
            if (error != NULL) *error = [NSError errorWithDomain:@"com.codex.vcam.configuration"
                                                           code:2 userInfo:@{NSLocalizedDescriptionKey: @"配置包含未允许的键"}];
            return NO;
        }
    }
    if (![NSJSONSerialization isValidJSONObject:changes]) {
        if (error != NULL) *error = [NSError errorWithDomain:@"com.codex.vcam.configuration"
                                                       code:3 userInfo:@{NSLocalizedDescriptionKey: @"配置值无法序列化"}];
        return NO;
    }
    return YES;
}

+ (BOOL)isWriteBrokerHost {
    NSString *process = NSProcessInfo.processInfo.processName.lowercaseString ?: @"";
    return [process isEqualToString:@"springboard"];
}

+ (BOOL)writeValuesDirectly:(NSDictionary<NSString *, id> *)changes error:(NSError **)error {
    if (![self validateChanges:changes error:error]) return NO;
    NSFileManager *manager = NSFileManager.defaultManager;
    NSString *path = self.configurationPath;
    if (![manager createDirectoryAtPath:path.stringByDeletingLastPathComponent
             withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    NSMutableDictionary<NSString *, id> *merged = [[self currentValues] mutableCopy];
    if (merged == nil) merged = [NSMutableDictionary dictionary];
    [merged addEntriesFromDictionary:changes];
    BOOL written = [merged writeToFile:path atomically:YES];
    if (!written && error != NULL) {
        *error = [NSError errorWithDomain:@"com.codex.vcam.configuration" code:4
                                userInfo:@{NSLocalizedDescriptionKey: @"SpringBoard 无法写入共享配置"}];
    }
    if (written) {
        [manager setAttributes:@{NSFileOwnerAccountName: @"mobile", NSFileGroupOwnerAccountName: @"mobile",
                                 NSFilePosixPermissions: @0644}
                  ofItemAtPath:path error:nil];
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFSTR("com.codex.vcam/preferences.changed"),
                                             NULL, NULL, true);
    }
    return written;
}

+ (BOOL)submitChangesToBroker:(NSDictionary<NSString *, id> *)changes error:(NSError **)error {
    if (![self validateChanges:changes error:error]) return NO;
    NSData *payload = [NSJSONSerialization dataWithJSONObject:changes options:0 error:error];
    if (payload.length == 0 || payload.length > VCAMConfigurationMaximumRequestBytes) return NO;
    int descriptor = [self connectedBrokerSocket];
    if (descriptor < 0) return NO;
    uint8_t command = VCAMConfigurationBrokerUpdateCommand;
    BOOL success = VCAMWriteAll(descriptor, &command, sizeof(command));
    uint32_t networkLength = htonl((uint32_t)payload.length);
    uint8_t response = 0;
    if (success) success = VCAMWriteAll(descriptor, &networkLength, sizeof(networkLength));
    if (success) success = VCAMWriteAll(descriptor, payload.bytes, payload.length);
    if (success) success = VCAMReadAll(descriptor, &response, sizeof(response)) && response == 1;
    close(descriptor);
    if (!success && error != NULL && *error == nil) {
        *error = [NSError errorWithDomain:@"com.codex.vcam.configuration" code:5
                                userInfo:@{NSLocalizedDescriptionKey: @"主屏配置服务不可用"}];
    }
    return success;
}

+ (BOOL)updateValues:(NSDictionary<NSString *, id> *)changes {
    return [self updateValues:changes error:nil];
}

+ (BOOL)updateValues:(NSDictionary<NSString *, id> *)changes error:(NSError **)error {
    return self.isWriteBrokerHost ? [self writeValuesDirectly:changes error:error]
                                  : [self submitChangesToBroker:changes error:error];
}

+ (void)startWriteBroker {
    if (!self.isWriteBrokerHost) return;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            int server = socket(AF_INET, SOCK_STREAM, 0);
            if (server < 0) return;
            int reuse = 1;
            setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
            struct sockaddr_in address = {0};
            address.sin_len = sizeof(address);
            address.sin_family = AF_INET;
            address.sin_port = htons(VCAMConfigurationBrokerPort);
            address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
            if (bind(server, (struct sockaddr *)&address, sizeof(address)) != 0 || listen(server, 8) != 0) {
                close(server);
                return;
            }
            while (YES) {
                int client = accept(server, NULL, NULL);
                if (client < 0) continue;
                @autoreleasepool {
                    uint8_t command = 0;
                    BOOL success = VCAMReadAll(client, &command, sizeof(command));
                    if (success && command == VCAMConfigurationBrokerReadCommand) {
                        NSDictionary *values = [self readValuesFromDisk];
                        NSData *data = [NSJSONSerialization dataWithJSONObject:values options:0 error:nil];
                        uint32_t responseLength = htonl((uint32_t)data.length);
                        VCAMWriteAll(client, &responseLength, sizeof(responseLength));
                        if (data.length > 0) VCAMWriteAll(client, data.bytes, data.length);
                        close(client);
                        continue;
                    }
                    uint32_t networkLength = 0;
                    success = success && command == VCAMConfigurationBrokerUpdateCommand &&
                              VCAMReadAll(client, &networkLength, sizeof(networkLength));
                    NSUInteger length = ntohl(networkLength);
                    success = success && length > 0 && length <= VCAMConfigurationMaximumRequestBytes;
                    NSMutableData *data = success ? [NSMutableData dataWithLength:length] : nil;
                    if (success) success = VCAMReadAll(client, data.mutableBytes, length);
                    NSDictionary *changes = success
                        ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
                    if (success) success = [self writeValuesDirectly:changes error:nil];
                    uint8_t response = success ? 1 : 0;
                    VCAMWriteAll(client, &response, sizeof(response));
                }
                close(client);
            }
        });
    });
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
                            [VCAMInjectionPolicy isCurrentProcessMediaReplacementEnabledForValues:values];
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

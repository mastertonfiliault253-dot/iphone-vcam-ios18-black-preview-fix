#import "VCAMConfiguration.h"
#import "../Shared/VCAMSharedFrame.h"
#import <arpa/inet.h>
#import <netinet/in.h>
#import <errno.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <sys/socket.h>
#import <unistd.h>

static const uint16_t VCAMConfigurationBrokerPort = 46321;
static const NSUInteger VCAMConfigurationMaximumRequestBytes = 1024 * 1024;
static const uint8_t VCAMConfigurationBrokerUpdateCommand = 1;
static const uint8_t VCAMConfigurationBrokerReadCommand = 2;
static const uint8_t VCAMConfigurationBrokerLegacyImportCommand = 3;
static const uint8_t VCAMConfigurationBrokerFetchMediaCommand = 4;
static const uint8_t VCAMConfigurationBrokerImportCommand = 5;

static BOOL VCAMReadAll(int descriptor, void *bytes, size_t length) {
    uint8_t *cursor = bytes;
    while (length > 0) {
        ssize_t count = read(descriptor, cursor, length);
        if (count < 0 && errno == EINTR) continue;
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
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return NO;
        cursor += count;
        length -= (size_t)count;
    }
    return YES;
}

static NSError *VCAMConfigurationError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"com.codex.vcam.configuration" code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"VCAM operation failed"}];
}

static void VCAMPruneImportedMediaFiles(NSFileManager *manager,
                                        NSString *directory,
                                        NSString *currentPath) {
    NSArray<NSString *> *names = [manager contentsOfDirectoryAtPath:directory error:nil];
    NSMutableArray<NSDictionary<NSString *, id> *> *imports = [NSMutableArray array];
    for (NSString *name in names) {
        if (![name hasPrefix:@"selected-"]) continue;
        NSString *path = [directory stringByAppendingPathComponent:name];
        if ([path isEqualToString:currentPath]) continue;
        NSDictionary *attributes = [manager attributesOfItemAtPath:path error:nil];
        if (attributes == nil || [attributes[NSFileType] isEqual:NSFileTypeRegular] == NO) continue;
        [imports addObject:@{
            @"path": path,
            @"date": attributes[NSFileModificationDate] ?: NSDate.distantPast,
        }];
    }
    [imports sortUsingDescriptors:@[
        [NSSortDescriptor sortDescriptorWithKey:@"date" ascending:NO]
    ]];
    // currentPath plus the newest predecessor is the bounded two-file set.
    for (NSUInteger index = 1; index < imports.count; index++) {
        [manager removeItemAtPath:imports[index][@"path"] error:nil];
    }
}

static NSString *VCAMDiagnosticsLogPath(void) {
    return @"/var/mobile/Media/VCAM/broker-probe.log";
}

static void VCAMAppendDiagnostics(NSString *message) {
    if (message.length == 0) return;
    NSFileManager *manager = NSFileManager.defaultManager;
    NSString *directory = VCAMDiagnosticsLogPath().stringByDeletingLastPathComponent;
    if (![manager createDirectoryAtPath:directory withIntermediateDirectories:YES
                             attributes:nil error:nil]) return;
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [formatter stringFromDate:NSDate.date], message];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:VCAMDiagnosticsLogPath()];
    if (handle == nil) {
        [line writeToFile:VCAMDiagnosticsLogPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    @try {
        [handle seekToEndOfFile];
        [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    } @catch (NSException *exception) {
        (void)exception;
        [line writeToFile:VCAMDiagnosticsLogPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    [handle closeFile];
}

const char *VCAMBuildTag(void) {
    return "com.codex.vcam/0.8.57+webkit-uncompressed";
}

static BOOL VCAMWriteBrokerMessage(int descriptor, BOOL success, NSString *message) {
    NSData *data = [(message ?: @"") dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t status = success ? 1 : 0;
    uint32_t networkLength = htonl((uint32_t)data.length);
    return VCAMWriteAll(descriptor, &status, sizeof(status)) &&
           VCAMWriteAll(descriptor, &networkLength, sizeof(networkLength)) &&
           (data.length == 0 || VCAMWriteAll(descriptor, data.bytes, data.length));
}

static NSDictionary<NSString *, id> *VCAMReadBrokerMessage(int descriptor) {
    uint8_t status = 0;
    uint32_t networkLength = 0;
    if (!VCAMReadAll(descriptor, &status, sizeof(status)) ||
        !VCAMReadAll(descriptor, &networkLength, sizeof(networkLength))) return nil;
    NSUInteger length = ntohl(networkLength);
    if (length > 4096) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:length];
    if (length > 0 && !VCAMReadAll(descriptor, data.mutableBytes, length)) return nil;
    NSString *message = length > 0
        ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
    if (message == nil) return nil;
    return @{ @"success": @(status == 1), @"message": message };
}

static BOOL VCAMDrainBrokerPayload(int descriptor, unsigned long long length) {
    uint8_t buffer[16 * 1024];
    while (length > 0) {
        size_t requested = (size_t)MIN((unsigned long long)sizeof(buffer), length);
        if (!VCAMReadAll(descriptor, buffer, requested)) return NO;
        length -= requested;
    }
    return YES;
}

static BOOL VCAMSynchronizeSharedRequestedState(NSDictionary<NSString *, id> *values,
                                                NSError **error) {
    id enabledValue = values[@"enabled"];
    if (![enabledValue isKindOfClass:NSNumber.class]) {
        // Missing or unreadable configuration stays fail-closed. Never turn an
        // unknown value into an explicit request to expose the real camera.
        VCAMAppendDiagnostics(@"shared requested mode retained: no persisted enabled value");
        return YES;
    }
    BOOL enabled = [enabledValue boolValue];
    BOOL written = VCAMSharedFrameSetRequestedActive(enabled);
    VCAMAppendDiagnostics([NSString stringWithFormat:
        @"shared requested mode enabled=%d written=%d", enabled, written]);
    if (!written && error != NULL) {
        *error = [NSError errorWithDomain:@"com.codex.vcam.configuration" code:4
                                userInfo:@{NSLocalizedDescriptionKey: @"SpringBoard 无法同步共享相机状态"}];
    }
    return written;
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
@property(nonatomic, copy, readwrite, nullable) NSURL *hlsURL;
@property(nonatomic, readwrite) NSInteger preferredFramesPerSecond;
@property(nonatomic, readwrite) VCAMLocalDecoderMode localDecoderMode;
@end

@implementation VCAMConfiguration+ (NSString *)processLogPath {
    return [[self storageDirectoryPath] stringByAppendingPathComponent:@"vcam-app.log"];
}

+ (void)appendProcessLog:(NSString *)message {
    if (message.length == 0) return;
    NSFileManager *manager = NSFileManager.defaultManager;
    NSString *directory = [self processLogPath].stringByDeletingLastPathComponent;
    if (![manager createDirectoryAtPath:directory withIntermediateDirectories:YES
                             attributes:nil error:nil]) return;
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"[%@][DEBUG-vcamapp] %@\n", [formatter stringFromDate:NSDate.date], message];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:[self processLogPath]];
    if (handle == nil) {
        [line writeToFile:[self processLogPath] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    @try {
        [handle seekToEndOfFile];
        [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    } @catch (NSException *exception) {
        (void)exception;
        [line writeToFile:[self processLogPath] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    [handle closeFile];
}


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
    if ([values isKindOfClass:NSDictionary.class]) {
        VCAMAppendDiagnostics([NSString stringWithFormat:
            @"readValuesFromDisk used legacy path %@ keys=%lu",
            legacyPath, (unsigned long)values.count]);
        return values;
    }
    return @{};
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
            @"replaceAudio", @"contentMode", @"obsWebSocketURL", @"rtspURL", @"hlsURL",
            @"depthImagePath", @"livePhotoStillPath", @"livePhotoMoviePath", @"photoMetadata",
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

+ (BOOL)isMediaWorkerHost {
    NSString *process = NSProcessInfo.processInfo.processName.lowercaseString ?: @"";
    return [process isEqualToString:@"vcamd"];
}

+ (BOOL)writeValuesDirectly:(NSDictionary<NSString *, id> *)changes error:(NSError **)error {
    @synchronized (self) {
    if (![self validateChanges:changes error:error]) return NO;
    NSFileManager *manager = NSFileManager.defaultManager;
    NSString *path = self.configurationPath;
    if (![manager createDirectoryAtPath:path.stringByDeletingLastPathComponent
             withIntermediateDirectories:YES attributes:nil error:error]) {
        VCAMAppendDiagnostics([NSString stringWithFormat:
            @"writeValuesDirectly mkdir failed path=%@ errno=%d", path, errno]);
        return NO;
    }
    NSMutableDictionary<NSString *, id> *merged = [[self currentValues] mutableCopy];
    if (merged == nil) merged = [NSMutableDictionary dictionary];
    [merged addEntriesFromDictionary:changes];
    BOOL written = [merged writeToFile:path atomically:YES];
    NSDictionary *readBack = nil;
    if (written) {
        [manager setAttributes:@{NSFileOwnerAccountName: @"mobile", NSFileGroupOwnerAccountName: @"mobile",
                                 NSFilePosixPermissions: @0644}
                  ofItemAtPath:path error:nil];
        readBack = [NSDictionary dictionaryWithContentsOfFile:path];
        for (NSString *key in changes) {
            id expected = changes[key];
            id actual = readBack[key];
            if (!(expected == nil && actual == nil) && ![expected isEqual:actual]) {
                written = NO;
                break;
            }
        }
    }
    VCAMAppendDiagnostics([NSString stringWithFormat:
        @"writeValuesDirectly path=%@ written=%d mergedCount=%lu fileExists=%d keys=%@",
        path, written ? 1 : 0, (unsigned long)merged.count,
        [manager fileExistsAtPath:path] ? 1 : 0, changes.allKeys]);
    BOOL notifyConfigurationChanged = written;
    if (written && !VCAMSynchronizeSharedRequestedState(readBack, error)) {
        written = NO;
    }
    if (notifyConfigurationChanged) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFSTR("com.codex.vcam/preferences.changed"),
                                             NULL, NULL, true);
    }
    if (!written && error != NULL && *error == nil) {
        *error = [NSError errorWithDomain:@"com.codex.vcam.configuration" code:4
                                userInfo:@{NSLocalizedDescriptionKey: @"SpringBoard 无法同步共享相机状态"}];
    }
    return written;
    }
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
    if (success) {
        NSDictionary *persisted = [self copyValuesFromBroker];
        for (NSString *key in changes) {
            id expected = changes[key];
            id actual = persisted[key];
            if (!(expected == nil && actual == nil) && ![expected isEqual:actual]) {
                success = NO;
                break;
            }
        }
    }
    VCAMAppendDiagnostics([NSString stringWithFormat:
        @"submitChangesToBroker success=%d keys=%@", success ? 1 : 0, changes.allKeys]);
    if (!success && error != NULL && *error == nil) {
        *error = [NSError errorWithDomain:@"com.codex.vcam.configuration" code:5
                                userInfo:@{NSLocalizedDescriptionKey: @"主屏配置服务不可用或写入未生效"}];
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

+ (nullable NSDictionary<NSString *, id> *)validatedMediaImportHeader:
        (NSDictionary<NSString *, id> *)header error:(NSError **)error {
    id fileSizeValue = header[@"fileSize"];
    if (![fileSizeValue isKindOfClass:NSNumber.class]) {
        if (error != NULL) *error = VCAMConfigurationError(20, @"Invalid media file size");
        return nil;
    }
    unsigned long long fileSize = [fileSizeValue unsignedLongLongValue];
    if (fileSize == 0 || fileSize > 16ULL * 1024ULL * 1024ULL * 1024ULL) {
        if (error != NULL) *error = VCAMConfigurationError(20, @"Invalid media file size");
        return nil;
    }
    NSString *suggestedName = [header[@"suggestedName"] isKindOfClass:NSString.class]
        ? [header[@"suggestedName"] lastPathComponent] : nil;
    NSString *sourceName = [header[@"sourceName"] isKindOfClass:NSString.class]
        ? [header[@"sourceName"] lastPathComponent] : nil;
    NSSet<NSString *> *allowedExtensions = [NSSet setWithArray:
        @[@"mov", @"mp4", @"m4v", @"png", @"jpg", @"jpeg", @"heic", @"heif"]];
    NSString *normalizedName = nil;
    for (NSString *candidate in @[suggestedName ?: @"", sourceName ?: @""]) {
        if ([allowedExtensions containsObject:candidate.pathExtension.lowercaseString]) {
            normalizedName = candidate;
            break;
        }
    }
    if (normalizedName.length == 0) {
        if (error != NULL) *error = VCAMConfigurationError(27, @"Unsupported image or video type");
        return nil;
    }
    return @{ @"fileSize": @(fileSize), @"suggestedName": normalizedName };
}

+ (nullable NSString *)receiveImportedMediaFromClient:(int)client
                                                header:(NSDictionary<NSString *, id> *)header
                                                 error:(NSError **)error {
    unsigned long long fileSize = [header[@"fileSize"] unsignedLongLongValue];
    NSString *suggestedName = header[@"suggestedName"];
    NSString *extension = suggestedName.pathExtension.lowercaseString;

    NSFileManager *manager = NSFileManager.defaultManager;
    NSString *directory = self.mediaDirectoryPath;
    if (![manager createDirectoryAtPath:directory withIntermediateDirectories:YES
                              attributes:nil error:error]) {
        VCAMDrainBrokerPayload(client, fileSize);
        return nil;
    }
    NSString *incoming = [directory stringByAppendingPathComponent:
        [NSString stringWithFormat:@".incoming-%@.%@", NSUUID.UUID.UUIDString, extension]];
    NSString *baseName = [@"selected-" stringByAppendingString:NSUUID.UUID.UUIDString];
    NSString *destination = [[directory stringByAppendingPathComponent:baseName]
        stringByAppendingPathExtension:extension];
    int output = open(incoming.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (output < 0) {
        int openError = errno;
        VCAMDrainBrokerPayload(client, fileSize);
        if (error != NULL) *error = VCAMConfigurationError(21, @"Unable to create shared VCAM media file");
        VCAMAppendDiagnostics([NSString stringWithFormat:
            @"broker import open failed errno=%d name=%@", openError, suggestedName]);
        return nil;
    }
    const size_t bufferSize = 256 * 1024;
    void *buffer = malloc(bufferSize);
    if (buffer == NULL) {
        close(output);
        [manager removeItemAtPath:incoming error:nil];
        VCAMDrainBrokerPayload(client, fileSize);
        if (error != NULL) *error = VCAMConfigurationError(29, @"Unable to allocate the VCAM import buffer");
        return nil;
    }
    unsigned long long remaining = fileSize;
    BOOL readSuccess = YES;
    BOOL writeSuccess = YES;
    int transferError = 0;
    while (readSuccess && remaining > 0) {
        size_t requested = (size_t)MIN((unsigned long long)bufferSize, remaining);
        readSuccess = VCAMReadAll(client, buffer, requested);
        if (!readSuccess) {
            transferError = errno;
            break;
        }
        if (writeSuccess && !VCAMWriteAll(output, buffer, requested)) {
            writeSuccess = NO;
            transferError = errno;
        }
        remaining -= requested;
    }
    free(buffer);
    BOOL syncSuccess = fsync(output) == 0;
    if (!syncSuccess && transferError == 0) transferError = errno;
    close(output);
    BOOL success = readSuccess && writeSuccess && syncSuccess && remaining == 0;
    if (!success) {
        [manager removeItemAtPath:incoming error:nil];
        if (error != NULL) *error = VCAMConfigurationError(22, @"Media transfer to SpringBoard was interrupted");
        VCAMAppendDiagnostics([NSString stringWithFormat:
            @"broker import transfer failed errno=%d remaining=%llu name=%@",
            transferError, remaining, suggestedName]);
        return nil;
    }
    NSError *moveError = nil;
    success = [manager moveItemAtPath:incoming toPath:destination error:&moveError];
    if (!success) {
        [manager removeItemAtPath:incoming error:nil];
        if (error != NULL) *error = moveError ?: VCAMConfigurationError(23, @"Unable to publish VCAM media file");
        return nil;
    }
    [manager setAttributes:@{NSFileOwnerAccountName: @"mobile", NSFileGroupOwnerAccountName: @"mobile",
                             NSFilePosixPermissions: @0644}
              ofItemAtPath:destination error:nil];
    // Keep the active import and one predecessor. The predecessor may still
    // have an open AVPlayer/ImageIO reader until the configuration notification
    // tears the old graph down.
    VCAMPruneImportedMediaFiles(manager, directory, destination);
    return destination;
}

+ (nullable NSString *)importMediaAtURL:(NSURL *)sourceURL
                          suggestedName:(nullable NSString *)suggestedName
                                  error:(NSError **)error {
    int input = open(sourceURL.fileSystemRepresentation, O_RDONLY);
    struct stat metadata = {0};
    if (input < 0 || fstat(input, &metadata) != 0 || metadata.st_size <= 0) {
        if (input >= 0) close(input);
        if (error != NULL) *error = VCAMConfigurationError(24, @"Unable to read the selected media");
        return nil;
    }
    int descriptor = [self connectedBrokerSocket];
    if (descriptor < 0) {
        close(input);
        if (error != NULL) *error = VCAMConfigurationError(25, @"SpringBoard VCAM service is unavailable");
        return nil;
    }
    struct timeval timeout = {.tv_sec = 120, .tv_usec = 0};
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    NSDictionary *header = @{ @"suggestedName": suggestedName ?: sourceURL.lastPathComponent ?: @"selected.mov",
                              @"sourceName": sourceURL.lastPathComponent ?: @"",
                              @"fileSize": @((unsigned long long)metadata.st_size) };
    NSData *headerData = [NSJSONSerialization dataWithJSONObject:header options:0 error:error];
    uint8_t command = VCAMConfigurationBrokerImportCommand;
    uint32_t networkLength = htonl((uint32_t)headerData.length);
    BOOL success = headerData.length > 0 &&
                   VCAMWriteAll(descriptor, &command, sizeof(command)) &&
                   VCAMWriteAll(descriptor, &networkLength, sizeof(networkLength)) &&
                   VCAMWriteAll(descriptor, headerData.bytes, headerData.length);
    NSDictionary<NSString *, id> *preflight = success ? VCAMReadBrokerMessage(descriptor) : nil;
    if (preflight == nil || ![preflight[@"success"] boolValue]) {
        close(input);
        close(descriptor);
        NSString *message = [preflight[@"message"] isKindOfClass:NSString.class]
            ? preflight[@"message"] : nil;
        if (error != NULL) *error = VCAMConfigurationError(
            26, message.length > 0 ? message : @"VCAM media import preflight failed");
        return nil;
    }

    uint8_t buffer[256 * 1024];
    unsigned long long remaining = (unsigned long long)metadata.st_size;
    NSString *transferMessage = nil;
    while (success && remaining > 0) {
        size_t requested = (size_t)MIN((unsigned long long)sizeof(buffer), remaining);
        ssize_t count = read(input, buffer, requested);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) {
            success = NO;
            transferMessage = @"The selected media changed or became unreadable during import";
            break;
        }
        if (!VCAMWriteAll(descriptor, buffer, (size_t)count)) {
            success = NO;
            transferMessage = @"Media transfer to SpringBoard was interrupted";
            break;
        }
        remaining -= (unsigned long long)count;
    }
    close(input);
    shutdown(descriptor, SHUT_WR);
    NSDictionary<NSString *, id> *response = VCAMReadBrokerMessage(descriptor);
    close(descriptor);
    NSString *message = [response[@"message"] isKindOfClass:NSString.class]
        ? response[@"message"] : nil;
    if (!success || response == nil || ![response[@"success"] boolValue]) {
        NSString *failureMessage = !success && transferMessage.length > 0
            ? transferMessage
            : (message.length > 0 ? message : @"VCAM media import failed");
        if (error != NULL) *error = VCAMConfigurationError(26, failureMessage);
        return nil;
    }
    return message;
}

+ (nullable NSString *)resolvedMediaPathForSharedPath:(NSString *)sharedPath
                                                error:(NSError **)error {
    if (![sharedPath isKindOfClass:NSString.class] || sharedPath.length == 0) {
        if (error != NULL) *error = VCAMConfigurationError(30, @"No shared media path configured");
        return nil;
    }
    static NSMutableDictionary<NSString *, NSString *> *resolvedCache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ resolvedCache = [NSMutableDictionary dictionary]; });
    @synchronized (resolvedCache) {
        NSString *cached = resolvedCache[sharedPath];
        if (cached.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:cached]) {
            return cached;
        }
    }

    if (self.isWriteBrokerHost || self.isMediaWorkerHost) {
        int probe = open(sharedPath.fileSystemRepresentation, O_RDONLY);
        if (probe >= 0) {
            close(probe);
            return sharedPath;
        }
    }

    int descriptor = [self connectedBrokerSocket];
    if (descriptor < 0) {
        if (error != NULL) *error = VCAMConfigurationError(31, @"VCAM broker unavailable for media fetch");
        return nil;
    }
    uint8_t command = VCAMConfigurationBrokerFetchMediaCommand;
    uint32_t zeroLength = 0;
    BOOL success = VCAMWriteAll(descriptor, &command, sizeof(command)) &&
                   VCAMWriteAll(descriptor, &zeroLength, sizeof(zeroLength));
    uint8_t status = 0;
    if (success) success = VCAMReadAll(descriptor, &status, sizeof(status)) && status == 1;
    uint32_t networkHeaderLength = 0;
    if (success) success = VCAMReadAll(descriptor, &networkHeaderLength, sizeof(networkHeaderLength));
    NSUInteger headerLength = ntohl(networkHeaderLength);
    success = success && headerLength > 0 && headerLength <= 4096;
    NSMutableData *headerData = success ? [NSMutableData dataWithLength:headerLength] : nil;
    if (success) success = VCAMReadAll(descriptor, headerData.mutableBytes, headerLength);
    id decodedResponseHeader = success
        ? [NSJSONSerialization JSONObjectWithData:headerData options:0 error:nil] : nil;
    NSDictionary<NSString *, id> *responseHeader =
        [decodedResponseHeader isKindOfClass:NSDictionary.class] ? decodedResponseHeader : nil;
    id fileSizeValue = responseHeader[@"fileSize"];
    success = success && [fileSizeValue isKindOfClass:NSNumber.class];
    unsigned long long fileSize = success ? [fileSizeValue unsignedLongLongValue] : 0;
    success = success && fileSize > 0 && fileSize <= 16ULL * 1024ULL * 1024ULL * 1024ULL;

    NSFileManager *manager = NSFileManager.defaultManager;
    NSString *directory = [[self storageDirectoryPath] stringByAppendingPathComponent:@"VCAM-media"];
    NSString *suggestedName = [responseHeader[@"suggestedName"] isKindOfClass:NSString.class]
        ? responseHeader[@"suggestedName"] : @"selected.mov";
    NSString *extension = suggestedName.pathExtension.lowercaseString;
    NSSet<NSString *> *allowedExtensions = [NSSet setWithArray:
        @[@"mov", @"mp4", @"m4v", @"png", @"jpg", @"jpeg", @"heic", @"heif"]];
    if (![allowedExtensions containsObject:extension]) success = NO;
    NSString *destination = [directory stringByAppendingPathComponent:
        [NSString stringWithFormat:@"selected.%@", extension]];
    success = success && [manager createDirectoryAtPath:directory withIntermediateDirectories:YES
                                              attributes:nil error:nil];
    int output = success ? open(destination.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0600) : -1;
    if (output < 0) success = NO;
    const size_t bufferSize = 256 * 1024;
    void *buffer = malloc(bufferSize);
    if (success && buffer == NULL) success = NO;
    unsigned long long remaining = fileSize;
    while (success && remaining > 0) {
        size_t requested = (size_t)MIN((unsigned long long)bufferSize, remaining);
        success = VCAMReadAll(descriptor, buffer, requested) && VCAMWriteAll(output, buffer, requested);
        remaining -= requested;
    }
    free(buffer);
    if (output >= 0) {
        fsync(output);
        close(output);
    }
    close(descriptor);
    if (!success) {
        [manager removeItemAtPath:destination error:nil];
        if (error != NULL) *error = VCAMConfigurationError(32, @"Media fetch from SpringBoard failed");
        return nil;
    }
    [manager setAttributes:@{NSFileOwnerAccountName: @"mobile", NSFileGroupOwnerAccountName: @"mobile",
                             NSFilePosixPermissions: @0600}
              ofItemAtPath:destination error:nil];
    @synchronized (resolvedCache) {
        resolvedCache[sharedPath] = destination;
    }
    VCAMAppendDiagnostics([NSString stringWithFormat:
        @"resolvedMediaPath shared=%@ local=%@ size=%llu", sharedPath, destination, fileSize]);
    return destination;
}

+ (void)startWriteBroker {
    if (!self.isWriteBrokerHost) return;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        @synchronized (self) {
            NSError *stateError = nil;
            BOOL stateSynchronized = VCAMSynchronizeSharedRequestedState(
                [self readValuesFromDisk], &stateError);
            VCAMAppendDiagnostics([NSString stringWithFormat:
                @"broker initial shared state synchronized=%d error=%@",
                stateSynchronized, stateError.localizedDescription ?: @"(none)"]);
        }
        VCAMAppendDiagnostics([NSString stringWithFormat:
            @"broker starting pid=%d tag=%s configPath=%@ mediaDir=%@",
            (int)getpid(), VCAMBuildTag(), self.configurationPath, self.mediaDirectoryPath]);
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
                int noSignal = 1;
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, sizeof(noSignal));
                struct timeval clientTimeout = {.tv_sec = 120, .tv_usec = 0};
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &clientTimeout, sizeof(clientTimeout));
                setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &clientTimeout, sizeof(clientTimeout));
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
                    BOOL importCommand = success &&
                        (command == VCAMConfigurationBrokerLegacyImportCommand ||
                         command == VCAMConfigurationBrokerImportCommand);
                    if (importCommand) {
                        BOOL preflightRequired = command == VCAMConfigurationBrokerImportCommand;
                        uint32_t networkLength = 0;
                        success = VCAMReadAll(client, &networkLength, sizeof(networkLength));
                        NSUInteger length = ntohl(networkLength);
                        success = success && length > 0 && length <= 4096;
                        NSMutableData *data = success ? [NSMutableData dataWithLength:length] : nil;
                        if (success) success = VCAMReadAll(client, data.mutableBytes, length);
                        id decodedHeader = success
                            ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
                        NSDictionary<NSString *, id> *headerDictionary =
                            [decodedHeader isKindOfClass:NSDictionary.class] ? decodedHeader : nil;
                        NSError *importError = nil;
                        NSDictionary *validatedHeader = success && headerDictionary != nil
                            ? [self validatedMediaImportHeader:headerDictionary error:&importError] : nil;
                        if (validatedHeader == nil && importError == nil) {
                            importError = VCAMConfigurationError(28, @"Invalid VCAM media import request");
                        }
                        BOOL preflightWritten = YES;
                        if (preflightRequired) {
                            preflightWritten = VCAMWriteBrokerMessage(
                                client, validatedHeader != nil, importError.localizedDescription);
                        }
                        VCAMAppendDiagnostics([NSString stringWithFormat:
                            @"broker import preflight required=%d accepted=%d written=%d name=%@ size=%@ error=%@",
                            preflightRequired, validatedHeader != nil, preflightWritten,
                            validatedHeader[@"suggestedName"] ?: headerDictionary[@"suggestedName"] ?: @"(none)",
                            validatedHeader[@"fileSize"] ?: headerDictionary[@"fileSize"] ?: @0,
                            importError.localizedDescription ?: @"(none)"]);
                        if (validatedHeader == nil || !preflightWritten) {
                            if (!preflightRequired) {
                                VCAMWriteBrokerMessage(client, NO, importError.localizedDescription);
                            }
                            close(client);
                            continue;
                        }
                        NSString *destination = [self receiveImportedMediaFromClient:client
                                                                                header:validatedHeader
                                                                                 error:&importError];
                        BOOL finalWritten = VCAMWriteBrokerMessage(
                            client, destination != nil, destination ?: importError.localizedDescription);
                        VCAMAppendDiagnostics([NSString stringWithFormat:
                            @"broker import complete success=%d written=%d destination=%@ error=%@",
                            destination != nil, finalWritten, destination ?: @"(none)",
                            importError.localizedDescription ?: @"(none)"]);
                        close(client);
                        continue;
                    }
                    if (success && command == VCAMConfigurationBrokerFetchMediaCommand) {
                        uint32_t requestLength = 0;
                        success = VCAMReadAll(client, &requestLength, sizeof(requestLength));
                        NSUInteger headerSize = ntohl(requestLength);
                        success = success && headerSize <= 4096;
                        NSMutableData *requestData = success && headerSize > 0
                            ? [NSMutableData dataWithLength:headerSize] : nil;
                        if (success && headerSize > 0) {
                            success = VCAMReadAll(client, requestData.mutableBytes, headerSize);
                        }
                        NSString *sharedPath = [self readValuesFromDisk][@"mediaPath"];
                        NSString *mediaPath = [sharedPath isKindOfClass:NSString.class] ? sharedPath : nil;
                        NSData *media = mediaPath.length > 0
                            ? [NSData dataWithContentsOfFile:mediaPath options:NSDataReadingMappedIfSafe error:nil] : nil;
                        uint8_t status = media.length > 0 ? 1 : 0;
                        VCAMWriteAll(client, &status, sizeof(status));
                        if (media.length > 0) {
                            NSDictionary *responseHeader = @{
                                @"fileSize": @(media.length),
                                @"suggestedName": mediaPath.lastPathComponent ?: @"selected.mov",
                            };
                            NSData *headerData = [NSJSONSerialization dataWithJSONObject:responseHeader options:0 error:nil];
                            uint32_t responseHeaderLength = htonl((uint32_t)headerData.length);
                            VCAMWriteAll(client, &responseHeaderLength, sizeof(responseHeaderLength));
                            VCAMWriteAll(client, headerData.bytes, headerData.length);
                            VCAMWriteAll(client, media.bytes, media.length);
                        }
                        VCAMAppendDiagnostics([NSString stringWithFormat:
                            @"broker fetch media path=%@ size=%lu", mediaPath ?: @"(none)",
                            (unsigned long)media.length]);
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
                    VCAMAppendDiagnostics([NSString stringWithFormat:
                        @"broker update response=%d keys=%@", success ? 1 : 0, changes.allKeys]);
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
    [self appendProcessLog:[NSString stringWithFormat:@"loadCurrent values=%lu enabledRaw=%d process=%@",
        (unsigned long)values.count, [values[@"enabled"] boolValue],
        NSProcessInfo.processInfo.processName ?: @"(unknown)"]];
    if (values.count == 0) return configuration;

    configuration.enabled = [values[@"enabled"] boolValue];
    configuration.replaceAudio = NO;
    configuration.loopMedia = values[@"loopMedia"] == nil ? YES : [values[@"loopMedia"] boolValue];
    configuration.mirrorHorizontally = [values[@"mirrorHorizontally"] boolValue];
    configuration.rotationDegrees = [values[@"rotationDegrees"] integerValue] % 360;
    configuration.preferredFramesPerSecond = MAX(1, MIN(60, [values[@"preferredFramesPerSecond"] integerValue] ?: 30));
    configuration.localDecoderMode = VCAMLocalDecoderModeSinglePlayer;

    NSString *source = [values[@"source"] lowercaseString];
    if ([source isEqualToString:@"local"]) {
        configuration.sourceKind = VCAMSourceKindLocalMedia;
    } else if ([source isEqualToString:@"obs"]) {
        configuration.sourceKind = VCAMSourceKindOBSWebSocket;
    } else if ([source isEqualToString:@"rtsp"]) {
        configuration.sourceKind = VCAMSourceKindRTSP;
    } else if ([source isEqualToString:@"hls"]) {
        configuration.sourceKind = VCAMSourceKindHLS;
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
        configuration.mediaPath = configuration.sourceKind == VCAMSourceKindLocalMedia
            ? [self resolvedMediaPathForSharedPath:mediaPath error:nil] ?: mediaPath
            : mediaPath;
    [self appendProcessLog:[NSString stringWithFormat:@"loadCurrent mediaPath=%@ resolved=%@", mediaPath ?: @"(none)", configuration.mediaPath ?: @"(none)"]];
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
    NSString *hlsURLString = values[@"hlsURL"];
    NSURL *hlsURL = [hlsURLString isKindOfClass:NSString.class] ? [NSURL URLWithString:hlsURLString] : nil;
    if ([@[@"http", @"https"] containsObject:hlsURL.scheme.lowercaseString]) {
        configuration.hlsURL = hlsURL;
    }
    [self appendProcessLog:[NSString stringWithFormat:@"loadCurrent final enabled=%d source=%ld mode=%ld path=%@", configuration.enabled, (long)configuration.sourceKind, (long)configuration.localDecoderMode, configuration.mediaPath ?: @"(none)"]];
    return configuration;
}

@end

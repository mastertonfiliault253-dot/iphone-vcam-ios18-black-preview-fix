#import "VCAMConfiguration.h"
#import "../Shared/VCAMSharedFrame.h"
#import "../Shared/VCAMSurfaceBroker.h"
#import <arpa/inet.h>
#import <netinet/in.h>
#import <errno.h>
#import <fcntl.h>
#import <limits.h>
#import <poll.h>
#import <sys/stat.h>
#import <sys/file.h>
#import <sys/socket.h>
#import <unistd.h>
#if VCAM_WITH_CONTROL_UI
#import <CoreImage/CoreImage.h>
#import <UIKit/UIKit.h>
#endif

#include <Security/Security.h>
#include <sys/sysctl.h>

static const uint16_t VCAMConfigurationBrokerPort = 46321;
static const NSUInteger VCAMConfigurationMaximumRequestBytes = 1024 * 1024;
static const uint8_t VCAMConfigurationBrokerUpdateCommand = 1;
static const uint8_t VCAMConfigurationBrokerReadCommand = 2;
static const uint8_t VCAMConfigurationBrokerLegacyImportCommand = 3;
static const uint8_t VCAMConfigurationBrokerImportCommand = 5;
static const uint8_t VCAMConfigurationBrokerPreviewCommand = 6;
static const NSUInteger VCAMConfigurationMaximumPreviewBytes = 2 * 1024 * 1024;

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

static uint64_t VCAMMonotonicMilliseconds(void) {
    struct timespec value = {0};
    if (clock_gettime(CLOCK_MONOTONIC, &value) != 0) return 0;
    return (uint64_t)value.tv_sec * 1000ULL + (uint64_t)value.tv_nsec / 1000000ULL;
}

static BOOL VCAMReadAllBeforeDeadline(int descriptor, void *bytes, size_t length,
                                      uint64_t deadlineMilliseconds) {
    uint8_t *cursor = bytes;
    while (length > 0) {
        uint64_t now = VCAMMonotonicMilliseconds();
        if (now == 0 || now >= deadlineMilliseconds) return NO;
        uint64_t remaining = deadlineMilliseconds - now;
        struct pollfd event = {.fd = descriptor, .events = POLLIN};
        int pollResult = poll(&event, 1, (int)MIN(remaining, (uint64_t)INT_MAX));
        if (pollResult < 0 && errno == EINTR) continue;
        if (pollResult <= 0 || (event.revents & (POLLERR | POLLHUP | POLLNVAL))) {
            return NO;
        }
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

static void VCAMAppendBoundedLine(NSString *path, NSData *line) {
    if (path.length == 0 || line.length == 0) return;
    int descriptor = open(path.fileSystemRepresentation,
                          O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (descriptor < 0) return;
    if (flock(descriptor, LOCK_EX) == 0) {
        struct stat metadata = {0};
        // ponytail: one bounded active log is enough; add archived rotations
        // only if a concrete support case needs older diagnostics.
        if (fstat(descriptor, &metadata) == 0 && metadata.st_size > 4 * 1024 * 1024) {
            (void)ftruncate(descriptor, 0);
        }
        (void)VCAMWriteAll(descriptor, line.bytes, line.length);
        (void)flock(descriptor, LOCK_UN);
    }
    close(descriptor);
}

static NSError *VCAMConfigurationError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"com.codex.vcam.configuration" code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"VCAM operation failed"}];
}

static BOOL VCAMMediaPathIsAllowed(NSString *path) {
    if (![path isKindOfClass:NSString.class] || path.length == 0) return NO;
    NSString *root = [@"/var/mobile/Media/VCAM" stringByResolvingSymlinksInPath];
    NSString *resolved = [[path stringByStandardizingPath]
        stringByResolvingSymlinksInPath];
    return [resolved hasPrefix:[root stringByAppendingString:@"/"]];
}

static BOOL VCAMConfigurationValueIsValid(NSString *key, id value) {
    if (![key isKindOfClass:NSString.class] || value == nil) return NO;
    // floatingDotGlobal 为布尔开关（缺省 NO），与其余开关共用 NSNumber 校验。
    // screenTintEnabled=三色调光开关（缺省 NO）：SpringBoard 采屏色→notifyd→相机侧染色。
    if ([@[@"enabled", @"loopMedia", @"mirrorHorizontally", @"replaceAudio",
           @"floatingDotGlobal", @"screenTintEnabled"] containsObject:key]) {
        return [value isKindOfClass:NSNumber.class];
    }
    if ([@[@"preferredFramesPerSecond", @"rotationDegrees"] containsObject:key]) {
        if (![value isKindOfClass:NSNumber.class]) return NO;
        NSInteger number = [value integerValue];
        return [key isEqualToString:@"preferredFramesPerSecond"]
            ? number >= 1 && number <= 60
            : number >= -359 && number <= 359;
    }
    if ([key isEqualToString:@"source"]) {
        return [value isKindOfClass:NSString.class] &&
            [@[@"camera", @"local", @"obs", @"rtsp", @"hls"]
                containsObject:[value lowercaseString]];
    }
    if ([key isEqualToString:@"contentMode"]) {
        return [value isKindOfClass:NSString.class] &&
            [@[@"fit", @"fill", @"stretch"] containsObject:[value lowercaseString]];
    }
    if ([key isEqualToString:@"localDecoderMode"]) {
        return [value isKindOfClass:NSString.class] &&
            [@[@"single", @"upstream"] containsObject:[value lowercaseString]];
    }
    if ([key isEqualToString:@"mediaPath"]) {
        return [value isKindOfClass:NSString.class] &&
            ([(NSString *)value length] == 0 || VCAMMediaPathIsAllowed(value));
    }
    if ([@[@"obsWebSocketURL", @"rtspURL", @"hlsURL", @"depthImagePath",
           @"livePhotoStillPath", @"livePhotoMoviePath"]
            containsObject:key]) {
        return [value isKindOfClass:NSString.class] &&
            [(NSString *)value length] <= 4096;
    }
    if ([@[@"photoMetadata", @"floatingButtonPositions",
           @"floatingButtonVisibility"] containsObject:key]) {
        return [value isKindOfClass:NSDictionary.class] &&
            [NSJSONSerialization isValidJSONObject:value];
    }
    if ([key isEqualToString:@"savedStreams"]) {
        if (![value isKindOfClass:NSArray.class]) return NO;
        NSArray<NSString *> *entries = (NSArray<NSString *> *)value;
        if (entries.count > 24) return NO;
        for (NSString *entry in entries) {
            if (![entry isKindOfClass:NSString.class] || entry.length == 0 || entry.length > 4096) return NO;
        }
        return [NSJSONSerialization isValidJSONObject:value];
    }
    return NO;
}

static NSDictionary<NSString *, id> *VCAMSanitizedConfigurationValues(
    NSDictionary<NSString *, id> *values) {
    if (![values isKindOfClass:NSDictionary.class]) return @{};
    NSMutableDictionary<NSString *, id> *sanitized = [NSMutableDictionary dictionary];
    [values enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
        (void)stop;
        if (VCAMConfigurationValueIsValid(key, value)) sanitized[key] = value;
    }];
    return sanitized;
}

static void VCAMPruneImportedMediaFiles(NSFileManager *manager,
                                        NSString *directory,
                                        NSString *currentPath,
                                        NSString *activePath) {
    NSArray<NSString *> *names = [manager contentsOfDirectoryAtPath:directory error:nil];
    for (NSString *name in names) {
        if (![name hasPrefix:@"selected-"]) continue;
        NSString *path = [directory stringByAppendingPathComponent:name];
        if ([path isEqualToString:currentPath] || [path isEqualToString:activePath]) continue;
        NSDictionary *attributes = [manager attributesOfItemAtPath:path error:nil];
        if (attributes == nil || [attributes[NSFileType] isEqual:NSFileTypeRegular] == NO) continue;
        [manager removeItemAtPath:path error:nil];
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
    VCAMAppendBoundedLine(VCAMDiagnosticsLogPath(),
                          [line dataUsingEncoding:NSUTF8StringEncoding]);
}

const char *VCAMBuildTag(void) {
    return "com.codex.vcam/0.8.120+wait-remote-peer";
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

static BOOL VCAMPersistedConfigurationExists(void) {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSArray<NSString *> *paths = @[
        VCAMConfiguration.configurationPath,
        @"/var/mobile/Library/Preferences/com.codex.vcam.plist",
        [[VCAMConfiguration storageDirectoryPath]
            stringByAppendingPathComponent:@"com.codex.vcam.plist"],
    ];
    for (NSString *path in paths) {
        if ([manager fileExistsAtPath:path]) return YES;
    }
    return NO;
}

static BOOL VCAMSynchronizeSharedRequestedState(NSDictionary<NSString *, id> *values,
                                                 NSError **error) {
    id enabledValue = values[@"enabled"];
    if (![enabledValue isKindOfClass:NSNumber.class]) {
        // A true first install must expose the real camera. If a persisted file
        // exists but is temporarily unreadable, retain the last shared request.
        if (VCAMPersistedConfigurationExists()) {
            VCAMAppendDiagnostics(@"shared requested mode retained: persisted enabled value unreadable");
            return YES;
        }
        enabledValue = @NO;
    }
    BOOL enabled = [enabledValue boolValue];
    if (enabled && ![VCAMConfiguration isLicensed]) {
        enabled = NO;
    }
    BOOL written = VCAMSharedFrameSetRequestedActive(enabled);
    VCAMAppendDiagnostics([NSString stringWithFormat:
        @"shared requested mode enabled=%d written=%d", enabled, written]);
    if (!written && error != NULL) {
        *error = [NSError errorWithDomain:@"com.codex.vcam.configuration" code:4
                                userInfo:@{NSLocalizedDescriptionKey: @"SpringBoard 无法同步共享相机状态"}];
    }
    return written;
}

#if VCAM_WITH_CONTROL_UI
static NSDictionary<NSString *, id> *VCAMCreateBrokerPreviewSnapshot(void) {
    static VCAMSharedFrameReader *frameReader;
    static VCAMSharedSurfaceReader *surfaceReader;
    static CVPixelBufferPoolRef framePool;
    static CVPixelBufferPoolRef framePoolNV12;
    static CIContext *context;
    static CGColorSpaceRef colorSpace;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        frameReader = VCAMSharedFrameReaderCreate();
        surfaceReader = VCAMSharedSurfaceReaderCreate();
        NSDictionary *poolAttributes = @{
            (id)kCVPixelBufferPoolMinimumBufferCountKey: @2,
        };
        NSDictionary *pixelAttributes = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferWidthKey: @(VCAMSharedFrameWidth),
            (id)kCVPixelBufferHeightKey: @(VCAMSharedFrameHeight),
        };
        CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                (__bridge CFDictionaryRef)poolAttributes,
                                (__bridge CFDictionaryRef)pixelAttributes,
                                &framePool);
        // SpringBoard's RTSP direct publisher writes video-range NV12 into
        // the ring; the reader lays bytes out by the *destination* format, so
        // an NV12 session must copy into an NV12 destination or the snapshot
        // JPEG is BGRA-misread noise (VCAMSharedFramePreviewView does the
        // same destination selection for its live path).
        NSDictionary *nv12PixelAttributes = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            (id)kCVPixelBufferWidthKey: @(VCAMSharedFrameWidth),
            (id)kCVPixelBufferHeightKey: @(VCAMSharedFrameHeight),
        };
        CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                (__bridge CFDictionaryRef)poolAttributes,
                                (__bridge CFDictionaryRef)nv12PixelAttributes,
                                &framePoolNV12);
        context = [CIContext contextWithOptions:@{
            kCIContextUseSoftwareRenderer: @NO,
        }];
        colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    });

    const uint64_t maximumAge = 2000000000ULL;
    VCAMSharedFrameMetadata frameMetadata = {0};
    VCAMSharedFrameMetadata surfaceMetadata = {0};
    BOOL hasFrame = frameReader != NULL &&
        VCAMSharedFrameReaderGetLatestMetadata(
            frameReader, maximumAge, &frameMetadata);
    BOOL hasSurface = surfaceReader != NULL &&
        VCAMSharedSurfaceReaderGetLatestMetadata(
            surfaceReader, maximumAge, &surfaceMetadata);
    if (!hasFrame && !hasSurface) return nil;
    BOOL useSurface = hasSurface && (!hasFrame ||
        surfaceMetadata.monotonicTimestampNanoseconds >=
            frameMetadata.monotonicTimestampNanoseconds);
    VCAMSharedFrameMetadata newestMetadata =
        useSurface ? surfaceMetadata : frameMetadata;

    static uint64_t cachedSequence;
    static uint64_t cachedGeneration;
    static BOOL cachedSurface;
    static NSDictionary<NSString *, id> *cachedSnapshot;
    if (cachedSnapshot != nil && newestMetadata.sequence == cachedSequence &&
        newestMetadata.surfaceGeneration == cachedGeneration &&
        useSurface == cachedSurface) {
        return cachedSnapshot;
    }

    CVPixelBufferRef pixelBuffer = NULL;
    VCAMSharedSurfaceFrame surfaceFrame = {0};
    VCAMSharedFrameMetadata copiedMetadata = {0};
    BOOL ownsPixelBuffer = NO;
    if (useSurface) {
        if (VCAMSharedSurfaceReaderCopyLatestPassive(
                surfaceReader, maximumAge, &surfaceFrame)) {
            pixelBuffer = surfaceFrame.pixelBuffer;
            copiedMetadata = surfaceFrame.metadata;
        } else if (hasFrame) {
            useSurface = NO;
        } else {
            return nil;
        }
    }
    if (!useSurface) {
        CVPixelBufferPoolRef pool = framePool;
        if (frameMetadata.pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
            frameMetadata.pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
            pool = framePoolNV12;
        }
        if (pool == NULL || CVPixelBufferPoolCreatePixelBuffer(
                kCFAllocatorDefault, pool, &pixelBuffer) !=
                kCVReturnSuccess) return nil;
        ownsPixelBuffer = YES;
        if (!VCAMSharedFrameReaderCopyLatest(
                frameReader, pixelBuffer, maximumAge, &copiedMetadata)) {
            CVPixelBufferRelease(pixelBuffer);
            return nil;
        }
    }

    size_t width = CVPixelBufferGetWidth(pixelBuffer);
    size_t height = CVPixelBufferGetHeight(pixelBuffer);
    CGFloat scale = MIN(1.0, 640.0 / (CGFloat)MAX(width, height));
    CIImage *image = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    image = [image imageByApplyingTransform:
        CGAffineTransformMakeScale(scale, scale)];
    CGRect extent = CGRectStandardize(image.extent);
    image = [image imageByApplyingTransform:CGAffineTransformMakeTranslation(
        -CGRectGetMinX(extent), -CGRectGetMinY(extent))];
    CGRect outputRect = CGRectMake(0, 0,
        MAX(1.0, ceil(CGRectGetWidth(extent))),
        MAX(1.0, ceil(CGRectGetHeight(extent))));
    CGImageRef cgImage = context != nil && colorSpace != NULL
        ? [context createCGImage:image fromRect:outputRect
                          format:kCIFormatBGRA8 colorSpace:colorSpace]
        : NULL;
    NSData *jpegData = nil;
    if (cgImage != NULL) {
        UIImage *previewImage = [UIImage imageWithCGImage:cgImage];
        jpegData = UIImageJPEGRepresentation(previewImage, 0.72);
        CGImageRelease(cgImage);
    }
    if (useSurface) VCAMSharedSurfaceFrameRelease(&surfaceFrame);
    else if (ownsPixelBuffer) CVPixelBufferRelease(pixelBuffer);
    if (jpegData.length == 0 ||
        jpegData.length > VCAMConfigurationMaximumPreviewBytes) return nil;

    cachedSequence = copiedMetadata.sequence;
    cachedGeneration = copiedMetadata.surfaceGeneration;
    cachedSurface = useSurface;
    cachedSnapshot = @{
        @"jpegData": jpegData,
        @"sequence": @(copiedMetadata.sequence),
        @"surfaceGeneration": @(copiedMetadata.surfaceGeneration),
        @"timestampNs": @(copiedMetadata.monotonicTimestampNanoseconds),
        @"width": @(width),
        @"height": @(height),
        @"surface": @(useSurface),
        @"decodeHardware": @(
            ((copiedMetadata.transferFunction & VCAMSharedFrameDecodeHardwareMask) >>
             VCAMSharedFrameDecodeHardwareShift) == 1),
    };
    return cachedSnapshot;
}
#endif

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

@implementation VCAMConfiguration


// === License verification ===

static NSData *VCAMLicensePublicKey(void) {
    static uint8_t key[294];
    static dispatch_once_t ot;
    dispatch_once(&ot, ^{
        const uint8_t raw[294] = { 48,130,1,34,48,13,6,9,42,134,72,134,247,13,1,1,1,5,0,3,130,1,15,0,48,130,1,10,2,130,1,1,0,175,122,187,177,144,70,20,255,217,92,1,161,33,229,98,7,19,121,16,43,128,120,123,186,41,226,191,230,244,25,38,233,83,178,110,128,72,12,68,177,221,223,49,204,174,44,79,92,102,145,252,230,10,133,253,253,45,149,217,36,197,143,108,66,169,54,116,52,76,158,89,80,30,21,218,26,99,173,105,169,50,47,35,241,138,197,99,53,233,219,20,72,24,122,121,125,110,212,42,53,223,193,202,102,238,174,40,10,126,111,251,80,68,73,232,43,169,101,135,223,58,44,131,127,101,97,173,108,221,46,198,121,85,234,131,153,100,252,73,175,231,37,105,93,197,156,155,211,107,63,128,182,175,62,218,215,164,74,238,119,199,104,241,117,255,167,243,76,109,234,206,198,254,0,191,225,84,10,32,102,72,199,15,233,208,228,37,199,150,186,83,12,0,22,26,188,247,74,20,67,103,83,58,116,158,238,2,35,105,102,180,192,164,88,215,35,228,90,189,80,63,214,101,77,194,134,94,100,240,132,120,105,65,169,127,79,149,253,93,192,90,213,184,108,212,218,55,102,190,146,139,43,33,196,179,153,2,3,1,0,1 };
        memcpy(key, raw, 294);
    });
    return [NSData dataWithBytes:key length:294];
}

static SecKeyRef VCAMLicenseSecKey(void) {
    static SecKeyRef cachedKey = NULL;
    static dispatch_once_t ot;
    dispatch_once(&ot, ^{
        NSData *pubKey = VCAMLicensePublicKey();
        CFErrorRef error = NULL;
        cachedKey = SecKeyCreateWithData((__bridge CFDataRef)pubKey,
            (__bridge CFDictionaryRef)@{(id)kSecAttrKeyType:(id)kSecAttrKeyTypeRSA,
                                         (id)kSecAttrKeyClass:(id)kSecAttrKeyClassPublic},
            &error);
        if (cachedKey == NULL) {
            VCAMAppendDiagnostics(@"license SecKeyCreateWithData failed");
        }
    });
    return cachedKey;
}

+ (BOOL)isLicensed {
    return [self validateLicenseFile];
}
+ (BOOL)validateLicenseFile {
    NSString *path = @"/var/mobile/Media/VCAM/license.plist";
    NSDictionary *lic = [NSDictionary dictionaryWithContentsOfFile:path];
    if (![lic isKindOfClass:NSDictionary.class]) return NO;
    NSString *udid = lic[@"udid"];
    NSString *expiry = lic[@"expiry"];
    NSData *sig = [[NSData alloc] initWithBase64EncodedString:lic[@"sig"] options:0];
    if (!udid.length || !sig.length) return NO;
    if (expiry.length > 0) {
        NSDateFormatter *df = [NSDateFormatter new];
        df.dateFormat = @"yyyy-MM-dd";
        NSDate *exp = [df dateFromString:expiry];
        if (exp != nil && [exp timeIntervalSinceNow] < 0) return NO;
    }
    NSString *payload = [NSString stringWithFormat:@"%@|%@", udid, expiry ?: @"2099-12-31"];
    NSData *payloadData = [payload dataUsingEncoding:NSUTF8StringEncoding];
    SecKeyRef secKey = VCAMLicenseSecKey();
    if (!secKey) return NO;
    CFErrorRef error = NULL;
    BOOL ok = SecKeyVerifySignature(secKey, kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256,
        (__bridge CFDataRef)payloadData, (__bridge CFDataRef)sig, &error);
    if (!ok) {
        // Retry once: Security framework can transiently fail in an
        // injected SpringBoard context (intermittent "需要授权" alert).
        VCAMAppendDiagnostics(@"license verify first attempt failed; retrying");
        ok = SecKeyVerifySignature(secKey, kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256,
            (__bridge CFDataRef)payloadData, (__bridge CFDataRef)sig, &error);
    }
    VCAMAppendDiagnostics([NSString stringWithFormat:@"license verify ok=%d", ok]);
    return ok;
}


+ (NSString *)processLogPath {
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
    VCAMAppendBoundedLine([self processLogPath],
                          [line dataUsingEncoding:NSUTF8StringEncoding]);
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
    if ([values isKindOfClass:NSDictionary.class]) {
        return VCAMSanitizedConfigurationValues(values);
    }
    values = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.codex.vcam.plist"];
    if ([values isKindOfClass:NSDictionary.class]) {
        return VCAMSanitizedConfigurationValues(values);
    }
    NSString *legacyPath = [[self storageDirectoryPath]
        stringByAppendingPathComponent:@"com.codex.vcam.plist"];
    values = [NSDictionary dictionaryWithContentsOfFile:legacyPath];
    if ([values isKindOfClass:NSDictionary.class]) {
        VCAMAppendDiagnostics([NSString stringWithFormat:
            @"readValuesFromDisk used legacy path %@ keys=%lu",
            legacyPath, (unsigned long)values.count]);
        return VCAMSanitizedConfigurationValues(values);
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

+ (NSDictionary<NSString *, id> *)copyPreviewSnapshotFromBroker {
    int descriptor = [self connectedBrokerSocket];
    if (descriptor < 0) return nil;
    struct timeval timeout = {.tv_sec = 0, .tv_usec = 500000};
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    uint8_t command = VCAMConfigurationBrokerPreviewCommand;
    uint8_t status = 0;
    BOOL success = VCAMWriteAll(descriptor, &command, sizeof(command)) &&
        VCAMReadAll(descriptor, &status, sizeof(status)) && status == 1;
    uint32_t networkHeaderLength = 0;
    if (success) {
        success = VCAMReadAll(descriptor, &networkHeaderLength,
                              sizeof(networkHeaderLength));
    }
    NSUInteger headerLength = ntohl(networkHeaderLength);
    success = success && headerLength > 0 && headerLength <= 4096;
    NSMutableData *headerData = success
        ? [NSMutableData dataWithLength:headerLength] : nil;
    if (success) {
        success = VCAMReadAll(descriptor, headerData.mutableBytes, headerLength);
    }
    id decodedHeader = success
        ? [NSJSONSerialization JSONObjectWithData:headerData options:0 error:nil]
        : nil;
    NSDictionary<NSString *, id> *header =
        [decodedHeader isKindOfClass:NSDictionary.class] ? decodedHeader : nil;
    id dataLengthValue = header[@"dataLength"];
    NSUInteger dataLength = [dataLengthValue isKindOfClass:NSNumber.class]
        ? [dataLengthValue unsignedIntegerValue] : 0;
    success = success && dataLength > 0 &&
        dataLength <= VCAMConfigurationMaximumPreviewBytes;
    NSMutableData *jpegData = success
        ? [NSMutableData dataWithLength:dataLength] : nil;
    if (success) {
        success = VCAMReadAll(descriptor, jpegData.mutableBytes, dataLength);
    }
    close(descriptor);
    if (!success) return nil;
    NSMutableDictionary<NSString *, id> *snapshot = [header mutableCopy];
    snapshot[@"jpegData"] = jpegData;
    return snapshot;
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
            @"floatingButtonPositions", @"floatingButtonVisibility", @"savedStreams",
            @"floatingDotGlobal", @"screenTintEnabled",
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
        if (!VCAMConfigurationValueIsValid(key, changes[key])) {
            if (error != NULL) *error = [NSError errorWithDomain:@"com.codex.vcam.configuration"
                                                           code:3 userInfo:@{NSLocalizedDescriptionKey: @"配置值类型或范围无效"}];
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
    BOOL previousFileExisted = [manager fileExistsAtPath:path];
    NSData *previousData = previousFileExisted
        ? [NSData dataWithContentsOfFile:path options:0 error:nil] : nil;
    if (previousFileExisted && previousData == nil) {
        if (error != NULL) {
            *error = VCAMConfigurationError(
                4, @"Unable to preserve the existing VCAM configuration");
        }
        VCAMAppendDiagnostics(@"writeValuesDirectly refused: existing config backup unreadable");
        return NO;
    }
    NSDictionary *previousValues = [NSDictionary dictionaryWithContentsOfFile:path];
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
    if (written && !VCAMSynchronizeSharedRequestedState(readBack, error)) {
        written = NO;
    }
    // cameracaptured 的沙箱读不到 /var/mobile/Media/VCAM（模式走 notifyd 就是
    // 这个原因）。photoreal/metadataBranch 这类相机侧新配置同样需要它在
    // 已授权目录里的一份镜像；cameracaptured 只按文本扫这三个键，写整个合并
    // 字典即可。镜像失败不回滚主配置（相机侧回落到缺省值，并在下次写入重试）。
    if (written) {
        NSString *mirrorPath =
            @"/var/mobile/Library/VirtualCaptureCard/VCAM/com.codex.vcam.plist";
        // cameracaptured 按裸文本扫 <key> 标签解析镜像；NSDictionary writeToFile
        // 缺省写 binary plist（无文本标签），曾导致相机侧所有配置键静默回落缺省值。
        // 镜像必须以 XML 文本格式写出。
        NSError *mirrorError = nil;
        NSData *mirrorData = [NSPropertyListSerialization dataWithPropertyList:merged
            format:NSPropertyListXMLFormat_v1_0 options:0 error:&mirrorError];
        if (mirrorData != nil) {
            [mirrorData writeToFile:mirrorPath atomically:YES];
        }
    }
    if (!written) {
        BOOL restored = previousFileExisted && previousData != nil
            ? [previousData writeToFile:path options:NSDataWritingAtomic error:nil]
            : ![manager fileExistsAtPath:path] || [manager removeItemAtPath:path error:nil];
        if (restored && previousFileExisted) {
            [manager setAttributes:@{NSFileOwnerAccountName: @"mobile",
                                     NSFileGroupOwnerAccountName: @"mobile",
                                     NSFilePosixPermissions: @0644}
                      ofItemAtPath:path error:nil];
        }
        if (restored && previousValues != nil) {
            (void)VCAMSynchronizeSharedRequestedState(previousValues, NULL);
        }
        VCAMAppendDiagnostics([NSString stringWithFormat:
            @"writeValuesDirectly rolled back restored=%d previousFile=%d",
            restored, previousFileExisted]);
    } else {
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
    if (fileSize == 0 || fileSize > 2ULL * 1024ULL * 1024ULL * 1024ULL) {
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
    NSFileManager *manager = NSFileManager.defaultManager;
    (void)[manager createDirectoryAtPath:self.mediaDirectoryPath
              withIntermediateDirectories:YES attributes:nil error:nil];
    NSDictionary *fileSystem = [manager attributesOfFileSystemForPath:
        self.mediaDirectoryPath error:nil];
    unsigned long long freeBytes = [fileSystem[NSFileSystemFreeSize]
        unsignedLongLongValue];
    if (freeBytes == 0 || freeBytes < fileSize + 256ULL * 1024ULL * 1024ULL) {
        if (error != NULL) *error = VCAMConfigurationError(
            20, @"Not enough free space for the selected media");
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
    NSDictionary *persisted = [NSDictionary dictionaryWithContentsOfFile:
        VCAMConfiguration.configurationPath];
    NSString *activePath = [persisted[@"mediaPath"] isKindOfClass:NSString.class]
        ? persisted[@"mediaPath"] : nil;
    // A received file is not active until the later configuration transaction
    // commits. Protect both that current active path and this destination; never
    // infer activity from mtime when imports overlap or activation fails.
    if ([persisted isKindOfClass:NSDictionary.class]) {
        VCAMPruneImportedMediaFiles(manager, directory, destination, activePath);
    } else {
        VCAMAppendDiagnostics(@"broker import prune skipped: active configuration unreadable");
    }
    return destination;
}

+ (nullable NSString *)importMediaAtURL:(NSURL *)sourceURL
                          suggestedName:(nullable NSString *)suggestedName
                                  error:(NSError **)error {
    if (![self isLicensed]) {
        if (error != NULL) *error = VCAMConfigurationError(28, @"VCAM is not licensed");
        return nil;
    }
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
    if (!VCAMMediaPathIsAllowed(sharedPath)) {
        if (error != NULL) *error = VCAMConfigurationError(30, @"No shared media path configured");
        return nil;
    }
    if (self.isWriteBrokerHost || self.isMediaWorkerHost) {
        int probe = open(sharedPath.fileSystemRepresentation, O_RDONLY);
        if (probe < 0) {
            if (error != NULL) *error = VCAMConfigurationError(31, @"Shared media is unreadable");
            return nil;
        }
        close(probe);
    }
    return [sharedPath stringByResolvingSymlinksInPath];
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
            dispatch_queue_t importQueue = dispatch_queue_create(
                "com.codex.vcam.configuration.import", DISPATCH_QUEUE_SERIAL);
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
                // A client must send its command/header promptly. Large media
                // transfers opt into a longer bounded timeout only after their
                // header has passed validation, so an idle socket cannot stall
                // the serial broker for two minutes.
                struct timeval clientTimeout = {.tv_sec = 2, .tv_usec = 0};
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &clientTimeout, sizeof(clientTimeout));
                setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &clientTimeout, sizeof(clientTimeout));
                @autoreleasepool {
                    uint64_t handshakeDeadline = VCAMMonotonicMilliseconds() + 2000ULL;
                    uint8_t command = 0;
                    BOOL success = VCAMReadAllBeforeDeadline(
                        client, &command, sizeof(command), handshakeDeadline);
                    if (success && command == VCAMConfigurationBrokerReadCommand) {
                        NSDictionary *values = [self readValuesFromDisk];
                        NSData *data = [NSJSONSerialization dataWithJSONObject:values options:0 error:nil];
                        uint32_t responseLength = htonl((uint32_t)data.length);
                        VCAMWriteAll(client, &responseLength, sizeof(responseLength));
                        if (data.length > 0) VCAMWriteAll(client, data.bytes, data.length);
                        close(client);
                        continue;
                    }
                    if (success && command == VCAMConfigurationBrokerPreviewCommand) {
#if VCAM_WITH_CONTROL_UI
                        NSDictionary<NSString *, id> *snapshot =
                            VCAMCreateBrokerPreviewSnapshot();
#else
                        NSDictionary<NSString *, id> *snapshot = nil;
#endif
                        NSData *jpegData = [snapshot[@"jpegData"]
                            isKindOfClass:NSData.class] ? snapshot[@"jpegData"] : nil;
                        NSMutableDictionary<NSString *, id> *header =
                            jpegData.length > 0 ? [snapshot mutableCopy] : nil;
                        [header removeObjectForKey:@"jpegData"];
                        header[@"dataLength"] = @(jpegData.length);
                        NSData *headerData = header != nil
                            ? [NSJSONSerialization dataWithJSONObject:header
                                                              options:0 error:nil]
                            : nil;
                        uint8_t previewStatus = headerData.length > 0 ? 1 : 0;
                        VCAMWriteAll(client, &previewStatus, sizeof(previewStatus));
                        if (previewStatus == 1) {
                            uint32_t responseHeaderLength =
                                htonl((uint32_t)headerData.length);
                            VCAMWriteAll(client, &responseHeaderLength,
                                         sizeof(responseHeaderLength));
                            VCAMWriteAll(client, headerData.bytes,
                                         headerData.length);
                            VCAMWriteAll(client, jpegData.bytes, jpegData.length);
                        }
                        close(client);
                        continue;
                    }
                    BOOL importCommand = success &&
                        (command == VCAMConfigurationBrokerLegacyImportCommand ||
                         command == VCAMConfigurationBrokerImportCommand);
                    if (importCommand) {
                        BOOL preflightRequired = command == VCAMConfigurationBrokerImportCommand;
                        uint32_t networkLength = 0;
                        success = VCAMReadAllBeforeDeadline(
                            client, &networkLength, sizeof(networkLength), handshakeDeadline);
                        NSUInteger length = ntohl(networkLength);
                        success = success && length > 0 && length <= 4096;
                        NSMutableData *data = success ? [NSMutableData dataWithLength:length] : nil;
                        if (success) success = VCAMReadAllBeforeDeadline(
                            client, data.mutableBytes, length, handshakeDeadline);
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
                        clientTimeout.tv_sec = 30;
                        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO,
                                   &clientTimeout, sizeof(clientTimeout));
                        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO,
                                   &clientTimeout, sizeof(clientTimeout));
                        int importClient = client;
                        NSDictionary<NSString *, id> *importHeader = [validatedHeader copy];
                        dispatch_async(importQueue, ^{
                            @autoreleasepool {
                                NSError *queuedImportError = nil;
                                NSString *destination =
                                    [self receiveImportedMediaFromClient:importClient
                                                                  header:importHeader
                                                                   error:&queuedImportError];
                                BOOL finalWritten = VCAMWriteBrokerMessage(
                                    importClient, destination != nil,
                                    destination ?: queuedImportError.localizedDescription);
                                VCAMAppendDiagnostics([NSString stringWithFormat:
                                    @"broker import complete success=%d written=%d destination=%@ error=%@",
                                    destination != nil, finalWritten,
                                    destination ?: @"(none)",
                                    queuedImportError.localizedDescription ?: @"(none)"]);
                                close(importClient);
                            }
                        });
                        continue;
                    }
                    uint32_t networkLength = 0;
                    success = success && command == VCAMConfigurationBrokerUpdateCommand &&
                              VCAMReadAllBeforeDeadline(
                                  client, &networkLength, sizeof(networkLength), handshakeDeadline);
                    NSUInteger length = ntohl(networkLength);
                    success = success && length > 0 && length <= VCAMConfigurationMaximumRequestBytes;
                    NSMutableData *data = success ? [NSMutableData dataWithLength:length] : nil;
                    if (success) success = VCAMReadAllBeforeDeadline(
                        client, data.mutableBytes, length, handshakeDeadline);
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
    if (values.count == 0) { configuration.enabled = NO; return configuration; }

    configuration.enabled = [values[@"enabled"] boolValue] && [self isLicensed];
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

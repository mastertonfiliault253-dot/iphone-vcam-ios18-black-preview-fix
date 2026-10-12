#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, VCAMSourceKind) {
    VCAMSourceKindCamera = 0,
    VCAMSourceKindLocalMedia = 1,
    VCAMSourceKindOBSWebSocket = 2,
    VCAMSourceKindRTSP = 3,
    VCAMSourceKindHLS = 4,
};

typedef NS_ENUM(NSInteger, VCAMContentMode) {
    VCAMContentModeAspectFit = 0,
    VCAMContentModeAspectFill = 1,
    VCAMContentModeStretch = 2,
};

typedef NS_ENUM(NSInteger, VCAMLocalDecoderMode) {
    VCAMLocalDecoderModeUpstreamTriple = 0,
    VCAMLocalDecoderModeSinglePlayer = 1,
};

/// Shared media-path classification: the video extension set accepted by the
/// importer. vcamd, the SpringBoard bridge and the control panel each make
/// routing decisions from this; one definition keeps the processes from
/// disagreeing about what counts as a video source.
static inline BOOL VCAMMediaPathIsVideo(NSString *_Nullable path) {
    NSString *extension = path.pathExtension.lowercaseString ?: @"";
    return [@[@"mov", @"mp4", @"m4v"] containsObject:extension];
}

/// Immutable configuration snapshot. Callers only need to load one snapshot;
/// path resolution and validation stay behind this interface.
@interface VCAMConfiguration : NSObject

@property(nonatomic, readonly) BOOL enabled;
@property(nonatomic, readonly) BOOL replaceAudio;
@property(nonatomic, readonly) BOOL loopMedia;
@property(nonatomic, readonly) BOOL mirrorHorizontally;
@property(nonatomic, readonly) NSInteger rotationDegrees;
@property(nonatomic, readonly) VCAMSourceKind sourceKind;
@property(nonatomic, readonly) VCAMContentMode contentMode;
@property(nonatomic, copy, readonly, nullable) NSString *mediaPath;
@property(nonatomic, copy, readonly, nullable) NSString *depthImagePath;
@property(nonatomic, copy, readonly, nullable) NSString *livePhotoStillPath;
@property(nonatomic, copy, readonly, nullable) NSString *livePhotoMoviePath;
@property(nonatomic, copy, readonly) NSDictionary<NSString *, id> *photoMetadata;
@property(nonatomic, copy, readonly, nullable) NSURL *obsWebSocketURL;
@property(nonatomic, copy, readonly, nullable) NSURL *rtspURL;
@property(nonatomic, copy, readonly, nullable) NSURL *hlsURL;
@property(nonatomic, readonly) NSInteger preferredFramesPerSecond;
@property(nonatomic, readonly) VCAMLocalDecoderMode localDecoderMode;

+ (instancetype)loadCurrent;
+ (NSDictionary<NSString *, id> *)currentValues;
+ (BOOL)updateValues:(NSDictionary<NSString *, id> *)changes;
+ (BOOL)updateValues:(NSDictionary<NSString *, id> *)changes error:(NSError **)error;

/// YES when a valid license.plist is present at /var/mobile/Media/VCAM/license.plist.
+ (BOOL)isLicensed;
/// Direct validation — reads license.plist every call (no dispatch_once).
+ (BOOL)validateLicenseFile;
+ (nullable NSString *)importMediaAtURL:(NSURL *)sourceURL
                          suggestedName:(nullable NSString *)suggestedName
                                  error:(NSError **)error;
+ (nullable NSString *)resolvedMediaPathForSharedPath:(NSString *)sharedPath
                                                error:(NSError **)error;
/// Returns a small JPEG preview plus shared-frame metadata through the
/// SpringBoard loopback broker. App sandboxes use this only when direct mmap
/// and IOSurface reads are unavailable.
+ (nullable NSDictionary<NSString *, id> *)copyPreviewSnapshotFromBroker;
+ (NSString *)processLogPath;
+ (void)appendProcessLog:(NSString *)message;
+ (void)startWriteBroker;
+ (NSString *)configurationPath;
+ (NSString *)mediaDirectoryPath;
+ (NSString *)storageDirectoryPath;

@end

NS_ASSUME_NONNULL_END

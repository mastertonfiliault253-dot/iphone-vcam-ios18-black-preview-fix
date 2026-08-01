#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, VCAMSourceKind) {
    VCAMSourceKindCamera = 0,
    VCAMSourceKindLocalMedia = 1,
    VCAMSourceKindOBSWebSocket = 2,
};

typedef NS_ENUM(NSInteger, VCAMContentMode) {
    VCAMContentModeAspectFit = 0,
    VCAMContentModeAspectFill = 1,
    VCAMContentModeStretch = 2,
};

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
@property(nonatomic, readonly) NSInteger preferredFramesPerSecond;

+ (instancetype)loadCurrent;
+ (NSString *)configurationPath;
+ (NSString *)mediaDirectoryPath;

@end

NS_ASSUME_NONNULL_END

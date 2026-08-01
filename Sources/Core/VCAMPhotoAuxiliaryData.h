#import <AVFoundation/AVFoundation.h>
#import "VCAMConfiguration.h"

NS_ASSUME_NONNULL_BEGIN

/// Loads optional, user-supplied test metadata through public ImageIO and
/// AVFoundation representations. It never synthesizes biometric outcomes.
@interface VCAMPhotoAuxiliaryData : NSObject
- (instancetype)initWithConfiguration:(VCAMConfiguration *)configuration;
- (nullable AVDepthData *)replacementDepthData;
- (NSDictionary<NSString *, id> *)metadataByMergingOriginal:(NSDictionary<NSString *, id> *)original;
- (nullable NSData *)pairedLivePhotoStillData;
- (nullable NSString *)pairedLivePhotoMoviePath;
@end

NS_ASSUME_NONNULL_END

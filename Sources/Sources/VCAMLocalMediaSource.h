#import <Foundation/Foundation.h>
#import "../Core/VCAMMediaSource.h"
#import "../Core/VCAMFrameRenderer.h"

NS_ASSUME_NONNULL_BEGIN

@interface VCAMLocalMediaSource : NSObject <VCAMMediaSource>
- (instancetype)initWithConfiguration:(VCAMConfiguration *)configuration
                              renderer:(VCAMFrameRenderer *)renderer;
- (BOOL)hasVideoAsset;
@end

NS_ASSUME_NONNULL_END

#import <Foundation/Foundation.h>
#import "../Core/VCAMMediaSource.h"
#import "../Core/VCAMFrameRenderer.h"

NS_ASSUME_NONNULL_BEGIN

/// Receives the latest JPEG frame from the desktop bridge over WebSocket.
/// Transport loss is fail-open: callers receive NULL and keep the real camera.
@interface VCAMOBSStreamSource : NSObject <VCAMMediaSource>
- (instancetype)initWithConfiguration:(VCAMConfiguration *)configuration
                              renderer:(VCAMFrameRenderer *)renderer;
@end

NS_ASSUME_NONNULL_END

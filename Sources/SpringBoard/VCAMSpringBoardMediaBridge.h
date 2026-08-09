#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// SpringBoard-owned HLS playback and frame publication. AVPlayer, GPU
/// rendering, buffering and diagnostics remain private to this module.
@interface VCAMSpringBoardMediaBridge : NSObject

+ (instancetype)sharedBridge;
- (void)start;
- (void)reload;
- (void)stop;
- (NSDictionary<NSString *, id> *)healthSnapshot;

@end

NS_ASSUME_NONNULL_END

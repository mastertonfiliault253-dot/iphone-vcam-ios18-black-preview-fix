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
/// One-shot diagnostic: proves whether a direct VTDecompressionSession can
/// produce frames from this SpringBoard process context. vcamd's daemon
/// context rejected every sample (-12911) on RTSP; AVPlayer playback from
/// this same process decodes fine, so this isolates whether the process
/// context (not the stream or sample shape) gates hardware decoding. Reads
/// the configured local media file as compressed samples and decodes the
/// first window directly.
- (void)runVideoToolboxHardwareSelfTest;

@end

NS_ASSUME_NONNULL_END

#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Draws the configured replacement frame into the camera's pixel buffer in
/// place.
typedef NS_ENUM(NSInteger, VCAMMediaServerReplacementResult) {
    /// Replacement is disabled / not requested: leave the real frame untouched
    /// and forward it.
    VCAMMediaServerReplacementPassedThrough = 0,
    /// Replacement pixels were written into the buffer: forward the sample.
    VCAMMediaServerReplacementDrawn,
    /// Replacement is active but produced no pixels this frame. The buffer
    /// still holds real camera pixels, so the caller must not forward the
    /// sample (fail closed: a missing, stale or unrenderable source must
    /// never expose a real camera frame).
    VCAMMediaServerReplacementFailed,
};
VCAMMediaServerReplacementResult VCAMMediaServerReplacementDrawIntoBuffer(
    CVPixelBufferRef targetBuffer);

#ifdef __cplusplus
}
#endif

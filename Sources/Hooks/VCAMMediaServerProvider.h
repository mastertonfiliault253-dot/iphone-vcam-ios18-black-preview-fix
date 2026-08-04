#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

/// Draws the configured replacement frame into the camera's pixel buffer in
/// place. Returns YES when a frame was drawn, NO to leave the real frame
/// unchanged (fail-open).
BOOL VCAMMediaServerReplacementDrawsIntoBuffer(CVPixelBufferRef targetBuffer);
#import <CoreVideo/CoreVideo.h>

#include <libavutil/frame.h>

// Fast YUV -> BGRA conversion for decoded AVFrames (RTSP and local FFmpeg
// software paths). Uses Accelerate/vImage when the input layout and row
// alignment allow it, and falls back to the historical scalar loop otherwise.
// The output is a caller-owned BGRA CVPixelBuffer scaled so the longer edge
// is at most 1920 pixels (the shared-frame contract).
CVPixelBufferRef VCAMCopyBGRAFromAVFrame(AVFrame *frame);

// Losslessly repacks an 8-bit FFmpeg YUV420P/NV12 frame into a caller-owned
// NV12 CVPixelBuffer. No RGB conversion or scaling is performed.
CVPixelBufferRef VCAMCopyNV12FromAVFrame(AVFrame *frame);

// Fast NV12 -> BGRA conversion between equal-sized CVPixelBuffers (used by
// the frame renderer for hardware decoder output). Returns NO when the input
// is not NV12, dimensions do not match, or vImage is unavailable.
BOOL VCAMCopyNV12PixelBufferToBGRA(CVPixelBufferRef source,
                                   CVPixelBufferRef destination);

// Converts, orients, mirrors, and scales an NV12 buffer into a BGRA camera
// buffer without creating a CGImage. rotationDegrees must be a multiple of 90.
// contentMode uses the VCAMContentMode numeric values (fit=0, fill=1,
// stretch=2) without coupling this low-level converter to configuration code.
BOOL VCAMRenderNV12PixelBufferToBGRA(CVPixelBufferRef source,
                                     CVPixelBufferRef destination,
                                     int rotationDegrees,
                                     BOOL mirrorHorizontally,
                                     int contentMode);

// Orients, mirrors, and scales an existing BGRA buffer into a BGRA camera
// buffer without the expensive CVPixelBuffer -> CGImage -> CGContext path.
BOOL VCAMRenderBGRAPixelBufferToBGRA(CVPixelBufferRef source,
                                     CVPixelBufferRef destination,
                                     int rotationDegrees,
                                     BOOL mirrorHorizontally,
                                     int contentMode);

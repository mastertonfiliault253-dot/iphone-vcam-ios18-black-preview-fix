#import <CoreVideo/CoreVideo.h>

#include <libavutil/frame.h>

// Fast YUV -> BGRA conversion for decoded AVFrames (RTSP and local FFmpeg
// software paths). Uses Accelerate/vImage when the input layout and row
// alignment allow it, and falls back to the historical scalar loop otherwise.
// The output is a caller-owned BGRA CVPixelBuffer scaled so the longer edge
// is at most 1920 pixels (the shared-frame contract).
CVPixelBufferRef VCAMCopyBGRAFromAVFrame(AVFrame *frame);

// Fast NV12 -> BGRA conversion between equal-sized CVPixelBuffers (used by
// the frame renderer for hardware decoder output). Returns NO when the input
// is not NV12, dimensions do not match, or vImage is unavailable.
BOOL VCAMCopyNV12PixelBufferToBGRA(CVPixelBufferRef source,
                                   CVPixelBufferRef destination);

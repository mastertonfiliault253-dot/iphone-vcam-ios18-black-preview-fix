#import <CoreMedia/CoreMedia.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

void VCAMRefLog(const char *message);
void loadReplacementMedia(void);
BOOL VCAMVirtualModeIsEnabled(void);
BOOL VCAMTargetBufferIsSupported(CVPixelBufferRef targetBuffer);

typedef enum VCAMFramePresentation {
    // The real camera graph still owns target size, pixel format, timing and
    // attachments. This value only selects how canonical VCAM pixels are
    // composed into that already-negotiated target.
    VCAMFramePresentationRealtimeFill = 0,
    VCAMFramePresentationCameraPreviewFit,
    VCAMFramePresentationWebKitFill,
    VCAMFramePresentationStillPhotoFill,
} VCAMFramePresentation;

BOOL drawReplacementOntoBuffer(CVPixelBufferRef targetBuffer,
                               VCAMFramePresentation presentation,
                               CVPixelBufferRef *replacementBufferOut,
                               BOOL *stillPhotoRequiresRightOrientationOut);

// iOS 18 cameracaptured does not accept a VCAM-created CMSampleBuffer in the
// BWNodeOutput callback. Copy a compressed replacement back into the original
// graph-owned pixel buffer so the caller can forward the original sample.
BOOL VCAMCopyReplacementBufferIntoTarget(CVPixelBufferRef replacementBuffer,
                                         CVPixelBufferRef targetBuffer);

#ifdef __cplusplus
}
#endif

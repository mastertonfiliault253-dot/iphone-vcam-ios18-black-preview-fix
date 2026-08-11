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
    VCAMFramePresentationWebKitFit,
    VCAMFramePresentationStillPhotoFill,
} VCAMFramePresentation;

BOOL drawReplacementOntoBuffer(CVPixelBufferRef targetBuffer,
                               VCAMFramePresentation presentation,
                               CVPixelBufferRef *replacementBufferOut,
                               BOOL *stillPhotoRequiresRightOrientationOut);

#ifdef __cplusplus
}
#endif

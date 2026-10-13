#import <CoreMedia/CoreMedia.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

void VCAMRefLog(const char *message);
void loadReplacementMedia(void);
BOOL VCAMVirtualModeIsEnabled(void);
// metadataBranch=replace 时让元数据分支也走替换路由（默认 0=passthrough，
// 保持物理 QR 识别）。决策点在 VCAMMediaServerRefEntry.xm 的 Preview Splitter。
int VCAMMetadataBranchReplaceEnabled(void);
BOOL VCAMTargetBufferIsSupported(CVPixelBufferRef targetBuffer);
void VCAMSetLastCameraIsFront(BOOL isFront);
BOOL VCAMLastCameraIsFront(void);

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

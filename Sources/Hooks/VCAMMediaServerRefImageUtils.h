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
// 路线 A：cameracaptured 内 BW 图设备节点观测到的真实 torch 电平（0..1）。
void VCAMSetObservedTorchLevel(double level);
// 路线 A-2（AE↔亮度全耦合）：真实传感器曝光终值（曝光时长秒 + ISO）。
// 来源=BW 设备节点 setExposureModeCustomWith...ISO: 控制路径，或输出
// sample buffer attachment 数据路径（auto-AE 不经过 setter，只有后者能覆盖）。
void VCAMSetObservedExposure(double durationSeconds, double iso);
// EV 补偿请求（setExposureTargetBias:）：不参与增益计算（终值已含在
// duration×ISO 里），仅记录进 photoreal_state.log 供对表。
void VCAMSetObservedExposureBias(double biasEV);
// 物理设备切换（前↔后摄像头、或 BW 设备实例更换）时作废全部真实相机观测
// 与基线。前后面切换由 SetLastCameraIsFront 内部调用；Entry 的 hook 检测到
// receiver 实例变化时也调用（同一 App 内切换物理设备不一定翻转 front 标志）。
void VCAMResetObservedPhysicalState(void);
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

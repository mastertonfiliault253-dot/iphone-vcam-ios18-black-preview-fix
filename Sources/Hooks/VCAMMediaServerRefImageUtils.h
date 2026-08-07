#import <CoreMedia/CoreMedia.h>

#ifdef __cplusplus
extern "C" {
#endif

void VCAMRefLog(const char *message);
void loadReplacementMedia(void);
BOOL VCAMVirtualModeIsEnabled(void);
BOOL VCAMTargetBufferIsSupported(CVPixelBufferRef targetBuffer);
BOOL drawReplacementOntoBuffer(CVPixelBufferRef targetBuffer, BOOL realtimeBudget,
                               BOOL aspectFit,
                               CVPixelBufferRef *replacementBufferOut);

#ifdef __cplusplus
}
#endif

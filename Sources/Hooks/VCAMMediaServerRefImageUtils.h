#import <CoreMedia/CoreMedia.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

void VCAMRefLog(const char *message);
void loadReplacementMedia(void);
BOOL VCAMVirtualModeIsEnabled(void);
BOOL VCAMTargetBufferIsSupported(CVPixelBufferRef targetBuffer);
BOOL drawReplacementOntoBuffer(CVPixelBufferRef targetBuffer,
                               BOOL realtimeCompensation, BOOL aspectFit,
                               BOOL webKitLandscapeStorage,
                               CVPixelBufferRef *replacementBufferOut,
                               BOOL *stillPhotoRequiresRightOrientationOut);

#ifdef __cplusplus
}
#endif

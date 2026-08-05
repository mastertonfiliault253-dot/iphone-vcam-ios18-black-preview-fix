#import <CoreMedia/CoreMedia.h>

#ifdef __cplusplus
extern "C" {
#endif

void VCAMRefLog(const char *message);
void loadReplacementMedia(void);
BOOL VCAMTargetBufferIsSupported(CVPixelBufferRef targetBuffer);
BOOL drawReplacementOntoBuffer(CVPixelBufferRef targetBuffer);

#ifdef __cplusplus
}
#endif

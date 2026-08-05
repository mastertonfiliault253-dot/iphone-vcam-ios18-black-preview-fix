#import <CoreMedia/CoreMedia.h>

#ifdef __cplusplus
extern "C" {
#endif

void VCAMRefLog(const char *message);
void loadReplacementMedia(void);
void drawReplacementOntoBuffer(CVPixelBufferRef targetBuffer);

#ifdef __cplusplus
}
#endif
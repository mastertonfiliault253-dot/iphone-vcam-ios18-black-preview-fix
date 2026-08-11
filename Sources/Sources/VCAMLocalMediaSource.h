#import <Foundation/Foundation.h>
#import "../Core/VCAMMediaSource.h"
#import "../Core/VCAMFrameRenderer.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSDictionary<NSString *, id> *VCAMLocalPlaybackPerformanceSnapshot(void);

@interface VCAMLocalMediaSource : NSObject <VCAMMediaSource>
- (instancetype)initWithConfiguration:(VCAMConfiguration *)configuration
                              renderer:(VCAMFrameRenderer *)renderer;
- (BOOL)hasVideoAsset;
- (CGSize)orientedStillImageSize;
- (BOOL)renderStillImageIntoPixelBuffer:(CVPixelBufferRef)pixelBuffer;
- (nullable AVPlayer *)previewPlayer;
- (void)tickDirectPreviewDiagnostics;
@end

NS_ASSUME_NONNULL_END

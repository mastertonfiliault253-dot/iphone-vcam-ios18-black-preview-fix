#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface VCAMPreviewDriver : NSObject
- (instancetype)initWithPreviewLayer:(AVCaptureVideoPreviewLayer *)previewLayer;
@end

NS_ASSUME_NONNULL_END

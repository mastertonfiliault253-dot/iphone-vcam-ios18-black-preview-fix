#import <AVFoundation/AVFoundation.h>
#import "VCAMConfiguration.h"

NS_ASSUME_NONNULL_BEGIN

/// Converts one current source frame into a BGRA camera-sized sample without
/// creating a GPU/EAGL context. The worker never buffers an entire video.
@interface VCAMFrameRenderer : NSObject

- (nullable CMSampleBufferRef)copySampleFromPixelBuffer:(CVPixelBufferRef)pixelBuffer
                                                template:(CMSampleBufferRef)templateBuffer
                                           configuration:(VCAMConfiguration *)configuration
    CF_RETURNS_RETAINED;

- (nullable CMSampleBufferRef)copySampleFromPixelBuffer:(CVPixelBufferRef)pixelBuffer
                                         sourceTransform:(CGAffineTransform)sourceTransform
                                                template:(CMSampleBufferRef)templateBuffer
                                           configuration:(VCAMConfiguration *)configuration
    CF_RETURNS_RETAINED;

- (nullable CMSampleBufferRef)copySampleFromCGImage:(CGImageRef)image
                                     sourceTransform:(CGAffineTransform)sourceTransform
                                            template:(CMSampleBufferRef)templateBuffer
                                       configuration:(VCAMConfiguration *)configuration
    CF_RETURNS_RETAINED;

@end

NS_ASSUME_NONNULL_END

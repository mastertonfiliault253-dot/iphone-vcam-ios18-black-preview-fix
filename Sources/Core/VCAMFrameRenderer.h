#import <AVFoundation/AVFoundation.h>
#import "VCAMConfiguration.h"

NS_ASSUME_NONNULL_BEGIN

/// Converts one current source frame into a BGRA camera-sized sample without
/// creating a GPU/EAGL context. The worker never buffers an entire video.
@interface VCAMFrameRenderer : NSObject

/// Draws one decoded image directly into an existing BGRA buffer. Static
/// IOSurface publication uses this to avoid a second full-resolution frame.
- (BOOL)renderCGImage:(CGImageRef)image
      sourceTransform:(CGAffineTransform)sourceTransform
   intoPixelBuffer:(CVPixelBufferRef)pixelBuffer
        configuration:(VCAMConfiguration *)configuration;

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

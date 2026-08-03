#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import "VCAMConfiguration.h"

NS_ASSUME_NONNULL_BEGIN

/// Converts source images into buffers that match the consumer's camera format.
/// Pixel format, size, orientation, mirroring, timing and propagated attachments
/// are all hidden behind this small interface.
@interface VCAMFrameRenderer : NSObject

- (nullable CMSampleBufferRef)copySampleFromPixelBuffer:(CVPixelBufferRef)pixelBuffer
                                                template:(CMSampleBufferRef)templateBuffer
                                           configuration:(VCAMConfiguration *)configuration
    CF_RETURNS_RETAINED;

- (nullable CMSampleBufferRef)copySampleFromImage:(CIImage *)image
                                         template:(CMSampleBufferRef)templateBuffer
                                    configuration:(VCAMConfiguration *)configuration
    CF_RETURNS_RETAINED;

@end

NS_ASSUME_NONNULL_END

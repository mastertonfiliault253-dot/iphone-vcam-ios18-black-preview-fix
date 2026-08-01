#import "VCAMFrameRenderer.h"
#import <CoreVideo/CoreVideo.h>

@interface VCAMFrameRenderer ()
@property(nonatomic, strong) CIContext *context;
@end

@implementation VCAMFrameRenderer

- (instancetype)init {
    self = [super init];
    if (self) {
        _context = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}];
    }
    return self;
}

- (CMSampleBufferRef)copySampleFromImage:(CIImage *)image
                                template:(CMSampleBufferRef)templateBuffer
                           configuration:(VCAMConfiguration *)configuration {
    CVImageBufferRef templateImage = CMSampleBufferGetImageBuffer(templateBuffer);
    if (templateImage == NULL || image == nil) {
        return NULL;
    }

    const size_t width = CVPixelBufferGetWidth(templateImage);
    const size_t height = CVPixelBufferGetHeight(templateImage);
    const OSType pixelFormat = CVPixelBufferGetPixelFormatType(templateImage);
    NSDictionary *attributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(pixelFormat),
        (id)kCVPixelBufferWidthKey: @(width),
        (id)kCVPixelBufferHeightKey: @(height),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
    };

    CVPixelBufferRef output = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, width, height, pixelFormat,
                            (__bridge CFDictionaryRef)attributes, &output) != kCVReturnSuccess) {
        return NULL;
    }

    CIImage *renderImage = [self transformedImage:image
                                           target:CGRectMake(0, 0, width, height)
                                    configuration:configuration];
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    [self.context render:renderImage
         toCVPixelBuffer:output
                  bounds:CGRectMake(0, 0, width, height)
              colorSpace:colorSpace];
    CGColorSpaceRelease(colorSpace);

    CMVideoFormatDescriptionRef format = NULL;
    CMSampleBufferRef sample = NULL;
    CMSampleTimingInfo timing = {
        .duration = CMSampleBufferGetDuration(templateBuffer),
        .presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(templateBuffer),
        .decodeTimeStamp = CMSampleBufferGetDecodeTimeStamp(templateBuffer),
    };
    OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, output, &format);
    if (status == noErr) {
        status = CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, output, true, NULL, NULL,
                                                    format, &timing, &sample);
    }
    if (status == noErr && sample != NULL) {
        CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(templateBuffer, false);
        if (attachments != NULL) {
            CMSetAttachment(sample, CFSTR("VCAMOriginalSampleAttachments"), attachments,
                            kCMAttachmentMode_ShouldNotPropagate);
        }
        CFTypeRef propagated = CMGetAttachment(templateBuffer, kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix, NULL);
        if (propagated != NULL) {
            CMSetAttachment(sample, kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix, propagated,
                            kCMAttachmentMode_ShouldPropagate);
        }
    }

    if (format != NULL) CFRelease(format);
    CVPixelBufferRelease(output);
    return sample;
}

- (CIImage *)transformedImage:(CIImage *)image
                        target:(CGRect)target
                 configuration:(VCAMConfiguration *)configuration {
    CGRect extent = image.extent;
    CGAffineTransform transform = CGAffineTransformIdentity;
    transform = CGAffineTransformTranslate(transform, -CGRectGetMidX(extent), -CGRectGetMidY(extent));
    if (configuration.rotationDegrees != 0) {
        transform = CGAffineTransformRotate(transform, configuration.rotationDegrees * M_PI / 180.0);
    }
    if (configuration.mirrorHorizontally) {
        transform = CGAffineTransformScale(transform, -1.0, 1.0);
    }
    CIImage *result = [image imageByApplyingTransform:transform];
    CGRect transformedExtent = result.extent;

    CGFloat sx = CGRectGetWidth(target) / MAX(1.0, CGRectGetWidth(transformedExtent));
    CGFloat sy = CGRectGetHeight(target) / MAX(1.0, CGRectGetHeight(transformedExtent));
    if (configuration.contentMode == VCAMContentModeAspectFit) {
        sx = sy = MIN(sx, sy);
    } else if (configuration.contentMode == VCAMContentModeAspectFill) {
        sx = sy = MAX(sx, sy);
    }
    result = [result imageByApplyingTransform:CGAffineTransformMakeScale(sx, sy)];
    CGRect scaled = result.extent;
    CGFloat tx = CGRectGetMidX(target) - CGRectGetMidX(scaled);
    CGFloat ty = CGRectGetMidY(target) - CGRectGetMidY(scaled);
    result = [result imageByApplyingTransform:CGAffineTransformMakeTranslation(tx, ty)];

    if (configuration.contentMode == VCAMContentModeAspectFit) {
        CIImage *background = [CIImage imageWithColor:CIColor.blackColor];
        result = [result imageByCompositingOverImage:[background imageByCroppingToRect:target]];
    }
    return [result imageByCroppingToRect:target];
}

@end

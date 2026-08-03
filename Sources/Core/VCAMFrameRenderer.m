#import "VCAMFrameRenderer.h"
#import <CoreVideo/CoreVideo.h>
#import <math.h>

@interface VCAMFrameRenderer () {
    CVPixelBufferPoolRef _pixelBufferPool;
    CMVideoFormatDescriptionRef _formatDescription;
    CGColorSpaceRef _colorSpace;
    size_t _poolWidth;
    size_t _poolHeight;
    OSType _poolPixelFormat;
}
@property(nonatomic, strong) CIContext *context;
@end

@implementation VCAMFrameRenderer

- (void)copyAttachmentsFromTemplate:(CMSampleBufferRef)templateBuffer
                            toSample:(CMSampleBufferRef)sample {
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(templateBuffer, false);
    if (attachments != NULL) {
        CMSetAttachment(sample, CFSTR("VCAMOriginalSampleAttachments"), attachments,
                        kCMAttachmentMode_ShouldNotPropagate);
    }
    CFTypeRef propagated = CMGetAttachment(templateBuffer,
                                            kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
                                            NULL);
    if (propagated != NULL) {
        CMSetAttachment(sample, kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix, propagated,
                        kCMAttachmentMode_ShouldPropagate);
    }
}

- (CMSampleBufferRef)copySampleWrappingPixelBuffer:(CVPixelBufferRef)pixelBuffer
                                           template:(CMSampleBufferRef)templateBuffer {
    CMVideoFormatDescriptionRef format = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &format) != noErr) {
        return NULL;
    }
    CMSampleTimingInfo timing = {
        .duration = CMSampleBufferGetDuration(templateBuffer),
        .presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(templateBuffer),
        .decodeTimeStamp = CMSampleBufferGetDecodeTimeStamp(templateBuffer),
    };
    CMSampleBufferRef sample = NULL;
    OSStatus status = CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, true,
                                                          NULL, NULL, format, &timing, &sample);
    CFRelease(format);
    if (status != noErr || sample == NULL) return NULL;
    [self copyAttachmentsFromTemplate:templateBuffer toSample:sample];
    return sample;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _context = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}];
        _colorSpace = CGColorSpaceCreateDeviceRGB();
    }
    return self;
}

- (void)dealloc {
    if (_pixelBufferPool != NULL) CVPixelBufferPoolRelease(_pixelBufferPool);
    if (_formatDescription != NULL) CFRelease(_formatDescription);
    if (_colorSpace != NULL) CGColorSpaceRelease(_colorSpace);
}

- (CMSampleBufferRef)copySampleFromPixelBuffer:(CVPixelBufferRef)pixelBuffer
                                       template:(CMSampleBufferRef)templateBuffer
                                  configuration:(VCAMConfiguration *)configuration {
    CVImageBufferRef targetBuffer = CMSampleBufferGetImageBuffer(templateBuffer);
    if (pixelBuffer == NULL || targetBuffer == NULL) return NULL;
    size_t sourceWidth = CVPixelBufferGetWidth(pixelBuffer);
    size_t sourceHeight = CVPixelBufferGetHeight(pixelBuffer);
    OSType sourcePixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);
    size_t targetWidth = CVPixelBufferGetWidth(targetBuffer);
    size_t targetHeight = CVPixelBufferGetHeight(targetBuffer);
    OSType targetPixelFormat = CVPixelBufferGetPixelFormatType(targetBuffer);
    BOOL identityTransform = configuration.rotationDegrees == 0 && !configuration.mirrorHorizontally;
    if (identityTransform && sourceWidth == targetWidth && sourceHeight == targetHeight &&
        sourcePixelFormat == targetPixelFormat) {
        return [self copySampleWrappingPixelBuffer:pixelBuffer template:templateBuffer];
    }
    CIImage *image = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    return [self copySampleFromImage:image template:templateBuffer configuration:configuration];
}

- (BOOL)preparePoolForWidth:(size_t)width height:(size_t)height pixelFormat:(OSType)pixelFormat {
    if (_pixelBufferPool != NULL && _poolWidth == width && _poolHeight == height &&
        _poolPixelFormat == pixelFormat) {
        return YES;
    }
    if (_pixelBufferPool != NULL) {
        CVPixelBufferPoolRelease(_pixelBufferPool);
        _pixelBufferPool = NULL;
    }
    if (_formatDescription != NULL) {
        CFRelease(_formatDescription);
        _formatDescription = NULL;
    }
    NSDictionary *poolAttributes = @{
        (id)kCVPixelBufferPoolMinimumBufferCountKey: @4,
    };
    NSDictionary *pixelAttributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(pixelFormat),
        (id)kCVPixelBufferWidthKey: @(width),
        (id)kCVPixelBufferHeightKey: @(height),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
    };
    CVReturn status = CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                               (__bridge CFDictionaryRef)poolAttributes,
                                               (__bridge CFDictionaryRef)pixelAttributes,
                                               &_pixelBufferPool);
    if (status != kCVReturnSuccess) return NO;
    _poolWidth = width;
    _poolHeight = height;
    _poolPixelFormat = pixelFormat;
    return YES;
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
    CVPixelBufferRef output = NULL;
    if (![self preparePoolForWidth:width height:height pixelFormat:pixelFormat] ||
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _pixelBufferPool, &output) != kCVReturnSuccess) {
        return NULL;
    }

    CIImage *renderImage = [self transformedImage:image
                                           target:CGRectMake(0, 0, width, height)
                                    configuration:configuration];
    [self.context render:renderImage
         toCVPixelBuffer:output
                  bounds:CGRectMake(0, 0, width, height)
              colorSpace:_colorSpace];

    CMSampleBufferRef sample = NULL;
    CMSampleTimingInfo timing = {
        .duration = CMSampleBufferGetDuration(templateBuffer),
        .presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(templateBuffer),
        .decodeTimeStamp = CMSampleBufferGetDecodeTimeStamp(templateBuffer),
    };
    OSStatus status = noErr;
    if (_formatDescription == NULL) {
        status = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, output,
                                                               &_formatDescription);
    }
    if (status == noErr && _formatDescription != NULL) {
        status = CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, output, true, NULL, NULL,
                                                    _formatDescription, &timing, &sample);
    }
    if (status == noErr && sample != NULL) {
        [self copyAttachmentsFromTemplate:templateBuffer toSample:sample];
    }

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
    BOOL uniformDownscale = fabs(sx - sy) < 0.0001 && sx < 1.0;
    if (uniformDownscale) {
        CIFilter *lanczos = [CIFilter filterWithName:@"CILanczosScaleTransform"];
        [lanczos setValue:result forKey:kCIInputImageKey];
        [lanczos setValue:@(sx) forKey:kCIInputScaleKey];
        [lanczos setValue:@1.0 forKey:kCIInputAspectRatioKey];
        result = lanczos.outputImage ?: [result imageByApplyingTransform:CGAffineTransformMakeScale(sx, sy)];
    } else {
        result = [result imageByApplyingTransform:CGAffineTransformMakeScale(sx, sy)];
    }
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

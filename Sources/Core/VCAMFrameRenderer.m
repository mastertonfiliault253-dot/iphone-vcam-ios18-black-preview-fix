#import "VCAMFrameRenderer.h"

#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>
#import "../Daemon/VCAMPixelConverter.h"
#import <math.h>
#import <string.h>

@interface VCAMFrameRenderer () {
    CVPixelBufferPoolRef _pixelBufferPool;
    CMVideoFormatDescriptionRef _formatDescription;
    CGColorSpaceRef _colorSpace;
    size_t _poolWidth;
    size_t _poolHeight;
}
@end

@implementation VCAMFrameRenderer

- (instancetype)init {
    self = [super init];
    if (self) _colorSpace = CGColorSpaceCreateDeviceRGB();
    return self;
}

- (void)dealloc {
    if (_pixelBufferPool != NULL) CVPixelBufferPoolRelease(_pixelBufferPool);
    if (_formatDescription != NULL) CFRelease(_formatDescription);
    if (_colorSpace != NULL) CGColorSpaceRelease(_colorSpace);
}

- (void)copyAttachmentsFromTemplate:(CMSampleBufferRef)templateBuffer
                            toSample:(CMSampleBufferRef)sample {
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(templateBuffer, false);
    if (attachments != NULL) {
        CMSetAttachment(sample, CFSTR("VCAMOriginalSampleAttachments"), attachments,
                        kCMAttachmentMode_ShouldNotPropagate);
    }
    CFTypeRef intrinsic = CMGetAttachment(templateBuffer,
                                           kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
                                           NULL);
    if (intrinsic != NULL) {
        CMSetAttachment(sample, kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix, intrinsic,
                        kCMAttachmentMode_ShouldPropagate);
    }
}

- (CMSampleBufferRef)copySampleWrappingPixelBuffer:(CVPixelBufferRef)pixelBuffer
                                           template:(CMSampleBufferRef)templateBuffer {
    CMVideoFormatDescriptionRef format = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer,
                                                      &format) != noErr) return NULL;
    CMSampleTimingInfo timing = {
        .duration = CMSampleBufferGetDuration(templateBuffer),
        .presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(templateBuffer),
        .decodeTimeStamp = CMSampleBufferGetDecodeTimeStamp(templateBuffer),
    };
    CMSampleBufferRef sample = NULL;
    OSStatus status = CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer,
                                                          true, NULL, NULL, format,
                                                          &timing, &sample);
    CFRelease(format);
    if (status != noErr || sample == NULL) return NULL;
    [self copyAttachmentsFromTemplate:templateBuffer toSample:sample];
    return sample;
}

- (BOOL)preparePoolForWidth:(size_t)width height:(size_t)height {
    if (_pixelBufferPool != NULL && _poolWidth == width && _poolHeight == height) return YES;
    if (_pixelBufferPool != NULL) {
        CVPixelBufferPoolRelease(_pixelBufferPool);
        _pixelBufferPool = NULL;
    }
    if (_formatDescription != NULL) {
        CFRelease(_formatDescription);
        _formatDescription = NULL;
    }
    NSDictionary *poolAttributes = @{(id)kCVPixelBufferPoolMinimumBufferCountKey: @4};
    NSDictionary *pixelAttributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey: @(width),
        (id)kCVPixelBufferHeightKey: @(height),
        (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
    };
    CVReturn status = CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                               (__bridge CFDictionaryRef)poolAttributes,
                                               (__bridge CFDictionaryRef)pixelAttributes,
                                               &_pixelBufferPool);
    if (status != kCVReturnSuccess) return NO;
    _poolWidth = width;
    _poolHeight = height;
    return YES;
}

- (CMSampleBufferRef)copySampleFromPixelBuffer:(CVPixelBufferRef)pixelBuffer
                                       template:(CMSampleBufferRef)templateBuffer
                                  configuration:(VCAMConfiguration *)configuration {
    return [self copySampleFromPixelBuffer:pixelBuffer
                           sourceTransform:CGAffineTransformIdentity
                                  template:templateBuffer
                             configuration:configuration];
}

- (CMSampleBufferRef)copySampleFromPixelBuffer:(CVPixelBufferRef)pixelBuffer
                                sourceTransform:(CGAffineTransform)sourceTransform
                                       template:(CMSampleBufferRef)templateBuffer
                                  configuration:(VCAMConfiguration *)configuration {
    CVImageBufferRef target = CMSampleBufferGetImageBuffer(templateBuffer);
    if (pixelBuffer == NULL || target == NULL) return NULL;
    BOOL identity = CGAffineTransformIsIdentity(sourceTransform) &&
        configuration.rotationDegrees == 0 && !configuration.mirrorHorizontally;
    if (identity && CVPixelBufferGetWidth(pixelBuffer) == CVPixelBufferGetWidth(target) &&
        CVPixelBufferGetHeight(pixelBuffer) == CVPixelBufferGetHeight(target) &&
        CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA) {
        return [self copySampleWrappingPixelBuffer:pixelBuffer template:templateBuffer];
    }
    // Hardware decoder output (NV12) that does not need rotation/mirroring is
    // converted with vImage instead of VTCreateCGImageFromCVPixelBuffer plus
    // a CPU CGContext draw, which was the dominant local-preview bottleneck.
    if (identity &&
        CVPixelBufferGetPixelFormatType(pixelBuffer) ==
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
        CVPixelBufferGetWidth(pixelBuffer) == CVPixelBufferGetWidth(target) &&
        CVPixelBufferGetHeight(pixelBuffer) == CVPixelBufferGetHeight(target) &&
        CVPixelBufferGetPixelFormatType(target) == kCVPixelFormatType_32BGRA &&
        [self preparePoolForWidth:CVPixelBufferGetWidth(target)
                           height:CVPixelBufferGetHeight(target)]) {
        CVPixelBufferRef output = NULL;
        if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault,
                                               _pixelBufferPool,
                                               &output) == kCVReturnSuccess) {
            BOOL converted = VCAMCopyNV12PixelBufferToBGRA(pixelBuffer, output);
            if (converted) {
                CMSampleBufferRef sample =
                    [self copySampleWrappingPixelBuffer:output
                                               template:templateBuffer];
                CVPixelBufferRelease(output);
                return sample;
            }
            CVPixelBufferRelease(output);
        }
    }

    CGImageRef image = NULL;
    OSStatus status = VTCreateCGImageFromCVPixelBuffer(pixelBuffer, NULL, &image);
    if (status != noErr || image == NULL) return NULL;
    CMSampleBufferRef sample = [self copySampleFromCGImage:image
                                           sourceTransform:sourceTransform
                                                  template:templateBuffer
                                             configuration:configuration];
    CGImageRelease(image);
    return sample;
}

- (CMSampleBufferRef)copySampleFromCGImage:(CGImageRef)image
                            sourceTransform:(CGAffineTransform)sourceTransform
                                   template:(CMSampleBufferRef)templateBuffer
                              configuration:(VCAMConfiguration *)configuration {
    CVImageBufferRef templateImage = CMSampleBufferGetImageBuffer(templateBuffer);
    if (image == NULL || templateImage == NULL) return NULL;
    const size_t width = CVPixelBufferGetWidth(templateImage);
    const size_t height = CVPixelBufferGetHeight(templateImage);
    if (CVPixelBufferGetPixelFormatType(templateImage) != kCVPixelFormatType_32BGRA ||
        ![self preparePoolForWidth:width height:height]) return NULL;

    CVPixelBufferRef output = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _pixelBufferPool,
                                           &output) != kCVReturnSuccess) return NULL;
    if (CVPixelBufferLockBaseAddress(output, 0) != kCVReturnSuccess) {
        CVPixelBufferRelease(output);
        return NULL;
    }

    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(output);
    memset(CVPixelBufferGetBaseAddress(output), 0, bytesPerRow * height);
    CGContextRef context = CGBitmapContextCreate(
        CVPixelBufferGetBaseAddress(output), width, height, 8, bytesPerRow,
        _colorSpace, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    if (context == NULL) {
        CVPixelBufferUnlockBaseAddress(output, 0);
        CVPixelBufferRelease(output);
        return NULL;
    }

    CGFloat sourceWidth = (CGFloat)CGImageGetWidth(image);
    CGFloat sourceHeight = (CGFloat)CGImageGetHeight(image);
    CGFloat sourceAngle = atan2(sourceTransform.b, sourceTransform.a);
    CGFloat rotation = sourceAngle + configuration.rotationDegrees * M_PI / 180.0;
    CGFloat absoluteCosine = fabs(cos(rotation));
    CGFloat absoluteSine = fabs(sin(rotation));
    CGFloat orientedWidth = sourceWidth * absoluteCosine + sourceHeight * absoluteSine;
    CGFloat orientedHeight = sourceWidth * absoluteSine + sourceHeight * absoluteCosine;
    CGFloat scaleX = (CGFloat)width / MAX(1.0, orientedWidth);
    CGFloat scaleY = (CGFloat)height / MAX(1.0, orientedHeight);
    if (configuration.contentMode == VCAMContentModeAspectFit) {
        scaleX = scaleY = MIN(scaleX, scaleY);
    } else if (configuration.contentMode == VCAMContentModeAspectFill) {
        scaleX = scaleY = MAX(scaleX, scaleY);
    }
    BOOL sourceMirrored = sourceTransform.a * sourceTransform.d -
        sourceTransform.b * sourceTransform.c < 0;
    BOOL mirror = sourceMirrored != configuration.mirrorHorizontally;

    // Convert the bitmap's lower-left coordinate system into top-left image
    // coordinates, then draw only the current source frame.
    CGContextTranslateCTM(context, 0, (CGFloat)height);
    CGContextScaleCTM(context, 1, -1);
    CGContextTranslateCTM(context, (CGFloat)width * 0.5, (CGFloat)height * 0.5);
    CGContextScaleCTM(context, scaleX, scaleY);
    CGContextRotateCTM(context, rotation);
    if (mirror) CGContextScaleCTM(context, -1, 1);
    CGContextTranslateCTM(context, -sourceWidth * 0.5, -sourceHeight * 0.5);
    // Video frames are already antialiased by the decoder pipeline; high
    // quality interpolation plus antialiasing is the dominant CPU cost here
    // and produces no visible benefit at 1080x1920. Medium + no AA keeps the
    // scale/rotate conversion on the CPU but several times cheaper.
    CGContextSetInterpolationQuality(context, kCGInterpolationMedium);
    CGContextSetShouldAntialias(context, NO);
    CGContextSetAllowsAntialiasing(context, NO);
    CGContextDrawImage(context, CGRectMake(0, 0, sourceWidth, sourceHeight), image);
    CGContextRelease(context);
    CVPixelBufferUnlockBaseAddress(output, 0);

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
    CMSampleBufferRef sample = NULL;
    if (status == noErr && _formatDescription != NULL) {
        status = CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, output, true,
                                                    NULL, NULL, _formatDescription,
                                                    &timing, &sample);
    }
    if (status == noErr && sample != NULL) {
        [self copyAttachmentsFromTemplate:templateBuffer toSample:sample];
    }
    CVPixelBufferRelease(output);
    return sample;
}

@end

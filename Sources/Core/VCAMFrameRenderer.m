#import "VCAMFrameRenderer.h"

#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>
#import "../Daemon/VCAMPixelConverter.h"
#import <math.h>
#import <string.h>

@interface VCAMFrameRenderer () {
    CVPixelBufferPoolRef _pixelBufferPool;
    CGColorSpaceRef _colorSpace;
    size_t _poolWidth;
    size_t _poolHeight;
    CFTypeRef _pixelTransferSession;
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
    if (_colorSpace != NULL) CGColorSpaceRelease(_colorSpace);
    if (_pixelTransferSession != NULL) CFRelease(_pixelTransferSession);
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

- (BOOL)renderCGImage:(CGImageRef)image
      sourceTransform:(CGAffineTransform)sourceTransform
   intoPixelBuffer:(CVPixelBufferRef)output
        configuration:(VCAMConfiguration *)configuration {
    if (image == NULL || output == NULL ||
        CVPixelBufferGetPixelFormatType(output) != kCVPixelFormatType_32BGRA) return NO;
    const size_t width = CVPixelBufferGetWidth(output);
    const size_t height = CVPixelBufferGetHeight(output);
    if (width == 0 || height == 0 ||
        CVPixelBufferLockBaseAddress(output, 0) != kCVReturnSuccess) return NO;

    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(output);
    memset(CVPixelBufferGetBaseAddress(output), 0, bytesPerRow * height);
    CGContextRef context = CGBitmapContextCreate(
        CVPixelBufferGetBaseAddress(output), width, height, 8, bytesPerRow,
        _colorSpace, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    if (context == NULL) {
        CVPixelBufferUnlockBaseAddress(output, 0);
        return NO;
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

    // CVPixelBuffer row zero is the displayed top row. Drawing in that row
    // order keeps the ImageIO-normalized source upright in both the passive
    // preview and mediaserverd; an extra Y flip inverted both consumers.
    CGContextTranslateCTM(context, (CGFloat)width * 0.5, (CGFloat)height * 0.5);
    CGContextScaleCTM(context, scaleX, scaleY);
    CGContextRotateCTM(context, rotation);
    if (mirror) CGContextScaleCTM(context, -1, 1);
    CGContextTranslateCTM(context, -sourceWidth * 0.5, -sourceHeight * 0.5);
    CGContextSetInterpolationQuality(context, kCGInterpolationMedium);
    CGContextSetShouldAntialias(context, NO);
    CGContextSetAllowsAntialiasing(context, NO);
    CGContextDrawImage(context, CGRectMake(0, 0, sourceWidth, sourceHeight), image);
    CGContextRelease(context);
    CVPixelBufferUnlockBaseAddress(output, 0);
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
    OSType sourceFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);
    // RTSP publishes NV12 (rotation at the push end). Scale/convert straight
    // to the NV12 output with VTPixelTransferSession instead of a vImage BGRA
    // round-trip.
    if (identity &&
        (sourceFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
         sourceFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) &&
        CVPixelBufferGetPixelFormatType(target) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
        // Already 420v at the target size: wrap directly, skip VTPixelTransfer.
        if (sourceFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
            CVPixelBufferGetWidth(pixelBuffer) == CVPixelBufferGetWidth(target) &&
            CVPixelBufferGetHeight(pixelBuffer) == CVPixelBufferGetHeight(target)) {
            return [self copySampleWrappingPixelBuffer:pixelBuffer template:templateBuffer];
        }
        if (_pixelTransferSession == NULL) {
            VTPixelTransferSessionRef session = NULL;
            if (VTPixelTransferSessionCreate(kCFAllocatorDefault, &session) == noErr) {
                _pixelTransferSession = session;
            }
        }
        if (_pixelTransferSession != NULL) {
            size_t outputWidth = CVPixelBufferGetWidth(target);
            size_t outputHeight = CVPixelBufferGetHeight(target);
            CVPixelBufferRef output = NULL;
            NSDictionary *outputAttributes = @{
                (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                (id)kCVPixelBufferWidthKey: @(outputWidth),
                (id)kCVPixelBufferHeightKey: @(outputHeight),
            };
            if (CVPixelBufferCreate(kCFAllocatorDefault, outputWidth, outputHeight,
                                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                    (__bridge CFDictionaryRef)outputAttributes,
                                    &output) == kCVReturnSuccess) {
                // Rotation and aspect are handled at the RTSP push end; scale
                // uniformly (stretch) so a 1:1 transfer stays a clean copy.
                (void)VTSessionSetProperty((VTPixelTransferSessionRef)_pixelTransferSession,
                                           kVTPixelTransferPropertyKey_ScalingMode,
                                           kVTScalingMode_Normal);
                (void)VTSessionSetProperty((VTPixelTransferSessionRef)_pixelTransferSession,
                                           kVTPixelTransferPropertyKey_RealTime, kCFBooleanTrue);
                OSStatus transferStatus = VTPixelTransferSessionTransferImage(
                    (VTPixelTransferSessionRef)_pixelTransferSession, pixelBuffer, output);
                if (transferStatus == kCVReturnSuccess) {
                    CVBufferSetAttachment(output, kCVImageBufferColorPrimariesKey,
                                          kCVImageBufferColorPrimaries_ITU_R_709_2,
                                          kCVAttachmentMode_ShouldPropagate);
                    CVBufferSetAttachment(output, kCVImageBufferTransferFunctionKey,
                                          kCVImageBufferTransferFunction_ITU_R_709_2,
                                          kCVAttachmentMode_ShouldPropagate);
                    CVBufferSetAttachment(output, kCVImageBufferYCbCrMatrixKey,
                                          kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                                          kCVAttachmentMode_ShouldPropagate);
                    CMSampleBufferRef sample = [self copySampleWrappingPixelBuffer:output
                                                                          template:templateBuffer];
                    CVPixelBufferRelease(output);
                    return sample;
                }
                CVPixelBufferRelease(output);
            }
        }
    }
    // Orient, mirror, crop, and scale decoded NV12 or BGRA frames with vImage
    // so local videos never take the VTCreateCGImage + CGContext path on every
    // camera callback.
    CGFloat sourceDegrees = atan2(sourceTransform.b, sourceTransform.a) *
        180.0 / M_PI;
    CGFloat combinedDegrees = sourceDegrees + configuration.rotationDegrees;
    NSInteger quarterTurns = (NSInteger)llround(combinedDegrees / 90.0);
    BOOL rightAngleTransform = fabs(combinedDegrees - quarterTurns * 90.0) < 0.01;
    BOOL sourceMirrored = sourceTransform.a * sourceTransform.d -
        sourceTransform.b * sourceTransform.c < 0;
    BOOL mirror = sourceMirrored != configuration.mirrorHorizontally;
    if ((sourceFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
         sourceFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
         sourceFormat == kCVPixelFormatType_32BGRA) &&
        rightAngleTransform &&
        CVPixelBufferGetPixelFormatType(target) == kCVPixelFormatType_32BGRA &&
        [self preparePoolForWidth:CVPixelBufferGetWidth(target)
                           height:CVPixelBufferGetHeight(target)]) {
        CVPixelBufferRef output = NULL;
        if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault,
                                               _pixelBufferPool,
                                               &output) == kCVReturnSuccess) {
            BOOL converted = sourceFormat == kCVPixelFormatType_32BGRA
                ? VCAMRenderBGRAPixelBufferToBGRA(
                    pixelBuffer, output, (int)(quarterTurns * 90), mirror,
                    (int)configuration.contentMode)
                : VCAMRenderNV12PixelBufferToBGRA(
                    pixelBuffer, output, (int)(quarterTurns * 90), mirror,
                    (int)configuration.contentMode);
            if (converted) {
                // Preserve the decoder-class tag across the vImage BGRA
                // conversion so hardware-decoded sources keep reporting
                // hardware decode upstream.
                CFTypeRef decodeHardware = CVBufferCopyAttachment(
                    pixelBuffer, CFSTR("com.codex.vcam.decodeHardware"), NULL);
                if (decodeHardware != NULL) {
                    CVBufferSetAttachment(
                        output, CFSTR("com.codex.vcam.decodeHardware"),
                        decodeHardware, kCVAttachmentMode_ShouldPropagate);
                    CFRelease(decodeHardware);
                }
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
    CMSampleBufferRef sample = [self renderCGImage:image
                                   sourceTransform:sourceTransform
                                intoPixelBuffer:output
                                     configuration:configuration]
        ? [self copySampleWrappingPixelBuffer:output template:templateBuffer] : NULL;
    CVPixelBufferRelease(output);
    return sample;
}

@end

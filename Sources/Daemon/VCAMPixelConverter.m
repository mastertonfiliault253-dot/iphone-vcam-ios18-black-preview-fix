#import "VCAMPixelConverter.h"

#import <Accelerate/Accelerate.h>
#import <Foundation/Foundation.h>

#include <libavutil/intreadwrite.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// A transformed software frame can coexist with three publication slots, the
// retained decoded image, one transformed output, two transform scratches and
// one source-sized template. Cap that eight-BGRA-equivalent working set at
// 256 MiB; vcamd's 384 MB jetsam limit leaves another 128 MB for FFmpeg,
// Objective-C and IOSurface bookkeeping. UHD/4K fits, larger sources fail
// explicitly instead of being silently downscaled.
static const uint64_t VCAMSourceSizedVideoPipelineBudget = 256ULL * 1024ULL * 1024ULL;
static const uint64_t VCAMSourceSizedVideoBGRACopies = 8ULL;

static BOOL VCAMSourceSizedVideoFrameFitsBudget(int width, int height) {
    if (width <= 0 || height <= 0) return NO;
    uint64_t pixels = (uint64_t)width * (uint64_t)height;
    return pixels <= VCAMSourceSizedVideoPipelineBudget /
        (VCAMSourceSizedVideoBGRACopies * 4ULL);
}

// BT.601 coefficients from the vImage documentation example. The SDK headers
// do not export kvImageITU601_YpCbCrToARGBMatrix, so define it explicitly.
static const vImage_YpCbCrToARGBMatrix VCAMITU601Matrix = {
    .Yp = 1.0f,
    .Cb_G = -0.3441f,
    .Cb_B = 1.772f,
    .Cr_R = 1.402f,
    .Cr_G = -0.7141f,
};

static const vImage_YpCbCrToARGBMatrix VCAMITU709Matrix = {
    .Yp = 1.0f,
    .Cb_G = -0.1873f,
    .Cb_B = 1.8556f,
    .Cr_R = 1.5748f,
    .Cr_G = -0.4681f,
};

static const vImage_YpCbCrToARGBMatrix VCAMITU2020Matrix = {
    .Yp = 1.0f,
    .Cb_G = -0.1646f,
    .Cb_B = 1.8814f,
    .Cr_R = 1.4746f,
    .Cr_G = -0.5714f,
};

static const vImage_YpCbCrToARGBMatrix *VCAMYpCbCrMatrix(
    enum AVColorSpace colorSpace, size_t width, size_t height) {
    if (colorSpace == AVCOL_SPC_BT2020_NCL) return &VCAMITU2020Matrix;
    if (colorSpace == AVCOL_SPC_BT709) return &VCAMITU709Matrix;
    if (colorSpace == AVCOL_SPC_BT470BG ||
        colorSpace == AVCOL_SPC_SMPTE170M) return &VCAMITU601Matrix;
    // FFmpeg reports AVCOL_SPC_UNSPECIFIED for many live H.264 publishers.
    // Rec.709 is the conventional matrix for HD; SD remains Rec.601.
    return MAX(width, height) >= 1280 ? &VCAMITU709Matrix : &VCAMITU601Matrix;
}

static void VCAMSetAVFrameColorAttachments(AVFrame *frame,
                                           CVPixelBufferRef pixelBuffer,
                                           size_t width, size_t height) {
    if (frame == NULL || pixelBuffer == NULL) return;
    CFStringRef primaries = NULL;
    switch (frame->color_primaries) {
        case AVCOL_PRI_BT709: primaries = kCVImageBufferColorPrimaries_ITU_R_709_2; break;
        case AVCOL_PRI_BT470BG: primaries = kCVImageBufferColorPrimaries_EBU_3213; break;
        case AVCOL_PRI_SMPTE170M: primaries = kCVImageBufferColorPrimaries_SMPTE_C; break;
        case AVCOL_PRI_BT2020: primaries = kCVImageBufferColorPrimaries_ITU_R_2020; break;
        default:
            if (frame->colorspace == AVCOL_SPC_BT2020_NCL) {
                primaries = kCVImageBufferColorPrimaries_ITU_R_2020;
            } else {
                primaries = MAX(width, height) >= 1280
                    ? kCVImageBufferColorPrimaries_ITU_R_709_2
                    : kCVImageBufferColorPrimaries_SMPTE_C;
            }
            break;
    }
    CFStringRef transfer = NULL;
    switch (frame->color_trc) {
        case AVCOL_TRC_SMPTE2084:
            transfer = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ; break;
        case AVCOL_TRC_ARIB_STD_B67:
            transfer = kCVImageBufferTransferFunction_ITU_R_2100_HLG; break;
        case AVCOL_TRC_IEC61966_2_1:
            transfer = kCVImageBufferTransferFunction_sRGB; break;
        case AVCOL_TRC_BT2020_10:
        case AVCOL_TRC_BT2020_12:
            transfer = kCVImageBufferTransferFunction_ITU_R_2020; break;
        default:
            transfer = kCVImageBufferTransferFunction_ITU_R_709_2; break;
    }
    CFStringRef matrix = NULL;
    switch (frame->colorspace) {
        case AVCOL_SPC_BT709:
            matrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2; break;
        case AVCOL_SPC_BT2020_NCL:
            matrix = kCVImageBufferYCbCrMatrix_ITU_R_2020; break;
        case AVCOL_SPC_SMPTE240M:
            matrix = kCVImageBufferYCbCrMatrix_SMPTE_240M_1995; break;
        case AVCOL_SPC_BT470BG:
        case AVCOL_SPC_SMPTE170M:
            matrix = kCVImageBufferYCbCrMatrix_ITU_R_601_4; break;
        default:
            matrix = MAX(width, height) >= 1280
                ? kCVImageBufferYCbCrMatrix_ITU_R_709_2
                : kCVImageBufferYCbCrMatrix_ITU_R_601_4; break;
    }
    CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey,
                          primaries, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey,
                          transfer, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey,
                          matrix, kCVAttachmentMode_ShouldPropagate);
}

// The conversion queues are fixed threads (RTSP conversion queue and the
// vcamd pipeline queue), so a thread-local scratch is safe without a lock.
static __thread uint8_t *VCAMThreadScratch;
static __thread size_t VCAMThreadScratchWidth;
static __thread size_t VCAMThreadScratchHeight;
static __thread uint8_t *VCAMThreadTransformScratch;
static __thread size_t VCAMThreadTransformScratchSize;

static uint8_t *VCAMConverterScratchBuffer(size_t width, size_t height) {
    size_t required = width * height * 4;
    if (required == 0 || required >
        VCAMSourceSizedVideoPipelineBudget / VCAMSourceSizedVideoBGRACopies) return NULL;
    if (VCAMThreadScratch == NULL ||
        VCAMThreadScratchWidth != width ||
        VCAMThreadScratchHeight != height) {
        free(VCAMThreadScratch);
        VCAMThreadScratch = NULL;
        VCAMThreadScratchWidth = 0;
        VCAMThreadScratchHeight = 0;
        uint8_t *replacement = malloc(required);
        if (replacement != NULL) {
            VCAMThreadScratch = replacement;
            VCAMThreadScratchWidth = width;
            VCAMThreadScratchHeight = height;
        }
    }
    return VCAMThreadScratch;
}

static uint8_t *VCAMTransformScratchBuffer(size_t required) {
    if (required == 0 || required >
        VCAMSourceSizedVideoPipelineBudget / VCAMSourceSizedVideoBGRACopies) return NULL;
    if (VCAMThreadTransformScratch == NULL ||
        VCAMThreadTransformScratchSize < required) {
        free(VCAMThreadTransformScratch);
        VCAMThreadTransformScratch = malloc(required);
        VCAMThreadTransformScratchSize =
            VCAMThreadTransformScratch == NULL ? 0 : required;
    }
    return VCAMThreadTransformScratch;
}

static BOOL VCAMRowBytesAligned(size_t rowBytes) {
    return rowBytes > 0 && (rowBytes % 16) == 0;
}

static enum AVColorSpace VCAMColorSpaceForPixelBuffer(
    CVPixelBufferRef pixelBuffer) {
    CFTypeRef matrix = CVBufferCopyAttachment(
        pixelBuffer, kCVImageBufferYCbCrMatrixKey, NULL);
    enum AVColorSpace result = AVCOL_SPC_UNSPECIFIED;
    if (matrix != NULL && CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_2020)) {
        result = AVCOL_SPC_BT2020_NCL;
    } else if (matrix != NULL &&
               CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)) {
        result = AVCOL_SPC_BT709;
    } else if (matrix != NULL &&
               CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_601_4)) {
        result = AVCOL_SPC_SMPTE170M;
    }
    if (matrix != NULL) CFRelease(matrix);
    return result;
}

static void VCAMLumaCoefficients(enum AVColorSpace colorSpace,
                                 size_t width, size_t height,
                                 double *red, double *blue) {
    if (colorSpace == AVCOL_SPC_BT2020_NCL) {
        *red = 0.2627;
        *blue = 0.0593;
    } else if (colorSpace == AVCOL_SPC_BT709 ||
               (colorSpace == AVCOL_SPC_UNSPECIFIED &&
                MAX(width, height) >= 1280)) {
        *red = 0.2126;
        *blue = 0.0722;
    } else {
        *red = 0.2990;
        *blue = 0.1140;
    }
}

static BOOL VCAMPrepareYpCbCrInfo(BOOL fullRange,
                                  BOOL planar,
                                  enum AVColorSpace colorSpace,
                                  size_t width,
                                  size_t height,
                                  vImage_YpCbCrToARGB *info) {
    if (info == NULL) return NO;
    vImage_YpCbCrPixelRange range;
    if (fullRange) {
        range = (vImage_YpCbCrPixelRange){
            .Yp_bias = 0,
            .CbCr_bias = 128,
            .YpRangeMax = 255,
            .CbCrRangeMax = 255,
            .YpMax = 255,
            .YpMin = 0,
            .CbCrMax = 255,
            .CbCrMin = 0,
        };
    } else {
        range = (vImage_YpCbCrPixelRange){
            .Yp_bias = 16,
            .CbCr_bias = 128,
            .YpRangeMax = 235,
            .CbCrRangeMax = 240,
            .YpMax = 255,
            .YpMin = 0,
            .CbCrMax = 255,
            .CbCrMin = 0,
        };
    }
    memset(info, 0, sizeof(*info));
    vImage_Error error = vImageConvert_YpCbCrToARGB_GenerateConversion(
        VCAMYpCbCrMatrix(colorSpace, width, height), &range, info,
        planar ? kvImage420Yp8_Cb8_Cr8 : kvImage420Yp8_CbCr8,
        kvImageARGB8888, kvImageNoFlags);
    return error == kvImageNoError;
}

// ARGB byte order is A,R,G,B. {3,2,1,0} writes B,G,R,A into the destination,
// which is exactly the kCVPixelFormatType_32BGRA byte layout.
static const uint8_t VCAMBGRAPermuteMap[4] = {3, 2, 1, 0};

static BOOL VCAMConvertYUVToBGRA(BOOL nv12,
                                 BOOL fullRange,
                                 enum AVColorSpace colorSpace,
                                 const uint8_t *luma,
                                 size_t lumaStride,
                                 const uint8_t *chroma,
                                 size_t chromaStride,
                                 const uint8_t *chromaV,
                                 size_t chromaVStride,
                                 size_t width,
                                 size_t height,
                                 uint8_t *destination,
                                 size_t destinationStride) {
    if (luma == NULL || chroma == NULL || destination == NULL ||
        width == 0 || height == 0 || (width & 1) != 0 || (height & 1) != 0 ||
        !VCAMRowBytesAligned(lumaStride) ||
        !VCAMRowBytesAligned(chromaStride) ||
        !VCAMRowBytesAligned(destinationStride)) {
        return NO;
    }
    vImage_YpCbCrToARGB info;
    if (!VCAMPrepareYpCbCrInfo(fullRange, !nv12, colorSpace,
                              width, height, &info)) return NO;
    vImage_Buffer yp = {
        .data = (void *)luma,
        .height = height,
        .width = width,
        .rowBytes = lumaStride,
    };
    vImage_Buffer out = {
        .data = destination,
        .height = height,
        .width = width,
        .rowBytes = destinationStride,
    };
    vImage_Error error = kvImageNoError;
    if (nv12) {
        vImage_Buffer cbcr = {
            .data = (void *)chroma,
            .height = height / 2,
            .width = width,
            .rowBytes = chromaStride,
        };
        error = vImageConvert_420Yp8_CbCr8ToARGB8888(
            &yp, &cbcr, &out, &info, VCAMBGRAPermuteMap, 255, kvImageNoFlags);
    } else {
        if (chromaV == NULL || !VCAMRowBytesAligned(chromaVStride)) return NO;
        vImage_Buffer cb = {
            .data = (void *)chroma,
            .height = height / 2,
            .width = width / 2,
            .rowBytes = chromaStride,
        };
        vImage_Buffer cr = {
            .data = (void *)chromaV,
            .height = height / 2,
            .width = width / 2,
            .rowBytes = chromaVStride,
        };
        error = vImageConvert_420Yp8_Cb8_Cr8ToARGB8888(
            &yp, &cb, &cr, &out, &info, VCAMBGRAPermuteMap, 255,
            kvImageNoFlags);
    }
    return error == kvImageNoError;
}

// Legacy scalar conversion kept as a fallback for formats or row alignment
// that Accelerate rejects (10-bit is first downsampled, then handled below).
static CVPixelBufferRef VCAMCopyBGRAFromAVFrameScalar(AVFrame *frame,
                                                       int outputWidth,
                                                       int outputHeight) {
    BOOL planar420 = frame->format == AV_PIX_FMT_YUV420P ||
        frame->format == AV_PIX_FMT_YUVJ420P;
    BOOL nv12 = frame->format == AV_PIX_FMT_NV12;
    BOOL planar420p10 = frame->format == AV_PIX_FMT_YUV420P10LE;
    BOOL p010 = frame->format == AV_PIX_FMT_P010LE;
    if (!planar420 && !nv12 && !planar420p10 && !p010) return NULL;
    if (frame->data[0] == NULL || frame->data[1] == NULL ||
        ((planar420 || planar420p10) && frame->data[2] == NULL)) return NULL;

    NSDictionary *attributes = @{
        (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
    };
    CVPixelBufferRef pixelBuffer = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, (size_t)outputWidth,
                            (size_t)outputHeight, kCVPixelFormatType_32BGRA,
                            (__bridge CFDictionaryRef)attributes,
                            &pixelBuffer) != kCVReturnSuccess) return NULL;
    if (CVPixelBufferLockBaseAddress(pixelBuffer, 0) != kCVReturnSuccess) {
        CVPixelBufferRelease(pixelBuffer);
        return NULL;
    }
    uint8_t *destination = (uint8_t *)CVPixelBufferGetBaseAddress(pixelBuffer);
    size_t destinationStride = CVPixelBufferGetBytesPerRow(pixelBuffer);
    int shift = planar420p10 ? 2 : (p010 ? 8 : 0);
    BOOL fullRange = frame->format == AV_PIX_FMT_YUVJ420P ||
        frame->color_range == AVCOL_RANGE_JPEG;
    double redLuma = 0.0;
    double blueLuma = 0.0;
    VCAMLumaCoefficients(frame->colorspace, (size_t)frame->width,
                         (size_t)frame->height, &redLuma, &blueLuma);
    double greenLuma = 1.0 - redLuma - blueLuma;
    for (int y = 0; y < outputHeight; y++) {
        int sourceY = MIN(frame->height - 1,
                          (int)((int64_t)y * frame->height / outputHeight));
        const uint8_t *luma = frame->data[0] + sourceY * frame->linesize[0];
        const uint8_t *chromaU = frame->data[1] + (sourceY / 2) * frame->linesize[1];
        const uint8_t *chromaV = (planar420 || planar420p10)
            ? frame->data[2] + (sourceY / 2) * frame->linesize[2] : NULL;
        uint8_t *row = destination + (size_t)y * destinationStride;
        for (int x = 0; x < outputWidth; x++) {
            int sourceX = MIN(frame->width - 1,
                              (int)((int64_t)x * frame->width / outputWidth));
            int sampleY;
            int sampleU;
            int sampleV;
            if (planar420 || nv12) {
                sampleY = luma[sourceX];
                if (planar420) {
                    sampleU = chromaU[sourceX / 2];
                    sampleV = chromaV[sourceX / 2];
                } else {
                    sampleU = chromaU[(sourceX / 2) * 2];
                    sampleV = chromaU[(sourceX / 2) * 2 + 1];
                }
            } else {
                sampleY = AV_RL16(luma + sourceX * 2) >> shift;
                if (planar420p10) {
                    sampleU = AV_RL16(chromaU + (sourceX / 2) * 2) >> shift;
                    sampleV = AV_RL16(chromaV + (sourceX / 2) * 2) >> shift;
                } else {
                    sampleU = AV_RL16(chromaU + ((sourceX / 2) * 2) * 2) >> shift;
                    sampleV = AV_RL16(chromaU + (((sourceX / 2) * 2) * 2) + 2) >> shift;
                }
            }
            double normalizedY = fullRange
                ? sampleY / 255.0 : (sampleY - 16.0) / 219.0;
            double normalizedU = (sampleU - 128.0) / (fullRange ? 255.0 : 224.0);
            double normalizedV = (sampleV - 128.0) / (fullRange ? 255.0 : 224.0);
            int red = (int)lrint(255.0 * (normalizedY +
                2.0 * (1.0 - redLuma) * normalizedV));
            int blue = (int)lrint(255.0 * (normalizedY +
                2.0 * (1.0 - blueLuma) * normalizedU));
            int green = (int)lrint(255.0 * (normalizedY -
                2.0 * blueLuma * (1.0 - blueLuma) / greenLuma * normalizedU -
                2.0 * redLuma * (1.0 - redLuma) / greenLuma * normalizedV));
            row[x * 4 + 0] = (uint8_t)MAX(0, MIN(255, blue));
            row[x * 4 + 1] = (uint8_t)MAX(0, MIN(255, green));
            row[x * 4 + 2] = (uint8_t)MAX(0, MIN(255, red));
            row[x * 4 + 3] = 255;
        }
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    VCAMSetAVFrameColorAttachments(frame, pixelBuffer,
                                   (size_t)outputWidth, (size_t)outputHeight);
    return pixelBuffer;
}

static BOOL VCAMDownsample10BitTo8Bit(const uint8_t *source,
                                      size_t sourceStride,
                                      uint8_t *destination,
                                      size_t destinationStride,
                                      size_t width,
                                      size_t height,
                                      unsigned int shift) {
    if (source == NULL || destination == NULL || width == 0 || height == 0 ||
        (shift != 2 && shift != 8)) {
        return NO;
    }
    for (size_t y = 0; y < height; y++) {
        const uint8_t *inputRow = source + y * sourceStride;
        uint8_t *outputRow = destination + y * destinationStride;
        for (size_t x = 0; x < width; x++) {
            outputRow[x] = (uint8_t)((AV_RL16(inputRow + x * 2) >> shift) & 0xff);
        }
    }
    return YES;
}

CVPixelBufferRef VCAMCopyNV12FromAVFrame(AVFrame *frame) {
    if (frame == NULL || frame->width <= 0 || frame->height <= 0 ||
        (frame->width & 1) != 0 || (frame->height & 1) != 0 ||
        !VCAMSourceSizedVideoFrameFitsBudget(frame->width, frame->height) ||
        frame->colorspace == AVCOL_SPC_BT2020_CL) return NULL;
    BOOL planar = frame->format == AV_PIX_FMT_YUV420P ||
        frame->format == AV_PIX_FMT_YUVJ420P;
    BOOL nv12 = frame->format == AV_PIX_FMT_NV12;
    if ((!planar && !nv12) || frame->data[0] == NULL ||
        frame->data[1] == NULL || (planar && frame->data[2] == NULL) ||
        frame->linesize[0] < frame->width ||
        frame->linesize[1] < frame->width / (planar ? 2 : 1) ||
        (planar && frame->linesize[2] < frame->width / 2)) return NULL;

    BOOL fullRange = frame->format == AV_PIX_FMT_YUVJ420P ||
        frame->color_range == AVCOL_RANGE_JPEG;
    OSType pixelFormat = fullRange
        ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn createStatus = CVPixelBufferCreate(
        kCFAllocatorDefault, (size_t)frame->width, (size_t)frame->height,
        pixelFormat, NULL, &pixelBuffer);
    if (createStatus != kCVReturnSuccess) {
        static dispatch_once_t createFailureToken;
        dispatch_once(&createFailureToken, ^{
            fprintf(stderr,
                    "vcamd NV12 intermediate create failed status=%d size=%dx%d\n",
                    createStatus, frame->width, frame->height);
            fflush(stderr);
        });
        return NULL;
    }
    CVReturn lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    if (lockStatus != kCVReturnSuccess) {
        static dispatch_once_t lockFailureToken;
        dispatch_once(&lockFailureToken, ^{
            fprintf(stderr, "vcamd NV12 intermediate lock failed status=%d\n",
                    lockStatus);
            fflush(stderr);
        });
        CVPixelBufferRelease(pixelBuffer);
        return NULL;
    }

    size_t width = (size_t)frame->width;
    size_t height = (size_t)frame->height;
    uint8_t *destinationY = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0);
    uint8_t *destinationUV = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1);
    size_t destinationYStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
    size_t destinationUVStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1);
    for (size_t row = 0; row < height; row++) {
        memcpy(destinationY + row * destinationYStride,
               frame->data[0] + row * (size_t)frame->linesize[0], width);
    }
    for (size_t row = 0; row < height / 2; row++) {
        uint8_t *output = destinationUV + row * destinationUVStride;
        const uint8_t *sourceU = frame->data[1] + row * (size_t)frame->linesize[1];
        if (nv12) {
            memcpy(output, sourceU, width);
            continue;
        }
        const uint8_t *sourceV = frame->data[2] + row * (size_t)frame->linesize[2];
        for (size_t column = 0; column < width / 2; column++) {
            output[column * 2] = sourceU[column];
            output[column * 2 + 1] = sourceV[column];
        }
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);

    VCAMSetAVFrameColorAttachments(frame, pixelBuffer, width, height);
    return pixelBuffer;
}

CVPixelBufferRef VCAMCopyBGRAFromAVFrame(AVFrame *frame) {
    if (frame == NULL || frame->width <= 0 || frame->height <= 0 ||
        frame->colorspace == AVCOL_SPC_BT2020_CL) return NULL;
    BOOL planar420 = frame->format == AV_PIX_FMT_YUV420P ||
        frame->format == AV_PIX_FMT_YUVJ420P;
    BOOL nv12 = frame->format == AV_PIX_FMT_NV12;
    BOOL planar420p10 = frame->format == AV_PIX_FMT_YUV420P10LE;
    BOOL p010 = frame->format == AV_PIX_FMT_P010LE;
    if (!planar420 && !nv12 && !planar420p10 && !p010) return NULL;
    if (frame->data[0] == NULL || frame->data[1] == NULL ||
        ((planar420 || planar420p10) && frame->data[2] == NULL)) return NULL;

    if (!VCAMSourceSizedVideoFrameFitsBudget(frame->width, frame->height)) return NULL;
    int outputWidth = frame->width;
    int outputHeight = frame->height;

    NSDictionary *attributes = @{
        (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
    };
    CVPixelBufferRef pixelBuffer = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, (size_t)outputWidth,
                            (size_t)outputHeight, kCVPixelFormatType_32BGRA,
                            (__bridge CFDictionaryRef)attributes,
                            &pixelBuffer) != kCVReturnSuccess) return NULL;
    if (CVPixelBufferLockBaseAddress(pixelBuffer, 0) != kCVReturnSuccess) {
        CVPixelBufferRelease(pixelBuffer);
        return NULL;
    }

    BOOL converted = NO;
    if ((planar420 || nv12) &&
        VCAMRowBytesAligned(frame->linesize[0]) &&
        VCAMRowBytesAligned(frame->linesize[1]) &&
        ((frame->linesize[0] * (size_t)frame->height) < (512ULL << 20))) {
        BOOL fullRange = frame->format == AV_PIX_FMT_YUVJ420P ||
            frame->color_range == AVCOL_RANGE_JPEG;
        converted = VCAMConvertYUVToBGRA(
            nv12, fullRange, frame->colorspace,
            frame->data[0], (size_t)frame->linesize[0],
            frame->data[1], (size_t)frame->linesize[1],
            planar420 ? frame->data[2] : NULL,
            planar420 ? (size_t)frame->linesize[2] : 0,
            (size_t)frame->width, (size_t)frame->height,
            (uint8_t *)CVPixelBufferGetBaseAddress(pixelBuffer),
            CVPixelBufferGetBytesPerRow(pixelBuffer));
    } else if (planar420p10 || p010) {
        size_t width = (size_t)frame->width;
        size_t height = (size_t)frame->height;
        size_t uvWidth = width / 2;
        size_t uvHeight = height / 2;
        size_t lumaStride = (width + 15) & ~(size_t)15;
        size_t uvStride = (uvWidth + 15) & ~(size_t)15;
        uint8_t *luma8 = malloc(lumaStride * height);
        uint8_t *chroma8 = malloc(uvStride * uvHeight * 2);
        uint8_t *destination =
            (uint8_t *)CVPixelBufferGetBaseAddress(pixelBuffer);
        size_t destinationStride = CVPixelBufferGetBytesPerRow(pixelBuffer);
        if (luma8 != NULL && chroma8 != NULL &&
            VCAMDownsample10BitTo8Bit(
                frame->data[0], (size_t)frame->linesize[0],
                luma8, lumaStride, width, height, p010 ? 8 : 2)) {
            BOOL fullRange = frame->color_range == AVCOL_RANGE_JPEG;
            BOOL convertedAtSourceSize = NO;
            if (p010) {
                if (VCAMDownsample10BitTo8Bit(
                        frame->data[1], (size_t)frame->linesize[1],
                        chroma8, lumaStride, width, uvHeight, 8)) {
                    convertedAtSourceSize = VCAMConvertYUVToBGRA(
                        YES, fullRange, frame->colorspace,
                        luma8, lumaStride,
                        chroma8, lumaStride,
                        NULL, 0,
                        width, height,
                        destination, destinationStride);
                }
            } else {
                if (VCAMDownsample10BitTo8Bit(
                        frame->data[1], (size_t)frame->linesize[1],
                        chroma8, uvStride, uvWidth, uvHeight, 2) &&
                    VCAMDownsample10BitTo8Bit(
                        frame->data[2], (size_t)frame->linesize[2],
                        chroma8 + uvStride * uvHeight, uvStride,
                        uvWidth, uvHeight, 2)) {
                    convertedAtSourceSize = VCAMConvertYUVToBGRA(
                        NO, fullRange, frame->colorspace,
                        luma8, lumaStride,
                        chroma8, uvStride,
                        chroma8 + uvStride * uvHeight, uvStride,
                        width, height,
                        destination, destinationStride);
                }
            }
            converted = convertedAtSourceSize;
        }
        free(luma8);
        free(chroma8);
    }

    if (!converted) {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
        CVPixelBufferRelease(pixelBuffer);
        return VCAMCopyBGRAFromAVFrameScalar(frame, outputWidth, outputHeight);
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    VCAMSetAVFrameColorAttachments(frame, pixelBuffer,
                                   (size_t)outputWidth, (size_t)outputHeight);
    return pixelBuffer;
}

BOOL VCAMCopyNV12PixelBufferToBGRA(CVPixelBufferRef source,
                                   CVPixelBufferRef destination) {
    if (source == NULL || destination == NULL ||
        CVPixelBufferGetPixelFormatType(source) !=
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
        CVPixelBufferGetPixelFormatType(destination) !=
            kCVPixelFormatType_32BGRA ||
        CVPixelBufferGetWidth(source) != CVPixelBufferGetWidth(destination) ||
        CVPixelBufferGetHeight(source) != CVPixelBufferGetHeight(destination) ||
        !CVPixelBufferIsPlanar(source) ||
        CVPixelBufferGetPlaneCount(source) != 2) {
        return NO;
    }
    size_t width = CVPixelBufferGetWidth(source);
    size_t height = CVPixelBufferGetHeight(source);
    if ((width & 1) != 0 || (height & 1) != 0) return NO;
    if (CVPixelBufferLockBaseAddress(source, kCVPixelBufferLock_ReadOnly) !=
            kCVReturnSuccess ||
        CVPixelBufferLockBaseAddress(destination, 0) != kCVReturnSuccess) {
        CVPixelBufferUnlockBaseAddress(source, kCVPixelBufferLock_ReadOnly);
        return NO;
    }
    BOOL converted = VCAMConvertYUVToBGRA(
        YES, NO, VCAMColorSpaceForPixelBuffer(source),
        (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(source, 0),
        CVPixelBufferGetBytesPerRowOfPlane(source, 0),
        (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(source, 1),
        CVPixelBufferGetBytesPerRowOfPlane(source, 1),
        NULL, 0, width, height,
        (uint8_t *)CVPixelBufferGetBaseAddress(destination),
        CVPixelBufferGetBytesPerRow(destination));
    CVPixelBufferUnlockBaseAddress(destination, 0);
    CVPixelBufferUnlockBaseAddress(source, kCVPixelBufferLock_ReadOnly);
    return converted;
}

static BOOL VCAMRenderBGRABuffer(vImage_Buffer initial,
                                 CVPixelBufferRef destination,
                                 int turns,
                                 BOOL mirrorHorizontally,
                                 int contentMode,
                                 uint8_t *scratchOne,
                                 uint8_t *scratchTwo) {
    size_t destinationWidth = CVPixelBufferGetWidth(destination);
    size_t destinationHeight = CVPixelBufferGetHeight(destination);
    size_t orientedWidth = (turns & 1) ? initial.height : initial.width;
    size_t orientedHeight = (turns & 1) ? initial.width : initial.height;

    // The common portrait-video case is exactly one right-angle rotation.
    // Write it straight into the camera buffer: no scratch, scale, or copy.
    if (!mirrorHorizontally && orientedWidth == destinationWidth &&
        orientedHeight == destinationHeight) {
        if (CVPixelBufferLockBaseAddress(destination, 0) != kCVReturnSuccess) {
            return NO;
        }
        vImage_Buffer output = {
            .data = CVPixelBufferGetBaseAddress(destination),
            .height = destinationHeight,
            .width = destinationWidth,
            .rowBytes = CVPixelBufferGetBytesPerRow(destination),
        };
        vImage_Error error = kvImageNoError;
        if (turns == 0) {
            size_t copyBytes = initial.width * 4;
            for (size_t row = 0; row < initial.height; row++) {
                memcpy((uint8_t *)output.data + row * output.rowBytes,
                       (const uint8_t *)initial.data + row * initial.rowBytes,
                       copyBytes);
            }
        } else {
            uint8_t background[4] = {0, 0, 0, 255};
            error = vImageRotate90_ARGB8888(&initial, &output,
                                            (uint8_t)turns, background,
                                            kvImageNoFlags);
        }
        CVPixelBufferUnlockBaseAddress(destination, 0);
        return error == kvImageNoError;
    }

    vImage_Buffer oriented = initial;
    if (turns != 0) {
        uint8_t *rotationBytes = initial.data == scratchOne
            ? scratchTwo : scratchOne;
        if (rotationBytes == NULL) return NO;
        vImage_Buffer rotated = {
            .data = rotationBytes,
            .height = orientedHeight,
            .width = orientedWidth,
            .rowBytes = orientedWidth * 4,
        };
        uint8_t background[4] = {0, 0, 0, 255};
        if (vImageRotate90_ARGB8888(&initial, &rotated, (uint8_t)turns,
                                    background, kvImageNoFlags) !=
            kvImageNoError) {
            return NO;
        }
        oriented = rotated;
    }
    if (mirrorHorizontally) {
        uint8_t *reflectionBytes = oriented.data == scratchOne
            ? scratchTwo : scratchOne;
        if (reflectionBytes == NULL) return NO;
        vImage_Buffer reflected = {
            .data = reflectionBytes,
            .height = orientedHeight,
            .width = orientedWidth,
            .rowBytes = orientedWidth * 4,
        };
        vImage_Error reflectionError = (turns & 1)
            ? vImageVerticalReflect_ARGB8888(&oriented, &reflected,
                                             kvImageNoFlags)
            : vImageHorizontalReflect_ARGB8888(&oriented, &reflected,
                                               kvImageNoFlags);
        if (reflectionError != kvImageNoError) return NO;
        oriented = reflected;
    }

    if (CVPixelBufferLockBaseAddress(destination, 0) != kCVReturnSuccess) {
        return NO;
    }
    uint8_t *destinationBytes =
        (uint8_t *)CVPixelBufferGetBaseAddress(destination);
    size_t destinationStride = CVPixelBufferGetBytesPerRow(destination);
    vImage_Buffer output = {
        .data = destinationBytes,
        .height = destinationHeight,
        .width = destinationWidth,
        .rowBytes = destinationStride,
    };
    vImage_Buffer input = oriented;
    if (contentMode == 1) {
        double sourceAspect = (double)orientedWidth / (double)orientedHeight;
        double destinationAspect =
            (double)destinationWidth / (double)destinationHeight;
        if (sourceAspect > destinationAspect) {
            size_t cropWidth = MAX((size_t)1,
                (size_t)llround((double)orientedHeight * destinationAspect));
            cropWidth = MIN(cropWidth, orientedWidth);
            input.data = (uint8_t *)input.data +
                ((orientedWidth - cropWidth) / 2) * 4;
            input.width = cropWidth;
        } else if (sourceAspect < destinationAspect) {
            size_t cropHeight = MAX((size_t)1,
                (size_t)llround((double)orientedWidth / destinationAspect));
            cropHeight = MIN(cropHeight, orientedHeight);
            input.data = (uint8_t *)input.data +
                ((orientedHeight - cropHeight) / 2) * input.rowBytes;
            input.height = cropHeight;
        }
    } else if (contentMode == 0) {
        memset(destinationBytes, 0, destinationStride * destinationHeight);
        double scale = MIN((double)destinationWidth / (double)orientedWidth,
                           (double)destinationHeight / (double)orientedHeight);
        size_t fittedWidth = MAX((size_t)1,
            MIN(destinationWidth, (size_t)llround(orientedWidth * scale)));
        size_t fittedHeight = MAX((size_t)1,
            MIN(destinationHeight, (size_t)llround(orientedHeight * scale)));
        output.data = destinationBytes +
            ((destinationHeight - fittedHeight) / 2) * destinationStride +
            ((destinationWidth - fittedWidth) / 2) * 4;
        output.width = fittedWidth;
        output.height = fittedHeight;
    }
    vImage_Error scaleError = kvImageNoError;
    if (input.width == output.width && input.height == output.height) {
        size_t copyBytes = input.width * 4;
        for (size_t row = 0; row < input.height; row++) {
            memcpy((uint8_t *)output.data + row * output.rowBytes,
                   (const uint8_t *)input.data + row * input.rowBytes,
                   copyBytes);
        }
    } else {
        scaleError = vImageScale_ARGB8888(&input, &output, NULL,
                                          kvImageNoFlags);
    }
    CVPixelBufferUnlockBaseAddress(destination, 0);
    return scaleError == kvImageNoError;
}

BOOL VCAMRenderBGRAPixelBufferToBGRA(CVPixelBufferRef source,
                                     CVPixelBufferRef destination,
                                     int rotationDegrees,
                                     BOOL mirrorHorizontally,
                                     int contentMode) {
    if (source == NULL || destination == NULL || source == destination ||
        CVPixelBufferGetPixelFormatType(source) != kCVPixelFormatType_32BGRA ||
        CVPixelBufferGetPixelFormatType(destination) !=
            kCVPixelFormatType_32BGRA ||
        rotationDegrees % 90 != 0 || contentMode < 0 || contentMode > 2) {
        return NO;
    }
    size_t sourceWidth = CVPixelBufferGetWidth(source);
    size_t sourceHeight = CVPixelBufferGetHeight(source);
    if (sourceWidth == 0 || sourceHeight == 0) return NO;
    size_t byteCount = sourceWidth * sourceHeight * 4;
    uint8_t *scratchOne = VCAMConverterScratchBuffer(sourceWidth, sourceHeight);
    uint8_t *scratchTwo = VCAMTransformScratchBuffer(byteCount);
    if (scratchOne == NULL || scratchTwo == NULL) return NO;
    if (CVPixelBufferLockBaseAddress(source, kCVPixelBufferLock_ReadOnly) !=
        kCVReturnSuccess) {
        return NO;
    }
    vImage_Buffer initial = {
        .data = CVPixelBufferGetBaseAddress(source),
        .height = sourceHeight,
        .width = sourceWidth,
        .rowBytes = CVPixelBufferGetBytesPerRow(source),
    };
    int turns = ((rotationDegrees / 90) % 4 + 4) % 4;
    BOOL rendered = VCAMRenderBGRABuffer(initial, destination, turns,
                                         mirrorHorizontally, contentMode,
                                         scratchOne, scratchTwo);
    CVPixelBufferUnlockBaseAddress(source, kCVPixelBufferLock_ReadOnly);
    return rendered;
}

BOOL VCAMRenderNV12PixelBufferToBGRA(CVPixelBufferRef source,
                                     CVPixelBufferRef destination,
                                     int rotationDegrees,
                                     BOOL mirrorHorizontally,
                                     int contentMode) {
    if (source == NULL || destination == NULL ||
        (CVPixelBufferGetPixelFormatType(source) !=
             kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
         CVPixelBufferGetPixelFormatType(source) !=
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) ||
        CVPixelBufferGetPixelFormatType(destination) !=
             kCVPixelFormatType_32BGRA ||
        !CVPixelBufferIsPlanar(source) ||
        CVPixelBufferGetPlaneCount(source) != 2) {
        return NO;
    }
    int turns = ((rotationDegrees / 90) % 4 + 4) % 4;
    if (rotationDegrees % 90 != 0 || contentMode < 0 || contentMode > 2) {
        return NO;
    }
    size_t sourceWidth = CVPixelBufferGetWidth(source);
    size_t sourceHeight = CVPixelBufferGetHeight(source);
    size_t destinationWidth = CVPixelBufferGetWidth(destination);
    size_t destinationHeight = CVPixelBufferGetHeight(destination);
    if (sourceWidth == 0 || sourceHeight == 0 || destinationWidth == 0 ||
        destinationHeight == 0 || (sourceWidth & 1) != 0 ||
        (sourceHeight & 1) != 0) {
        return NO;
    }
    size_t byteCount = sourceWidth * sourceHeight * 4;
    uint8_t *convertedBytes = VCAMConverterScratchBuffer(sourceWidth,
                                                          sourceHeight);
    uint8_t *transformedBytes = VCAMTransformScratchBuffer(byteCount);
    if (convertedBytes == NULL || transformedBytes == NULL) return NO;

    if (CVPixelBufferLockBaseAddress(source, kCVPixelBufferLock_ReadOnly) !=
            kCVReturnSuccess) {
        return NO;
    }
    BOOL fullRange = CVPixelBufferGetPixelFormatType(source) ==
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    BOOL converted = VCAMConvertYUVToBGRA(
        YES, fullRange, VCAMColorSpaceForPixelBuffer(source),
        (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(source, 0),
        CVPixelBufferGetBytesPerRowOfPlane(source, 0),
        (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(source, 1),
        CVPixelBufferGetBytesPerRowOfPlane(source, 1),
        NULL, 0, sourceWidth, sourceHeight,
        convertedBytes, sourceWidth * 4);
    CVPixelBufferUnlockBaseAddress(source, kCVPixelBufferLock_ReadOnly);
    if (!converted) return NO;

    vImage_Buffer initial = {
        .data = convertedBytes,
        .height = sourceHeight,
        .width = sourceWidth,
        .rowBytes = sourceWidth * 4,
    };
    return VCAMRenderBGRABuffer(initial, destination, turns,
                                mirrorHorizontally, contentMode,
                                convertedBytes, transformedBytes);
}

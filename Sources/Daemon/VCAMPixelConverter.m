#import "VCAMPixelConverter.h"

#import <Accelerate/Accelerate.h>
#import <Foundation/Foundation.h>

#include <libavutil/intreadwrite.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

// BT.601 coefficients from the vImage documentation example. The SDK headers
// do not export kvImageITU601_YpCbCrToARGBMatrix, so define it explicitly.
static const vImage_YpCbCrToARGBMatrix VCAMITU601Matrix = {
    .Yp = 1.0f,
    .Cb_G = -0.3441f,
    .Cb_B = 1.772f,
    .Cr_R = 1.402f,
    .Cr_G = -0.7141f,
};

// The conversion queues are fixed threads (RTSP conversion queue and the
// vcamd pipeline queue), so a thread-local scratch is safe without a lock.
static __thread uint8_t *VCAMThreadScratch;
static __thread size_t VCAMThreadScratchWidth;
static __thread size_t VCAMThreadScratchHeight;
static __thread uint8_t *VCAMThreadTransformScratch;
static __thread size_t VCAMThreadTransformScratchSize;

static uint8_t *VCAMConverterScratchBuffer(size_t width, size_t height) {
    size_t required = width * height * 4;
    if (required == 0 || required > 512ULL * 1024 * 1024) return NULL;
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
    if (required == 0 || required > 512ULL * 1024 * 1024) return NULL;
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

static BOOL VCAMPrepareYpCbCrInfo(BOOL fullRange,
                                  BOOL planar,
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
        &VCAMITU601Matrix, &range, info,
        planar ? kvImage420Yp8_Cb8_Cr8 : kvImage420Yp8_CbCr8,
        kvImageARGB8888, kvImageNoFlags);
    return error == kvImageNoError;
}

// ARGB byte order is A,R,G,B. {3,2,1,0} writes B,G,R,A into the destination,
// which is exactly the kCVPixelFormatType_32BGRA byte layout.
static const uint8_t VCAMBGRAPermuteMap[4] = {3, 2, 1, 0};

static BOOL VCAMConvertYUVToBGRA(BOOL nv12,
                                 BOOL fullRange,
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
    if (!VCAMPrepareYpCbCrInfo(fullRange, !nv12, &info)) return NO;
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

static BOOL VCAMScaleBGRAInPlace(const uint8_t *source,
                                 size_t sourceStride,
                                 size_t sourceWidth,
                                 size_t sourceHeight,
                                 uint8_t *destination,
                                 size_t destinationStride,
                                 size_t destinationWidth,
                                 size_t destinationHeight) {
    if (source == NULL || destination == NULL || sourceWidth == 0 ||
        sourceHeight == 0 || destinationWidth == 0 || destinationHeight == 0 ||
        !VCAMRowBytesAligned(sourceStride) ||
        !VCAMRowBytesAligned(destinationStride)) {
        return NO;
    }
    vImage_Buffer src = {
        .data = (void *)source,
        .height = sourceHeight,
        .width = sourceWidth,
        .rowBytes = sourceStride,
    };
    vImage_Buffer dst = {
        .data = destination,
        .height = destinationHeight,
        .width = destinationWidth,
        .rowBytes = destinationStride,
    };
    vImage_Error error = vImageScale_ARGB8888(
        &src, &dst, NULL, kvImageHighQualityResampling);
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
    int shift = (planar420p10 || p010) ? 2 : 0;
    BOOL fullRange = frame->format == AV_PIX_FMT_YUVJ420P ||
        frame->color_range == AVCOL_RANGE_JPEG;
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
            int c = fullRange ? sampleY : MAX(0, sampleY - 16);
            int d = sampleU - 128;
            int e = sampleV - 128;
            int red = fullRange ? c + ((359 * e + 128) >> 8)
                                : (298 * c + 409 * e + 128) >> 8;
            int green = fullRange ? c - ((88 * d + 183 * e + 128) >> 8)
                                  : (298 * c - 100 * d - 208 * e + 128) >> 8;
            int blue = fullRange ? c + ((454 * d + 128) >> 8)
                                 : (298 * c + 516 * d + 128) >> 8;
            row[x * 4 + 0] = (uint8_t)MAX(0, MIN(255, blue));
            row[x * 4 + 1] = (uint8_t)MAX(0, MIN(255, green));
            row[x * 4 + 2] = (uint8_t)MAX(0, MIN(255, red));
            row[x * 4 + 3] = 255;
        }
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    return pixelBuffer;
}

static BOOL VCAMDownsample10BitPlanarTo8Bit(const uint8_t *source,
                                            size_t sourceStride,
                                            uint8_t *destination,
                                            size_t destinationStride,
                                            size_t width,
                                            size_t height) {
    if (source == NULL || destination == NULL || width == 0 || height == 0) {
        return NO;
    }
    for (size_t y = 0; y < height; y++) {
        const uint8_t *inputRow = source + y * sourceStride;
        uint8_t *outputRow = destination + y * destinationStride;
        for (size_t x = 0; x < width; x++) {
            outputRow[x] = (uint8_t)((AV_RL16(inputRow + x * 2) >> 2) & 0xff);
        }
    }
    return YES;
}

static BOOL VCAMDownsample10BitNV12To8Bit(const uint8_t *source,
                                          size_t sourceStride,
                                          uint8_t *destination,
                                          size_t destinationStride,
                                          size_t width,
                                          size_t height) {
    if (source == NULL || destination == NULL || width == 0 || height == 0 ||
        (width & 1) != 0) {
        return NO;
    }
    for (size_t y = 0; y < height; y++) {
        const uint8_t *inputRow = source + y * sourceStride;
        uint8_t *outputRow = destination + y * destinationStride;
        for (size_t x = 0; x < width; x++) {
            outputRow[x] = (uint8_t)((AV_RL16(inputRow + x * 2) >> 2) & 0xff);
        }
    }
    return YES;
}

CVPixelBufferRef VCAMCopyBGRAFromAVFrame(AVFrame *frame) {
    if (frame == NULL || frame->width <= 0 || frame->height <= 0) return NULL;
    BOOL planar420 = frame->format == AV_PIX_FMT_YUV420P ||
        frame->format == AV_PIX_FMT_YUVJ420P;
    BOOL nv12 = frame->format == AV_PIX_FMT_NV12;
    BOOL planar420p10 = frame->format == AV_PIX_FMT_YUV420P10LE;
    BOOL p010 = frame->format == AV_PIX_FMT_P010LE;
    if (!planar420 && !nv12 && !planar420p10 && !p010) return NULL;
    if (frame->data[0] == NULL || frame->data[1] == NULL ||
        ((planar420 || planar420p10) && frame->data[2] == NULL)) return NULL;

    const int maximumDimension = 1920;
    double scale = MIN(1.0, (double)maximumDimension /
        (double)MAX(frame->width, frame->height));
    int outputWidth = MAX(1, (int)lrint((double)frame->width * scale));
    int outputHeight = MAX(1, (int)lrint((double)frame->height * scale));
    if ((outputWidth & 1) != 0) outputWidth += 1;
    if ((outputHeight & 1) != 0) outputHeight += 1;

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
        uint8_t *scratch = VCAMConverterScratchBuffer(
            (size_t)frame->width, (size_t)frame->height);
        if (scratch != NULL) {
            BOOL fullRange = frame->format == AV_PIX_FMT_YUVJ420P ||
                frame->color_range == AVCOL_RANGE_JPEG;
            BOOL convertedAtSourceSize = VCAMConvertYUVToBGRA(
                nv12, fullRange,
                frame->data[0], (size_t)frame->linesize[0],
                frame->data[1], (size_t)frame->linesize[1],
                planar420 ? frame->data[2] : NULL,
                planar420 ? (size_t)frame->linesize[2] : 0,
                (size_t)frame->width, (size_t)frame->height,
                scratch, (size_t)frame->width * 4);
            if (convertedAtSourceSize) {
                uint8_t *destination =
                    (uint8_t *)CVPixelBufferGetBaseAddress(pixelBuffer);
                size_t destinationStride =
                    CVPixelBufferGetBytesPerRow(pixelBuffer);
                converted = VCAMScaleBGRAInPlace(
                    scratch, (size_t)frame->width * 4,
                    (size_t)frame->width, (size_t)frame->height,
                    destination, destinationStride,
                    (size_t)outputWidth, (size_t)outputHeight);
            }
        }
    } else if (planar420p10 || p010) {
        size_t width = (size_t)frame->width;
        size_t height = (size_t)frame->height;
        size_t uvWidth = width / 2;
        size_t uvHeight = height / 2;
        size_t lumaStride = (width + 15) & ~(size_t)15;
        size_t uvStride = (uvWidth + 15) & ~(size_t)15;
        uint8_t *luma8 = malloc(lumaStride * height);
        uint8_t *chroma8 = malloc(uvStride * uvHeight * 2);
        uint8_t *argb = malloc(width * height * 4);
        if (luma8 != NULL && chroma8 != NULL && argb != NULL &&
            VCAMDownsample10BitPlanarTo8Bit(
                frame->data[0], (size_t)frame->linesize[0],
                luma8, lumaStride, width, height)) {
            BOOL fullRange = frame->color_range == AVCOL_RANGE_JPEG;
            BOOL convertedAtSourceSize = NO;
            if (p010) {
                if (VCAMDownsample10BitNV12To8Bit(
                        frame->data[1], (size_t)frame->linesize[1],
                        chroma8, lumaStride, width, uvHeight)) {
                    convertedAtSourceSize = VCAMConvertYUVToBGRA(
                        YES, fullRange,
                        luma8, lumaStride,
                        chroma8, lumaStride,
                        NULL, 0,
                        width, height,
                        argb, width * 4);
                }
            } else {
                if (VCAMDownsample10BitPlanarTo8Bit(
                        frame->data[1], (size_t)frame->linesize[1],
                        chroma8, uvStride, uvWidth, uvHeight) &&
                    VCAMDownsample10BitPlanarTo8Bit(
                        frame->data[2], (size_t)frame->linesize[2],
                        chroma8 + uvStride * uvHeight, uvStride,
                        uvWidth, uvHeight)) {
                    convertedAtSourceSize = VCAMConvertYUVToBGRA(
                        NO, fullRange,
                        luma8, lumaStride,
                        chroma8, uvStride,
                        chroma8 + uvStride * uvHeight, uvStride,
                        width, height,
                        argb, width * 4);
                }
            }
            if (convertedAtSourceSize) {
                uint8_t *destination =
                    (uint8_t *)CVPixelBufferGetBaseAddress(pixelBuffer);
                size_t destinationStride =
                    CVPixelBufferGetBytesPerRow(pixelBuffer);
                converted = VCAMScaleBGRAInPlace(
                    argb, width * 4, width, height,
                    destination, destinationStride,
                    (size_t)outputWidth, (size_t)outputHeight);
            }
        }
        free(luma8);
        free(chroma8);
        free(argb);
    }

    if (!converted) {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
        CVPixelBufferRelease(pixelBuffer);
        return VCAMCopyBGRAFromAVFrameScalar(frame, outputWidth, outputHeight);
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
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
        YES, NO,
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
        YES, fullRange,
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

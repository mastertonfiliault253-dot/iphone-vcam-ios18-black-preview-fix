#import "VCAMHardwareVideoDecoder.h"
#import "../Core/VCAMConfiguration.h"

#import <VideoToolbox/VideoToolbox.h>

#include <libavcodec/avcodec.h>
#include <stdint.h>
#include <string.h>

#ifndef kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder
#define kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder \
    CFSTR("EnableHardwareAcceleratedVideoDecoder")
#endif
#ifndef kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder
#define kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder \
    CFSTR("RequireHardwareAcceleratedVideoDecoder")
#endif
enum { VCAMHardwareMaxFrames = 16 };

static BOOL VCAMIsAnnexBStartCode(const uint8_t *bytes, size_t length,
                                  size_t offset, size_t *startCodeLength) {
    if (offset + 3 <= length && bytes[offset] == 0 && bytes[offset + 1] == 0 &&
        bytes[offset + 2] == 1) {
        if (startCodeLength != NULL) *startCodeLength = 3;
        return YES;
    }
    if (offset + 4 <= length && bytes[offset] == 0 && bytes[offset + 1] == 0 &&
        bytes[offset + 2] == 0 && bytes[offset + 3] == 1) {
        if (startCodeLength != NULL) *startCodeLength = 4;
        return YES;
    }
    return NO;
}

static size_t VCAMTrimAnnexBTrailingZeroBytes(const uint8_t *bytes,
                                              size_t payloadStart,
                                              size_t payloadEnd) {
    while (payloadEnd > payloadStart && bytes[payloadEnd - 1] == 0) {
        payloadEnd -= 1;
    }
    return payloadEnd;
}

// iOS VideoToolbox rejects samples that carry SPS/PPS NALs with
// kVTVideoDecoderBadDataErr (-12909), and on iOS 16.1 a sample that starts
// with SEI NALs (pic_timing/buffering_period, which this pipeline's streams
// emit before every IDR) makes the first IDR fail with
// kVTVideoDecoderReferenceMissingErr (-12780). Parameter sets must live only
// in the CMVideoFormatDescription (avcC/hvcC record) and SEI carries no
// decode information, so both are dropped here. This helper converts either
// Annex-B or length-prefixed input into a length-prefixed sample containing
// only slice NALs. It returns NULL when the caller can keep using the
// original bytes (no omittable NALs found in a length-prefixed packet) or
// when the packet contains no slice NALs.
static BOOL VCAMIsOmittableNAL(const uint8_t *payload, size_t payloadLength,
                               BOOL hevc) {
    if (payload == NULL || payloadLength < 1) return NO;
    int type = hevc ? ((payload[0] >> 1) & 0x3F) : (payload[0] & 0x1F);
    if (hevc) {
        return type == 32 || type == 33 || type == 34 ||
            type == 39 || type == 40;
    }
    return type == 6 || type == 7 || type == 8;
}

static uint8_t *VCAMFilterParameterSetNALs(const uint8_t *bytes, size_t length,
                                           size_t *outLength, BOOL hevc,
                                           BOOL *strippedAny) {
    if (outLength == NULL || bytes == NULL || length < 4) return NULL;
    *outLength = 0;
    if (strippedAny != NULL) *strippedAny = NO;
    BOOL annexB = VCAMIsAnnexBStartCode(bytes, length, 0, NULL);
    size_t payloadStarts[1024] = {0};
    size_t payloadSizes[1024] = {0};
    size_t nalCount = 0;
    BOOL sawParameterSet = NO;
    size_t total = 0;
    if (annexB) {
        size_t scan = 0;
        while (scan < length && nalCount < 1024) {
            size_t startCodeLength = 0;
            if (!VCAMIsAnnexBStartCode(bytes, length, scan, &startCodeLength)) {
                if (bytes[scan] == 0) {
                    scan += 1;
                    continue;
                }
                break;
            }
            size_t payloadStart = scan + startCodeLength;
            size_t next = payloadStart;
            while (next < length &&
                   !VCAMIsAnnexBStartCode(bytes, length, next, NULL)) {
                next += 1;
            }
            size_t payloadEnd = VCAMTrimAnnexBTrailingZeroBytes(
                bytes, payloadStart, next);
            size_t payloadLength = payloadEnd - payloadStart;
            if (VCAMIsOmittableNAL(bytes + payloadStart, payloadLength, hevc)) {
                sawParameterSet = YES;
            } else {
                payloadStarts[nalCount] = payloadStart;
                payloadSizes[nalCount] = payloadLength;
                nalCount += 1;
                total += payloadLength + 4;
            }
            scan = next;
        }
    } else {
        size_t scan = 0;
        while (scan + 4 <= length && nalCount < 1024) {
            uint32_t nalSize =
                ((uint32_t)bytes[scan] << 24) | ((uint32_t)bytes[scan + 1] << 16) |
                ((uint32_t)bytes[scan + 2] << 8) | (uint32_t)bytes[scan + 3];
            if (nalSize == 0 || nalSize > length - scan - 4) break;
            size_t payloadStart = scan + 4;
            if (VCAMIsOmittableNAL(bytes + payloadStart, nalSize, hevc)) {
                sawParameterSet = YES;
            } else {
                payloadStarts[nalCount] = payloadStart;
                payloadSizes[nalCount] = nalSize;
                nalCount += 1;
                total += nalSize + 4;
            }
            scan = payloadStart + nalSize;
        }
    }
    if (strippedAny != NULL) *strippedAny = sawParameterSet;
    if (!sawParameterSet && !annexB) {
        *outLength = length;
        return NULL;
    }
    if (nalCount == 0 || total == 0) return NULL;
    uint8_t *output = malloc(total);
    if (output == NULL) return NULL;
    size_t cursor = 0;
    for (size_t index = 0; index < nalCount; index++) {
        size_t nalSize = payloadSizes[index];
        output[cursor] = (uint8_t)((nalSize >> 24) & 0xff);
        output[cursor + 1] = (uint8_t)((nalSize >> 16) & 0xff);
        output[cursor + 2] = (uint8_t)((nalSize >> 8) & 0xff);
        output[cursor + 3] = (uint8_t)(nalSize & 0xff);
        memcpy(output + cursor + 4, bytes + payloadStarts[index], nalSize);
        cursor += nalSize + 4;
    }
    *outLength = cursor;
    return output;
}

static CFDataRef VCAMBuildAVCCRecord(const uint8_t *const spsPointers[],
                                     const size_t spsSizes[], int spsCount,
                                     const uint8_t *const ppsPointers[],
                                     const size_t ppsSizes[], int ppsCount) {
    if (spsCount < 1 || ppsCount < 1 || spsSizes[0] < 4 || ppsSizes[0] < 1) {
        return NULL;
    }
    size_t total = 6;
    for (int i = 0; i < spsCount; i++) {
        total += 2 + spsSizes[i];
    }
    total += 1;
    for (int i = 0; i < ppsCount; i++) {
        total += 2 + ppsSizes[i];
    }
    uint8_t *record = malloc(total);
    if (record == NULL) return NULL;
    record[0] = 1;
    record[1] = spsPointers[0][1];
    record[2] = spsPointers[0][2];
    record[3] = spsPointers[0][3];
    record[4] = 0xFF; // reserved 111111 + nalLengthSizeMinusOne 11 (4 bytes)
    record[5] = 0xE0 | (uint8_t)(spsCount & 0x1F);
    size_t cursor = 6;
    for (int i = 0; i < spsCount; i++) {
        record[cursor++] = (uint8_t)((spsSizes[i] >> 8) & 0xff);
        record[cursor++] = (uint8_t)(spsSizes[i] & 0xff);
        memcpy(record + cursor, spsPointers[i], spsSizes[i]);
        cursor += spsSizes[i];
    }
    record[cursor++] = (uint8_t)(ppsCount & 0xff);
    for (int i = 0; i < ppsCount; i++) {
        record[cursor++] = (uint8_t)((ppsSizes[i] >> 8) & 0xff);
        record[cursor++] = (uint8_t)(ppsSizes[i] & 0xff);
        memcpy(record + cursor, ppsPointers[i], ppsSizes[i]);
        cursor += ppsSizes[i];
    }
    CFDataRef data = CFDataCreate(kCFAllocatorDefault, record, cursor);
    free(record);
    return data;
}

static CFDataRef VCAMBuildHVCCRecord(const uint8_t *const vpsPointers[],
                                     const size_t vpsSizes[], int vpsCount,
                                     const uint8_t *const spsPointers[],
                                     const size_t spsSizes[], int spsCount,
                                     const uint8_t *const ppsPointers[],
                                     const size_t ppsSizes[], int ppsCount) {
    if (vpsCount < 1 || spsCount < 1 || ppsCount < 1 ||
        vpsPointers[0] == NULL || spsPointers[0] == NULL ||
        ppsPointers[0] == NULL || vpsSizes[0] < 14 ||
        spsSizes[0] < 4 || ppsSizes[0] < 4) {
        return NULL;
    }
    const uint8_t *sets[3] = {vpsPointers[0], spsPointers[0], ppsPointers[0]};
    size_t setSizes[3] = {vpsSizes[0], spsSizes[0], ppsSizes[0]};
    int setTypes[3] = {32, 33, 34};
    size_t total = 22;
    for (int arrayIndex = 0; arrayIndex < 3; arrayIndex++) {
        // Each hvcC array is one type byte, a two-byte NAL count, a two-byte
        // NAL length, then the NAL bytes themselves.
        if (setSizes[arrayIndex] > UINT16_MAX ||
            total > SIZE_MAX - 5 - setSizes[arrayIndex]) {
            return NULL;
        }
        total += 5 + setSizes[arrayIndex];
    }
    uint8_t *record = malloc(total);
    if (record == NULL) return NULL;
    record[0] = 1;
    record[1] = vpsPointers[0][2]; // profile_space/tier/profile_idc
    memcpy(record + 2, vpsPointers[0] + 3, 4);  // compatibility flags
    memcpy(record + 6, vpsPointers[0] + 7, 6);  // constraint indicator
    record[12] = vpsPointers[0][13];            // general_level_idc
    record[13] = 0xF0; // min_spatial_segmentation_idc = 0
    record[14] = 0xFC; // parallelismType = 0
    record[15] = 0xFC; // chromaFormat = 0 (4:2:0)
    record[16] = 0xF8; // bitDepthLumaMinus8 = 0
    record[17] = 0xF8; // bitDepthChromaMinus8 = 0
    record[18] = 0;    // avgFrameRate high
    record[19] = 0;    // avgFrameRate low
    record[20] = 0x03; // lengthSizeMinusOne = 3, temporal id nested
    record[21] = 3;    // numOfArrays: VPS, SPS, PPS
    size_t cursor = 22;
    for (int arrayIndex = 0; arrayIndex < 3; arrayIndex++) {
        record[cursor++] = 0x80 | (uint8_t)setTypes[arrayIndex];
        record[cursor++] = 0;
        record[cursor++] = 1;
        record[cursor++] = (uint8_t)((setSizes[arrayIndex] >> 8) & 0xff);
        record[cursor++] = (uint8_t)(setSizes[arrayIndex] & 0xff);
        memcpy(record + cursor, sets[arrayIndex], setSizes[arrayIndex]);
        cursor += setSizes[arrayIndex];
    }
    CFDataRef data = CFDataCreate(kCFAllocatorDefault, record, cursor);
    free(record);
    return data;
}

static CFDictionaryRef VCAMDecoderSpecificationCreate(CMVideoCodecType codecType,
                                                      CFDataRef record) {
    CFMutableDictionaryRef atoms = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 1, &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    if (atoms == NULL) return NULL;
    CFDictionarySetValue(atoms,
                         codecType == kCMVideoCodecType_HEVC ? CFSTR("hvcC")
                                                              : CFSTR("avcC"),
                         record);
    CFMutableDictionaryRef specification = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 2, &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    if (specification == NULL) {
        CFRelease(atoms);
        return NULL;
    }
    CFDictionarySetValue(specification,
                         kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms,
                         atoms);
    CFStringRef hardwareKey =
        codecType == kCMVideoCodecType_HEVC
            ? kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder
            : kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder;
    CFDictionarySetValue(specification, hardwareKey, kCFBooleanTrue);
    CFRelease(atoms);
    return specification;
}

static CFDictionaryRef VCAMHardwareOnlyDecoderSpecificationCreate(
    CMVideoCodecType codecType) {
    CFMutableDictionaryRef specification = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 1, &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    if (specification == NULL) return NULL;
    CFStringRef hardwareKey =
        codecType == kCMVideoCodecType_HEVC
            ? kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder
            : kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder;
    CFDictionarySetValue(specification, hardwareKey, kCFBooleanTrue);
    return specification;
}

static OSStatus VCAMCreateVideoFormatDescription(
    BOOL hevc,
    const uint8_t *const spsPointers[], const size_t spsSizes[], int spsCount,
    const uint8_t *const ppsPointers[], const size_t ppsSizes[], int ppsCount,
    const uint8_t *const vpsPointers[], const size_t vpsSizes[], int vpsCount,
    int nalHeaderLength,
    int width,
    int height,
    CFDictionaryRef *decoderSpecificationOut,
    CMVideoFormatDescriptionRef *formatDescriptionOut) {
    if (formatDescriptionOut == NULL || decoderSpecificationOut == NULL ||
        spsCount <= 0 || ppsCount <= 0) {
        return -1;
    }
    *formatDescriptionOut = NULL;
    *decoderSpecificationOut = NULL;
    const uint8_t *parameterSets[64] = {0};
    size_t parameterSetSizes[64] = {0};
    int parameterSetCount = 0;
    if (hevc) {
        for (int i = 0; i < vpsCount && parameterSetCount < 64; i++) {
            parameterSets[parameterSetCount] = vpsPointers[i];
            parameterSetSizes[parameterSetCount] = vpsSizes[i];
            parameterSetCount += 1;
        }
    }
    for (int i = 0; i < spsCount && parameterSetCount < 64; i++) {
        parameterSets[parameterSetCount] = spsPointers[i];
        parameterSetSizes[parameterSetCount] = spsSizes[i];
        parameterSetCount += 1;
    }
    for (int i = 0; i < ppsCount && parameterSetCount < 64; i++) {
        parameterSets[parameterSetCount] = ppsPointers[i];
        parameterSetSizes[parameterSetCount] = ppsSizes[i];
        parameterSetCount += 1;
    }
    if (parameterSetCount == 0) return -1;

    // Apple's canonical format-description construction is the reliable path
    // for hardware H.264/HEVC on iOS. The avcC/hvcC SampleDescriptionExtension
    // route is kept only as a fallback.
    OSStatus status = hevc
        ? CMVideoFormatDescriptionCreateFromHEVCParameterSets(
              kCFAllocatorDefault, (size_t)parameterSetCount,
              parameterSets, parameterSetSizes,
              nalHeaderLength, NULL, formatDescriptionOut)
        : CMVideoFormatDescriptionCreateFromH264ParameterSets(
              kCFAllocatorDefault, (size_t)parameterSetCount,
              parameterSets, parameterSetSizes,
              nalHeaderLength, formatDescriptionOut);
    if (status == noErr && *formatDescriptionOut != NULL) {
        *decoderSpecificationOut = VCAMHardwareOnlyDecoderSpecificationCreate(
            hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264);
        return noErr;
    }
    if (*formatDescriptionOut != NULL) {
        CFRelease(*formatDescriptionOut);
        *formatDescriptionOut = NULL;
    }

    CFDataRef record = NULL;
    if (hevc) {
        record = VCAMBuildHVCCRecord(vpsPointers, vpsSizes, vpsCount,
                                     spsPointers, spsSizes, spsCount,
                                     ppsPointers, ppsSizes, ppsCount);
    } else {
        record = VCAMBuildAVCCRecord(spsPointers, spsSizes, spsCount,
                                     ppsPointers, ppsSizes, ppsCount);
    }
    if (record == NULL) return status;
    CFDictionaryRef specification = VCAMDecoderSpecificationCreate(
        hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264, record);
    CFRelease(record);
    if (specification == NULL) return status;
    status = CMVideoFormatDescriptionCreate(
        kCFAllocatorDefault,
        hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
        width, height, specification, formatDescriptionOut);
    if (status == noErr && *formatDescriptionOut != NULL) {
        *decoderSpecificationOut = specification;
        return noErr;
    }
    CFRelease(specification);
    if (*formatDescriptionOut != NULL) {
        CFRelease(*formatDescriptionOut);
        *formatDescriptionOut = NULL;
    }
    return status;
}

static BOOL VCAMCollectH264AnnexBParameterSets(
    const uint8_t *extra, size_t extraSize,
    const uint8_t *spsPointers[32], size_t spsSizes[32], int *spsCountOut,
    const uint8_t *ppsPointers[32], size_t ppsSizes[32], int *ppsCountOut) {
    int spsCount = 0;
    int ppsCount = 0;
    size_t scan = 0;
    while (scan + 4 <= extraSize) {
        size_t startCodeLength = 0;
        if (!VCAMIsAnnexBStartCode(extra, extraSize, scan, &startCodeLength)) {
            scan += 1;
            continue;
        }
        size_t payloadStart = scan + startCodeLength;
        if (payloadStart >= extraSize) break;
        int nalType = extra[payloadStart] & 0x1F;
        size_t next = payloadStart + 1;
        while (next < extraSize && !VCAMIsAnnexBStartCode(extra, extraSize, next, NULL)) {
            next += 1;
        }
        size_t payloadEnd = VCAMTrimAnnexBTrailingZeroBytes(
            extra, payloadStart, next);
        if (nalType == 7 && spsCount < 32) {
            spsPointers[spsCount] = extra + payloadStart;
            spsSizes[spsCount] = payloadEnd - payloadStart;
            spsCount += 1;
        } else if (nalType == 8 && ppsCount < 32) {
            ppsPointers[ppsCount] = extra + payloadStart;
            ppsSizes[ppsCount] = payloadEnd - payloadStart;
            ppsCount += 1;
        }
        scan = next;
    }
    if (spsCountOut != NULL) *spsCountOut = spsCount;
    if (ppsCountOut != NULL) *ppsCountOut = ppsCount;
    return spsCount > 0 && ppsCount > 0;
}

static BOOL VCAMCollectHEVCAnnexBParameterSets(
    const uint8_t *extra, size_t extraSize,
    const uint8_t *vpsPointers[16], size_t vpsSizes[16], int *vpsCountOut,
    const uint8_t *spsPointers[32], size_t spsSizes[32], int *spsCountOut,
    const uint8_t *ppsPointers[32], size_t ppsSizes[32], int *ppsCountOut) {
    int vpsCount = 0;
    int spsCount = 0;
    int ppsCount = 0;
    size_t scan = 0;
    while (scan + 4 <= extraSize) {
        size_t startCodeLength = 0;
        if (!VCAMIsAnnexBStartCode(extra, extraSize, scan, &startCodeLength)) {
            scan += 1;
            continue;
        }
        size_t payloadStart = scan + startCodeLength;
        if (payloadStart >= extraSize) break;
        int nalType = (extra[payloadStart] >> 1) & 0x3F;
        size_t next = payloadStart + 1;
        while (next < extraSize && !VCAMIsAnnexBStartCode(extra, extraSize, next, NULL)) {
            next += 1;
        }
        size_t payloadEnd = VCAMTrimAnnexBTrailingZeroBytes(
            extra, payloadStart, next);
        if (nalType == 32 && vpsCount < 16) {
            vpsPointers[vpsCount] = extra + payloadStart;
            vpsSizes[vpsCount] = payloadEnd - payloadStart;
            vpsCount += 1;
        } else if (nalType == 33 && spsCount < 32) {
            spsPointers[spsCount] = extra + payloadStart;
            spsSizes[spsCount] = payloadEnd - payloadStart;
            spsCount += 1;
        } else if (nalType == 34 && ppsCount < 32) {
            ppsPointers[ppsCount] = extra + payloadStart;
            ppsSizes[ppsCount] = payloadEnd - payloadStart;
            ppsCount += 1;
        }
        scan = next;
    }
    if (vpsCountOut != NULL) *vpsCountOut = vpsCount;
    if (spsCountOut != NULL) *spsCountOut = spsCount;
    if (ppsCountOut != NULL) *ppsCountOut = ppsCount;
    return spsCount > 0 && ppsCount > 0;
}

typedef struct {
    CVPixelBufferRef buffer;
    CMTime presentationTime;
} VCAMHardwareFrame;

@interface VCAMHardwareVideoDecoder () {
    CMVideoFormatDescriptionRef _formatDescription;
    CFDictionaryRef _decoderSpecification;
    VTDecompressionSessionRef _session;
    VCAMHardwareFrame _frames[VCAMHardwareMaxFrames];
    NSInteger _frameCount;
    BOOL _active;
    BOOL _isHEVC;
    int _width;
    int _height;
}
@end

@implementation VCAMHardwareVideoDecoder

static void VCAMHardwareDecoderCallback(void *refcon,
                                        void *sourceFrameRefCon,
                                        OSStatus status,
                                        VTDecodeInfoFlags infoFlags,
                                        CVImageBufferRef imageBuffer,
                                        CMTime presentationTimeStamp,
                                        CMTime presentationDuration) {
    (void)sourceFrameRefCon;
    (void)presentationDuration;
    VCAMHardwareVideoDecoder *decoder = (__bridge VCAMHardwareVideoDecoder *)refcon;
    static volatile int callbackEntry = 0;
    int entry = __sync_add_and_fetch(&callbackEntry, 1);
    if (entry <= 3) {
        fprintf(stderr, "vcam VT callback ENTRY count=%d status=%d image=%d\n",
                entry, (int)status, imageBuffer != NULL);
        fflush(stderr);
    }
    if (status != noErr) {
        // A missing reference frame is recoverable: the decoder will produce
        // output again once the next keyframe arrives. Treat it as noise
        // instead of a session failure (mirrors FFmpeg's videotoolbox path).
        if (status == kVTVideoDecoderReferenceMissingErr) {
            static volatile int referenceMissingCount = 0;
            int count = __sync_add_and_fetch(&referenceMissingCount, 1);
            if (count <= 4) {
                [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
                    @"[DEBUG-vtpack] reference frame missing count=%d status=%d flags=%u",
                    count, (int)status, (unsigned)infoFlags]];
            }
            return;
        }
        static volatile int callbackFailures = 0;
        int failureCount = __sync_add_and_fetch(&callbackFailures, 1);
        if (failureCount <= 4) {
            [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
                @"[DEBUG-vtpack] callback failed status=%d flags=%u image=%d",
                (int)status, (unsigned)infoFlags, imageBuffer != NULL]];
        }
        return;
    }
    if (imageBuffer == NULL || decoder == nil) {
        static volatile int nullImageCount = 0;
        int count = __sync_add_and_fetch(&nullImageCount, 1);
        if (count <= 4) {
            fprintf(stderr, "vcam VT callback status=0 but imageBuffer=NULL count=%d\n", count);
            fflush(stderr);
        }
        return;
    }
    static volatile int outputFrames = 0;
    int outputCount = __sync_add_and_fetch(&outputFrames, 1);
    if (outputCount <= 5) {
        [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
            @"[DEBUG-vtpack] output frame count=%d size=%zux%zu flags=%u",
            outputCount, (size_t)CVPixelBufferGetWidth(imageBuffer),
            (size_t)CVPixelBufferGetHeight(imageBuffer), (unsigned)infoFlags]];
    }
    CVPixelBufferRef retained = CVPixelBufferRetain(imageBuffer);
    @synchronized (decoder) {
        if (decoder->_frameCount < VCAMHardwareMaxFrames) {
            decoder->_frames[decoder->_frameCount].buffer = retained;
            decoder->_frames[decoder->_frameCount].presentationTime = presentationTimeStamp;
            decoder->_frameCount += 1;
        } else {
            CVPixelBufferRelease(retained);
        }
    }
}

- (void)dealloc {
    [self stop];
}

- (nullable instancetype)initWithCodecParameters:(AVCodecParameters *)parameters {
    self = [super init];
    if (self == nil) return nil;
    if (parameters == NULL || parameters->extradata == NULL ||
        parameters->extradata_size <= 0 ||
        (parameters->codec_id != AV_CODEC_ID_H264 &&
         parameters->codec_id != AV_CODEC_ID_HEVC)) {
        return nil;
    }
    if (parameters->width <= 0 || parameters->height <= 0) return nil;

    const uint8_t *extra = parameters->extradata;
    int extraSize = parameters->extradata_size;
    OSStatus status = noErr;
    _isHEVC = parameters->codec_id == AV_CODEC_ID_HEVC;
    _width = parameters->width;
    _height = parameters->height;
    if (parameters->codec_id == AV_CODEC_ID_H264) {
        BOOL annexB = extraSize >= 4 &&
            VCAMIsAnnexBStartCode(extra, (size_t)extraSize, 0, NULL);
        if (annexB) {
            // Some RTSP servers advertise SPS/PPS in the SDP as Annex B
            // parameter sets (00 00 00 01 67...) instead of an avcC record.
            const uint8_t *spsPointers[32] = {0};
            size_t spsSizes[32] = {0};
            const uint8_t *ppsPointers[32] = {0};
            size_t ppsSizes[32] = {0};
            int spsCount = 0;
            int ppsCount = 0;
            if (!VCAMCollectH264AnnexBParameterSets(
                    extra, (size_t)extraSize,
                    spsPointers, spsSizes, &spsCount,
                    ppsPointers, ppsSizes, &ppsCount)) {
                return nil;
            }
            status = VCAMCreateVideoFormatDescription(
                NO,
                spsPointers, spsSizes, spsCount,
                ppsPointers, ppsSizes, ppsCount,
                NULL, NULL, 0,
                4, _width, _height,
                &_decoderSpecification, &_formatDescription);
            NSString *annexBLine = [NSString stringWithFormat:
                @"[DEBUG-vtpack] H264 annexB psets sps=%d pps=%d status=%d nal=4 sizes=%zu,%zu",
                spsCount, ppsCount, (int)status, spsSizes[0], ppsSizes[0]];
            fprintf(stderr, "vcam %s\n", annexBLine.UTF8String);
            fflush(stderr);
            [VCAMConfiguration appendProcessLog:annexBLine];
        } else {
        if (extraSize < 7) return nil;
        int nalHeaderLength = (extra[4] & 0x03) + 1;
        int offset = 6;
        int numSPS = extra[5] & 0x1F;
        const uint8_t *spsPointers[32] = {0};
        size_t spsSizes[32] = {0};
        int spsCount = 0;
        for (int i = 0; i < numSPS && offset + 2 <= extraSize && spsCount < 32; i++) {
            int length = (extra[offset] << 8) | extra[offset + 1];
            offset += 2;
            if (length <= 0 || offset + length > extraSize) return nil;
            spsPointers[spsCount] = extra + offset;
            spsSizes[spsCount] = (size_t)length;
            spsCount += 1;
            offset += length;
        }
        if (spsCount == 0 || offset >= extraSize) return nil;
        int numPPS = extra[offset++];
        const uint8_t *ppsPointers[32] = {0};
        size_t ppsSizes[32] = {0};
        int ppsCount = 0;
        for (int i = 0; i < numPPS && offset + 2 <= extraSize && ppsCount < 32; i++) {
            int length = (extra[offset] << 8) | extra[offset + 1];
            offset += 2;
            if (length <= 0 || offset + length > extraSize) return nil;
            ppsPointers[ppsCount] = extra + offset;
            ppsSizes[ppsCount] = (size_t)length;
            ppsCount += 1;
            offset += length;
        }
        if (ppsCount == 0) return nil;
        status = VCAMCreateVideoFormatDescription(
            NO,
            spsPointers, spsSizes, spsCount,
            ppsPointers, ppsSizes, ppsCount,
            NULL, NULL, 0,
            nalHeaderLength, _width, _height,
            &_decoderSpecification, &_formatDescription);
        [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
            @"[DEBUG-vtpack] H264 avcC psets sps=%d pps=%d status=%d nal=%d",
            spsCount, ppsCount, (int)status, nalHeaderLength]];
        }
    } else {
        BOOL annexB = extraSize >= 4 &&
            VCAMIsAnnexBStartCode(extra, (size_t)extraSize, 0, NULL);
        if (annexB) {
            // In-band/Annex B VPS+SPS+PPS parameter sets (e.g. from RTSP SDP).
            const uint8_t *vpsPointers[16] = {0};
            size_t vpsSizes[16] = {0};
            const uint8_t *spsPointers[32] = {0};
            size_t spsSizes[32] = {0};
            const uint8_t *ppsPointers[32] = {0};
            size_t ppsSizes[32] = {0};
            int vpsCount = 0, spsCount = 0, ppsCount = 0;
            if (!VCAMCollectHEVCAnnexBParameterSets(
                    extra, (size_t)extraSize,
                    vpsPointers, vpsSizes, &vpsCount,
                    spsPointers, spsSizes, &spsCount,
                    ppsPointers, ppsSizes, &ppsCount)) {
                return nil;
            }
            status = VCAMCreateVideoFormatDescription(
                YES,
                spsPointers, spsSizes, spsCount,
                ppsPointers, ppsSizes, ppsCount,
                vpsPointers, vpsSizes, vpsCount,
                4, _width, _height,
                &_decoderSpecification, &_formatDescription);
            [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
                @"[DEBUG-vtpack] HEVC annexB psets vps=%d sps=%d pps=%d status=%d nal=4",
                vpsCount, spsCount, ppsCount, (int)status]];
        } else {
        // ISO/IEC 14496-15 HEVCDecoderConfigurationRecord
        if (extraSize < 23) return nil;
        int nalHeaderLength = (extra[21] & 0x03) + 1;
        int offset = 22;
        if (offset >= extraSize) return nil;
        int numArrays = extra[offset++];
        const uint8_t *vpsPointers[16] = {0};
        size_t vpsSizes[16] = {0};
        const uint8_t *spsPointers[32] = {0};
        size_t spsSizes[32] = {0};
        const uint8_t *ppsPointers[32] = {0};
        size_t ppsSizes[32] = {0};
        int vpsCount = 0, spsCount = 0, ppsCount = 0;
        for (int i = 0; i < numArrays && offset < extraSize; i++) {
            int byte = extra[offset++];
            int nalType = byte & 0x3F;
            if (offset + 2 > extraSize) return nil;
            int numNalus = (extra[offset] << 8) | extra[offset + 1];
            offset += 2;
            for (int n = 0; n < numNalus && offset + 2 <= extraSize; n++) {
                int length = (extra[offset] << 8) | extra[offset + 1];
                offset += 2;
                if (length <= 0 || offset + length > extraSize) return nil;
                if (nalType == 32 && vpsCount < 16) {
                    vpsPointers[vpsCount] = extra + offset;
                    vpsSizes[vpsCount] = (size_t)length;
                    vpsCount += 1;
                } else if (nalType == 33 && spsCount < 32) {
                    spsPointers[spsCount] = extra + offset;
                    spsSizes[spsCount] = (size_t)length;
                    spsCount += 1;
                } else if (nalType == 34 && ppsCount < 32) {
                    ppsPointers[ppsCount] = extra + offset;
                    ppsSizes[ppsCount] = (size_t)length;
                    ppsCount += 1;
                }
                offset += length;
            }
        }
        if (spsCount == 0 || ppsCount == 0) return nil;
        status = VCAMCreateVideoFormatDescription(
            YES,
            spsPointers, spsSizes, spsCount,
            ppsPointers, ppsSizes, ppsCount,
            vpsPointers, vpsSizes, vpsCount,
            nalHeaderLength, _width, _height,
            &_decoderSpecification, &_formatDescription);
        [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
            @"[DEBUG-vtpack] HEVC hvcC psets vps=%d sps=%d pps=%d status=%d nal=%d",
            vpsCount, spsCount, ppsCount, (int)status, nalHeaderLength]];
        }
    }
    if (status != noErr || _formatDescription == NULL) return nil;
    return self;
}

- (BOOL)start:(NSError **)error {
    if (_active) return YES;
    NSDictionary *destinationAttributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
    };
    VTDecompressionOutputCallbackRecord callback = {
        .decompressionOutputCallback = VCAMHardwareDecoderCallback,
        .decompressionOutputRefCon = (__bridge void *)self,
    };
    OSStatus status = VTDecompressionSessionCreate(
        kCFAllocatorDefault,
        _formatDescription,
        NULL,
        (__bridge CFDictionaryRef)destinationAttributes,
        &callback,
        &_session);
    fprintf(stderr, "vcam VTDecompressionSessionCreate status=%d fmt=%p session=%p\n",
            (int)status, (void *)_formatDescription, (void *)_session);
    fflush(stderr);
    if (status != noErr) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"VCAMHardwareVideoDecoder" code:1
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         [NSString stringWithFormat:@"VTDecompressionSessionCreate failed %d", (int)status]}];
        }
        return NO;
    }
    _active = YES;
    return YES;
}

- (BOOL)decodePacket:(const uint8_t *)bytes
               length:(size_t)length
       presentationTime:(CMTime)presentationTime
             decodeTime:(CMTime)decodeTime
               duration:(CMTime)duration
             isKeyFrame:(BOOL)isKeyFrame {
    if (!_active || _session == NULL || bytes == NULL || length == 0) return NO;
    size_t feedLength = length;
    const uint8_t *feedBytes = bytes;
    uint8_t *filtered = NULL;
    BOOL stripped = NO;
    BOOL annexB = VCAMIsAnnexBStartCode(bytes, length, 0, NULL);
    filtered = VCAMFilterParameterSetNALs(bytes, length, &feedLength, _isHEVC, &stripped);
    if (filtered != NULL) {
        feedBytes = filtered;
    } else if (feedLength == 0) {
        // Parameter-set-only packet (SPS/PPS arrive separately on RTP). The
        // format description already carries them; nothing to decode.
        return YES;
    } else if (annexB) {
        static volatile int annexBFailures = 0;
        int failureCount = __sync_add_and_fetch(&annexBFailures, 1);
        if (failureCount <= 4) {
            NSLog(@"VCAMHardwareVideoDecoder annexB conversion failed length=%zu", length);
        }
        return NO;
    }
    if (stripped) {
        static volatile int strippedCount = 0;
        int count = __sync_add_and_fetch(&strippedCount, 1);
        if (count <= 4) {
            [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
                @"[DEBUG-vtpack] stripped param/SEI NALs input=%zu output=%zu",
                length, feedLength]];
        }
    }
    // Let the block buffer allocate and own the memory (the 0.8.10 pattern
    // that produced frames on device), then copy the packet in. The sample
    // retains the block buffer, so the memory stays valid for async decode.
    CMBlockBufferRef blockBuffer = NULL;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(
        kCFAllocatorDefault,
        NULL,
        feedLength,
        kCFAllocatorDefault,
        NULL,
        0,
        feedLength,
        0,
        &blockBuffer);
    if (status != kCMBlockBufferNoErr) {
        free(filtered);
        return NO;
    }
    status = CMBlockBufferReplaceDataBytes(feedBytes, blockBuffer, 0, feedLength);
    if (status != kCMBlockBufferNoErr) {
        CFRelease(blockBuffer);
        free(filtered);
        return NO;
    }
    CMSampleTimingInfo timing = {
        .duration = duration,
        .presentationTimeStamp = presentationTime,
        .decodeTimeStamp = decodeTime,
    };
    size_t sizeArray[1] = {feedLength};
    CMSampleBufferRef sampleBuffer = NULL;
    status = CMSampleBufferCreate(
        kCFAllocatorDefault,
        blockBuffer,
        true,
        NULL,
        NULL,
        _formatDescription,
        1,
        1,
        &timing,
        1,
        sizeArray,
        &sampleBuffer);
    CFRelease(blockBuffer);
    if (status != noErr || sampleBuffer == NULL) {
        free(filtered);
        return NO;
    }
    // VideoToolbox relies on the per-sample sync/dependency markers to treat
    // an IDR as a reference-free sync point, especially when the sample
    // starts with SEI NALs instead of the slice itself. Without the markers
    // the first IDR can be rejected with kVTVideoDecoderReferenceMissingErr
    // (-12780) even though DecodeFrame accepts the sample.
    CFArrayRef sampleAttachmentsArray =
        CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, true);
    if (sampleAttachmentsArray != NULL &&
        CFArrayGetCount(sampleAttachmentsArray) > 0) {
        CFMutableDictionaryRef sampleAttachment =
            (CFMutableDictionaryRef)CFArrayGetValueAtIndex(
                sampleAttachmentsArray, 0);
        if (sampleAttachment != NULL) {
            CFDictionarySetValue(sampleAttachment,
                                 kCMSampleAttachmentKey_NotSync,
                                 isKeyFrame ? kCFBooleanFalse
                                            : kCFBooleanTrue);
            CFDictionarySetValue(sampleAttachment,
                                 kCMSampleAttachmentKey_DependsOnOthers,
                                 isKeyFrame ? kCFBooleanFalse
                                            : kCFBooleanTrue);
        }
    }
    static volatile int packetDiagnostics = 0;
    int packetDiagnostic = __sync_add_and_fetch(&packetDiagnostics, 1);
    int firstNAL = feedLength >= 5 ? (_isHEVC ? ((feedBytes[4] >> 1) & 0x3f)
                                             : (feedBytes[4] & 0x1f)) : -1;
    int secondNAL = -1;
    int thirdNAL = -1;
    if (feedLength >= 10) {
        size_t offset = 4;
        size_t firstSize =
            ((size_t)feedBytes[0] << 24) | ((size_t)feedBytes[1] << 16) |
            ((size_t)feedBytes[2] << 8) | (size_t)feedBytes[3];
        if (firstSize > 0 && offset + 4 + firstSize <= feedLength) {
            offset += 4 + firstSize;
            secondNAL = _isHEVC ? ((feedBytes[offset] >> 1) & 0x3f)
                                : (feedBytes[offset] & 0x1f);
            if (offset + 4 + 1 <= feedLength) {
                size_t secondSize =
                    ((size_t)feedBytes[offset - 4] << 24) |
                    ((size_t)feedBytes[offset - 3] << 16) |
                    ((size_t)feedBytes[offset - 2] << 8) |
                    (size_t)feedBytes[offset - 1];
                if (secondSize > 0 &&
                    offset + 4 + secondSize <= feedLength) {
                    thirdNAL = _isHEVC
                        ? ((feedBytes[offset + 4 + secondSize] >> 1) & 0x3f)
                        : (feedBytes[offset + 4 + secondSize] & 0x1f);
                }
            }
        }
    }
    if (packetDiagnostic <= 4) {
        NSString *packetLine = [NSString stringWithFormat:
            @"[DEBUG-vtpack] packet count=%d key=%d annexB=%d stripped=%d input=%zu output=%zu nals=%d,%d,%d sampleStatus=%d pts=%lld/%d dts=%lld/%d",
            packetDiagnostic, isKeyFrame, annexB, stripped, length, feedLength,
            firstNAL, secondNAL, thirdNAL, (int)status,
            presentationTime.value, presentationTime.timescale,
            decodeTime.value, decodeTime.timescale];
        fprintf(stderr, "vcam %s\n", packetLine.UTF8String);
        fflush(stderr);
        [VCAMConfiguration appendProcessLog:packetLine];
    }
    VTDecodeInfoFlags decodeFlags = 0;
    status = VTDecompressionSessionDecodeFrame(
        _session, sampleBuffer, 0, NULL, &decodeFlags);
    if (status == noErr) {
        // The frame is delivered asynchronously to VCAMHardwareDecoderCallback
        // on VT's own thread. Wait for it before draining the frame queue,
        // otherwise copyNextOutputFrame runs before the callback and returns
        // nothing (which made direct-VT look like it produced no frames).
        status = VTDecompressionSessionWaitForAsynchronousFrames(_session);
    }
    if (packetDiagnostic <= 4 || status != noErr) {
        fprintf(stderr, "vcam [DEBUG-vtpack] decode count=%d status=%d flags=%u\n",
                packetDiagnostic, (int)status, (unsigned)decodeFlags);
        fflush(stderr);
        [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
            @"[DEBUG-vtpack] decode count=%d status=%d flags=%u",
            packetDiagnostic, (int)status, (unsigned)decodeFlags]];
    }
    if (status != noErr) {
        if (status != kVTVideoDecoderReferenceMissingErr) {
            static volatile int decodeFailures = 0;
            int failureCount = __sync_add_and_fetch(&decodeFailures, 1);
            if (failureCount <= 4) {
                fprintf(stderr, "vcam VCAMHardwareVideoDecoder decode failed status=%d\n", (int)status);
                fflush(stderr);
                NSLog(@"VCAMHardwareVideoDecoder decode failed status=%d", (int)status);
            }
        }
    }
    CFRelease(sampleBuffer);
    free(filtered);
    return status == noErr || status == kVTVideoDecoderReferenceMissingErr;
}

- (nullable CVPixelBufferRef)copyNextOutputFrame:(CMTime *)presentationTimeOut {
    CVPixelBufferRef buffer = NULL;
    CMTime pts = kCMTimeInvalid;
    @synchronized (self) {
        if (_frameCount > 0) {
            buffer = _frames[0].buffer;
            pts = _frames[0].presentationTime;
            for (NSInteger i = 1; i < _frameCount; i++) {
                _frames[i - 1] = _frames[i];
            }
            _frameCount -= 1;
        }
    }
    if (presentationTimeOut != NULL) *presentationTimeOut = pts;
    return buffer;
}

- (void)flush {
    @synchronized (self) {
        for (NSInteger i = 0; i < _frameCount; i++) {
            if (_frames[i].buffer != NULL) CVPixelBufferRelease(_frames[i].buffer);
            _frames[i].buffer = NULL;
        }
        _frameCount = 0;
    }
    if (_session != NULL) {
        VTDecompressionSessionFinishDelayedFrames(_session);
        VTDecompressionSessionWaitForAsynchronousFrames(_session);
    }
}

- (void)stop {
    if (_session != NULL) {
        VTDecompressionSessionInvalidate(_session);
        CFRelease(_session);
        _session = NULL;
    }
    if (_decoderSpecification != NULL) {
        CFRelease(_decoderSpecification);
        _decoderSpecification = NULL;
    }
    if (_formatDescription != NULL) {
        CFRelease(_formatDescription);
        _formatDescription = NULL;
    }
    [self flush];
    _active = NO;
}

@end

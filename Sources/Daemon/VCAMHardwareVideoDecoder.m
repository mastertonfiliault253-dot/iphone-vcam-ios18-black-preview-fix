#import "VCAMHardwareVideoDecoder.h"

#import <VideoToolbox/VideoToolbox.h>

#include <libavcodec/avcodec.h>
#include <string.h>

#ifndef kVTVideoDecoderReferenceMissingErr
#define kVTVideoDecoderReferenceMissingErr -12780
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

// FFmpeg normally hands MOV/MP4 samples to us already length-prefixed. Some
// containers/remuxers instead deliver Annex B start codes, which VideoToolbox
// rejects with kVTVideoDecoderReferenceMissingErr because it cannot frame the
// NAL units. Convert defensively so both layouts decode on the hardware path.
static uint8_t *VCAMConvertAnnexBToLengthPrefixed(const uint8_t *bytes,
                                                  size_t length,
                                                  size_t *outLength) {
    if (outLength == NULL || length < 4 ||
        !VCAMIsAnnexBStartCode(bytes, length, 0, NULL)) return NULL;
    size_t payloadStarts[512] = {0};
    size_t nalCount = 0;
    size_t scan = 0;
    size_t total = 0;
    while (scan < length && nalCount < 512) {
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
        while (next < length && !VCAMIsAnnexBStartCode(bytes, length, next, NULL)) {
            next += 1;
        }
        payloadStarts[nalCount++] = payloadStart;
        total += (next - payloadStart) + 4;
        scan = next;
    }
    if (nalCount == 0 || total == 0) return NULL;
    uint8_t *output = malloc(total);
    if (output == NULL) return NULL;
    size_t cursor = 0;
    size_t index = 0;
    scan = 0;
    while (scan < length && index < nalCount) {
        size_t startCodeLength = 0;
        if (!VCAMIsAnnexBStartCode(bytes, length, scan, &startCodeLength)) {
            scan += 1;
            continue;
        }
        size_t payloadStart = scan + startCodeLength;
        size_t next = payloadStart;
        while (next < length && !VCAMIsAnnexBStartCode(bytes, length, next, NULL)) {
            next += 1;
        }
        size_t payloadLength = next - payloadStart;
        output[cursor] = (uint8_t)((payloadLength >> 24) & 0xff);
        output[cursor + 1] = (uint8_t)((payloadLength >> 16) & 0xff);
        output[cursor + 2] = (uint8_t)((payloadLength >> 8) & 0xff);
        output[cursor + 3] = (uint8_t)(payloadLength & 0xff);
        memcpy(output + cursor + 4, bytes + payloadStart, payloadLength);
        cursor += payloadLength + 4;
        index += 1;
        scan = next;
    }
    *outLength = cursor;
    return output;
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
        if (nalType == 7 && spsCount < 32) {
            spsPointers[spsCount] = extra + payloadStart;
            spsSizes[spsCount] = next - payloadStart;
            spsCount += 1;
        } else if (nalType == 8 && ppsCount < 32) {
            ppsPointers[ppsCount] = extra + payloadStart;
            ppsSizes[ppsCount] = next - payloadStart;
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
        if (nalType == 32 && vpsCount < 16) {
            vpsPointers[vpsCount] = extra + payloadStart;
            vpsSizes[vpsCount] = next - payloadStart;
            vpsCount += 1;
        } else if (nalType == 33 && spsCount < 32) {
            spsPointers[spsCount] = extra + payloadStart;
            spsSizes[spsCount] = next - payloadStart;
            spsCount += 1;
        } else if (nalType == 34 && ppsCount < 32) {
            ppsPointers[ppsCount] = extra + payloadStart;
            ppsSizes[ppsCount] = next - payloadStart;
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
    VTDecompressionSessionRef _session;
    VCAMHardwareFrame _frames[VCAMHardwareMaxFrames];
    NSInteger _frameCount;
    BOOL _active;
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
    (void)infoFlags;
    (void)sourceFrameRefCon;
    (void)presentationDuration;
    VCAMHardwareVideoDecoder *decoder = (__bridge VCAMHardwareVideoDecoder *)refcon;
    if (status != noErr) {
        // A missing reference frame is recoverable: the decoder will produce
        // output again once the next keyframe arrives. Treat it as noise
        // instead of a session failure (mirrors FFmpeg's videotoolbox path).
        if (status == kVTVideoDecoderReferenceMissingErr) {
            static volatile int referenceMissingCount = 0;
            int count = __sync_add_and_fetch(&referenceMissingCount, 1);
            if (count <= 40 || count % 1000 == 0) {
                NSLog(@"[DEBUG-a4f2] reference frame missing count=%d status=%d", count, (int)status);
            }
            return;
        }
        static volatile int callbackFailures = 0;
        int failureCount = __sync_add_and_fetch(&callbackFailures, 1);
        if (failureCount <= 4) {
            NSLog(@"VCAMHardwareVideoDecoder callback failed status=%d", (int)status);
        }
        return;
    }
    if (imageBuffer == NULL || decoder == nil) return;
    static volatile int deliveredFrames = 0;
    int delivered = __sync_add_and_fetch(&deliveredFrames, 1);
    if (delivered <= 3) {
        NSLog(@"[DEBUG-a4f2] delivered frame count=%d size=%zux%zu",
              delivered, CVPixelBufferGetWidth(imageBuffer),
              CVPixelBufferGetHeight(imageBuffer));
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
            const uint8_t *combined[64] = {0};
            size_t combinedSizes[64] = {0};
            for (int i = 0; i < spsCount; i++) {
                combined[i] = spsPointers[i];
                combinedSizes[i] = spsSizes[i];
            }
            for (int i = 0; i < ppsCount; i++) {
                combined[spsCount + i] = ppsPointers[i];
                combinedSizes[spsCount + i] = ppsSizes[i];
            }
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                kCFAllocatorDefault,
                spsCount + ppsCount,
                (const uint8_t *const *)combined,
                combinedSizes,
                4,
                &_formatDescription);
            NSLog(@"VCAMHardwareVideoDecoder H264 annexB sps=%d pps=%d status=%d",
                  spsCount, ppsCount, (int)status);
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
        const uint8_t *combined[64] = {0};
        size_t combinedSizes[64] = {0};
        for (int i = 0; i < spsCount; i++) { combined[i] = spsPointers[i]; combinedSizes[i] = spsSizes[i]; }
        for (int i = 0; i < ppsCount; i++) { combined[spsCount + i] = ppsPointers[i]; combinedSizes[spsCount + i] = ppsSizes[i]; }
        status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            kCFAllocatorDefault,
            spsCount + ppsCount,
            (const uint8_t *const *)combined,
            combinedSizes,
            (size_t)nalHeaderLength,
            &_formatDescription);
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
            const uint8_t *all[64] = {0};
            size_t allSizes[64] = {0};
            int total = 0;
            for (int i = 0; i < vpsCount; i++) {
                all[total] = vpsPointers[i];
                allSizes[total] = vpsSizes[i];
                total++;
            }
            for (int i = 0; i < spsCount; i++) {
                all[total] = spsPointers[i];
                allSizes[total] = spsSizes[i];
                total++;
            }
            for (int i = 0; i < ppsCount; i++) {
                all[total] = ppsPointers[i];
                allSizes[total] = ppsSizes[i];
                total++;
            }
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                kCFAllocatorDefault,
                total,
                (const uint8_t *const *)all,
                allSizes,
                4,
                NULL,
                &_formatDescription);
            NSLog(@"VCAMHardwareVideoDecoder HEVC annexB vps=%d sps=%d pps=%d status=%d",
                  vpsCount, spsCount, ppsCount, (int)status);
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
        const uint8_t *all[64] = {0};
        size_t allSizes[64] = {0};
        int total = 0;
        for (int i = 0; i < vpsCount; i++) { all[total] = vpsPointers[i]; allSizes[total] = vpsSizes[i]; total++; }
        for (int i = 0; i < spsCount; i++) { all[total] = spsPointers[i]; allSizes[total] = spsSizes[i]; total++; }
        for (int i = 0; i < ppsCount; i++) { all[total] = ppsPointers[i]; allSizes[total] = ppsSizes[i]; total++; }
        status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
            kCFAllocatorDefault,
            total,
            (const uint8_t *const *)all,
            allSizes,
            (size_t)nalHeaderLength,
            NULL,
            &_formatDescription);
        NSLog(@"VCAMHardwareVideoDecoder HEVC nalu=%d vps=%d sps=%d pps=%d status=%d",
              nalHeaderLength, vpsCount, spsCount, ppsCount, (int)status);
        }
    }
    if (status != noErr || _formatDescription == NULL) return nil;
    return self;
}

- (BOOL)start:(NSError **)error {
    if (_active) return YES;
    // kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder is
    // only declared iOS 17+, while the package targets iOS 15. The key's
    // documented CFString value is stable; hardware decode is the default on
    // iOS 16 anyway, so this is an explicit preference rather than a gate.
    static NSString *const hardwareAcceleratedDecoderKey =
        @"EnableHardwareAcceleratedVideoDecoder";
    NSDictionary *decoderSpecification = @{
        hardwareAcceleratedDecoderKey: @YES,
    };
    NSDictionary *destinationAttributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (id)kCVPixelBufferOpenGLCompatibilityKey: @YES,
    };
    VTDecompressionOutputCallbackRecord callback = {
        .decompressionOutputCallback = VCAMHardwareDecoderCallback,
        .decompressionOutputRefCon = (__bridge void *)self,
    };
    OSStatus status = VTDecompressionSessionCreate(
        kCFAllocatorDefault,
        _formatDescription,
        (__bridge CFDictionaryRef)decoderSpecification,
        (__bridge CFDictionaryRef)destinationAttributes,
        &callback,
        &_session);
    if (status != noErr) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"VCAMHardwareVideoDecoder" code:1
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         [NSString stringWithFormat:@"VTDecompressionSessionCreate failed %d", (int)status]}];
        }
        return NO;
    }
    VTSessionSetProperty(_session, kVTDecompressionPropertyKey_RealTime, kCFBooleanTrue);
    _active = YES;
    return YES;
}

- (BOOL)decodePacket:(const uint8_t *)bytes
               length:(size_t)length
       presentationTime:(CMTime)presentationTime
             decodeTime:(CMTime)decodeTime
               duration:(CMTime)duration {
    if (!_active || _session == NULL || bytes == NULL || length == 0) return NO;
    static volatile int decodePacketDiag = 0;
    int diagIndex = __sync_add_and_fetch(&decodePacketDiag, 1);
    if (diagIndex <= 6) {
        BOOL annexB = length >= 4 && VCAMIsAnnexBStartCode(bytes, length, 0, NULL);
        NSLog(@"[DEBUG-a4f2] decodePacket idx=%d length=%zu annexB=%d head=%02x%02x%02x%02x%02x%02x%02x%02x",
              diagIndex, length, annexB ? 1 : 0,
              length > 0 ? bytes[0] : 0, length > 1 ? bytes[1] : 0,
              length > 2 ? bytes[2] : 0, length > 3 ? bytes[3] : 0,
              length > 4 ? bytes[4] : 0, length > 5 ? bytes[5] : 0,
              length > 6 ? bytes[6] : 0, length > 7 ? bytes[7] : 0);
    }
    size_t feedLength = length;
    const uint8_t *feedBytes = bytes;
    uint8_t *converted = NULL;
    if (VCAMIsAnnexBStartCode(bytes, length, 0, NULL)) {
        converted = VCAMConvertAnnexBToLengthPrefixed(bytes, length, &feedLength);
        if (converted != NULL) feedBytes = converted;
    }
    if (VCAMIsAnnexBStartCode(bytes, length, 0, NULL) && converted == NULL) {
        static volatile int annexBFailures = 0;
        int failureCount = __sync_add_and_fetch(&annexBFailures, 1);
        if (failureCount <= 4) {
            NSLog(@"[DEBUG-a4f2] annexB conversion failed length=%zu", length);
        }
        return NO;
    }
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
        free(converted);
        return NO;
    }
    status = CMBlockBufferReplaceDataBytes(feedBytes, blockBuffer, 0, feedLength);
    if (status != kCMBlockBufferNoErr) {
        CFRelease(blockBuffer);
        free(converted);
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
        free(converted);
        return NO;
    }
    status = VTDecompressionSessionDecodeFrame(_session, sampleBuffer, 0, NULL, NULL);
    if (diagIndex <= 6) {
        NSLog(@"[DEBUG-a4f2] decodePacket idx=%d decodeStatus=%d", diagIndex, (int)status);
    }
    if (status != noErr) {
        if (status != kVTVideoDecoderReferenceMissingErr) {
            static volatile int decodeFailures = 0;
            int failureCount = __sync_add_and_fetch(&decodeFailures, 1);
            if (failureCount <= 4) {
                NSLog(@"VCAMHardwareVideoDecoder decode failed status=%d", (int)status);
            }
        }
    }
    CFRelease(sampleBuffer);
    free(converted);
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
    if (_formatDescription != NULL) {
        CFRelease(_formatDescription);
        _formatDescription = NULL;
    }
    [self flush];
    _active = NO;
}

@end

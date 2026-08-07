#import "VCAMHardwareVideoDecoder.h"

#import <VideoToolbox/VideoToolbox.h>

#include <libavcodec/avcodec.h>
#include <string.h>

enum { VCAMHardwareMaxFrames = 16 };

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
                                        OSStatus status,
                                        VTDecodeInfoFlags infoFlags,
                                        CVImageBufferRef imageBuffer,
                                        CMTime presentationTimeStamp,
                                        CMTime presentationDuration) {
    (void)infoFlags;
    (void)presentationDuration;
    VCAMHardwareVideoDecoder *decoder = (__bridge VCAMHardwareVideoDecoder *)refcon;
    if (status != noErr || imageBuffer == NULL || decoder == nil) return;
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
    } else {
        // ISO/IEC 14496-15 HEVCDecoderConfigurationRecord
        if (extraSize < 23) return nil;
        int nalHeaderLength = (extra[20] & 0x03) + 1;
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
    }
    if (status != noErr || _formatDescription == NULL) return nil;
    return self;
}

- (BOOL)start:(NSError **)error {
    if (_active) return YES;
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
        NULL,
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
    _active = YES;
    return YES;
}

- (BOOL)decodePacket:(const uint8_t *)bytes
               length:(size_t)length
       presentationTime:(CMTime)presentationTime
             decodeTime:(CMTime)decodeTime
               duration:(CMTime)duration {
    if (!_active || _session == NULL || bytes == NULL || length == 0) return NO;
    uint8_t *copy = malloc(length);
    if (copy == NULL) return NO;
    memcpy(copy, bytes, length);
    CMBlockBufferRef blockBuffer = NULL;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(
        kCFAllocatorDefault,
        copy,
        length,
        kCFAllocatorNull,
        NULL,
        0,
        length,
        0,
        &blockBuffer);
    if (status != kCMBlockBufferNoErr) {
        free(copy);
        return NO;
    }
    CMSampleTimingInfo timing = {
        .duration = duration,
        .presentationTimeStamp = presentationTime,
        .decodeTimeStamp = decodeTime,
    };
    size_t sizeArray[1] = {length};
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
        free(copy);
        return NO;
    }
    status = VTDecompressionSessionDecodeFrame(_session, sampleBuffer, 0, NULL, NULL);
    CFRelease(sampleBuffer);
    free(copy);
    return status == noErr;
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

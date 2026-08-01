#import "VCAMPhotoAuxiliaryData.h"
#import <ImageIO/ImageIO.h>

@interface VCAMPhotoAuxiliaryData ()
@property(nonatomic, strong) VCAMConfiguration *configuration;
@property(nonatomic, strong, nullable) AVDepthData *cachedDepthData;
@property(nonatomic) BOOL attemptedDepthLoad;
@end

@implementation VCAMPhotoAuxiliaryData

- (instancetype)initWithConfiguration:(VCAMConfiguration *)configuration {
    self = [super init];
    if (self) _configuration = configuration;
    return self;
}

- (AVDepthData *)replacementDepthData {
    @synchronized (self) {
        if (self.attemptedDepthLoad) return self.cachedDepthData;
        self.attemptedDepthLoad = YES;
        NSString *path = self.configuration.depthImagePath;
        if (path.length == 0) return nil;
        NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
        if (data == nil) return nil;
        CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
        if (source == NULL) return nil;
        CFDictionaryRef auxiliary = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
            source, 0, kCGImageAuxiliaryDataTypeDisparity);
        if (auxiliary == NULL) {
            auxiliary = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeDepth);
        }
        if (auxiliary != NULL) {
            self.cachedDepthData = [AVDepthData depthDataFromDictionaryRepresentation:(__bridge NSDictionary *)auxiliary
                                                                               error:nil];
            CFRelease(auxiliary);
        }
        CFRelease(source);
        return self.cachedDepthData;
    }
}

- (NSDictionary<NSString *,id> *)metadataByMergingOriginal:(NSDictionary<NSString *,id> *)original {
    if (self.configuration.photoMetadata.count == 0) return original ?: @{};
    NSMutableDictionary *merged = [NSMutableDictionary dictionaryWithDictionary:original ?: @{}];
    [merged addEntriesFromDictionary:self.configuration.photoMetadata];
    return merged;
}

- (NSData *)pairedLivePhotoStillData {
    NSString *path = self.configuration.livePhotoStillPath;
    return path.length == 0 ? nil : [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
}

- (NSString *)pairedLivePhotoMoviePath {
    NSString *path = self.configuration.livePhotoMoviePath;
    return [[NSFileManager defaultManager] fileExistsAtPath:path] ? path : nil;
}

@end

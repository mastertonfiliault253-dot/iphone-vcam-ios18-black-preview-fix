#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <CoreMedia/CoreMedia.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <sys/time.h>
#import <unistd.h>
#import <fcntl.h>
#import <string.h>
#import <time.h>

// This can be a static image or video file
static NSString *VCAMReferenceMediaPath(void) {
    // mediaserverd's sandbox cannot read /var/mobile/Media/VCAM, so prefer a
    // copy under /var/tmp (the daemon's writable scratch space) and fall back
    // to the app-facing shared config, then a tmp media default.
    NSDictionary *config = [NSDictionary dictionaryWithContentsOfFile:@"/var/tmp/com.codex.vcam.plist"];
    NSString *path = config[@"mediaPath"];
    if (![path isKindOfClass:NSString.class] || path.length == 0) {
        config = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Media/VCAM/com.codex.vcam.plist"];
        path = config[@"mediaPath"];
    }
    if ([path isKindOfClass:NSString.class] && path.length > 0) return path;
    return @"/var/tmp/vcam-selected.mov";
}


void VCAMRefLog(const char *message) {
    struct timeval tv = {0};
    gettimeofday(&tv, NULL);
    time_t now = tv.tv_sec;
    struct tm brokenDown = {0};
    localtime_r(&now, &brokenDown);
    char stamp[64] = {0};
    strftime(stamp, sizeof(stamp), "%H:%M:%S", &brokenDown);
    char line[1024] = {0};
    snprintf(line, sizeof(line), "[%d][%s.%03d] %s\n",
             getpid(), stamp, (int)(tv.tv_usec / 1000), message);
    int descriptor = open("/var/tmp/vcam-ref-msd.log",
                          O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (descriptor >= 0) {
        (void)write(descriptor, line, strlen(line));
        close(descriptor);
    }
}
typedef enum {
    VCamModeNone = 0,
    VCamModeImage,
    VCamModeVideo
} VCamMode;

static VCamMode currentMode = VCamModeNone;
static CGImageRef replacementImage = NULL;
static NSMutableArray *videoFrames = NULL;
static NSUInteger currentFrameIndex = 0;
static CIContext *sharedCIContext = NULL;
static NSObject *vcamLock = nil;

void loadReplacementMedia(void) {
    NSString *kReplacementMediaPath = VCAMReferenceMediaPath();
    char loadPathBuf[1024] = {0};
    snprintf(loadPathBuf, sizeof(loadPathBuf), "load path=%s exists=%d",
             kReplacementMediaPath.UTF8String ?: "(nil)",
             (int)[[NSFileManager defaultManager] fileExistsAtPath:kReplacementMediaPath]);
    VCAMRefLog(loadPathBuf);
    if (!vcamLock) {
        vcamLock = [[NSObject alloc] init];
    }

    if (![[NSFileManager defaultManager] fileExistsAtPath:kReplacementMediaPath]) {
        VCAMRefLog("load file missing");
        return;
    }

    NSString *extension = [[kReplacementMediaPath pathExtension] lowercaseString];
    if ([extension isEqualToString:@"png"] || [extension isEqualToString:@"jpg"] || [extension isEqualToString:@"jpeg"]) {
        UIImage *image = [UIImage imageWithContentsOfFile:kReplacementMediaPath];
        if (image && image.CGImage) {
            replacementImage = CGImageRetain(image.CGImage);
            currentMode = VCamModeImage;
            VCAMRefLog("load mode=image");
        }
    }
    else if ([extension isEqualToString:@"mp4"] || [extension isEqualToString:@"mov"]) {
        NSURL *videoURL = [NSURL fileURLWithPath:kReplacementMediaPath];
        AVAsset *asset = [AVAsset assetWithURL:videoURL];

        NSError *error = nil;
        AVAssetReader *assetReader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
        if (error) {
            char errBuf[256] = {0};
            snprintf(errBuf, sizeof(errBuf), "load video reader init error=%s", error.localizedDescription.UTF8String ?: "(nil)");
            VCAMRefLog(errBuf);
            return;
        }

        NSArray *videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
        if (videoTracks.count == 0) {
            VCAMRefLog("load video no video tracks");
            return;
        }

        AVAssetTrack *videoTrack = videoTracks[0];
        NSDictionary *outputSettings = @{ (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA) };
        AVAssetReaderTrackOutput *videoOutput = [[AVAssetReaderTrackOutput alloc] initWithTrack:videoTrack outputSettings:outputSettings];
        videoOutput.alwaysCopiesSampleData = NO;

        if (![assetReader canAddOutput:videoOutput]) {
            VCAMRefLog("load video cannot add output");
            return;
        }

        [assetReader addOutput:videoOutput];
        [assetReader startReading];
        if (assetReader.status != AVAssetReaderStatusReading) {
            char stBuf[128] = {0};
            snprintf(stBuf, sizeof(stBuf), "load video startReading status=%ld error=%s",
                     (long)assetReader.status, assetReader.error.localizedDescription.UTF8String ?: "(none)");
            VCAMRefLog(stBuf);
        } else {
            char okBuf[256] = {0};
            snprintf(okBuf, sizeof(okBuf), "load video reader started size=%.0fx%.0f",
                     videoTrack.naturalSize.width, videoTrack.naturalSize.height);
            VCAMRefLog(okBuf);
        }

        videoFrames = [[NSMutableArray alloc] init];
        int frameCount = 0;
        int maxFrames = 60;
        // Guard against OOM: cap preload bytes (~256 MB) for large 4K sources.
        CGFloat frameBytes = 4.0 * videoTrack.naturalSize.width * videoTrack.naturalSize.height;
        if (frameBytes > 0) {
            int byteCapFrames = (int)((256.0 * 1024.0 * 1024.0) / frameBytes);
            if (byteCapFrames > 0 && byteCapFrames < maxFrames) maxFrames = byteCapFrames;
        }
        while (assetReader.status == AVAssetReaderStatusReading && frameCount < maxFrames) {
            CMSampleBufferRef sampleBuffer = [videoOutput copyNextSampleBuffer];
            if (sampleBuffer == NULL) {
                break;
            }

            CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
            if (pixelBuffer) {
                CVPixelBufferRetain(pixelBuffer);
                [videoFrames addObject:(__bridge id)pixelBuffer];
                frameCount++;
            }

            CFRelease(sampleBuffer);
        }

        if (frameCount > 0) {
            currentMode = VCamModeVideo;
            char doneBuf[128] = {0};
            snprintf(doneBuf, sizeof(doneBuf), "load video frames=%d mode=video", frameCount);
            VCAMRefLog(doneBuf);
        } else {
            char emptyBuf[128] = {0};
            snprintf(emptyBuf, sizeof(emptyBuf), "load video zero frames status=%ld",
                     (long)assetReader.status);
            VCAMRefLog(emptyBuf);
        }

        [assetReader cancelReading];
    }

    if (sharedCIContext == NULL) {
        sharedCIContext = [CIContext context];
    }
}

void drawReplacementOntoBuffer(CVPixelBufferRef targetBuffer) {
    static int drawCalls = 0;
    static CFAbsoluteTime lastRenderTime = 0;
    static NSInteger rotationDegrees = 0;
    static BOOL mirrorHorizontally = NO;
    static int configRefreshCount = 0;
    drawCalls++;
    if (drawCalls <= 5) {
        char drawBuf[192] = {0};
        snprintf(drawBuf, sizeof(drawBuf), "draw call=%d mode=%d target=%zux%zu",
                 drawCalls, (int)currentMode,
                 CVPixelBufferGetWidth(targetBuffer), CVPixelBufferGetHeight(targetBuffer));
        VCAMRefLog(drawBuf);
    }
    // Only draw into preview-sized buffers; the large sensor/photo nodes would
    // otherwise overload the GPU at ~600 fps and stall the camera pipeline.
    size_t targetWidthPixels = CVPixelBufferGetWidth(targetBuffer);
    size_t targetHeightPixels = CVPixelBufferGetHeight(targetBuffer);
    if (targetWidthPixels * targetHeightPixels > 2200000) {
        return;
    }
    // Throttle rendering to 30 fps; upstream emits several video nodes at a
    // much higher combined rate.
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (lastRenderTime > 0 && (now - lastRenderTime) < (1.0 / 30.0)) {
        return;
    }
    lastRenderTime = now;
    // Refresh rotation/mirror from the daemon-readable config occasionally so
    // control-panel changes apply without restarting mediaserverd.
    if (configRefreshCount++ % 30 == 0) {
        NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:@"/var/tmp/com.codex.vcam.plist"];
        if (cfg == nil) {
            cfg = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Media/VCAM/com.codex.vcam.plist"];
        }
        rotationDegrees = [cfg[@"rotationDegrees"] integerValue] % 360;
        mirrorHorizontally = [cfg[@"mirrorHorizontally"] boolValue];
    }
    @synchronized(vcamLock) {
        CIImage *replacementCIImage = nil;

        if (currentMode == VCamModeImage) {
            replacementCIImage = [CIImage imageWithCGImage:replacementImage];
        } 
        else if (currentMode == VCamModeVideo) {
            CVPixelBufferRef videoFrame = (__bridge CVPixelBufferRef)videoFrames[currentFrameIndex];
            currentFrameIndex = (currentFrameIndex + 1) % videoFrames.count;
            replacementCIImage = [CIImage imageWithCVPixelBuffer:videoFrame];
        }

        if (!replacementCIImage) {
            return;
        }

        // Apply config rotation/mirror around the frame center before scaling.
        if (rotationDegrees != 0 || mirrorHorizontally) {
            CGRect extent = replacementCIImage.extent;
            CGAffineTransform orient = CGAffineTransformTranslate(
                CGAffineTransformIdentity,
                -CGRectGetMidX(extent), -CGRectGetMidY(extent));
            if (rotationDegrees != 0) {
                orient = CGAffineTransformRotate(orient, rotationDegrees * M_PI / 180.0);
            }
            if (mirrorHorizontally) {
                orient = CGAffineTransformScale(orient, -1.0, 1.0);
            }
            replacementCIImage = [replacementCIImage imageByApplyingTransform:orient];
        }

        CGFloat targetWidth = (CGFloat)targetWidthPixels;
        CGFloat targetHeight = (CGFloat)targetHeightPixels;
        CGRect replacementExtent = replacementCIImage.extent;

        CGFloat scaleX = targetWidth / replacementExtent.size.width;
        CGFloat scaleY = targetHeight / replacementExtent.size.height;
        CGFloat scale = MIN(scaleX, scaleY);

        CGAffineTransform transform = CGAffineTransformMakeScale(scale, scale);
        CIImage *scaledImage = [replacementCIImage imageByApplyingTransform:transform];
        
        CGRect scaledExtent = scaledImage.extent;
        CGFloat offsetX = (targetWidth - scaledExtent.size.width) / 2.0;
        CGFloat offsetY = (targetHeight - scaledExtent.size.height) / 2.0;        
        CGAffineTransform translationTransform = CGAffineTransformMakeTranslation(offsetX, offsetY);
        CIImage *finalImage = [scaledImage imageByApplyingTransform:translationTransform];

        if (sharedCIContext) {
            [sharedCIContext render:finalImage toCVPixelBuffer:targetBuffer];
        }
    }
}
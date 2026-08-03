#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import "../Core/VCAMInjectionPolicy.h"
#import "VCAMPreviewDriver.h"

static const void *VCAMPreviewDriverKey = &VCAMPreviewDriverKey;

static void VCAMInstallPreviewDriver(AVCaptureVideoPreviewLayer *layer) {
    if (layer == nil || objc_getAssociatedObject(layer, VCAMPreviewDriverKey) != nil) return;
    VCAMPreviewDriver *driver = [[VCAMPreviewDriver alloc] initWithPreviewLayer:layer];
    objc_setAssociatedObject(layer, VCAMPreviewDriverKey, driver, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%group VCAMCameraPreviewHooks

%hook AVCaptureVideoPreviewLayer

- (instancetype)initWithSession:(AVCaptureSession *)session {
    AVCaptureVideoPreviewLayer *layer = %orig;
    VCAMInstallPreviewDriver(layer);
    return layer;
}

- (instancetype)initWithSessionWithNoConnection:(AVCaptureSession *)session {
    AVCaptureVideoPreviewLayer *layer = %orig;
    VCAMInstallPreviewDriver(layer);
    return layer;
}

%end

%end

%ctor {
    @autoreleasepool {
        if ([VCAMInjectionPolicy currentTarget] == VCAMInjectionTargetCamera &&
            [VCAMInjectionPolicy isCurrentProcessMediaReplacementEnabled]) {
            %init(VCAMCameraPreviewHooks);
        }
    }
}

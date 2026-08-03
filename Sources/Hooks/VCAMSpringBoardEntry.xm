#import "../Core/VCAMConfiguration.h"
#import "../UI/VCAMMediaPickerController.h"

%ctor {
    @autoreleasepool {
        [VCAMConfiguration startWriteBroker];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [[VCAMMediaPickerController sharedController] startControlUI];
        });
    }
}

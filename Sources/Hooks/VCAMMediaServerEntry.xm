#import "../Core/VCAMConfiguration.h"
#import "../Core/VCAMInjectionPolicy.h"

%ctor {
    @autoreleasepool {
        if ([VCAMInjectionPolicy currentTarget] != VCAMInjectionTargetMediaServer) return;
        BOOL enabled = [VCAMInjectionPolicy isCurrentProcessEnabled];
        [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:@"mediaserverd ctor enabled=%d", enabled]];
    }
}
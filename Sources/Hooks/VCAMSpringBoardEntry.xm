#import "../Core/VCAMConfiguration.h"
#import "../SpringBoard/VCAMSpringBoardMediaBridge.h"
#import "../UI/VCAMMediaPickerController.h"
#import "../Shared/VCAMProcessIdentity.h"

#include <fcntl.h>
#include <string.h>
#include <unistd.h>

static void VCAMAppendClientProof(const char *line) {
    int descriptor = open("/var/tmp/vcam-springboard-client.log",
                          O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (descriptor >= 0) {
        (void)write(descriptor, line, strlen(line));
        close(descriptor);
    }
}

static void VCAMWriteClientProof(void) {
    char line[128] = {0};
    snprintf(line, sizeof(line), "pid=%d start=%llu ctor\n", (int)getpid(),
             (unsigned long long)VCAMProcessStartToken(getpid()));
    VCAMAppendClientProof(line);
}

%ctor {
    @autoreleasepool {
        VCAMWriteClientProof();
        [VCAMConfiguration startWriteBroker];
        dispatch_async(dispatch_get_main_queue(), ^{
            [[VCAMMediaPickerController sharedController] startControlUI];
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [[VCAMSpringBoardMediaBridge sharedBridge] start];
        });
        // One-shot: prove whether direct VT hardware decode works from the
        // GUI app process at all (vcamd's daemon context failed -12911).
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [[VCAMSpringBoardMediaBridge sharedBridge] runVideoToolboxHardwareSelfTest];
        });
    }
}

#import "../Core/VCAMConfiguration.h"
#import "../UI/VCAMMediaPickerController.h"

#include <fcntl.h>
#include <unistd.h>

static void VCAMWriteClientProof(void) {
    char line[128] = {0};
    int length = snprintf(line, sizeof(line), "pid=%d ctor\n", (int)getpid());
    int descriptor = open("/var/tmp/vcam-springboard-client.log",
                          O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (descriptor >= 0) {
        (void)write(descriptor, line, (size_t)length);
        close(descriptor);
    }
}

%ctor {
    @autoreleasepool {
        VCAMWriteClientProof();
        [VCAMConfiguration startWriteBroker];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [[VCAMMediaPickerController sharedController] startControlUI];
        });
    }
}

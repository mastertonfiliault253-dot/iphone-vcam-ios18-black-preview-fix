// vcam_frame_listener.m
// On-device root tool (not sandboxed). Polls a Darwin notification posted by
// the cameracaptured hook, and records hits to /var/tmp/vcam-ios18-frames.log.

#import <notify.h>
#include <stdio.h>
#include <unistd.h>

int main(void) {
    int token = -1;
    if (notify_register_check("com.codex.vcam.ios18.frame", &token) != NOTIFY_STATUS_OK) {
        printf("notify_register_check failed\n");
        return 1;
    }
    printf("listener ready pid=%d\n", getpid());
    fflush(stdout);
    long last = 0;
    while (1) {
        int check = 0;
        if (notify_check(token, &check) == NOTIFY_STATUS_OK && check != 0) {
            last++;
            FILE *f = fopen("/var/tmp/vcam-ios18-frames.log", "a");
            if (f) {
                fprintf(f, "frame hit count=%ld\n", last);
                fclose(f);
            }
        }
        usleep(50000);
    }
    return 0;
}

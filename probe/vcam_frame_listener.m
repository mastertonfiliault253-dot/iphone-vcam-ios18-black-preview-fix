// vcam_frame_listener.m
// Runs on-device (as a normal root tool, NOT sandboxed). Registers for the
// Darwin notification posted by the cameracaptured hook and records each hit
// to /var/tmp/vcam-ios18-frames.log.

#import <Foundation/Foundation.h>
#import <notify.h>
#include <stdio.h>
#include <unistd.h>

int main(void) {
    int token = -1;
    __block long count = 0;
    uint32_t status = notify_register_dispatch(
        "com.codex.vcam.ios18.frame",
        &token,
        dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
        ^(int t) {
            long n = __sync_add_and_fetch(&count, 1);
            FILE *f = fopen("/var/tmp/vcam-ios18-frames.log", "a");
            if (f) {
                fprintf(f, "frame hit count=%ld\n", n);
                fclose(f);
            }
        });
    if (status != NOTIFY_STATUS_OK) {
        printf("notify_register_dispatch failed: %u\n", status);
        return 1;
    }
    printf("listener registered for com.codex.vcam.ios18.frame pid=%d\n", getpid());
    fflush(stdout);
    while (1) {
        sleep(10);
    }
    return 0;
}

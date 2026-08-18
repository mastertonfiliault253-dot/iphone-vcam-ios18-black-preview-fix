// vcam_frame_listener.m
// On-device root tool. Polls Darwin notifications posted by the
// cameracaptured hook, and records hits to /var/tmp/vcam-ios18-frames.log.

#import <notify.h>
#include <stdio.h>
#include <unistd.h>
#include <string.h>

static const char *g_names[] = {
    "com.codex.vcam.ios18.frame",
    "com.codex.vcam.ios18.vmode",
    "com.codex.vcam.ios18.route",
    "com.codex.vcam.ios18.metal",
    "com.codex.vcam.ios18.metalnil",
    "com.codex.vcam.ios18.rendered",
    "com.codex.vcam.ios18.renderfail",
    "com.codex.vcam.ios18.sbcreated",
    "com.codex.vcam.ios18.sbfail",
};

int main(void) {
    int tokens[9] = {-1,-1,-1,-1,-1,-1,-1,-1,-1};
    long counts[9] = {0,0,0,0,0,0,0,0,0};
    for (int i = 0; i < 9; i++) {
        if (notify_register_check(g_names[i], &tokens[i]) != NOTIFY_STATUS_OK) {
            printf("notify_register_check failed for %s\n", g_names[i]);
            return 1;
        }
    }
    printf("listener ready pid=%d\n", getpid());
    fflush(stdout);
    while (1) {
        int any = 0;
        for (int i = 0; i < 9; i++) {
            int check = 0;
            if (notify_check(tokens[i], &check) == NOTIFY_STATUS_OK && check != 0) {
                counts[i]++; any = 1;
            }
        }
        if (any) {
            FILE *f = fopen("/var/tmp/vcam-ios18-frames.log", "a");
            if (f) {
                fprintf(f, "frame=%ld vmode=%ld route=%ld metal=%ld metalnil=%ld rendered=%ld renderfail=%ld sbcreated=%ld sbfail=%ld\n",
                        counts[0],counts[1],counts[2],counts[3],counts[4],counts[5],counts[6],counts[7],counts[8]);
                fclose(f);
            }
        }
        usleep(50000);
    }
    return 0;
}

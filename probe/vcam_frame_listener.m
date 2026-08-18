// vcam_frame_listener.m
// On-device root tool. Polls Darwin notifications posted by the cameracaptured
// hook, and records hits to /var/tmp/vcam-ios18-frames.log.

#import <notify.h>
#include <stdio.h>
#include <unistd.h>

static const char *g_names[] = {
    "com.codex.vcam.ios18.frame",
    "com.codex.vcam.ios18.vmode",
    "com.codex.vcam.ios18.route.camsrc",
    "com.codex.vcam.ios18.route.converter",
    "com.codex.vcam.ios18.route.preview",
    "com.codex.vcam.ios18.route.recording",
    "com.codex.vcam.ios18.route.still",
    "com.codex.vcam.ios18.route.other",
    "com.codex.vcam.ios18.metal",
    "com.codex.vcam.ios18.metalnil",
    "com.codex.vcam.ios18.rendered",
    "com.codex.vcam.ios18.renderfail",
    "com.codex.vcam.ios18.sbcreated",
    "com.codex.vcam.ios18.sbfail",
};
#define N (int)(sizeof(g_names)/sizeof(g_names[0]))

int main(void) {
    int tokens[N];
    long counts[N];
    for (int i = 0; i < N; i++) {
        tokens[i] = -1;
        counts[i] = 0;
        if (notify_register_check(g_names[i], &tokens[i]) != NOTIFY_STATUS_OK) {
            printf("notify_register_check failed for %s\n", g_names[i]);
            return 1;
        }
    }
    printf("listener ready pid=%d n=%d\n", getpid(), N);
    fflush(stdout);
    while (1) {
        int any = 0;
        for (int i = 0; i < N; i++) {
            int check = 0;
            if (notify_check(tokens[i], &check) == NOTIFY_STATUS_OK && check != 0) {
                counts[i]++;
                any = 1;
            }
        }
        if (any) {
            FILE *f = fopen("/var/tmp/vcam-ios18-frames.log", "a");
            if (f) {
                fprintf(f,
                    "frame=%ld vmode=%ld camsrc=%ld converter=%ld preview=%ld recording=%ld still=%ld other=%ld metal=%ld metalnil=%ld rendered=%ld renderfail=%ld sbcreated=%ld sbfail=%ld\n",
                    counts[0],counts[1],counts[2],counts[3],counts[4],counts[5],counts[6],counts[7],counts[8],counts[9],counts[10],counts[11],counts[12],counts[13]);
                fclose(f);
            }
        }
        usleep(50000);
    }
    return 0;
}

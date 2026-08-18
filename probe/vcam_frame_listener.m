// vcam_frame_listener.m
// On-device root tool. Polls three Darwin notifications posted by the
// cameracaptured hook, and records hits to /var/tmp/vcam-ios18-frames.log.

#import <notify.h>
#include <stdio.h>
#include <unistd.h>
#include <string.h>

static const char *g_names[] = {
    "com.codex.vcam.ios18.frame",
    "com.codex.vcam.ios18.vmode",
    "com.codex.vcam.ios18.route",
};

int main(void) {
    int tokens[3] = {-1, -1, -1};
    long counts[3] = {0, 0, 0};
    for (int i = 0; i < 3; i++) {
        if (notify_register_check(g_names[i], &tokens[i]) != NOTIFY_STATUS_OK) {
            printf("notify_register_check failed for %s\n", g_names[i]);
            return 1;
        }
    }
    printf("listener ready pid=%d\n", getpid());
    fflush(stdout);
    while (1) {
        int any = 0;
        for (int i = 0; i < 3; i++) {
            int check = 0;
            if (notify_check(tokens[i], &check) == NOTIFY_STATUS_OK && check != 0) {
                counts[i]++;
                any = 1;
            }
        }
        if (any) {
            FILE *f = fopen("/var/tmp/vcam-ios18-frames.log", "a");
            if (f) {
                fprintf(f, "frame=%ld vmode=%ld route=%ld\n", counts[0], counts[1], counts[2]);
                fclose(f);
            }
        }
        usleep(50000);
    }
    return 0;
}

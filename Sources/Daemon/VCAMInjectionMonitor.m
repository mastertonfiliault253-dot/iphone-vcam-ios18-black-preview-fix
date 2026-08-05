#import <Foundation/Foundation.h>

#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;
extern int proc_listallpids(void *buffer, int buffersize);
extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);

enum { VCAMProcessPathCapacity = 4096 };

typedef struct {
    const char *name;
    const char *processPath;
    const char *dylibPath;
    const char *proofPath;
    const char *proofFormat;
    pid_t observedPID;
    pid_t injectedPID;
    time_t nextAttempt;
} VCAMInjectionTarget;

static pid_t VCAMFindProcessAtPath(const char *expectedPath) {
    int capacity = proc_listallpids(NULL, 0);
    if (capacity <= 0) return 0;
    capacity += 32;
    pid_t *pids = calloc((size_t)capacity, sizeof(pid_t));
    if (pids == NULL) return 0;
    int count = proc_listallpids(pids, capacity * (int)sizeof(pid_t));
    pid_t match = 0;
    for (int index = 0; index < count; index++) {
        if (pids[index] <= 1) continue;
        char path[VCAMProcessPathCapacity] = {0};
        if (proc_pidpath(pids[index], path, sizeof(path)) > 0 &&
            strcmp(path, expectedPath) == 0) {
            match = pids[index];
            break;
        }
    }
    free(pids);
    return match;
}

static BOOL VCAMProofContainsPID(VCAMInjectionTarget *target, pid_t pid) {
    if (pid <= 0) return NO;
    NSString *path = [NSString stringWithUTF8String:target->proofPath];
    NSString *contents = [NSString stringWithContentsOfFile:path
                                                   encoding:NSUTF8StringEncoding
                                                      error:nil];
    if (contents.length == 0) return NO;
    NSString *format = [NSString stringWithUTF8String:target->proofFormat];
    NSString *needle = [NSString stringWithFormat:format, pid];
    return [contents containsString:needle];
}

static int VCAMRunInjector(VCAMInjectionTarget *target, pid_t pid) {
    static const char *injector = "/var/jb/usr/bin/opainject";
    char pidString[32] = {0};
    snprintf(pidString, sizeof(pidString), "%d", pid);
    char *const arguments[] = {
        (char *)injector,
        pidString,
        (char *)target->dylibPath,
        NULL,
    };
    pid_t child = 0;
    int spawnResult = posix_spawn(&child, injector, NULL, NULL, arguments, environ);
    if (spawnResult != 0) return spawnResult;

    int status = 0;
    for (int attempt = 0; attempt < 50; attempt++) {
        pid_t waited = waitpid(child, &status, WNOHANG);
        if (waited == child) {
            if (WIFEXITED(status)) return WEXITSTATUS(status);
            return 128 + (WIFSIGNALED(status) ? WTERMSIG(status) : 0);
        }
        if (waited < 0 && errno != EINTR) return errno;
        usleep(100000);
    }
    kill(child, SIGKILL);
    (void)waitpid(child, &status, 0);
    return ETIMEDOUT;
}

static void VCAMCheckTarget(VCAMInjectionTarget *target) {
    pid_t pid = VCAMFindProcessAtPath(target->processPath);
    if (pid != target->observedPID) {
        fprintf(stderr, "target=%s pid changed old=%d new=%d\n",
                target->name, target->observedPID, pid);
        target->observedPID = pid;
        target->injectedPID = 0;
        target->nextAttempt = 0;
    }
    if (pid <= 0 || target->injectedPID == pid) return;

    time_t now = time(NULL);
    if (now < target->nextAttempt) return;
    target->nextAttempt = now + 5;
    int result = VCAMRunInjector(target, pid);
    sleep(1);
    pid_t observed = VCAMFindProcessAtPath(target->processPath);
    BOOL proved = result == 0 && observed == pid && VCAMProofContainsPID(target, pid);
    fprintf(stderr, "target=%s pid=%d injector=%d stable=%d proof=%d\n",
            target->name, pid, result, observed == pid, proved);
    if (proved) target->injectedPID = pid;
}

int main(int argc, char *argv[]) {
    (void)argc;
    (void)argv;
    VCAMInjectionTarget targets[] = {
        {
            .name = "SpringBoard",
            .processPath = "/System/Library/CoreServices/SpringBoard.app/SpringBoard",
            .dylibPath = "/var/jb/Library/MobileSubstrate/DynamicLibraries/VCAMSpringBoardClient.dylib",
            .proofPath = "/var/mobile/Media/VCAM/broker-probe.log",
            .proofFormat = "broker starting pid=%d ",
        },
        {
            .name = "mediaserverd",
            .processPath = "/usr/sbin/mediaserverd",
            .dylibPath = "/var/jb/Library/MobileSubstrate/DynamicLibraries/VCAMMediaServerClient.dylib",
            .proofPath = "/var/tmp/vcam-ref-msd.log",
            .proofFormat = "[%d][",
        },
    };
    fprintf(stderr, "vcaminjectd starting with %zu exact targets\n",
            sizeof(targets) / sizeof(targets[0]));
    fflush(stderr);
    while (YES) {
        @autoreleasepool {
            for (size_t index = 0; index < sizeof(targets) / sizeof(targets[0]); index++) {
                VCAMCheckTarget(&targets[index]);
            }
        }
        fflush(stderr);
        sleep(2);
    }
    return 0;
}

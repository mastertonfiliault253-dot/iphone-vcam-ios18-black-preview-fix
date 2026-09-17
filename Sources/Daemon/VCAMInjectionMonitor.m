#import <Foundation/Foundation.h>
#import "../Shared/VCAMProcessIdentity.h"

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
    uint64_t observedStartToken;
    pid_t injectedPID;
    uint64_t injectedStartToken;
    pid_t attemptedPID;
    uint64_t attemptedStartToken;
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

static BOOL VCAMProofContainsProcess(VCAMInjectionTarget *target, pid_t pid,
                                     uint64_t startToken) {
    if (pid <= 0 || startToken == 0) return NO;
    NSString *path = [NSString stringWithUTF8String:target->proofPath];
    NSString *contents = [NSString stringWithContentsOfFile:path
                                                   encoding:NSUTF8StringEncoding
                                                      error:nil];
    if (contents.length == 0) return NO;
    NSString *format = [NSString stringWithUTF8String:target->proofFormat];
    NSString *needle = [NSString stringWithFormat:format, pid,
        (unsigned long long)startToken];
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
    uint64_t startToken = VCAMProcessStartToken(pid);
    if (pid != target->observedPID ||
        startToken != target->observedStartToken) {
        fprintf(stderr,
                "target=%s process changed old=%d/%llu new=%d/%llu\n",
                target->name, target->observedPID,
                (unsigned long long)target->observedStartToken, pid,
                (unsigned long long)startToken);
        target->observedPID = pid;
        target->observedStartToken = startToken;
        target->injectedPID = 0;
        target->injectedStartToken = 0;
        target->attemptedPID = 0;
        target->attemptedStartToken = 0;
        target->nextAttempt = 0;
    }
    if (pid <= 0 || startToken == 0) return;
    if (target->injectedPID == pid &&
        target->injectedStartToken == startToken) return;

    // A proof line already in the shared log means the dylib is loaded in this
    // exact pid (from postinst or a previous daemon run). Never re-inject:
    // repeated PAC injection into an already-loaded process is what wedges the
    // target and leaves spinning opainject children behind.
    if (VCAMProofContainsProcess(target, pid, startToken)) {
        target->injectedPID = pid;
        target->injectedStartToken = startToken;
        fprintf(stderr, "target=%s pid=%d already-loaded proof=1\n",
                target->name, pid);
        return;
    }

    // A sandbox-invisible proof is not a reason to inject the same stable
    // process again. The proof check above remains first so a delayed proof
    // can still promote this attempt to verified without another injection.
    if (target->attemptedPID == pid &&
        target->attemptedStartToken == startToken) return;

    time_t now = time(NULL);
    if (now < target->nextAttempt) return;
    // Generous backoff: opainject PAC mode can take several seconds, and a
    // failed attempt must not pile up another injector while the previous one
    // is still settling.
    target->nextAttempt = now + 30;
    int result = VCAMRunInjector(target, pid);
    sleep(1);
    pid_t observed = VCAMFindProcessAtPath(target->processPath);
    // The injector may return ETIMEDOUT even after a successful dlopen when
    // opainject's PAC bootstrap thread never reports back. Prefer constructor
    // proof, but do not use a missing proof to justify another PAC injection.
    uint64_t observedStartToken = VCAMProcessStartToken(observed);
    BOOL stable = observed == pid && observedStartToken == startToken;
    BOOL proved = stable &&
        VCAMProofContainsProcess(target, pid, startToken);
    fprintf(stderr, "target=%s pid=%d injector=%d stable=%d proof=%d\n",
            target->name, pid, result, stable, proved);
    if (proved) {
        target->injectedPID = pid;
        target->injectedStartToken = startToken;
    }
    else {
        // The injected ctor can flush its proof shortly after the injector
        // returns or is killed. Give it a few more seconds before ever
        // considering a retry, regardless of the injector exit status.
        for (int extra = 0; extra < 5 &&
             !VCAMProofContainsProcess(target, pid, startToken); extra++) {
            sleep(1);
        }
        observed = VCAMFindProcessAtPath(target->processPath);
        observedStartToken = VCAMProcessStartToken(observed);
        stable = observed == pid && observedStartToken == startToken;
        if (stable && VCAMProofContainsProcess(target, pid, startToken)) {
            target->injectedPID = pid;
            target->injectedStartToken = startToken;
            proved = YES;
            fprintf(stderr, "target=%s pid=%d late-proof=1\n", target->name, pid);
        }
    }

    if (stable) {
        // Mark the exact pid/start pair as attempted even when the proof file
        // is unreadable from the daemon's context. This is deliberately
        // separate from injectedPID: a zero exit plus a stable target is
        // enough to avoid the crash loop, but remains an explicit assumption
        // until the runtime hook produces observable evidence.
        target->attemptedPID = pid;
        target->attemptedStartToken = startToken;
        if (!proved && result == 0) {
            target->injectedPID = pid;
            target->injectedStartToken = startToken;
        }
        if (target->injectedPID == pid &&
            target->injectedStartToken == startToken) {
            if (!proved) {
                fprintf(stderr, "target=%s pid=%d assumed-loaded proof=0\n",
                        target->name, pid);
            }
        }
        else {
            fprintf(stderr,
                    "target=%s pid=%d attempted-without-proof injector=%d\n",
                    target->name, pid, result);
        }
    }
}

int main(int argc, char *argv[]) {
    (void)argc;
    (void)argv;
    VCAMInjectionTarget targets[] = {
        {
            .name = "cameracaptured",
            .processPath = "/usr/libexec/cameracaptured",
            .dylibPath = "/var/jb/Library/MobileSubstrate/DynamicLibraries/VCAMMediaServerClient.dylib",
            // Keep proof verification on the same first-choice path used by
            // VCAMRefLog. cameracaptured can write this sandbox-approved
            // directory, and postinst creates the file before respawning it.
            .proofPath = "/var/mobile/Library/VirtualCaptureCard/VCAM/vcam-ref.log",
            .proofFormat = "[%d][start=%llu][",
        },
    };
    fprintf(stderr, "vcaminjectd starting with %zu exact targets (SpringBoard and application clients use ElleKit auto-injection)\n",
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

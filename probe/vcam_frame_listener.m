// vcam_frame_listener.m
// On-device root tool. Polls Darwin notifications and reads the cameracaptured
// hook's current signature string via task_for_pid + mach_vm_read.

#import <notify.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#include <stdio.h>
#include <stdint.h>
#include <unistd.h>
#include <string.h>

extern int proc_listallpids(void *buffer, int buffersize);
extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);

enum {
    VCAMProbeEventCapacity = 16,
    VCAMProbeMessageCapacity = 768,
    VCAMProbeFlagStarted = 1 << 0,
    VCAMProbeFlagClassFound = 1 << 1,
    VCAMProbeFlagClassMissing = 1 << 2,
    VCAMProbeFlagMethodFound = 1 << 3,
    VCAMProbeFlagMethodMissing = 1 << 4,
    VCAMProbeFlagSwizzled = 1 << 5,
    VCAMProbeFlagDone = 1 << 6,
    VCAMProbeFlagEmit = 1 << 7,
    VCAMProbeFlagProductionImage = 1 << 8,
    VCAMProbeFlagSubstrateImage = 1 << 9,
    VCAMProbeFlagRemoteClassFound = 1 << 10,
    VCAMProbeFlagRemoteMethodFound = 1 << 11,
    VCAMProbeFlagRemoteSwizzled = 1 << 12,
    VCAMProbeFlagRemoteCalled = 1 << 13,
    VCAMProbeFlagPhotoClassFound = 1 << 14,
    VCAMProbeFlagPhotoMethodFound = 1 << 15,
    VCAMProbeFlagPhotoSwizzled = 1 << 16,
    VCAMProbeFlagPhotoCalled = 1 << 17,
};

typedef struct {
    uint64_t sequence;
    char message[VCAMProbeMessageCapacity];
} VCAMProbeEvent;

static kern_return_t read_remote(mach_port_t task, uint64_t address,
                                  void *buffer, vm_size_t size) {
    vm_size_t received = size;
    return vm_read_overwrite(task, (vm_address_t)address, size,
                             (vm_address_t)buffer, &received);
}

static void record_line(const char *path, const char *prefix,
                        uint64_t sequence, const char *message) {
    printf("%s seq=%llu %s\n", prefix,
           (unsigned long long)sequence, message);
    fflush(stdout);
    FILE *f = fopen(path, "a");
    if (f) {
        fprintf(f, "%s seq=%llu %s\n", prefix,
                (unsigned long long)sequence, message);
        fclose(f);
    }
}

static void record_probe_flags(uint64_t flags, uint64_t previous) {
    struct FlagName {
        uint64_t flag;
        const char *name;
    };
    static const struct FlagName names[] = {
        {VCAMProbeFlagStarted, "constructor-started"},
        {VCAMProbeFlagClassFound, "BWNodeOutput-class-found"},
        {VCAMProbeFlagClassMissing, "BWNodeOutput-class-missing"},
        {VCAMProbeFlagMethodFound, "emitSampleBuffer-method-found"},
        {VCAMProbeFlagMethodMissing, "emitSampleBuffer-method-missing"},
        {VCAMProbeFlagSwizzled, "emitSampleBuffer-swizzled"},
        {VCAMProbeFlagDone, "constructor-done"},
        {VCAMProbeFlagEmit, "emitSampleBuffer-called"},
        {VCAMProbeFlagProductionImage, "production-VCAMMediaServerClient-loaded"},
        {VCAMProbeFlagSubstrateImage, "substrate-or-ellekit-loaded"},
        {VCAMProbeFlagRemoteClassFound, "BWRemoteQueueSinkNode-class-found"},
        {VCAMProbeFlagRemoteMethodFound, "remote-renderSampleBuffer-method-found"},
        {VCAMProbeFlagRemoteSwizzled, "remote-renderSampleBuffer-swizzled"},
        {VCAMProbeFlagRemoteCalled, "remote-renderSampleBuffer-called"},
        {VCAMProbeFlagPhotoClassFound, "BWPhotoEncoderNode-class-found"},
        {VCAMProbeFlagPhotoMethodFound, "photo-renderSampleBuffer-method-found"},
        {VCAMProbeFlagPhotoSwizzled, "photo-renderSampleBuffer-swizzled"},
        {VCAMProbeFlagPhotoCalled, "photo-renderSampleBuffer-called"},
    };
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        if ((flags & names[i].flag) != 0 &&
            (previous & names[i].flag) == 0) {
            record_line("/var/tmp/vcam-ios18-probe-events.log",
                        "VCAMPROBE-FLAG", names[i].flag, names[i].name);
        }
    }
}

static const char *const g_vcam_event_names[] = {
    "com.codex.vcam.ios18.frame",
    "com.codex.vcam.ios18.vmode",
    "com.codex.vcam.ios18.route.camsrc",
    "com.codex.vcam.ios18.route.converter",
    "com.codex.vcam.ios18.route.preview",
    "com.codex.vcam.ios18.route.recording",
    "com.codex.vcam.ios18.route.still",
    "com.codex.vcam.ios18.route.photo-encoder",
    "com.codex.vcam.ios18.route.other",
    "com.codex.vcam.ios18.rendered",
    "com.codex.vcam.ios18.renderfail",
    "com.codex.vcam.ios18.metal",
    "com.codex.vcam.ios18.metalnil",
};

static pid_t find_cameracaptured(void) {
    int n = proc_listallpids(NULL, 0);
    if (n <= 0) return 0;
    pid_t *pids = (pid_t *)malloc((size_t)(n + 32) * sizeof(pid_t));
    if (!pids) return 0;
    int count = proc_listallpids(pids, (n + 32) * (int)sizeof(pid_t));
    pid_t match = 0;
    for (int i = 0; i < count; i++) {
        char path[4096] = {0};
        if (proc_pidpath(pids[i], path, sizeof(path)) > 0 &&
            strcmp(path, "/usr/libexec/cameracaptured") == 0) {
            match = pids[i];
            break;
        }
    }
    free(pids);
    return match;
}

int main(void) {
    int sigtoken = -1;
    int addrtoken = -1;
    int probeToken = -1;
    int probeAddrToken = -1;
    int probeSequenceToken = -1;
    int probeFlagsToken = -1;
    int probeCountToken = -1;
    int probeDimensionsToken = -1;
    int probeFormatToken = -1;
    int productionCtorToken = -1;
    int productionPIDToken = -1;
    int productionStartToken = -1;
    int productionOutputCountToken = -1;
    int productionRemoteCountToken = -1;
    int productionPhotoCountToken = -1;
    int productionReplacementCountToken = -1;
    int productionReplacementRouteToken = -1;
    int productionLastKindToken = -1;
    int productionLastCountToken = -1;
    int productionLastDimensionsToken = -1;
    int productionLastFormatToken = -1;
    int vcamEventTokens[sizeof(g_vcam_event_names) /
                        sizeof(g_vcam_event_names[0])] = {0};
    if (notify_register_check("com.codex.vcam.ios18.signew", &sigtoken) != NOTIFY_STATUS_OK ||
        notify_register_check("com.codex.vcam.ios18.sigaddr", &addrtoken) != NOTIFY_STATUS_OK ||
        notify_register_check("com.codex.vcam.ios18.probe", &probeToken) != NOTIFY_STATUS_OK ||
        notify_register_check("com.codex.vcam.ios18.probe.addr", &probeAddrToken) != NOTIFY_STATUS_OK ||
        notify_register_check("com.codex.vcam.ios18.probe.sequence", &probeSequenceToken) != NOTIFY_STATUS_OK ||
        notify_register_check("com.codex.vcam.ios18.probe.flags.state", &probeFlagsToken) != NOTIFY_STATUS_OK ||
        notify_register_check("com.codex.vcam.ios18.probe.count.state", &probeCountToken) != NOTIFY_STATUS_OK ||
        notify_register_check("com.codex.vcam.ios18.probe.dimensions.state", &probeDimensionsToken) != NOTIFY_STATUS_OK ||
        notify_register_check("com.codex.vcam.ios18.probe.format.state", &probeFormatToken) != NOTIFY_STATUS_OK) {
        printf("notify_register_check failed\n");
        return 1;
    }
    if (notify_register_check("com.codex.vcam.ios18.production.ctor.state", &productionCtorToken) != NOTIFY_STATUS_OK ||
        notify_register_check("com.codex.vcam.ios18.production.pid.state", &productionPIDToken) != NOTIFY_STATUS_OK ||
        notify_register_check("com.codex.vcam.ios18.production.start.state", &productionStartToken) != NOTIFY_STATUS_OK ||
        notify_register_check("com.codex.vcam.ios18.production.output-count.state", &productionOutputCountToken) != NOTIFY_STATUS_OK ||
        notify_register_check("com.codex.vcam.ios18.production.remote-count.state", &productionRemoteCountToken) != NOTIFY_STATUS_OK ||
        notify_register_check("com.codex.vcam.ios18.production.photo-count.state", &productionPhotoCountToken) != NOTIFY_STATUS_OK ||
        notify_register_check("com.codex.vcam.ios18.production.replacement-count.state", &productionReplacementCountToken) != NOTIFY_STATUS_OK ||
        notify_register_check("com.codex.vcam.ios18.production.replacement-route.state", &productionReplacementRouteToken) != NOTIFY_STATUS_OK ||
        notify_register_check("com.codex.vcam.ios18.production.last-kind.state", &productionLastKindToken) != NOTIFY_STATUS_OK ||
        notify_register_check("com.codex.vcam.ios18.production.last-count.state", &productionLastCountToken) != NOTIFY_STATUS_OK ||
        notify_register_check("com.codex.vcam.ios18.production.last-dimensions.state", &productionLastDimensionsToken) != NOTIFY_STATUS_OK ||
        notify_register_check("com.codex.vcam.ios18.production.last-format.state", &productionLastFormatToken) != NOTIFY_STATUS_OK) {
        printf("notify_register_check failed for production telemetry\n");
        return 1;
    }
    for (size_t i = 0; i < sizeof(vcamEventTokens) / sizeof(vcamEventTokens[0]); i++) {
        if (notify_register_check(g_vcam_event_names[i],
                                  &vcamEventTokens[i]) != NOTIFY_STATUS_OK) {
            printf("notify_register_check failed for %s\n",
                   g_vcam_event_names[i]);
            return 1;
        }
    }
    printf("sig listener ready pid=%d\n", getpid());
    fflush(stdout);
    uint64_t lastProbeSequence = 0;
    uint64_t lastProbeFlags = 0;
    uint64_t lastProbeCount = 0;
    int reportedTaskFailure = 0;
    int reportedInitialState = 0;
    while (1) {
        int check = 0;
        int probeCheck = 0;
        (void)notify_check(sigtoken, &check);
        (void)notify_check(probeToken, &probeCheck);

        uint64_t sigAddr = 0;
        uint64_t probeAddr = 0;
        uint64_t probeSequence = 0;
        uint64_t probeFlags = 0;
        uint64_t probeCount = 0;
        uint64_t probeDimensions = 0;
        uint64_t probeFormat = 0;
        uint64_t productionCtor = 0;
        uint64_t productionPID = 0;
        uint64_t productionStart = 0;
        uint64_t productionOutputCount = 0;
        uint64_t productionRemoteCount = 0;
        uint64_t productionPhotoCount = 0;
        uint64_t productionReplacementCount = 0;
        uint64_t productionReplacementRoute = 0;
        uint64_t productionLastKind = 0;
        uint64_t productionLastCount = 0;
        uint64_t productionLastDimensions = 0;
        uint64_t productionLastFormat = 0;
        notify_get_state(addrtoken, &sigAddr);
        notify_get_state(probeAddrToken, &probeAddr);
        notify_get_state(probeSequenceToken, &probeSequence);
        notify_get_state(probeFlagsToken, &probeFlags);
        notify_get_state(probeCountToken, &probeCount);
        notify_get_state(probeDimensionsToken, &probeDimensions);
        notify_get_state(probeFormatToken, &probeFormat);
        notify_get_state(productionCtorToken, &productionCtor);
        notify_get_state(productionPIDToken, &productionPID);
        notify_get_state(productionStartToken, &productionStart);
        notify_get_state(productionOutputCountToken, &productionOutputCount);
        notify_get_state(productionRemoteCountToken, &productionRemoteCount);
        notify_get_state(productionPhotoCountToken, &productionPhotoCount);
        notify_get_state(productionReplacementCountToken, &productionReplacementCount);
        notify_get_state(productionReplacementRouteToken, &productionReplacementRoute);
        notify_get_state(productionLastKindToken, &productionLastKind);
        notify_get_state(productionLastCountToken, &productionLastCount);
        notify_get_state(productionLastDimensionsToken, &productionLastDimensions);
        notify_get_state(productionLastFormatToken, &productionLastFormat);
        for (size_t i = 0; i < sizeof(vcamEventTokens) / sizeof(vcamEventTokens[0]); i++) {
            int eventCheck = 0;
            if (notify_check(vcamEventTokens[i], &eventCheck) == NOTIFY_STATUS_OK &&
                eventCheck != 0) {
                record_line("/var/tmp/vcam-ios18-probe-events.log",
                            "VCAM-NOTIFY", 0, g_vcam_event_names[i]);
            }
        }
        if (!reportedInitialState) {
            printf("listener state sigAddr=%llu probeAddr=%llu probeSeq=%llu probeFlags=%llu productionCtor=%llu productionPID=%llu productionStart=%llu output=%llu remote=%llu photo=%llu replacement=%llu lastKind=%llu lastCount=%llu lastDimensions=%ux%u lastFormat=0x%llx\n",
                   (unsigned long long)sigAddr,
                   (unsigned long long)probeAddr,
                   (unsigned long long)probeSequence,
                   (unsigned long long)probeFlags,
                   (unsigned long long)productionCtor,
                   (unsigned long long)productionPID,
                   (unsigned long long)productionStart,
                   (unsigned long long)productionOutputCount,
                   (unsigned long long)productionRemoteCount,
                   (unsigned long long)productionPhotoCount,
                   (unsigned long long)productionReplacementCount,
                   (unsigned long long)productionLastKind,
                   (unsigned long long)productionLastCount,
                   (unsigned int)(productionLastDimensions >> 32),
                   (unsigned int)productionLastDimensions,
                   (unsigned long long)productionLastFormat);
            fflush(stdout);
            reportedInitialState = 1;
        }
        static uint64_t lastProductionPID = 0;
        static uint64_t lastProductionStart = 0;
        static uint64_t lastProductionOutput = 0;
        static uint64_t lastProductionRemote = 0;
        static uint64_t lastProductionPhoto = 0;
        static uint64_t lastProductionReplacement = 0;
        if (productionPID != lastProductionPID || productionStart != lastProductionStart) {
            record_line("/var/tmp/vcam-ios18-probe-events.log", "VCAM-PRODUCTION",
                        productionPID, productionCtor != 0 ? "constructor-loaded" : "not-loaded");
            printf("production identity pid=%llu start=%llu ctor=%llu\n",
                   (unsigned long long)productionPID,
                   (unsigned long long)productionStart,
                   (unsigned long long)productionCtor);
            fflush(stdout);
            lastProductionPID = productionPID;
            lastProductionStart = productionStart;
        }
        if (productionOutputCount != lastProductionOutput) {
            printf("production output-count=%llu\n", (unsigned long long)productionOutputCount);
            fflush(stdout);
            lastProductionOutput = productionOutputCount;
        }
        if (productionRemoteCount != lastProductionRemote) {
            printf("production remote-count=%llu\n", (unsigned long long)productionRemoteCount);
            fflush(stdout);
            lastProductionRemote = productionRemoteCount;
        }
        if (productionPhotoCount != lastProductionPhoto) {
            printf("production photo-count=%llu\n", (unsigned long long)productionPhotoCount);
            fflush(stdout);
            lastProductionPhoto = productionPhotoCount;
        }
        if (productionReplacementCount != lastProductionReplacement) {
            printf("production replacement-count=%llu route=%llu\n",
                   (unsigned long long)productionReplacementCount,
                   (unsigned long long)productionReplacementRoute);
            fflush(stdout);
            lastProductionReplacement = productionReplacementCount;
        }
        if (probeFlags != lastProbeFlags) {
            record_probe_flags(probeFlags, lastProbeFlags);
            lastProbeFlags = probeFlags;
        }
        if (probeCount != lastProbeCount && probeCount != 0) {
            uint32_t width = (uint32_t)(probeDimensions >> 32);
            uint32_t height = (uint32_t)probeDimensions;
            char message[256];
            snprintf(message, sizeof(message),
                     "count=%llu dimensions=%ux%u format=0x%llx",
                     (unsigned long long)probeCount, width, height,
                     (unsigned long long)probeFormat);
            record_line("/var/tmp/vcam-ios18-probe-events.log",
                        "VCAMPROBE-EMIT", probeCount, message);
            lastProbeCount = probeCount;
        }
        if ((check != 0 || probeCheck != 0 ||
             probeSequence > lastProbeSequence) &&
            (sigAddr != 0 || probeAddr != 0)) {
            pid_t pid = find_cameracaptured();
            mach_port_t task = MACH_PORT_NULL;
            kern_return_t taskResult = pid > 0
                ? task_for_pid(mach_task_self(), pid, &task)
                : KERN_INVALID_ARGUMENT;
            if (pid > 0 && taskResult == KERN_SUCCESS) {
                if (check != 0 && sigAddr != 0) {
                    char buf[VCAMProbeMessageCapacity] = {0};
                    if (read_remote(task, sigAddr, buf, sizeof(buf) - 1) == KERN_SUCCESS) {
                        buf[sizeof(buf) - 1] = '\0';
                        record_line("/var/tmp/vcam-ios18-sigs.log",
                                    "VCAM-SIGNATURE", 0, buf);
                    }
                }
                if (probeSequence > lastProbeSequence && probeAddr != 0) {
                    VCAMProbeEvent events[VCAMProbeEventCapacity] = {0};
                    if (read_remote(task, probeAddr, events, sizeof(events)) == KERN_SUCCESS) {
                        uint64_t first = lastProbeSequence + 1;
                        if (probeSequence - first >= VCAMProbeEventCapacity) {
                            first = probeSequence - VCAMProbeEventCapacity + 1;
                        }
                        for (uint64_t sequence = first;
                             sequence <= probeSequence; sequence++) {
                            VCAMProbeEvent *event = &events[
                                (sequence - 1) % VCAMProbeEventCapacity];
                            if (event->sequence == sequence) {
                                event->message[VCAMProbeMessageCapacity - 1] = '\0';
                                record_line("/var/tmp/vcam-ios18-probe-events.log",
                                            "VCAMPROBE-NOTIFY", sequence,
                                            event->message);
                            }
                        }
                        lastProbeSequence = probeSequence;
                    }
                }
                mach_port_deallocate(mach_task_self(), task);
            } else if (!reportedTaskFailure) {
                printf("listener task_for_pid failed pid=%d kr=%d probeCheck=%d probeSeq=%llu\n",
                       pid, taskResult, probeCheck,
                       (unsigned long long)probeSequence);
                fflush(stdout);
                reportedTaskFailure = 1;
            }
        }
        usleep(100000);
    }
    return 0;
}

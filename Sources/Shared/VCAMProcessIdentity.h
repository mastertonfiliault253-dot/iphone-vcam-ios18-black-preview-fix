#pragma once

#include <stdint.h>
#include <string.h>
#include <sys/sysctl.h>
#include <sys/types.h>

/// Stable identity for one process lifetime. PID alone is unsafe because iOS
/// reuses it; KERN_PROC_PID exposes the public process start timestamp.
static inline uint64_t VCAMProcessStartToken(pid_t pid) {
    if (pid <= 0) return 0;
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
    struct kinfo_proc process;
    memset(&process, 0, sizeof(process));
    size_t size = sizeof(process);
    if (sysctl(mib, 4, &process, &size, NULL, 0) != 0 ||
        size < sizeof(process) || process.kp_proc.p_starttime.tv_sec <= 0) {
        return 0;
    }
    return (uint64_t)process.kp_proc.p_starttime.tv_sec * 1000000ULL +
        (uint64_t)process.kp_proc.p_starttime.tv_usec;
}

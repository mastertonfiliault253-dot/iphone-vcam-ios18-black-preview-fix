// vcam-ios18-probe.m
// Standalone (no-substrate) probe. Uses ObjC +load (guaranteed on dlopen) plus
// a constructor fallback. Verifies inside cameracaptured that BWNodeOutput
// resolves and emitSampleBuffer: is called.

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <notify.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <fcntl.h>
#include <stdint.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <stdarg.h>
#include <pthread.h>
#include <mach-o/dyld.h>
#include <sys/time.h>

static const char *g_log_paths[] = {
    "/var/jb/Library/MobileSubstrate/DynamicLibraries/vcam-ios18-probe.log",
    "/var/jb/var/tmp/vcam-ios18-probe.log",
    "/var/jb/tmp/vcam-ios18-probe.log",
    "/var/tmp/vcam-ios18-probe.log",
    NULL,
};

static int g_fd = -1;
static pthread_mutex_t g_mutex = PTHREAD_MUTEX_INITIALIZER;

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

// cameracaptured cannot reliably write any of the usual log locations. Keep
// the bounded event ring in this image and publish only its address/sequence
// through Darwin notify; the separate root listener reads it with task_for_pid.
static VCAMProbeEvent g_probe_events[VCAMProbeEventCapacity] = {0};
static uint64_t g_probe_sequence = 0;
static int g_probe_addr_token = -1;
static int g_probe_sequence_token = -1;
static pthread_mutex_t g_notify_mutex = PTHREAD_MUTEX_INITIALIZER;
static uint64_t g_probe_flags = 0;
static uint64_t g_probe_count = 0;
static uint64_t g_probe_dimensions = 0;
static uint64_t g_probe_format = 0;
static int g_probe_flags_token = -1;
static int g_probe_count_token = -1;
static int g_probe_dimensions_token = -1;
static int g_probe_format_token = -1;

static void probe_set_state_unlocked(int *token, const char *stateName,
                                     uint64_t value) {
    if (*token < 0) {
        notify_register_check(stateName, token);
    }
    if (*token >= 0) notify_set_state(*token, value);
}

static void probe_publish_flag_unlocked(uint64_t flag) {
    g_probe_flags |= flag;
    probe_set_state_unlocked(&g_probe_flags_token,
                             "com.codex.vcam.ios18.probe.flags.state",
                             g_probe_flags);
    notify_post("com.codex.vcam.ios18.probe.flags");
}

static void probe_notify(const char *msg) {
    pthread_mutex_lock(&g_notify_mutex);
    if (g_probe_addr_token < 0) {
        notify_register_check("com.codex.vcam.ios18.probe.addr",
                              &g_probe_addr_token);
    }
    if (g_probe_sequence_token < 0) {
        notify_register_check("com.codex.vcam.ios18.probe.sequence",
                              &g_probe_sequence_token);
    }
    if (g_probe_addr_token < 0 || g_probe_sequence_token < 0) {
        pthread_mutex_unlock(&g_notify_mutex);
        return;
    }

    uint64_t sequence = g_probe_sequence + 1;
    VCAMProbeEvent *event = &g_probe_events[
        (sequence - 1) % VCAMProbeEventCapacity];
    event->sequence = 0;
    strlcpy(event->message, msg ? msg : "(null)",
            sizeof(event->message));
    __sync_synchronize();
    event->sequence = sequence;
    g_probe_sequence = sequence;
    notify_set_state(g_probe_addr_token,
                     (uint64_t)(uintptr_t)g_probe_events);
    notify_set_state(g_probe_sequence_token, sequence);
    notify_post("com.codex.vcam.ios18.probe");
    pthread_mutex_unlock(&g_notify_mutex);
}

static void probe_publish_emit_unlocked(uint64_t count, size_t width,
                                        size_t height, OSType format) {
    g_probe_count = count;
    g_probe_dimensions = ((uint64_t)(uint32_t)width << 32) |
        (uint64_t)(uint32_t)height;
    g_probe_format = (uint64_t)format;
    probe_set_state_unlocked(&g_probe_count_token,
                             "com.codex.vcam.ios18.probe.count.state",
                             g_probe_count);
    probe_set_state_unlocked(&g_probe_dimensions_token,
                             "com.codex.vcam.ios18.probe.dimensions.state",
                             g_probe_dimensions);
    probe_set_state_unlocked(&g_probe_format_token,
                             "com.codex.vcam.ios18.probe.format.state",
                             g_probe_format);
    probe_publish_flag_unlocked(VCAMProbeFlagEmit);
    notify_post("com.codex.vcam.ios18.probe.emit");
}

static void probe_log(const char *msg) {
    probe_notify(msg);
    NSLog(@"VCAMPROBE %s", msg);
    pthread_mutex_lock(&g_mutex);
    if (g_fd < 0) {
        for (int i = 0; g_log_paths[i]; i++) {
            int fd = open(g_log_paths[i], O_WRONLY | O_CREAT | O_APPEND, 0644);
            if (fd >= 0) {
                g_fd = fd;
                char p[256];
                snprintf(p, sizeof(p), "log_path=%s\n", g_log_paths[i]);
                write(fd, p, strlen(p));
                break;
            }
        }
    }
    if (g_fd >= 0) {
        write(g_fd, msg, strlen(msg));
        fsync(g_fd);
    }
    pthread_mutex_unlock(&g_mutex);
}

static void probe_logf(const char *fmt, ...) {
    char buf[768];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    probe_log(buf);
}

static void (*orig_emitSampleBuffer)(id, SEL, void *) = NULL;
static void (*orig_remoteRender)(id, SEL, void *, id) = NULL;
static void (*orig_photoRender)(id, SEL, void *, id) = NULL;
static int g_probed = 0;

static void probe_publish_call(uint64_t flag, void *sampleBuffer) {
    size_t width = 0;
    size_t height = 0;
    OSType format = 0;
    CMSampleBufferRef sb = (CMSampleBufferRef)sampleBuffer;
    CVPixelBufferRef pb = sb ? CMSampleBufferGetImageBuffer(sb) : NULL;
    if (pb != NULL) {
        width = CVPixelBufferGetWidth(pb);
        height = CVPixelBufferGetHeight(pb);
        format = CVPixelBufferGetPixelFormatType(pb);
    }
    pthread_mutex_lock(&g_notify_mutex);
    probe_publish_flag_unlocked(flag);
    probe_publish_emit_unlocked(1, width, height, format);
    pthread_mutex_unlock(&g_notify_mutex);
}

static void hooked_emitSampleBuffer(id self, SEL _cmd, void *sampleBuffer) {
    static volatile long s_count = 0;
    long n = __sync_add_and_fetch(&s_count, 1);
    if (n <= 8 || n % 300 == 0) {
        CMSampleBufferRef sb = (CMSampleBufferRef)sampleBuffer;
        CVPixelBufferRef pb = sb ? CMSampleBufferGetImageBuffer(sb) : NULL;
        size_t w = pb ? CVPixelBufferGetWidth(pb) : 0;
        size_t h = pb ? CVPixelBufferGetHeight(pb) : 0;
        OSType fmt = pb ? CVPixelBufferGetPixelFormatType(pb) : 0;
        char fc[5] = {0};
        fc[0] = (char)((fmt >> 24) & 0xff);
        fc[1] = (char)((fmt >> 16) & 0xff);
        fc[2] = (char)((fmt >> 8) & 0xff);
        fc[3] = (char)(fmt & 0xff);
        probe_logf("emitSampleBuffer count=%ld self=%p sb=%p pb=%p %zux%zu fmt=%s\n",
                   n, self, sb, pb, w, h, fc);
        pthread_mutex_lock(&g_notify_mutex);
        probe_publish_emit_unlocked((uint64_t)n, w, h, fmt);
        pthread_mutex_unlock(&g_notify_mutex);
    }
    if (orig_emitSampleBuffer) {
        orig_emitSampleBuffer(self, _cmd, sampleBuffer);
    }
}

static void hooked_remoteRender(id self, SEL _cmd, void *sampleBuffer, id input) {
    (void)self;
    (void)input;
    probe_publish_call(VCAMProbeFlagRemoteCalled, sampleBuffer);
    if (orig_remoteRender) orig_remoteRender(self, _cmd, sampleBuffer, input);
}

static void hooked_photoRender(id self, SEL _cmd, void *sampleBuffer, id input) {
    (void)self;
    (void)input;
    probe_publish_call(VCAMProbeFlagPhotoCalled, sampleBuffer);
    if (orig_photoRender) orig_photoRender(self, _cmd, sampleBuffer, input);
}

static void probe_publish_loaded_image_flags(void) {
    BOOL production = NO;
    BOOL substrate = NO;
    for (uint32_t index = 0; index < _dyld_image_count(); index++) {
        const char *name = _dyld_get_image_name(index);
        if (name == NULL) continue;
        if (strstr(name, "VCAMMediaServerClient") != NULL) production = YES;
        if (strstr(name, "substrate") != NULL ||
            strstr(name, "ElleKit") != NULL) substrate = YES;
    }
    pthread_mutex_lock(&g_notify_mutex);
    if (production) probe_publish_flag_unlocked(VCAMProbeFlagProductionImage);
    if (substrate) probe_publish_flag_unlocked(VCAMProbeFlagSubstrateImage);
    pthread_mutex_unlock(&g_notify_mutex);
}

static void probe_hook_class(Class cls, SEL sel, IMP replacement, IMP *original,
                             uint64_t classFlag, uint64_t methodFlag,
                             uint64_t swizzledFlag) {
    if (cls == Nil) return;
    pthread_mutex_lock(&g_notify_mutex);
    probe_publish_flag_unlocked(classFlag);
    pthread_mutex_unlock(&g_notify_mutex);
    Method method = class_getInstanceMethod(cls, sel);
    if (method == NULL) {
        return;
    }
    pthread_mutex_lock(&g_notify_mutex);
    probe_publish_flag_unlocked(methodFlag);
    pthread_mutex_unlock(&g_notify_mutex);
    IMP old = method_setImplementation(method, replacement);
    *original = old;
    pthread_mutex_lock(&g_notify_mutex);
    probe_publish_flag_unlocked(swizzledFlag);
    pthread_mutex_unlock(&g_notify_mutex);
}

static void do_probe(void) {
    if (g_probed) return;
    g_probed = 1;

    pthread_mutex_lock(&g_notify_mutex);
    // Reset process-global notify state so a newly injected probe is not
    // mistaken for the previous process instance by the root listener.
    probe_set_state_unlocked(&g_probe_flags_token,
                             "com.codex.vcam.ios18.probe.flags.state", 0);
    probe_set_state_unlocked(&g_probe_count_token,
                             "com.codex.vcam.ios18.probe.count.state", 0);
    probe_publish_flag_unlocked(VCAMProbeFlagStarted);
    pthread_mutex_unlock(&g_notify_mutex);

    probe_publish_loaded_image_flags();

    struct timeval tv = {0};
    gettimeofday(&tv, NULL);
    probe_logf("PROBE pid=%d t=%ld.%03d\n", getpid(), (long)tv.tv_sec, (int)(tv.tv_usec / 1000));

    Class cls = objc_getClass("BWNodeOutput");
    probe_logf("BWNodeOutput class=%p name=%s\n", cls, cls ? class_getName(cls) : "(nil)");

    if (cls) {
        pthread_mutex_lock(&g_notify_mutex);
        probe_publish_flag_unlocked(VCAMProbeFlagClassFound);
        pthread_mutex_unlock(&g_notify_mutex);
        SEL sel = sel_registerName("emitSampleBuffer:");
        Method m = class_getInstanceMethod(cls, sel);
        if (m) {
            pthread_mutex_lock(&g_notify_mutex);
            probe_publish_flag_unlocked(VCAMProbeFlagMethodFound);
            pthread_mutex_unlock(&g_notify_mutex);
            const char *enc = method_getTypeEncoding(m);
            probe_logf("emitSampleBuffer: method=%p selector=%s type=%s\n",
                       m, sel_getName(method_getName(m)), enc ? enc : "(nil)");
            IMP old = method_setImplementation(m, (IMP)hooked_emitSampleBuffer);
            orig_emitSampleBuffer = (void (*)(id, SEL, void *))old;
            pthread_mutex_lock(&g_notify_mutex);
            probe_publish_flag_unlocked(VCAMProbeFlagSwizzled);
            pthread_mutex_unlock(&g_notify_mutex);
            probe_logf("swizzled emitSampleBuffer: old_imp=%p new_imp=%p\n",
                       (void *)old, (void *)hooked_emitSampleBuffer);
        } else {
            pthread_mutex_lock(&g_notify_mutex);
            probe_publish_flag_unlocked(VCAMProbeFlagMethodMissing);
            pthread_mutex_unlock(&g_notify_mutex);
            probe_log("emitSampleBuffer: method NOT found\n");
        }
    } else {
        pthread_mutex_lock(&g_notify_mutex);
        probe_publish_flag_unlocked(VCAMProbeFlagClassMissing);
        pthread_mutex_unlock(&g_notify_mutex);
    }

    probe_hook_class(objc_getClass("BWRemoteQueueSinkNode"),
                     sel_registerName("renderSampleBuffer:forInput:"),
                     (IMP)hooked_remoteRender, (IMP *)&orig_remoteRender,
                     VCAMProbeFlagRemoteClassFound,
                     VCAMProbeFlagRemoteMethodFound,
                     VCAMProbeFlagRemoteSwizzled);
    probe_hook_class(objc_getClass("BWPhotoEncoderNode"),
                     sel_registerName("renderSampleBuffer:forInput:"),
                     (IMP)hooked_photoRender, (IMP *)&orig_photoRender,
                     VCAMProbeFlagPhotoClassFound,
                     VCAMProbeFlagPhotoMethodFound,
                     VCAMProbeFlagPhotoSwizzled);
    pthread_mutex_lock(&g_notify_mutex);
    probe_publish_flag_unlocked(VCAMProbeFlagDone);
    pthread_mutex_unlock(&g_notify_mutex);
    probe_log("PROBE DONE\n");
}

@interface VCAMProbe : NSObject
@end
@implementation VCAMProbe
+ (void)load {
    do_probe();
}
@end

__attribute__((constructor))
void vcam_ios18_probe_ctor(void) {
    do_probe();
}

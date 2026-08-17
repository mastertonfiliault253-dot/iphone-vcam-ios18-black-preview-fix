// vcam-ios18-probe.m
// Standalone (no-substrate) probe to verify, inside cameracaptured:
//   1. constructors run under opainject;
//   2. BWNodeOutput class resolves;
//   3. emitSampleBuffer: method resolves and is swizzlable;
//   4. emitSampleBuffer: is actually called (frames flow through it).
// Built as a plain arm64e dylib. No CydiaSubstrate / ElleKit / Theos %hook.

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <stdarg.h>
#include <pthread.h>
#include <sys/time.h>

#define PROBE_LOG "/var/tmp/vcam-ios18-probe.log"

static int g_fd = -1;
static pthread_mutex_t g_mutex = PTHREAD_MUTEX_INITIALIZER;

static void probe_log(const char *msg) {
    pthread_mutex_lock(&g_mutex);
    if (g_fd < 0) {
        g_fd = open(PROBE_LOG, O_WRONLY | O_CREAT | O_APPEND, 0644);
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
    }
    if (orig_emitSampleBuffer) {
        orig_emitSampleBuffer(self, _cmd, sampleBuffer);
    }
}

__attribute__((constructor))
static void probe_ctor(void) {
    char buf[512];
    struct timeval tv = {0};
    gettimeofday(&tv, NULL);
    probe_logf("PROBE CTOR pid=%d t=%ld.%03d\n", getpid(), (long)tv.tv_sec, (int)(tv.tv_usec / 1000));

    Class cls = objc_getClass("BWNodeOutput");
    probe_logf("BWNodeOutput class=%p name=%s\n", cls, cls ? class_getName(cls) : "(nil)");

    if (cls) {
        SEL sel = sel_registerName("emitSampleBuffer:");
        Method m = class_getInstanceMethod(cls, sel);
        if (m) {
            const char *enc = method_getTypeEncoding(m);
            probe_logf("emitSampleBuffer: method=%p selector=%s type=%s\n",
                       m, sel_getName(method_getName(m)), enc ? enc : "(nil)");
            IMP old = method_setImplementation(m, (IMP)hooked_emitSampleBuffer);
            orig_emitSampleBuffer = (void (*)(id, SEL, void *))old;
            probe_logf("swizzled emitSampleBuffer: old_imp=%p new_imp=%p\n",
                       (void *)old, (void *)hooked_emitSampleBuffer);
        } else {
            probe_log("emitSampleBuffer: method NOT found\n");
        }
    }
    probe_log("PROBE CTOR DONE\n");
}

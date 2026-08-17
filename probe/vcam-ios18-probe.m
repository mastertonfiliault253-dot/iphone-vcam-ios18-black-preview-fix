// vcam-ios18-probe.m
// Standalone (no-substrate) probe. Uses ObjC +load (guaranteed on dlopen) plus
// a constructor fallback. Verifies inside cameracaptured that BWNodeOutput
// resolves and emitSampleBuffer: is called.

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

static const char *g_log_paths[] = {
    "/var/jb/Library/MobileSubstrate/DynamicLibraries/vcam-ios18-probe.log",
    "/var/jb/var/tmp/vcam-ios18-probe.log",
    "/var/jb/tmp/vcam-ios18-probe.log",
    "/var/tmp/vcam-ios18-probe.log",
    NULL,
};

static int g_fd = -1;
static pthread_mutex_t g_mutex = PTHREAD_MUTEX_INITIALIZER;

static void probe_log(const char *msg) {
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
static int g_probed = 0;

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

static void do_probe(void) {
    if (g_probed) return;
    g_probed = 1;

    struct timeval tv = {0};
    gettimeofday(&tv, NULL);
    probe_logf("PROBE pid=%d t=%ld.%03d\n", getpid(), (long)tv.tv_sec, (int)(tv.tv_usec / 1000));

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

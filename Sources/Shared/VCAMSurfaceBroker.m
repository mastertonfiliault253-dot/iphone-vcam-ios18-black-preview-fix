#import "VCAMSurfaceBroker.h"

#import <Foundation/Foundation.h>

#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

// Xcode ships the private-on-iOS XPC declarations while the Linux iPhoneOS
// 16.5 SDK does not. Use the system types where present and keep the narrow ABI
// fallback only for that header-less toolchain.
#if __has_include(<xpc/xpc.h>)
#import <xpc/xpc.h>
#define VCAM_HAS_SYSTEM_XPC 1
#else
#define VCAM_HAS_SYSTEM_XPC 0
typedef void *xpc_object_t;
typedef xpc_object_t xpc_connection_t;
typedef const void *xpc_type_t;

extern void xpc_connection_set_event_handler(
    xpc_connection_t connection, void (^handler)(xpc_object_t event));
extern void xpc_connection_resume(xpc_connection_t connection);
extern void xpc_connection_send_message(xpc_connection_t connection,
                                        xpc_object_t message);
extern void xpc_connection_send_message_with_reply(
    xpc_connection_t connection, xpc_object_t message,
                                        dispatch_queue_t replyQueue, void (^handler)(xpc_object_t reply));
extern xpc_object_t xpc_connection_send_message_with_reply_sync(
    xpc_connection_t connection, xpc_object_t message);
extern xpc_type_t xpc_get_type(xpc_object_t object);
extern xpc_object_t xpc_dictionary_create(
    const char *const _Nullable *keys,
    const xpc_object_t _Nullable *values, size_t count);
extern const char *_Nullable xpc_dictionary_get_string(xpc_object_t dictionary,
                                                        const char *key);
extern uint64_t xpc_dictionary_get_uint64(xpc_object_t dictionary,
                                          const char *key);
extern int xpc_dictionary_dup_fd(xpc_object_t dictionary, const char *key);
extern xpc_object_t _Nullable xpc_dictionary_get_value(xpc_object_t dictionary,
                                                        const char *key);
extern void xpc_dictionary_set_string(xpc_object_t dictionary, const char *key,
                                      const char *value);
extern void xpc_dictionary_set_uint64(xpc_object_t dictionary, const char *key,
                                      uint64_t value);
extern void xpc_dictionary_set_double(xpc_object_t dictionary, const char *key,
                                      double value);
extern double xpc_dictionary_get_double(xpc_object_t dictionary,
                                        const char *key);
extern void xpc_dictionary_set_value(xpc_object_t dictionary, const char *key,
                                     xpc_object_t value);
extern xpc_object_t xpc_data_create(const void *bytes, size_t length);
const void *xpc_data_get_bytes_ptr(xpc_object_t data);
size_t xpc_data_get_length(xpc_object_t data);
void xpc_dictionary_set_data(xpc_object_t dictionary, const char *key,
                             const void *bytes, size_t length);
const void *xpc_dictionary_get_data(xpc_object_t dictionary, const char *key,
                                    size_t *length);
void xpc_retain(xpc_object_t object);
void xpc_release(xpc_object_t object);
extern const struct _xpc_type_s _xpc_type_dictionary;
#endif

#if VCAM_HAS_SYSTEM_XPC && defined(OS_OBJECT_USE_OBJC) && OS_OBJECT_USE_OBJC
#define VCAMXPCRelease(object) ((void)(object))
#else
#define VCAMXPCRelease(object) xpc_release(object)
#endif

extern xpc_object_t IOSurfaceCreateXPCObject(IOSurfaceRef surface);
extern IOSurfaceRef _Nullable IOSurfaceLookupFromXPCObject(xpc_object_t object)
    CF_RETURNS_RETAINED;
extern uint32_t IOSurfaceGetID(IOSurfaceRef surface);

static const char *const VCAMSurfaceBrokerService = "com.codex.vcam.surface";
static const uint64_t VCAMXPCMachServicePrivileged = 1ULL << 1;
static const char *const VCAMSurfaceKeys[] = {
    "surface0", "surface1", "surface2",
};

static xpc_type_t VCAMXPCTypeDictionary(void) {
#if VCAM_HAS_SYSTEM_XPC
    return XPC_TYPE_DICTIONARY;
#else
    return (xpc_type_t)&_xpc_type_dictionary;
#endif
}

#if !VCAM_HAS_SYSTEM_XPC
extern const struct _xpc_type_s _xpc_type_connection;
#endif

static xpc_type_t VCAMXPCTypeConnection(void) {
#if VCAM_HAS_SYSTEM_XPC
    return XPC_TYPE_CONNECTION;
#else
    return (xpc_type_t)&_xpc_type_connection;
#endif
}

#if !VCAM_HAS_SYSTEM_XPC
extern const struct _xpc_type_s _xpc_type_error;
#endif

static xpc_type_t VCAMXPCTypeError(void) {
#if VCAM_HAS_SYSTEM_XPC
    return XPC_TYPE_ERROR;
#else
    return (xpc_type_t)&_xpc_type_error;
#endif
}

typedef xpc_connection_t (*VCAMXPCMachServiceCreateFunction)(
    const char *name, dispatch_queue_t _Nullable targetQueue, uint64_t flags);

static xpc_connection_t VCAMXPCMachServiceCreate(
    const char *name, dispatch_queue_t queue, uint64_t flags) {
    static VCAMXPCMachServiceCreateFunction createFunction;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *symbol = dlsym(RTLD_DEFAULT,
                             "xpc_connection_create_mach_service");
        memcpy(&createFunction, &symbol, sizeof(createFunction));
    });
    return createFunction != NULL ? createFunction(name, queue, flags) : NULL;
}

// xpc_connection_is_valid is public API but absent from the Linux iPhoneOS
// 16.5 stub library, so resolve it the same way as the mach-service creator.
static BOOL VCAMXPCConnectionIsValid(xpc_connection_t connection) {
    static BOOL (*isValidFunction)(xpc_connection_t);
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *symbol = dlsym(RTLD_DEFAULT, "xpc_connection_is_valid");
        memcpy(&isValidFunction, &symbol, sizeof(isValidFunction));
    });
    // Without the symbol we cannot tell peer death from an ordinary event;
    // treat connections as valid (announce) rather than rebuild endlessly.
    return isValidFunction != NULL ? (isValidFunction(connection) ? YES : NO) : YES;
}

static xpc_connection_t VCAMPublisherConnection;
static dispatch_once_t VCAMPublisherOnce;

static xpc_connection_t VCAMSurfaceBrokerPublisherConnection(void) {
    dispatch_once(&VCAMPublisherOnce, ^{
        dispatch_queue_t queue = dispatch_queue_create(
            "com.codex.vcam.surface.publisher", DISPATCH_QUEUE_SERIAL);
        VCAMPublisherConnection = VCAMXPCMachServiceCreate(
            VCAMSurfaceBrokerService, queue, VCAMXPCMachServicePrivileged);
        if (VCAMPublisherConnection == NULL) return;
        xpc_connection_set_event_handler(VCAMPublisherConnection,
                                          ^(xpc_object_t event) { (void)event; });
        xpc_connection_resume(VCAMPublisherConnection);
    });
    return VCAMPublisherConnection;
}

void VCAMSurfaceBrokerPublish(IOSurfaceRef const *surfaces, uint32_t count) {
    if (surfaces == NULL || !VCAMSurfaceBrokerSlotCountIsValid(count)) return;
    xpc_connection_t connection = VCAMSurfaceBrokerPublisherConnection();
    if (connection == NULL) return;
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(message, "command", "publish");
    struct timespec now = {0};
    clock_gettime(CLOCK_MONOTONIC, &now);
    uint64_t generation = (uint64_t)now.tv_sec * 1000000000ULL + now.tv_nsec;
    xpc_dictionary_set_uint64(message, "generation", generation);
    xpc_dictionary_set_uint64(message, "slotCount", count);
    for (uint32_t slot = 0; slot < count; slot++) {
        if (surfaces[slot] == NULL) continue;
        xpc_object_t object = IOSurfaceCreateXPCObject(surfaces[slot]);
        if (object == NULL) continue;
        xpc_dictionary_set_value(message, VCAMSurfaceKeys[slot], object);
        VCAMXPCRelease(object);
    }
    xpc_connection_send_message(connection, message);
    VCAMXPCRelease(message);
}

static pthread_mutex_t VCAMSubscriberLock = PTHREAD_MUTEX_INITIALIZER;
static IOSurfaceRef VCAMSubscriberSurfaces[VCAMSurfaceBrokerVideoSlotCount];
static int VCAMSubscriberFrameDescriptor = -1;
static int VCAMSubscriberSurfaceDescriptor = -1;
static xpc_connection_t VCAMSubscriberConnection;
static dispatch_queue_t VCAMSubscriberQueue;
static dispatch_once_t VCAMSubscriberOnce;
static _Atomic(uint64_t) VCAMSubscriberLastRequestNanoseconds;
static _Atomic(int32_t) VCAMSubscriberStatus;

enum {
    VCAMSubscriberStatusWaiting = 0,
    VCAMSubscriberStatusConnectionUnavailable = 1,
    VCAMSubscriberStatusInvalidReply = 2,
    VCAMSubscriberStatusInvalidRegistry = 3,
    VCAMSubscriberStatusImportFailed = 4,
    VCAMSubscriberStatusReady = 5,
    VCAMSubscriberStatusSurfaceMiss = 6,
};

static xpc_connection_t VCAMSurfaceBrokerSubscriberConnection(void) {
    dispatch_once(&VCAMSubscriberOnce, ^{
        VCAMSubscriberQueue = dispatch_queue_create(
            "com.codex.vcam.surface.subscriber", DISPATCH_QUEUE_SERIAL);
        VCAMSubscriberConnection = VCAMXPCMachServiceCreate(
            VCAMSurfaceBrokerService, VCAMSubscriberQueue,
            VCAMXPCMachServicePrivileged);
        if (VCAMSubscriberConnection == NULL) {
            atomic_store_explicit(&VCAMSubscriberStatus,
                                  VCAMSubscriberStatusConnectionUnavailable,
                                  memory_order_release);
            return;
        }
        xpc_connection_set_event_handler(VCAMSubscriberConnection,
                                          ^(xpc_object_t event) { (void)event; });
        xpc_connection_resume(VCAMSubscriberConnection);
    });
    return VCAMSubscriberConnection;
}

void VCAMSurfaceBrokerRequestRegistry(void) {
    struct timespec now = {0};
    clock_gettime(CLOCK_MONOTONIC, &now);
    uint64_t nanoseconds = (uint64_t)now.tv_sec * 1000000000ULL + now.tv_nsec;
    uint64_t previous = atomic_load_explicit(
        &VCAMSubscriberLastRequestNanoseconds, memory_order_acquire);
    if (previous != 0 && nanoseconds > previous &&
        nanoseconds - previous < 1000000000ULL) return;
    atomic_store_explicit(&VCAMSubscriberLastRequestNanoseconds, nanoseconds,
                          memory_order_release);
    xpc_connection_t connection = VCAMSurfaceBrokerSubscriberConnection();
    if (connection == NULL) return;
    xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(request, "command", "get");
    xpc_connection_send_message_with_reply(
        connection, request, VCAMSubscriberQueue, ^(xpc_object_t reply) {
            if (xpc_get_type(reply) != VCAMXPCTypeDictionary() ||
                strcmp(xpc_dictionary_get_string(reply, "command") ?: "",
                       "registry") != 0) {
                atomic_store_explicit(&VCAMSubscriberStatus,
                                      VCAMSubscriberStatusInvalidReply,
                                      memory_order_release);
                return;
            }
            uint64_t slotCount = xpc_dictionary_get_uint64(reply, "slotCount");
            if (!VCAMSurfaceBrokerSlotCountIsValid(slotCount)) {
                atomic_store_explicit(&VCAMSubscriberStatus,
                                      VCAMSubscriberStatusInvalidRegistry,
                                      memory_order_release);
                return;
            }
            int frameDescriptor = xpc_dictionary_dup_fd(reply, "frameFD");
            int surfaceDescriptor = xpc_dictionary_dup_fd(reply, "surfaceFD");
            IOSurfaceRef replacements[VCAMSurfaceBrokerVideoSlotCount] = {0};
            uint32_t imported = 0;
            for (uint32_t slot = 0; slot < slotCount; slot++) {
                xpc_object_t object = xpc_dictionary_get_value(
                    reply, VCAMSurfaceKeys[slot]);
                if (object != NULL) {
                    replacements[slot] = IOSurfaceLookupFromXPCObject(object);
                    if (replacements[slot] != NULL) imported += 1;
                }
            }
            atomic_store_explicit(&VCAMSubscriberStatus,
                                  imported == slotCount
                                      ? VCAMSubscriberStatusReady
                                      : VCAMSubscriberStatusImportFailed,
                                  memory_order_release);
            pthread_mutex_lock(&VCAMSubscriberLock);
            if (frameDescriptor >= 0) {
                if (VCAMSubscriberFrameDescriptor >= 0) {
                    close(VCAMSubscriberFrameDescriptor);
                }
                VCAMSubscriberFrameDescriptor = frameDescriptor;
            }
            if (surfaceDescriptor >= 0) {
                if (VCAMSubscriberSurfaceDescriptor >= 0) {
                    close(VCAMSubscriberSurfaceDescriptor);
                }
                VCAMSubscriberSurfaceDescriptor = surfaceDescriptor;
            }
            for (uint32_t slot = 0; slot < VCAMSurfaceBrokerVideoSlotCount; slot++) {
                if (VCAMSubscriberSurfaces[slot] != NULL) {
                    CFRelease(VCAMSubscriberSurfaces[slot]);
                }
                VCAMSubscriberSurfaces[slot] = replacements[slot];
            }
            pthread_mutex_unlock(&VCAMSubscriberLock);
        });
    VCAMXPCRelease(request);
}

IOSurfaceRef VCAMSurfaceBrokerCopySurface(uint32_t surfaceID) {
    IOSurfaceRef result = NULL;
    pthread_mutex_lock(&VCAMSubscriberLock);
    for (uint32_t slot = 0; slot < VCAMSurfaceBrokerVideoSlotCount; slot++) {
        IOSurfaceRef candidate = VCAMSubscriberSurfaces[slot];
        if (candidate != NULL && IOSurfaceGetID(candidate) == surfaceID) {
            result = (IOSurfaceRef)CFRetain(candidate);
            break;
        }
    }
    pthread_mutex_unlock(&VCAMSubscriberLock);
    if (result == NULL) {
        if (atomic_load_explicit(&VCAMSubscriberStatus,
                                 memory_order_acquire) ==
            VCAMSubscriberStatusReady) {
            atomic_store_explicit(&VCAMSubscriberStatus,
                                  VCAMSubscriberStatusSurfaceMiss,
                                  memory_order_release);
        }
        VCAMSurfaceBrokerRequestRegistry();
    }
    return result;
}

const char *VCAMSurfaceBrokerSubscriberStatus(void) {
    switch (atomic_load_explicit(&VCAMSubscriberStatus, memory_order_acquire)) {
        case VCAMSubscriberStatusConnectionUnavailable: return "connection-unavailable";
        case VCAMSubscriberStatusInvalidReply: return "invalid-reply";
        case VCAMSubscriberStatusInvalidRegistry: return "invalid-registry";
        case VCAMSubscriberStatusImportFailed: return "surface-import-failed";
        case VCAMSubscriberStatusReady: return "ready";
        case VCAMSubscriberStatusSurfaceMiss: return "surface-id-miss";
        default: return "waiting-for-reply";
    }
}

int VCAMSurfaceBrokerCopySharedFrameFileDescriptor(void) {
    int result = -1;
    pthread_mutex_lock(&VCAMSubscriberLock);
    if (VCAMSubscriberFrameDescriptor >= 0) {
        result = dup(VCAMSubscriberFrameDescriptor);
    }
    pthread_mutex_unlock(&VCAMSubscriberLock);
    if (result < 0) VCAMSurfaceBrokerRequestRegistry();
    return result;
}

int VCAMSurfaceBrokerCopySharedSurfaceFileDescriptor(void) {
    int result = -1;
    pthread_mutex_lock(&VCAMSubscriberLock);
    if (VCAMSubscriberSurfaceDescriptor >= 0) {
        result = dup(VCAMSubscriberSurfaceDescriptor);
    }
    pthread_mutex_unlock(&VCAMSubscriberLock);
    if (result < 0) VCAMSurfaceBrokerRequestRegistry();
    return result;
}

bool VCAMSurfaceBrokerCopyConfigurationToken(uint64_t *high, uint64_t *low) {
    if (high == NULL || low == NULL) return false;
    *high = 0;
    *low = 0;
    xpc_connection_t connection = VCAMSurfaceBrokerPublisherConnection();
    if (connection == NULL) return false;
    xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(request, "command", "config-auth");
    xpc_object_t reply = xpc_connection_send_message_with_reply_sync(
        connection, request);
    VCAMXPCRelease(request);
    if (reply == NULL || xpc_get_type(reply) != VCAMXPCTypeDictionary() ||
        strcmp(xpc_dictionary_get_string(reply, "command") ?: "",
               "config-auth") != 0) {
        if (reply != NULL) VCAMXPCRelease(reply);
        return false;
    }
    *high = xpc_dictionary_get_uint64(reply, "tokenHigh");
    *low = xpc_dictionary_get_uint64(reply, "tokenLow");
    VCAMXPCRelease(reply);
    return *high != 0 && *low != 0;
}

bool VCAMSurfaceBrokerValidateConfigurationToken(uint64_t high, uint64_t low) {
    if (high == 0 || low == 0) return false;
    xpc_connection_t connection = VCAMSurfaceBrokerPublisherConnection();
    if (connection == NULL) return false;
    xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(request, "command", "config-auth-consume");
    xpc_dictionary_set_uint64(request, "tokenHigh", high);
    xpc_dictionary_set_uint64(request, "tokenLow", low);
    xpc_object_t reply = xpc_connection_send_message_with_reply_sync(
        connection, request);
    VCAMXPCRelease(request);
    bool accepted = reply != NULL &&
        xpc_get_type(reply) == VCAMXPCTypeDictionary() &&
        strcmp(xpc_dictionary_get_string(reply, "command") ?: "",
               "config-auth-consume") == 0 &&
        xpc_dictionary_get_uint64(reply, "accepted") == 1;
    if (reply != NULL) VCAMXPCRelease(reply);
    return accepted;
}

static bool VCAMSurfaceBrokerSendBoundedHLSRequest(
    xpc_object_t request, const char *expectedCommand,
    uint64_t *tokenHigh, uint64_t *tokenLow) {
    xpc_connection_t connection = VCAMSurfaceBrokerPublisherConnection();
    if (connection == NULL) return false;
    NSObject *gate = [NSObject new];
    dispatch_semaphore_t completion = dispatch_semaphore_create(0);
    __block BOOL waiting = YES;
    __block BOOL completed = NO;
    __block BOOL accepted = NO;
    __block uint64_t high = 0;
    __block uint64_t low = 0;
    xpc_connection_send_message_with_reply(
        connection, request,
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
        ^(xpc_object_t reply) {
            BOOL valid = reply != NULL &&
                xpc_get_type(reply) == VCAMXPCTypeDictionary() &&
                strcmp(xpc_dictionary_get_string(reply, "command") ?: "",
                       expectedCommand) == 0;
            BOOL replyAccepted = valid &&
                xpc_dictionary_get_uint64(reply, "accepted") == 1;
            uint64_t replyHigh = tokenHigh != NULL && replyAccepted ?
                xpc_dictionary_get_uint64(reply, "tokenHigh") : 0;
            uint64_t replyLow = tokenLow != NULL && replyAccepted ?
                xpc_dictionary_get_uint64(reply, "tokenLow") : 0;
            @synchronized (gate) {
                if (waiting) {
                    completed = YES;
                    accepted = replyAccepted;
                    high = replyHigh;
                    low = replyLow;
                }
            }
            dispatch_semaphore_signal(completion);
        });
    dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC);
    dispatch_semaphore_wait(completion, deadline);
    @synchronized (gate) {
        waiting = NO;
        if (!completed || !accepted) return false;
        if (tokenHigh != NULL) *tokenHigh = high;
        if (tokenLow != NULL) *tokenLow = low;
    }
    return true;
}

bool VCAMSurfaceBrokerCreateHLSProxySession(const char *upstreamURL,
                                            uint64_t sessionEpoch,
                                            uint64_t *high, uint64_t *low) {
    if (upstreamURL == NULL || sessionEpoch == 0 ||
        high == NULL || low == NULL) return false;
    *high = 0;
    *low = 0;
    uint64_t proposed[2] = {0};
    do {
        arc4random_buf(proposed, sizeof(proposed));
    } while (proposed[0] == 0 || proposed[1] == 0);
    xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(request, "command", "hls-proxy-session");
    xpc_dictionary_set_string(request, "upstreamURL", upstreamURL);
    xpc_dictionary_set_uint64(request, "sessionEpoch", sessionEpoch);
    xpc_dictionary_set_uint64(request, "tokenHigh", proposed[0]);
    xpc_dictionary_set_uint64(request, "tokenLow", proposed[1]);
    bool accepted = VCAMSurfaceBrokerSendBoundedHLSRequest(
        request, "hls-proxy-session", high, low);
    VCAMXPCRelease(request);
    accepted = accepted && *high == proposed[0] && *low == proposed[1];
    if (!accepted) {
        xpc_object_t invalidate = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_string(invalidate, "command", "hls-proxy-invalidate");
        xpc_dictionary_set_uint64(invalidate, "tokenHigh", proposed[0]);
        xpc_dictionary_set_uint64(invalidate, "tokenLow", proposed[1]);
        xpc_connection_t connection = VCAMSurfaceBrokerPublisherConnection();
        if (connection != NULL) xpc_connection_send_message(connection, invalidate);
        VCAMXPCRelease(invalidate);
        *high = 0;
        *low = 0;
    }
    return accepted;
}

bool VCAMSurfaceBrokerInvalidateHLSProxySession(uint64_t high, uint64_t low) {
    if (high == 0 || low == 0) return false;
    xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(request, "command", "hls-proxy-invalidate");
    xpc_dictionary_set_uint64(request, "tokenHigh", high);
    xpc_dictionary_set_uint64(request, "tokenLow", low);
    bool accepted = VCAMSurfaceBrokerSendBoundedHLSRequest(
        request, "hls-proxy-invalidate", NULL, NULL);
    VCAMXPCRelease(request);
    return accepted;
}

// ---------------------------------------------------------------------------
// Remote hardware decode client role (injected SpringBoard service only).
// A dedicated connection keeps decode-session traffic off the publisher and
// subscriber connections; the server pushes rtsp-hw-open/rtsp-hw-au/
// rtsp-hw-close and this side answers with open-ack/frame/error.

static xpc_connection_t VCAMRemoteDecoderConnection;
static dispatch_once_t VCAMRemoteDecoderOnce;
static dispatch_queue_t VCAMRemoteDecoderQueue;
static VCAMRemoteDecodeOpenHandler VCAMRemoteDecodeOpen;
static VCAMRemoteDecodeAUHandler VCAMRemoteDecodeAU;
static VCAMRemoteDecodeCloseHandler VCAMRemoteDecodeClose;

static void VCAMRemoteDecoderSendReady(void) {
    if (VCAMRemoteDecoderConnection == NULL) return;
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(message, "command", "rtsp-hw-ready");
    xpc_connection_send_message(VCAMRemoteDecoderConnection, message);
    VCAMXPCRelease(message);
}

static void VCAMRemoteDecoderEstablishConnection(void);

// XPC surfaces connection loss/interruption as an error-type event, never a
// connection-type one (only the listener receives those), so the error
// branch in the event handler below is the only path that sees vcamd
// restarts. The reconnect is delayed one second and de-duplicated: with the
// service entirely gone every fresh connection errors immediately, and an
// immediate rebuild would hot-spin the queue.
static void VCAMRemoteDecoderScheduleReconnect(void) {
    static BOOL reconnectPending;
    if (reconnectPending) return;
    reconnectPending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)NSEC_PER_SEC),
                   VCAMRemoteDecoderQueue, ^{
        reconnectPending = NO;
        // Rebuild unconditionally, never gated on validity: killing vcamd
        // delivers an interruption to the client, and an interrupted
        // mach-service connection keeps reporting xpc_connection_is_valid
        // == true forever (its send right stays bound to the dead task's
        // port). A validity gate here starved every rebuild in field
        // testing; only a fresh connection re-resolves the service name
        // and reaches the replacement daemon.
        VCAMRemoteDecoderEstablishConnection();
    });
}

void VCAMSurfaceBrokerStartRemoteDecoderClient(
    VCAMRemoteDecodeOpenHandler openHandler,
    VCAMRemoteDecodeAUHandler auHandler,
    VCAMRemoteDecodeCloseHandler closeHandler) {
    dispatch_once(&VCAMRemoteDecoderOnce, ^{
        VCAMRemoteDecodeOpen = [openHandler copy];
        VCAMRemoteDecodeAU = [auHandler copy];
        VCAMRemoteDecodeClose = [closeHandler copy];
        VCAMRemoteDecoderQueue = dispatch_queue_create(
            "com.codex.vcam.surface.decoder", DISPATCH_QUEUE_SERIAL);
        VCAMRemoteDecoderEstablishConnection();
    });
}

// A mach-service client only re-establishes lazily once it sends traffic,
// and this connection idles between RTSP sessions. When vcamd restarts,
// the server side drops every registered peer, so the cancelled connection
// must be rebuilt (and immediately re-announced) or no future session can
// use the remote decoder.
static void VCAMRemoteDecoderEstablishConnection(void) {
    xpc_connection_t connection = VCAMXPCMachServiceCreate(
        VCAMSurfaceBrokerService, VCAMRemoteDecoderQueue,
        VCAMXPCMachServicePrivileged);
    if (connection == NULL) return;
    xpc_connection_t staleConnection = VCAMRemoteDecoderConnection;
    VCAMRemoteDecoderConnection = connection;
    VCAMXPCRelease(staleConnection);
    xpc_connection_set_event_handler(connection,
                                      ^(xpc_object_t event) {
        if (xpc_get_type(event) == VCAMXPCTypeConnection()) {
            if (VCAMXPCConnectionIsValid(VCAMRemoteDecoderConnection)) {
                // Re-announce after the connection (re-)establishes.
                VCAMRemoteDecoderSendReady();
            } else {
                VCAMRemoteDecoderEstablishConnection();
            }
            return;
        }
        if (xpc_get_type(event) == VCAMXPCTypeError()) {
            // vcamd died or restarted: this is the only event a client ever
            // sees for it, and an interruption leaves the connection object
            // "valid", so the rebuild is scheduled instead of gated.
            NSLog(@"vcam sb decoder client: peer error, rebuild scheduled");
            VCAMRemoteDecoderScheduleReconnect();
            return;
        }
            if (xpc_get_type(event) != VCAMXPCTypeDictionary()) return;
            const char *command = xpc_dictionary_get_string(event, "command");
            if (command == NULL) return;
            uint64_t epoch = xpc_dictionary_get_uint64(event, "epoch");
            if (strcmp(command, "rtsp-hw-open") == 0) {
                size_t parameterLength = 0;
                const void *parameterData = xpc_dictionary_get_data(
                    event, "parameterData", &parameterLength);
                const char *codec = xpc_dictionary_get_string(event, "codec");
                if (VCAMRemoteDecodeOpen != nil && codec != NULL &&
                    parameterData != NULL && parameterLength > 0) {
                    VCAMRemoteDecodeOpen(
                        epoch, codec,
                        (int)xpc_dictionary_get_uint64(event, "width"),
                        (int)xpc_dictionary_get_uint64(event, "height"),
                        parameterData, parameterLength);
                }
            } else if (strcmp(command, "rtsp-hw-au") == 0) {
                size_t dataLength = 0;
                const void *data = xpc_dictionary_get_data(
                    event, "data", &dataLength);
                if (VCAMRemoteDecodeAU != nil && data != NULL &&
                    dataLength > 0) {
                    VCAMRemoteDecodeAU(
                        epoch, data, dataLength,
                        xpc_dictionary_get_double(event, "presentationSeconds"),
                        xpc_dictionary_get_uint64(event, "isKeyFrame") != 0);
                }
            } else if (strcmp(command, "rtsp-hw-close") == 0) {
                if (VCAMRemoteDecodeClose != nil) {
                    VCAMRemoteDecodeClose(epoch);
                }
            }
    });
    xpc_connection_resume(connection);
    // Announce immediately: a mach-service client buffers messages sent
    // right after resume until the connection lands (the publisher and
    // subscriber connections above rely on the same behavior).
    VCAMRemoteDecoderSendReady();
}

void VCAMSurfaceBrokerSendRemoteDecoderOpenAck(uint64_t epoch, BOOL accepted) {
    if (VCAMRemoteDecoderConnection == NULL || epoch == 0) return;
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(message, "command", "rtsp-hw-open-ack");
    xpc_dictionary_set_uint64(message, "epoch", epoch);
    xpc_dictionary_set_uint64(message, "accepted", accepted ? 1 : 0);
    xpc_connection_send_message(VCAMRemoteDecoderConnection, message);
    VCAMXPCRelease(message);
}

void VCAMSurfaceBrokerSendRemoteDecoderFrameData(
    uint64_t epoch, const void *plane0, uint32_t rowBytes0,
    const void *plane1, uint32_t rowBytes1, uint32_t height) {
    if (VCAMRemoteDecoderConnection == NULL || epoch == 0 ||
        plane0 == NULL || plane1 == NULL || rowBytes0 == 0 ||
        rowBytes1 == 0 || height == 0) {
        return;
    }
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(message, "command", "rtsp-hw-frame");
    xpc_dictionary_set_uint64(message, "epoch", epoch);
    xpc_dictionary_set_data(message, "plane0", plane0,
                            (size_t)rowBytes0 * (size_t)height);
    xpc_dictionary_set_data(message, "plane1", plane1,
                            (size_t)rowBytes1 * (size_t)(height / 2));
    xpc_dictionary_set_uint64(message, "rowBytes0", rowBytes0);
    xpc_dictionary_set_uint64(message, "rowBytes1", rowBytes1);
    xpc_dictionary_set_uint64(message, "height", height);
    xpc_connection_send_message(VCAMRemoteDecoderConnection, message);
    VCAMXPCRelease(message);
}

void VCAMSurfaceBrokerSendRemoteDecoderError(uint64_t epoch,
                                             const char *reason) {
    if (VCAMRemoteDecoderConnection == NULL || epoch == 0) return;
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(message, "command", "rtsp-hw-error");
    xpc_dictionary_set_uint64(message, "epoch", epoch);
    xpc_dictionary_set_string(message, "reason", reason ?: "(unspecified)");
    xpc_connection_send_message(VCAMRemoteDecoderConnection, message);
    VCAMXPCRelease(message);
}

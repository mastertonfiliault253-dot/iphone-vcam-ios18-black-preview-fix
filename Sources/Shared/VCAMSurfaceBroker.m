#import "VCAMSurfaceBroker.h"

#import <Foundation/Foundation.h>

#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>
#include <time.h>

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
extern xpc_object_t _Nullable xpc_dictionary_get_value(xpc_object_t dictionary,
                                                        const char *key);
extern void xpc_dictionary_set_string(xpc_object_t dictionary, const char *key,
                                      const char *value);
extern void xpc_dictionary_set_uint64(xpc_object_t dictionary, const char *key,
                                      uint64_t value);
extern void xpc_dictionary_set_value(xpc_object_t dictionary, const char *key,
                                     xpc_object_t value);
extern void xpc_release(xpc_object_t object);
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

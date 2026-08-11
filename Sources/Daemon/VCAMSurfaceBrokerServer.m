#import "../Shared/VCAMSurfaceBroker.h"

#import <Foundation/Foundation.h>

#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdatomic.h>
#include <string.h>

// Prefer Xcode's XPC types. The Linux iPhoneOS 16.5 SDK omits this header, so
// retain a narrow ABI fallback for WSL validation builds.
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
extern pid_t xpc_connection_get_pid(xpc_connection_t connection);
extern xpc_type_t xpc_get_type(xpc_object_t object);
extern xpc_object_t xpc_dictionary_create(
    const char *const _Nullable *keys,
    const xpc_object_t _Nullable *values, size_t count);
extern xpc_object_t _Nullable xpc_dictionary_create_reply(xpc_object_t original);
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
extern const struct _xpc_type_s _xpc_type_connection;
extern const struct _xpc_type_s _xpc_type_dictionary;
#endif

#if VCAM_HAS_SYSTEM_XPC && defined(OS_OBJECT_USE_OBJC) && OS_OBJECT_USE_OBJC
#define VCAMXPCRelease(object) ((void)(object))
#else
#define VCAMXPCRelease(object) xpc_release(object)
#endif

extern int proc_name(int pid, void *buffer, uint32_t bufferSize);

static const char *const VCAMSurfaceBrokerService = "com.codex.vcam.surface";
static const uint64_t VCAMXPCMachServiceListener = 1ULL << 0;
static const char *const VCAMSurfaceKeys[] = {
    "surface0", "surface1", "surface2",
};

static xpc_type_t VCAMXPCTypeConnection(void) {
#if VCAM_HAS_SYSTEM_XPC
    return XPC_TYPE_CONNECTION;
#else
    return (xpc_type_t)&_xpc_type_connection;
#endif
}

static xpc_type_t VCAMXPCTypeDictionary(void) {
#if VCAM_HAS_SYSTEM_XPC
    return XPC_TYPE_DICTIONARY;
#else
    return (xpc_type_t)&_xpc_type_dictionary;
#endif
}

typedef xpc_connection_t (*VCAMXPCMachServiceCreateFunction)(
    const char *name, dispatch_queue_t _Nullable targetQueue, uint64_t flags);
typedef pid_t (*VCAMXPCConnectionGetPIDFunction)(xpc_connection_t connection);

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

static pid_t VCAMXPCConnectionGetPID(xpc_connection_t connection) {
    static VCAMXPCConnectionGetPIDFunction getPIDFunction;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *symbol = dlsym(RTLD_DEFAULT, "xpc_connection_get_pid");
        memcpy(&getPIDFunction, &symbol, sizeof(getPIDFunction));
    });
    return getPIDFunction != NULL ? getPIDFunction(connection) : -1;
}

static bool VCAMSurfaceBrokerPeerIs(xpc_connection_t peer,
                                    const char *expectedName) {
    pid_t pid = VCAMXPCConnectionGetPID(peer);
    char name[64] = {0};
    return pid > 0 && proc_name(pid, name, sizeof(name)) > 0 &&
        strcmp(name, expectedName) == 0;
}

static bool VCAMSurfaceBrokerPeerCanPublish(xpc_connection_t peer) {
    return VCAMSurfaceBrokerPeerIs(peer, "SpringBoard") ||
        VCAMSurfaceBrokerPeerIs(peer, "vcamd");
}

static bool VCAMSurfaceBrokerPeerCanSubscribe(xpc_connection_t peer) {
    // mediaserverd replaces camera frames; SpringBoard owns the in-process
    // preview and native local-video/HLS producer. Both need read-only access
    // to the current IOSurface registry.
    return VCAMSurfaceBrokerPeerIs(peer, "mediaserverd") ||
        VCAMSurfaceBrokerPeerIs(peer, "SpringBoard");
}

static xpc_object_t VCAMBrokerRegistry;
static _Atomic(uint32_t) VCAMBrokerGetDiagnostics;

static void VCAMSurfaceBrokerHandleMessage(xpc_connection_t peer,
                                            xpc_object_t message) {
    if (xpc_get_type(message) != VCAMXPCTypeDictionary()) return;
    const char *command = xpc_dictionary_get_string(message, "command");
    if (command == NULL) return;
    if (strcmp(command, "publish") == 0) {
        if (!VCAMSurfaceBrokerPeerCanPublish(peer)) return;
        uint64_t slotCount = xpc_dictionary_get_uint64(message, "slotCount");
        if (!VCAMSurfaceBrokerSlotCountIsValid(slotCount)) return;
        xpc_object_t registry = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_uint64(
            registry, "generation",
            xpc_dictionary_get_uint64(message, "generation"));
        xpc_dictionary_set_uint64(registry, "slotCount", slotCount);
        for (uint32_t slot = 0; slot < slotCount; slot++) {
            xpc_object_t surface = xpc_dictionary_get_value(
                message, VCAMSurfaceKeys[slot]);
            if (surface != NULL) {
                xpc_dictionary_set_value(registry, VCAMSurfaceKeys[slot], surface);
            }
        }
        if (VCAMBrokerRegistry != NULL) VCAMXPCRelease(VCAMBrokerRegistry);
        VCAMBrokerRegistry = registry;
        fprintf(stderr, "vcamd IOSurface registry published pid=%d\n",
                VCAMXPCConnectionGetPID(peer));
        fflush(stderr);
        return;
    }
    if (strcmp(command, "get") != 0) return;
    pid_t peerPID = VCAMXPCConnectionGetPID(peer);
    char peerName[64] = {0};
    if (peerPID > 0) proc_name(peerPID, peerName, sizeof(peerName));
    bool accepted = VCAMSurfaceBrokerPeerCanSubscribe(peer);
    uint32_t diagnostic = atomic_fetch_add_explicit(
        &VCAMBrokerGetDiagnostics, 1, memory_order_relaxed);
    if (diagnostic < 6) {
        fprintf(stderr,
                "vcamd IOSurface registry request pid=%d name=%s accepted=%d registry=%d\n",
                peerPID, peerName[0] == '\0' ? "(unknown)" : peerName,
                accepted, VCAMBrokerRegistry != NULL);
        fflush(stderr);
    }
    if (!accepted) return;
    xpc_object_t reply = xpc_dictionary_create_reply(message);
    if (reply == NULL) return;
    xpc_dictionary_set_string(reply, "command", "registry");
    if (VCAMBrokerRegistry != NULL) {
        xpc_dictionary_set_uint64(
            reply, "generation",
            xpc_dictionary_get_uint64(VCAMBrokerRegistry, "generation"));
        uint64_t slotCount = xpc_dictionary_get_uint64(
            VCAMBrokerRegistry, "slotCount");
        xpc_dictionary_set_uint64(reply, "slotCount", slotCount);
        for (uint32_t slot = 0; slot < slotCount; slot++) {
            xpc_object_t surface = xpc_dictionary_get_value(
                VCAMBrokerRegistry, VCAMSurfaceKeys[slot]);
            if (surface != NULL) {
                xpc_dictionary_set_value(reply, VCAMSurfaceKeys[slot], surface);
            }
        }
    }
    xpc_connection_send_message(peer, reply);
    VCAMXPCRelease(reply);
}

void VCAMSurfaceBrokerStartServer(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dispatch_queue_t queue = dispatch_queue_create(
            "com.codex.vcam.surface.server", DISPATCH_QUEUE_SERIAL);
        xpc_connection_t listener = VCAMXPCMachServiceCreate(
            VCAMSurfaceBrokerService, queue, VCAMXPCMachServiceListener);
        if (listener == NULL) return;
        xpc_connection_set_event_handler(listener, ^(xpc_object_t event) {
            if (xpc_get_type(event) != VCAMXPCTypeConnection()) return;
            xpc_connection_t peer = (xpc_connection_t)event;
            xpc_connection_set_event_handler(peer, ^(xpc_object_t message) {
                VCAMSurfaceBrokerHandleMessage(peer, message);
            });
            xpc_connection_resume(peer);
        });
        xpc_connection_resume(listener);
        fprintf(stderr, "vcamd IOSurface broker started\n");
        fflush(stderr);
    });
}

#import "../Shared/VCAMSurfaceBroker.h"
#import "../Shared/VCAMProcessIdentity.h"

#import <Foundation/Foundation.h>

#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>

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
extern int proc_pidpath(int pid, void *buffer, uint32_t bufferSize);

typedef int (*VCAMCSOpsFunction)(pid_t pid, unsigned int operation,
                                 void *buffer, size_t bufferSize);

enum {
    VCAMCSOpsStatus = 0,
    VCAMCSOpsIdentity = 11,
    VCAMCSOpsTeamID = 14,
};
static const uint32_t VCAMCSPlatformBinary = 0x04000000;

static BOOL VCAMCSOps(pid_t pid, unsigned int operation,
                      void *buffer, size_t bufferSize) {
    static VCAMCSOpsFunction function;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *symbol = dlsym(RTLD_DEFAULT, "csops");
        memcpy(&function, &symbol, sizeof(function));
    });
    return function != NULL && function(pid, operation, buffer, bufferSize) == 0;
}

static NSString *VCAMCodeSigningString(pid_t pid, unsigned int operation) {
    char value[256] = {0};
    if (!VCAMCSOps(pid, operation, value, sizeof(value))) return nil;
    value[sizeof(value) - 1] = '\0';
    return value[0] != '\0' ? [NSString stringWithUTF8String:value] : nil;
}

static BOOL VCAMPeerIsPlatformBinary(pid_t pid) {
    uint32_t status = 0;
    // csops can be unavailable or patched under a jailbreak. When it cannot
    // be queried, do not block the peer: the exact path/name/bundle checks in
    // VCAMSurfaceBrokerIdentityForPeer still constrain who can subscribe or
    // publish. When csops does answer, keep the platform-binary requirement.
    if (!VCAMCSOps(pid, VCAMCSOpsStatus, &status, sizeof(status))) return YES;
    return (status & VCAMCSPlatformBinary) != 0;
}

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

typedef NS_ENUM(NSInteger, VCAMSurfaceBrokerPeerIdentity) {
    VCAMSurfaceBrokerPeerIdentityUnknown,
    VCAMSurfaceBrokerPeerIdentitySpringBoard,
    VCAMSurfaceBrokerPeerIdentityMediaServer,
    VCAMSurfaceBrokerPeerIdentityDaemon,
    VCAMSurfaceBrokerPeerIdentityUIHost,
};

static NSBundle *VCAMBundleForExecutablePath(NSString *path) {
    NSRange marker = [path rangeOfString:@".app/" options:NSBackwardsSearch];
    if (marker.location == NSNotFound) return nil;
    NSString *bundlePath = [path substringToIndex:NSMaxRange(marker) - 1];
    NSBundle *bundle = [NSBundle bundleWithPath:bundlePath];
    return [bundle.executablePath isEqualToString:path] ? bundle : nil;
}

static BOOL VCAMRootOwnedDaemonPathIsSafe(NSString *path) {
    struct stat info;
    return stat(path.fileSystemRepresentation, &info) == 0 &&
        info.st_uid == 0 && (info.st_mode & (S_IWGRP | S_IWOTH)) == 0;
}

static VCAMSurfaceBrokerPeerIdentity VCAMSurfaceBrokerIdentityForPeer(
    xpc_connection_t peer) {
    pid_t pid = VCAMXPCConnectionGetPID(peer);
    // KERN_PROC_PID can be unavailable under a jailbreak; startToken is then 0
    // and is used only as a best-effort PID-reuse guard below (0 always passes).
    uint64_t startToken = pid > 0 ? VCAMProcessStartToken(pid) : 0;
    char name[64] = {0};
    char pathBuffer[4096] = {0};
    if (pid <= 0 || proc_name(pid, name, sizeof(name)) <= 0 ||
        proc_pidpath(pid, pathBuffer, sizeof(pathBuffer)) <= 0) {
        return VCAMSurfaceBrokerPeerIdentityUnknown;
    }
    NSString *path = [NSString stringWithUTF8String:pathBuffer];
    NSString *signingIdentifier = VCAMCodeSigningString(pid, VCAMCSOpsIdentity);
    if ([path isEqualToString:@"/usr/sbin/mediaserverd"] &&
        strcmp(name, "mediaserverd") == 0 &&
        VCAMPeerIsPlatformBinary(pid) &&
        (signingIdentifier.length == 0 ||
         [signingIdentifier isEqualToString:@"com.apple.mediaserverd"])) {
        return VCAMProcessStartToken(pid) == startToken
            ? VCAMSurfaceBrokerPeerIdentityMediaServer
            : VCAMSurfaceBrokerPeerIdentityUnknown;
    }
    if ([path hasSuffix:@"/usr/libexec/vcamd"] &&
        ([path hasPrefix:@"/var/jb/"] || [path hasPrefix:@"/var/containers/Bundle/tweaksupport/"]) &&
        strcmp(name, "vcamd") == 0 && VCAMRootOwnedDaemonPathIsSafe(path)) {
        return VCAMProcessStartToken(pid) == startToken
            ? VCAMSurfaceBrokerPeerIdentityDaemon
            : VCAMSurfaceBrokerPeerIdentityUnknown;
    }
    if ([path isEqualToString:@"/System/Library/CoreServices/SpringBoard.app/SpringBoard"] &&
        strcmp(name, "SpringBoard") == 0 && VCAMPeerIsPlatformBinary(pid) &&
        (signingIdentifier.length == 0 ||
         [signingIdentifier isEqualToString:@"com.apple.springboard"])) {
        return VCAMProcessStartToken(pid) == startToken
            ? VCAMSurfaceBrokerPeerIdentitySpringBoard
            : VCAMSurfaceBrokerPeerIdentityUnknown;
    }
    NSBundle *bundle = VCAMBundleForExecutablePath(path);
    NSString *bundleIdentifier = bundle.bundleIdentifier;
    if (bundleIdentifier.length == 0) {
        return VCAMSurfaceBrokerPeerIdentityUnknown;
    }
    // A readable signing identity must match the bundle; when csops cannot
    // provide one (jailbreak), the exact path/bundle checks stand on their own.
    if (signingIdentifier.length > 0 &&
        ![signingIdentifier isEqualToString:bundleIdentifier]) {
        return VCAMSurfaceBrokerPeerIdentityUnknown;
    }
    if (([bundleIdentifier isEqualToString:@"com.apple.camera"] ||
        [bundleIdentifier isEqualToString:@"com.apple.mobilesafari"]) &&
        VCAMPeerIsPlatformBinary(pid) && [path hasPrefix:@"/Applications/"]) {
        return VCAMProcessStartToken(pid) == startToken
            ? VCAMSurfaceBrokerPeerIdentityUIHost
            : VCAMSurfaceBrokerPeerIdentityUnknown;
    }
    NSDictionary<NSString *, NSString *> *allowedThirdPartyTeams = @{
        @"com.google.chrome.ios": @"EQHXZ8M8AV",
        @"com.microsoft.msedge": @"UBF8T346G9",
        @"org.mozilla.ios.Firefox": @"43AQ936H96",
    };
    NSString *expectedTeam = allowedThirdPartyTeams[bundleIdentifier];
    NSString *actualTeam = VCAMCodeSigningString(pid, VCAMCSOpsTeamID);
    return expectedTeam.length > 0 &&
        (actualTeam.length == 0 || [actualTeam isEqualToString:expectedTeam]) &&
        VCAMProcessStartToken(pid) == startToken
        ? VCAMSurfaceBrokerPeerIdentityUIHost
        : VCAMSurfaceBrokerPeerIdentityUnknown;
}

static bool VCAMSurfaceBrokerPeerCanPublish(xpc_connection_t peer) {
    VCAMSurfaceBrokerPeerIdentity identity =
        VCAMSurfaceBrokerIdentityForPeer(peer);
    return identity == VCAMSurfaceBrokerPeerIdentitySpringBoard ||
        identity == VCAMSurfaceBrokerPeerIdentityDaemon;
}

static bool VCAMSurfaceBrokerPeerCanSubscribe(xpc_connection_t peer) {
    // mediaserverd replaces camera frames. The remaining exact process names
    // mirror VCAMSpringBoardClient.plist: those UI-only hosts render the
    // in-process preview and therefore need read-only registry access.
    VCAMSurfaceBrokerPeerIdentity identity =
        VCAMSurfaceBrokerIdentityForPeer(peer);
    return identity == VCAMSurfaceBrokerPeerIdentityMediaServer ||
        identity == VCAMSurfaceBrokerPeerIdentitySpringBoard ||
        identity == VCAMSurfaceBrokerPeerIdentityUIHost;
}

static bool VCAMSurfaceBrokerPeerCanControl(xpc_connection_t peer) {
    VCAMSurfaceBrokerPeerIdentity identity =
        VCAMSurfaceBrokerIdentityForPeer(peer);
    return identity == VCAMSurfaceBrokerPeerIdentitySpringBoard ||
        identity == VCAMSurfaceBrokerPeerIdentityUIHost;
}

static xpc_object_t VCAMBrokerRegistry;
static _Atomic(uint32_t) VCAMBrokerGetDiagnostics;

typedef struct {
    uint64_t high;
    uint64_t low;
    uint64_t issuedNanoseconds;
} VCAMConfigurationToken;

enum { VCAMConfigurationTokenCapacity = 16 };
static const uint64_t VCAMConfigurationTokenLifetimeNanoseconds =
    10ULL * 1000000000ULL;
static VCAMConfigurationToken
    VCAMConfigurationTokens[VCAMConfigurationTokenCapacity];

static uint64_t VCAMSurfaceBrokerMonotonicNanoseconds(void) {
    struct timespec now = {0};
    return clock_gettime(CLOCK_MONOTONIC, &now) == 0
        ? (uint64_t)now.tv_sec * 1000000000ULL + (uint64_t)now.tv_nsec : 0;
}

static void VCAMSurfaceBrokerStoreConfigurationToken(uint64_t high,
                                                     uint64_t low) {
    uint64_t now = VCAMSurfaceBrokerMonotonicNanoseconds();
    size_t selected = 0;
    uint64_t oldest = UINT64_MAX;
    for (size_t index = 0; index < VCAMConfigurationTokenCapacity; index++) {
        uint64_t issued = VCAMConfigurationTokens[index].issuedNanoseconds;
        if (issued == 0 || now < issued ||
            now - issued > VCAMConfigurationTokenLifetimeNanoseconds) {
            selected = index;
            break;
        }
        if (issued < oldest) {
            oldest = issued;
            selected = index;
        }
    }
    VCAMConfigurationTokens[selected] = (VCAMConfigurationToken){
        .high = high, .low = low, .issuedNanoseconds = now,
    };
}

static bool VCAMSurfaceBrokerConsumeConfigurationToken(uint64_t high,
                                                       uint64_t low) {
    uint64_t now = VCAMSurfaceBrokerMonotonicNanoseconds();
    for (size_t index = 0; now != 0 &&
         index < VCAMConfigurationTokenCapacity; index++) {
        VCAMConfigurationToken *token = &VCAMConfigurationTokens[index];
        bool fresh = token->issuedNanoseconds != 0 &&
            now >= token->issuedNanoseconds &&
            now - token->issuedNanoseconds <=
                VCAMConfigurationTokenLifetimeNanoseconds;
        bool matches = ((token->high ^ high) | (token->low ^ low)) == 0;
        if (fresh && matches) {
            memset(token, 0, sizeof(*token));
            return true;
        }
    }
    return false;
}

static void VCAMSurfaceBrokerHandleMessage(xpc_connection_t peer,
                                            xpc_object_t message) {
    if (xpc_get_type(message) != VCAMXPCTypeDictionary()) return;
    const char *command = xpc_dictionary_get_string(message, "command");
    if (command == NULL) return;
    if (strcmp(command, "config-auth") == 0) {
        if (!VCAMSurfaceBrokerPeerCanControl(peer)) return;
        uint64_t token[2] = {0};
        do {
            arc4random_buf(token, sizeof(token));
        } while (token[0] == 0 || token[1] == 0);
        VCAMSurfaceBrokerStoreConfigurationToken(token[0], token[1]);
        xpc_object_t reply = xpc_dictionary_create_reply(message);
        if (reply == NULL) return;
        xpc_dictionary_set_string(reply, "command", "config-auth");
        xpc_dictionary_set_uint64(reply, "tokenHigh", token[0]);
        xpc_dictionary_set_uint64(reply, "tokenLow", token[1]);
        xpc_connection_send_message(peer, reply);
        VCAMXPCRelease(reply);
        return;
    }
    if (strcmp(command, "config-auth-consume") == 0) {
        if (VCAMSurfaceBrokerIdentityForPeer(peer) !=
            VCAMSurfaceBrokerPeerIdentitySpringBoard) return;
        bool accepted = VCAMSurfaceBrokerConsumeConfigurationToken(
            xpc_dictionary_get_uint64(message, "tokenHigh"),
            xpc_dictionary_get_uint64(message, "tokenLow"));
        xpc_object_t reply = xpc_dictionary_create_reply(message);
        if (reply == NULL) return;
        xpc_dictionary_set_string(reply, "command", "config-auth-consume");
        xpc_dictionary_set_uint64(reply, "accepted", accepted ? 1 : 0);
        xpc_connection_send_message(peer, reply);
        VCAMXPCRelease(reply);
        return;
    }
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

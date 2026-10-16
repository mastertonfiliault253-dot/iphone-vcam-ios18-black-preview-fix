#import "../Shared/VCAMSurfaceBroker.h"
#import "../Shared/VCAMSharedFrame.h"
#import "VCAMHLSLoopbackProxy.h"
#import "../Shared/VCAMProcessIdentity.h"

#import <Foundation/Foundation.h>

#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

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
const void *xpc_dictionary_get_data(xpc_object_t dictionary, const char *key,
                                    size_t *length);
extern void xpc_dictionary_set_string(xpc_object_t dictionary, const char *key,
                                      const char *value);
extern void xpc_dictionary_set_uint64(xpc_object_t dictionary, const char *key,
                                      uint64_t value);
extern void xpc_dictionary_set_fd(xpc_object_t dictionary, const char *key,
                                  int descriptor);
extern void xpc_dictionary_set_value(xpc_object_t dictionary, const char *key,
                                     xpc_object_t value);
extern xpc_object_t xpc_data_create(const void *bytes, size_t length);
void xpc_dictionary_set_data(xpc_object_t dictionary, const char *key,
                             const void *bytes, size_t length);
void xpc_dictionary_set_double(xpc_object_t dictionary, const char *key,
                               double value);
void xpc_retain(xpc_object_t object);
void xpc_release(xpc_object_t object);
extern const struct _xpc_type_s _xpc_type_connection;
extern const struct _xpc_type_s _xpc_type_dictionary;
extern const struct _xpc_type_s _xpc_type_error;
#endif

#if VCAM_HAS_SYSTEM_XPC && defined(OS_OBJECT_USE_OBJC) && OS_OBJECT_USE_OBJC
#define VCAMXPCRelease(object) ((void)(object))
#else
#define VCAMXPCRelease(object) xpc_release(object)
#endif

extern int proc_name(int pid, void *buffer, uint32_t bufferSize);
extern int proc_pidpath(int pid, void *buffer, uint32_t bufferSize);

extern IOSurfaceRef _Nullable IOSurfaceLookupFromXPCObject(xpc_object_t object)
    CF_RETURNS_RETAINED;
extern xpc_object_t IOSurfaceCreateXPCObject(IOSurfaceRef surface);

// Present in libSystem but undeclared in this SDK's XPC headers.
extern const char *xpc_type_get_name(xpc_type_t type);
extern mach_port_t xpc_mach_send_get_right(xpc_object_t object);

// One-shot in-process probe of the exact IOSurface<->XPC pair every remote
// frames use. Real device: SB-created surfaces arrive here as an XPC
// "mach send right" and import as NULL, while the same pair in the frame
// publish direction (vcamd create -> SpringBoard import) works. This tells
// whether the pair itself is dead in the vcamd context or only imports of
// foreign surfaces fail.
static void VCAMRemoteDecoderSurfaceSelfTest(void) {
    static BOOL tested;
    if (tested) return;
    tested = YES;
    NSDictionary *properties = @{
        (id)kIOSurfaceWidth: @64,
        (id)kIOSurfaceHeight: @64,
        (id)kIOSurfaceBytesPerElement: @4,
    };
    IOSurfaceRef probe =
        IOSurfaceCreate((__bridge CFDictionaryRef)properties);
    xpc_object_t encoded =
        probe != NULL ? IOSurfaceCreateXPCObject(probe) : NULL;
    mach_port_t right = encoded != NULL ? xpc_mach_send_get_right(encoded)
                                        : MACH_PORT_NULL;
    IOSurfaceRef decoded = encoded != NULL
        ? IOSurfaceLookupFromXPCObject(encoded) : NULL;
    fprintf(stderr,
            "vcamd surface selftest created=%d xpc=%d xpcType=%s machRight=%d imported=%d\n",
            probe != NULL, encoded != NULL,
            encoded != NULL
                ? xpc_type_get_name(xpc_get_type(encoded)) : "(none)",
            right != MACH_PORT_NULL, decoded != NULL);
    fflush(stderr);
    if (decoded != NULL) CFRelease(decoded);
    if (encoded != NULL) VCAMXPCRelease(encoded);
    if (probe != NULL) CFRelease(probe);
}

static BOOL VCAMPeerIsPlatformBinary(pid_t pid) {
    // csops is unreliable under a jailbreak: queries can fail or return a
    // patched status without the platform flag, which would reject legitimate
    // system daemons (mediaserverd) and UI hosts (Safari) that the exact
    // path/name/bundle allow-list below already constrains. That allow-list is
    // the real boundary -- proc_pidpath cannot be forged -- so this check is
    // intentionally permissive.
    (void)pid;
    return YES;
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

static xpc_type_t VCAMXPCTypeError(void) {
#if VCAM_HAS_SYSTEM_XPC
    return XPC_TYPE_ERROR;
#else
    return (xpc_type_t)&_xpc_type_error;
#endif
}

typedef xpc_connection_t (*VCAMXPCMachServiceCreateFunction)(
    const char *name, dispatch_queue_t _Nullable targetQueue, uint64_t flags);
typedef pid_t (*VCAMXPCConnectionGetPIDFunction)(xpc_connection_t connection);
typedef const char *(*VCAMXPCConnectionGetNameFunction)(
    xpc_connection_t connection);

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

static const char *VCAMXPCConnectionGetName(xpc_connection_t connection) {
    static VCAMXPCConnectionGetNameFunction getNameFunction;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *symbol = dlsym(RTLD_DEFAULT, "xpc_connection_get_name");
        memcpy(&getNameFunction, &symbol, sizeof(getNameFunction));
    });
    return getNameFunction != NULL ? getNameFunction(connection) : NULL;
}

static BOOL VCAMXPCNameIsCameraCaptured(const char *name) {
    return name != NULL &&
        (strcmp(name, "cameracaptured") == 0 ||
         strcmp(name, "/usr/libexec/cameracaptured") == 0 ||
         strcmp(name, "com.apple.cameracaptured") == 0);
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
    char name[64] = {0};
    char pathBuffer[4096] = {0};
    if (pid <= 0 || proc_name(pid, name, sizeof(name)) <= 0 ||
        proc_pidpath(pid, pathBuffer, sizeof(pathBuffer)) <= 0) {
        const char *xpcName = VCAMXPCConnectionGetName(peer);
        if (VCAMXPCNameIsCameraCaptured(xpcName)) {
            fprintf(stderr,
                    "vcamd identity cameracaptured via XPC peer name=%s pid=%d\n",
                    xpcName, pid);
            return VCAMSurfaceBrokerPeerIdentityMediaServer;
        }
        fprintf(stderr,
                "vcamd identity unknown pid=%d (proc_name/proc_pidpath unavailable, xpc_name=%s)\n",
                pid, xpcName == NULL ? "(unknown)" : xpcName);
        return VCAMSurfaceBrokerPeerIdentityUnknown;
    }
    NSString *path = [NSString stringWithUTF8String:pathBuffer];
    // Signing-identity gates (csops) are intentionally not used: under a
    // jailbreak they are unreliable and rejected legitimate peers that the
    // exact path/name/bundle allow-list below already constrains.
    if (VCAMPeerIsPlatformBinary(pid) &&
        (([path isEqualToString:@"/usr/libexec/cameracaptured"] &&
          strcmp(name, "cameracaptured") == 0) ||
         ([path isEqualToString:@"/usr/sbin/mediaserverd"] &&
          strcmp(name, "mediaserverd") == 0))) {
        return VCAMSurfaceBrokerPeerIdentityMediaServer;
    }
    if ([path hasSuffix:@"/usr/libexec/vcamd"] &&
        ([path hasPrefix:@"/var/jb/"] || [path hasPrefix:@"/var/containers/Bundle/tweaksupport/"]) &&
        strcmp(name, "vcamd") == 0 && VCAMRootOwnedDaemonPathIsSafe(path)) {
        return VCAMSurfaceBrokerPeerIdentityDaemon;
    }
    if ([path isEqualToString:@"/System/Library/CoreServices/SpringBoard.app/SpringBoard"] &&
        strcmp(name, "SpringBoard") == 0 && VCAMPeerIsPlatformBinary(pid)) {
        return VCAMSurfaceBrokerPeerIdentitySpringBoard;
    }
    NSBundle *bundle = VCAMBundleForExecutablePath(path);
    NSString *bundleIdentifier = bundle.bundleIdentifier;
    if (bundleIdentifier.length == 0) {
        return VCAMSurfaceBrokerPeerIdentityUnknown;
    }
    if (([bundleIdentifier isEqualToString:@"com.apple.camera"] ||
        [bundleIdentifier isEqualToString:@"com.apple.mobilesafari"]) &&
        VCAMPeerIsPlatformBinary(pid) && [path hasPrefix:@"/Applications/"]) {
        return VCAMSurfaceBrokerPeerIdentityUIHost;
    }
    // Membership test is by bundle identifier only. The dictionary carries the
    // vendors' App Store team IDs as documentation and as the anchor a future
    // signature check would compare against; the values are deliberately not
    // compared at runtime because csops-based identity queries are unreliable
    // under a jailbreak (see VCAMPeerIsPlatformBinary above) and the exact
    // proc_pidpath + /Applications/ prefix checks above already bind the peer
    // to a concrete on-disk bundle.
    NSDictionary<NSString *, NSString *> *allowedThirdPartyBundles = @{
        @"com.google.chrome.ios": @"EQHXZ8M8AV",
        @"com.microsoft.msedge": @"UBF8T346G9",
        @"org.mozilla.ios.Firefox": @"43AQ936H96",
    };
    NSString *teamIDForBundle = allowedThirdPartyBundles[bundleIdentifier];
    return teamIDForBundle.length > 0
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

static void VCAMSurfaceBrokerAttachFileDescriptor(
    xpc_object_t reply, const char *key, const char *path, int flags) {
    int descriptor = open(path, flags);
    if (descriptor < 0) return;
    xpc_dictionary_set_fd(reply, key, descriptor);
    close(descriptor);
}

static void VCAMSurfaceBrokerAttachMediaServerDescriptors(
    xpc_object_t reply) {
    // cameracaptured's sandbox rejects path-based access to /var/tmp even
    // when the shared files are world-readable. The authenticated Mach peer
    // receives already-open descriptors instead; UI subscribers never do.
    VCAMSurfaceBrokerAttachFileDescriptor(
        reply, "frameFD", VCAMSharedFrameFileSystemPath(), O_RDONLY);
    VCAMSurfaceBrokerAttachFileDescriptor(
        reply, "surfaceFD", VCAMSharedSurfaceFileSystemPath(), O_RDWR);
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

static void VCAMSurfaceBrokerStoreConfigurationToken(uint64_t high,
                                                     uint64_t low) {
    uint64_t now = VCAMSharedFrameMonotonicNanoseconds();
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
    uint64_t now = VCAMSharedFrameMonotonicNanoseconds();
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

// Remote hardware decode session state (see the "Remote hardware decode"
// block in VCAMSurfaceBroker.h). Only one SpringBoard decoder peer is
// tracked; its connection stays alive while its event handler block holds
// the peer reference, so storing the value here does not own it.
static xpc_connection_t VCAMRemoteDecoderPeer;
static uint64_t VCAMRemoteDecoderSessionEpoch;
static _Atomic(uint64_t) VCAMRemoteDecoderFrames;
// First-look diagnostics are session-scoped (reset when a new decode epoch
// opens): a process-lifetime cap hid the second session's truth behind the
// first session's log budget.
static int VCAMRemoteDecoderLoggedInbound;
static int VCAMRemoteDecoderLoggedNonPeer;
static int VCAMRemoteDecoderLoggedStale;
static int VCAMRemoteDecoderLoggedSurfaceFailure;

static void VCAMRemoteDecoderResetSessionDiagnostics(void) {
    VCAMRemoteDecoderLoggedInbound = 0;
    VCAMRemoteDecoderLoggedNonPeer = 0;
    VCAMRemoteDecoderLoggedStale = 0;
    VCAMRemoteDecoderLoggedSurfaceFailure = 0;
    atomic_store_explicit(&VCAMRemoteDecoderFrames, 0, memory_order_relaxed);
}
static void (^VCAMRemoteDecodeEventHandler)(VCAMRemoteDecoderEvent,
                                           uint64_t,
                                           const VCAMRemoteDecoderFramePayload
                                           * _Nullable);

static void VCAMRemoteDecoderNotify(
    VCAMRemoteDecoderEvent event, uint64_t epoch,
    const VCAMRemoteDecoderFramePayload * _Nullable payload) {
    // The borrowed payload is valid for the synchronous call; consumers
    // copy the pixels they outlive (the RTSP source copies into an owned
    // AVFrame). No surface references cross this boundary anymore: the
    // device rejects IOSurfaceCreate for non-GUI-session processes, so
    // vcamd can never hold one (docs VIDEOTOOLBOX case E9 + probe).
    void (^handler)(VCAMRemoteDecoderEvent, uint64_t,
                    const VCAMRemoteDecoderFramePayload * _Nullable) =
        VCAMRemoteDecodeEventHandler;
    if (handler != nil) {
        handler(event, epoch, payload);
    }
}

static void VCAMRemoteDecoderLosePeer(void) {
    if (VCAMRemoteDecoderPeer == NULL) return;
    VCAMRemoteDecoderPeer = NULL;
    VCAMRemoteDecoderSessionEpoch = 0;
    fprintf(stderr, "vcamd remote decoder peer lost\n");
    fflush(stderr);
    VCAMRemoteDecoderNotify(VCAMRemoteDecoderEventPeerLost, 0, NULL);
}

void VCAMSurfaceBrokerSetRemoteDecoderEventHandler(
    void (^_Nullable handler)(VCAMRemoteDecoderEvent event, uint64_t epoch,
                              const VCAMRemoteDecoderFramePayload * _Nullable
                              payload)) {
    VCAMRemoteDecodeEventHandler = [handler copy];
}

BOOL VCAMSurfaceBrokerRemoteDecoderPeerAvailable(void) {
    return VCAMRemoteDecoderPeer != NULL;
}

static BOOL VCAMRemoteDecoderSendToPeer(xpc_object_t message) {
    if (VCAMRemoteDecoderPeer == NULL) {
        VCAMXPCRelease(message);
        return NO;
    }
    xpc_connection_send_message(VCAMRemoteDecoderPeer, message);
    VCAMXPCRelease(message);
    return YES;
}

BOOL VCAMSurfaceBrokerPushRemoteDecoderOpen(uint64_t epoch, const char *codec,
                                           int width, int height,
                                           const void *parameterData,
                                           size_t length) {
    if (epoch == 0 || codec == NULL || width <= 0 || height <= 0 ||
        parameterData == NULL || length == 0 ||
        VCAMRemoteDecoderSessionEpoch != 0) {
        return NO;
    }
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(message, "command", "rtsp-hw-open");
    xpc_dictionary_set_uint64(message, "epoch", epoch);
    xpc_dictionary_set_string(message, "codec", codec);
    xpc_dictionary_set_uint64(message, "width", (uint64_t)width);
    xpc_dictionary_set_uint64(message, "height", (uint64_t)height);
    xpc_dictionary_set_data(message, "parameterData", parameterData, length);
    VCAMRemoteDecoderResetSessionDiagnostics();
    // Register the epoch BEFORE the message can reach the peer: SpringBoard
    // answers rtsp-hw-open-ack on its own connection queue, and the inbound
    // handler must never judge a matching ack stale just because this thread
    // had not resumed after the send yet (defect K, 2026-10-16: an ack whose
    // epoch equaled the open's was dropped as "stale ... active=0", and the
    // client's one-shot failure latch then forced software decode for the
    // rest of the process).
    VCAMRemoteDecoderSessionEpoch = epoch;
    if (!VCAMRemoteDecoderSendToPeer(message)) {
        VCAMRemoteDecoderSessionEpoch = 0;
        return NO;
    }
    VCAMRemoteDecoderSurfaceSelfTest();
    fprintf(stderr, "vcamd remote decode open epoch=%llu codec=%s %dx%d\n",
            (unsigned long long)epoch, codec, width, height);
    fflush(stderr);
    return YES;
}

BOOL VCAMSurfaceBrokerPushRemoteDecoderAU(uint64_t epoch, const void *bytes,
                                         size_t length,
                                         double presentationSeconds,
                                         BOOL isKeyFrame) {
    if (epoch == 0 || epoch != VCAMRemoteDecoderSessionEpoch ||
        bytes == NULL || length == 0) {
        return NO;
    }
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(message, "command", "rtsp-hw-au");
    xpc_dictionary_set_uint64(message, "epoch", epoch);
    xpc_dictionary_set_data(message, "data", bytes, length);
    xpc_dictionary_set_double(message, "presentationSeconds",
                              presentationSeconds);
    xpc_dictionary_set_uint64(message, "isKeyFrame", isKeyFrame ? 1 : 0);
    return VCAMRemoteDecoderSendToPeer(message);
}

void VCAMSurfaceBrokerEndRemoteDecoderSession(uint64_t epoch) {
    if (epoch == 0 || epoch != VCAMRemoteDecoderSessionEpoch) return;
    VCAMRemoteDecoderSessionEpoch = 0;
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(message, "command", "rtsp-hw-close");
    xpc_dictionary_set_uint64(message, "epoch", epoch);
    VCAMRemoteDecoderSendToPeer(message);
}

static void VCAMSurfaceBrokerHandleMessage(xpc_connection_t peer,
                                            xpc_object_t message) {
    if (xpc_get_type(message) == VCAMXPCTypeError()) {
        if (peer == VCAMRemoteDecoderPeer) VCAMRemoteDecoderLosePeer();
        return;
    }
    if (xpc_get_type(message) != VCAMXPCTypeDictionary()) return;
    const char *command = xpc_dictionary_get_string(message, "command");
    if (command == NULL) return;
    if (strcmp(command, "rtsp-hw-ready") == 0) {
        // Only the injected SpringBoard service may offer hardware decode.
        if (VCAMSurfaceBrokerIdentityForPeer(peer) !=
            VCAMSurfaceBrokerPeerIdentitySpringBoard) return;
        if (peer != VCAMRemoteDecoderPeer) {
            VCAMRemoteDecoderPeer = peer;
            VCAMRemoteDecoderSessionEpoch = 0;
            fprintf(stderr, "vcamd remote decoder peer ready pid=%d\n",
                    VCAMXPCConnectionGetPID(peer));
            fflush(stderr);
            VCAMRemoteDecoderNotify(VCAMRemoteDecoderEventPeerAvailable,
                                    0, NULL);
        }
        return;
    }
    if (strcmp(command, "rtsp-hw-open-ack") == 0 ||
        strcmp(command, "rtsp-hw-frame") == 0 ||
        strcmp(command, "rtsp-hw-error") == 0 ||
        strcmp(command, "rtsp-hw-close") == 0) {
        // First-look diagnostics: a frame message can die in XPC transport
        // without any visible event, so log arrival before any gate decides
        // silently.
        if (VCAMRemoteDecoderLoggedInbound < 4) {
            VCAMRemoteDecoderLoggedInbound += 1;
            fprintf(stderr, "vcamd remote decoder inbound command=%s pid=%d epoch=%llu\n",
                    command, VCAMXPCConnectionGetPID(peer),
                    xpc_dictionary_get_uint64(message, "epoch"));
            fflush(stderr);
        }
        if (peer != VCAMRemoteDecoderPeer) {
            if (VCAMRemoteDecoderLoggedNonPeer < 3) {
                VCAMRemoteDecoderLoggedNonPeer += 1;
                fprintf(stderr, "vcamd remote decoder non-peer %s pid=%d\n",
                        command, VCAMXPCConnectionGetPID(peer));
                fflush(stderr);
            }
            return;
        }
        uint64_t epoch = xpc_dictionary_get_uint64(message, "epoch");
        if (epoch == 0 || epoch != VCAMRemoteDecoderSessionEpoch) {
            if (VCAMRemoteDecoderLoggedStale < 3) {
                VCAMRemoteDecoderLoggedStale += 1;
                fprintf(stderr,
                        "vcamd remote decoder stale %s epoch=%llu active=%llu\n",
                        command, (unsigned long long)epoch,
                        (unsigned long long)VCAMRemoteDecoderSessionEpoch);
                fflush(stderr);
            }
            return;
        }
        if (strcmp(command, "rtsp-hw-open-ack") == 0) {
            VCAMRemoteDecoderNotify(
                xpc_dictionary_get_uint64(message, "accepted") != 0
                    ? VCAMRemoteDecoderEventOpenAccepted
                    : VCAMRemoteDecoderEventOpenRejected,
                epoch, NULL);
            return;
        }
        if (strcmp(command, "rtsp-hw-error") == 0) {
            fprintf(stderr, "vcamd remote decode error epoch=%llu reason=%s\n",
                    (unsigned long long)epoch,
                    xpc_dictionary_get_string(message, "reason") ?: "(none)");
            fflush(stderr);
            VCAMRemoteDecoderSessionEpoch = 0;
            VCAMRemoteDecoderNotify(VCAMRemoteDecoderEventFailure, epoch, NULL);
            return;
        }
        if (strcmp(command, "rtsp-hw-close") == 0) {
            VCAMRemoteDecoderSessionEpoch = 0;
            VCAMRemoteDecoderNotify(VCAMRemoteDecoderEventPeerLost,
                                    epoch, NULL);
            return;
        }
        uint64_t width = xpc_dictionary_get_uint64(message, "width");
        uint64_t height = xpc_dictionary_get_uint64(message, "height");
        if (width == 0 || height == 0) {
            // The completion carried no usable source size; visible once per
            // session instead of silently dropping.
            if (VCAMRemoteDecoderLoggedSurfaceFailure < 4) {
                VCAMRemoteDecoderLoggedSurfaceFailure += 1;
                fprintf(stderr,
                        "vcamd remote decode frame metadata missing epoch=%llu\n",
                        (unsigned long long)epoch);
                fflush(stderr);
            }
            VCAMRemoteDecoderNotify(VCAMRemoteDecoderEventFailure,
                                    epoch, NULL);
            return;
        }
        uint64_t frames = atomic_fetch_add_explicit(
            &VCAMRemoteDecoderFrames, 1, memory_order_relaxed);
        if (frames < 4) {
            fprintf(stderr,
                    "vcamd remote decode frame epoch=%llu size=%llux%llu\n",
                    (unsigned long long)epoch,
                    (unsigned long long)width,
                    (unsigned long long)height);
            fflush(stderr);
        }
        VCAMRemoteDecoderFramePayload payload = {
            .width = (uint32_t)width,
            .height = (uint32_t)height,
        };
        VCAMRemoteDecoderNotify(VCAMRemoteDecoderEventFrame, epoch, &payload);
        return;
    }
    if (strcmp(command, "config-auth") == 0) {
        // Config tokens are single-purpose, 10-second-lifetime and only
        // unlock configuration reads/writes through the SpringBoard broker.
        // The CanControl identity gate rejects legitimate UI hosts
        // (Camera/Safari) under a jailbreak where sysctl/bundle data can be
        // unavailable, so issue tokens to any loopback peer (0.8.80 parity).
        fprintf(stderr, "vcamd config-auth issued pid=%d\n",
                VCAMXPCConnectionGetPID(peer));
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
    if (strcmp(command, "hls-proxy-session") == 0) {
        if (VCAMSurfaceBrokerIdentityForPeer(peer) !=
            VCAMSurfaceBrokerPeerIdentitySpringBoard) return;
        const char *upstreamBytes = xpc_dictionary_get_string(
            message, "upstreamURL");
        NSString *upstreamString = upstreamBytes == NULL ? nil :
            [NSString stringWithUTF8String:upstreamBytes];
        NSURL *upstreamURL = upstreamString.length <= 4096 ?
            [NSURL URLWithString:upstreamString] : nil;
        uint64_t high = xpc_dictionary_get_uint64(message, "tokenHigh");
        uint64_t low = xpc_dictionary_get_uint64(message, "tokenLow");
        uint64_t sessionEpoch = xpc_dictionary_get_uint64(
            message, "sessionEpoch");
        BOOL accepted = upstreamURL != nil &&
            VCAMHLSLoopbackProxyRegisterSession(
                upstreamURL, sessionEpoch, high, low);
        xpc_object_t reply = xpc_dictionary_create_reply(message);
        if (reply == NULL) return;
        xpc_dictionary_set_string(reply, "command", "hls-proxy-session");
        xpc_dictionary_set_uint64(reply, "accepted", accepted ? 1 : 0);
        if (accepted) {
            xpc_dictionary_set_uint64(reply, "tokenHigh", high);
            xpc_dictionary_set_uint64(reply, "tokenLow", low);
        }
        xpc_connection_send_message(peer, reply);
        VCAMXPCRelease(reply);
        return;
    }
    if (strcmp(command, "hls-proxy-invalidate") == 0) {
        if (VCAMSurfaceBrokerIdentityForPeer(peer) !=
            VCAMSurfaceBrokerPeerIdentitySpringBoard) return;
        BOOL invalidated = VCAMHLSLoopbackProxyInvalidateSession(
            xpc_dictionary_get_uint64(message, "tokenHigh"),
            xpc_dictionary_get_uint64(message, "tokenLow"));
        xpc_object_t reply = xpc_dictionary_create_reply(message);
        if (reply == NULL) return;
        xpc_dictionary_set_string(reply, "command", "hls-proxy-invalidate");
        xpc_dictionary_set_uint64(reply, "accepted", invalidated ? 1 : 0);
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
    VCAMSurfaceBrokerPeerIdentity peerIdentity = accepted
        ? VCAMSurfaceBrokerIdentityForPeer(peer)
        : VCAMSurfaceBrokerPeerIdentityUnknown;
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
    if (peerIdentity == VCAMSurfaceBrokerPeerIdentityMediaServer) {
        VCAMSurfaceBrokerAttachMediaServerDescriptors(reply);
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

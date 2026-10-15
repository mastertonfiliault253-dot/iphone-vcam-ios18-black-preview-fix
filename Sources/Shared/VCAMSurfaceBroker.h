#import <CoreVideo/CoreVideo.h>

#include <stdbool.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

enum {
    VCAMSurfaceBrokerStaticSlotCount = 1,
    VCAMSurfaceBrokerVideoSlotCount = 3,
};

static inline bool VCAMSurfaceBrokerSlotCountIsValid(uint64_t count) {
    return count == VCAMSurfaceBrokerStaticSlotCount ||
        count == VCAMSurfaceBrokerVideoSlotCount;
}

/// Starts the launchd-owned XPC relay in vcamd. Other processes must not call
/// this entry point.
void VCAMSurfaceBrokerStartServer(void);

/// Sends retained IOSurface rights to the relay. The call is asynchronous and
/// never waits on the SpringBoard render thread.
void VCAMSurfaceBrokerPublish(
    IOSurfaceRef _Nonnull const * _Nonnull surfaces, uint32_t count);

/// Requests the current registry asynchronously. Safe to call repeatedly;
/// requests are throttled internally.
void VCAMSurfaceBrokerRequestRegistry(void);

/// Returns a retained surface matching the published ID, or NULL while the
/// asynchronous registry handshake is incomplete.
IOSurfaceRef _Nullable VCAMSurfaceBrokerCopySurface(uint32_t surfaceID)
    CF_RETURNS_RETAINED;

/// Low-volume subscriber state for device diagnostics. The returned string is
/// process-lifetime storage and never contains media or user data.
const char *VCAMSurfaceBrokerSubscriberStatus(void);

/// Returns a duplicated descriptor for the shared mmap data plane received
/// from the authenticated broker, or -1 while the asynchronous registry
/// handshake is incomplete. The caller owns the returned descriptor.
int VCAMSurfaceBrokerCopySharedFrameFileDescriptor(void);

/// Returns a duplicated read-write descriptor for the shared-surface header
/// received from the authenticated broker, or -1 while unavailable. The
/// caller owns the returned descriptor.
int VCAMSurfaceBrokerCopySharedSurfaceFileDescriptor(void);

/// Obtains a short-lived, single-use configuration token from the
/// audit-identified XPC service. Returns false for non-UI peers.
bool VCAMSurfaceBrokerCopyConfigurationToken(uint64_t *high, uint64_t *low);

/// Asks the audit-identified XPC service to consume a previously issued token.
bool VCAMSurfaceBrokerValidateConfigurationToken(uint64_t high, uint64_t low);

/// Requests an HLS relay session from the audit-identified vcamd service.
/// Only SpringBoard is authorized. The random token is embedded in AVPlayer's
/// loopback URL and is invalidated atomically when a new session is issued.
bool VCAMSurfaceBrokerCreateHLSProxySession(const char *upstreamURL,
                                            uint64_t sessionEpoch,
                                            uint64_t *high, uint64_t *low);

/// Invalidates the matching HLS relay session. The reply is bounded to one
/// second so SpringBoard never waits indefinitely on its main thread.
bool VCAMSurfaceBrokerInvalidateHLSProxySession(uint64_t high, uint64_t low);

// ---------------------------------------------------------------------------
// Remote hardware decode (RTSP): the vcamd daemon cannot reach the system
// video decode service (docs VIDEOTOOLBOX case E9, -12911), so vcamd keeps
// the RTSP demuxer and pushes compressed access units to the injected
// SpringBoard service, which decodes them with VideoToolbox in an app
// process and sends the decoded pixels back.
//
// The return channel is a pixel data plane, not an IOSurface: the device
// rejects IOSurfaceCreate for every non-GUI-session process (probe:
// vcamd selftest created=0, standalone probe under ssh create=0), so a
// surface reference could never materialize in vcamd even though its mach
// right transports fine. SpringBoard copies NV12 planes into the message.

// Client role, called only by the injected SpringBoard remote-decode
// service. Registers handlers for the pushed session messages, connects, and
// re-registers automatically if the connection is re-established.
typedef void (^VCAMRemoteDecodeOpenHandler)(uint64_t epoch, const char *codec,
                                           int width, int height,
                                           const void *parameterData,
                                           size_t length);
typedef void (^VCAMRemoteDecodeAUHandler)(uint64_t epoch, const void *bytes,
                                         size_t length,
                                         double presentationSeconds,
                                         BOOL isKeyFrame);
typedef void (^VCAMRemoteDecodeCloseHandler)(uint64_t epoch);
void VCAMSurfaceBrokerStartRemoteDecoderClient(
    VCAMRemoteDecodeOpenHandler openHandler,
    VCAMRemoteDecodeAUHandler auHandler,
    VCAMRemoteDecodeCloseHandler closeHandler);
void VCAMSurfaceBrokerSendRemoteDecoderOpenAck(uint64_t epoch, BOOL accepted);
// Frame completion. SpringBoard resizes the decoded frame into the fixed
// shared-frame canvas and publishes it into the shared-frame mmap ring
// buffer itself (docs E9/E10: only data copies, no IOSurface), so this
// message carries just the decoded source size: enough for the daemon to
// release one flow-control credit and drive its first/perf diagnostics.
// No pixel bytes cross XPC anymore.
void VCAMSurfaceBrokerSendRemoteDecoderFrame(uint64_t epoch, uint32_t width,
                                             uint32_t height);
void VCAMSurfaceBrokerSendRemoteDecoderError(uint64_t epoch,
                                             const char *reason);

// vcamd-only role (like VCAMSurfaceBrokerStartServer): routes decoder
// protocol messages into the daemon pipeline and pushes session traffic to
// the registered SpringBoard peer. Other processes must not call these.
typedef struct VCAMRemoteDecoderFramePayload {
    // Decoded source size of one published frame; the pixels never travel
    // over XPC because SpringBoard writes the shared ring buffer directly.
    uint32_t width;
    uint32_t height;
} VCAMRemoteDecoderFramePayload;

typedef NS_ENUM(NSInteger, VCAMRemoteDecoderEvent) {
    VCAMRemoteDecoderEventPeerAvailable,
    VCAMRemoteDecoderEventPeerLost,
    VCAMRemoteDecoderEventOpenAccepted,
    VCAMRemoteDecoderEventOpenRejected,
    /// Frame completion: SpringBoard has already published the frame into
    /// the shared ring buffer; payload carries only the decoded source size.
    VCAMRemoteDecoderEventFrame,
    VCAMRemoteDecoderEventFailure,
};
void VCAMSurfaceBrokerSetRemoteDecoderEventHandler(
    void (^_Nullable handler)(VCAMRemoteDecoderEvent event, uint64_t epoch,
                              const VCAMRemoteDecoderFramePayload * _Nullable
                              payload));
BOOL VCAMSurfaceBrokerRemoteDecoderPeerAvailable(void);
BOOL VCAMSurfaceBrokerPushRemoteDecoderOpen(uint64_t epoch, const char *codec,
                                           int width, int height,
                                           const void *parameterData,
                                           size_t length);
BOOL VCAMSurfaceBrokerPushRemoteDecoderAU(uint64_t epoch, const void *bytes,
                                         size_t length,
                                         double presentationSeconds,
                                         BOOL isKeyFrame);
void VCAMSurfaceBrokerEndRemoteDecoderSession(uint64_t epoch);

NS_ASSUME_NONNULL_END

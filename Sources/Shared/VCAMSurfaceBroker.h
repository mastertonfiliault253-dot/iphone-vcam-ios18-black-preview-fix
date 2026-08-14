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

NS_ASSUME_NONNULL_END

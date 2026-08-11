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

NS_ASSUME_NONNULL_END

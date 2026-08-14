#import <Foundation/Foundation.h>
#import "../Shared/VCAMHLSLoopbackProtocol.h"

NS_ASSUME_NONNULL_BEGIN

/// Starts the vcamd-owned HTTP proxy on 127.0.0.1. The proxy never decodes
/// media; it only relays HLS playlists and segments to SpringBoard.
FOUNDATION_EXPORT void VCAMHLSLoopbackProxyStart(void);

/// Creates the sole active, random session accepted by the proxy. Only the
/// audit-identified SpringBoard XPC command calls this entry point. Creating a
/// new session invalidates every URL from the previous HLS source.
FOUNDATION_EXPORT BOOL VCAMHLSLoopbackProxyRegisterSession(
    NSURL *upstreamURL, uint64_t sessionEpoch,
    uint64_t tokenHigh, uint64_t tokenLow);

/// Invalidates the active session only when both random token halves match.
FOUNDATION_EXPORT BOOL VCAMHLSLoopbackProxyInvalidateSession(
    uint64_t tokenHigh, uint64_t tokenLow);

NS_ASSUME_NONNULL_END

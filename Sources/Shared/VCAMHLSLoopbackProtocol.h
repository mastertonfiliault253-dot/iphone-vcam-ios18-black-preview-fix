#import <Foundation/Foundation.h>
#include <arpa/inet.h>

NS_ASSUME_NONNULL_BEGIN

#define VCAMHLSLoopbackProxyPort 46322

static inline BOOL VCAMHLSLoopbackProxyNeedsRelay(NSURL *upstreamURL) {
    NSString *host = upstreamURL.host.lowercaseString ?: @"";
    BOOL loopback = [host isEqualToString:@"127.0.0.1"] ||
        [host isEqualToString:@"localhost"] || [host isEqualToString:@"::1"];
    struct in_addr ipv4 = {0};
    struct in6_addr ipv6 = {0};
    BOOL numeric = inet_pton(AF_INET, host.UTF8String, &ipv4) == 1 ||
        inet_pton(AF_INET6, host.UTF8String, &ipv6) == 1;
    return [upstreamURL.scheme.lowercaseString isEqualToString:@"http"] &&
        !loopback && numeric;
}

/// Builds the AVPlayer URL for an audit-authorized random relay session.
/// Relative HLS resources inherit the tokenized path prefix automatically.
static inline NSURL * _Nullable VCAMHLSLoopbackProxyURLForUpstreamURL(
    NSURL *upstreamURL, uint64_t tokenHigh, uint64_t tokenLow) {
    if (upstreamURL == nil || tokenHigh == 0 || tokenLow == 0) return nil;
    if (!VCAMHLSLoopbackProxyNeedsRelay(upstreamURL)) return upstreamURL;
    NSURLComponents *components = [NSURLComponents componentsWithURL:upstreamURL
                                               resolvingAgainstBaseURL:NO];
    components.scheme = @"http";
    components.host = @"127.0.0.1";
    components.port = @(VCAMHLSLoopbackProxyPort);
    NSString *sessionPrefix = [NSString stringWithFormat:
        @"/__vcam_hls/%016llx%016llx", tokenHigh, tokenLow];
    components.percentEncodedPath = [sessionPrefix stringByAppendingString:
        components.percentEncodedPath.length > 0 ? components.percentEncodedPath : @"/"];
    components.user = nil;
    components.password = nil;
    return components.URL;
}

NS_ASSUME_NONNULL_END

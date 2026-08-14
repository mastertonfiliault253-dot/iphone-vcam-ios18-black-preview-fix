#import "VCAMHLSLoopbackProxy.h"

#import "../Core/VCAMConfiguration.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

static const NSUInteger VCAMHLSMaximumRequestHeaderBytes = 64 * 1024;
static const NSUInteger VCAMHLSMaximumPlaylistResponseBytes = 4 * 1024 * 1024;
static const NSUInteger VCAMHLSMaximumPlaylistSignatureProbeBytes = 64 * 1024;
static const long double VCAMHLSRequestHeaderDeadlineSeconds = 5.0L;
static const long double VCAMHLSResponseDeadlineSeconds = 30.0L;
static const long VCAMHLSMaximumConcurrentClients = 12;
static NSURL *VCAMHLSUpstreamURL;
static uint64_t VCAMHLSSessionTokenHigh;
static uint64_t VCAMHLSSessionTokenLow;
static uint64_t VCAMHLSSessionEpoch;

static long double VCAMHLSMonotonicSeconds(void) {
    struct timespec timestamp = {0};
    if (clock_gettime(CLOCK_MONOTONIC, &timestamp) != 0) return 0.0L;
    return (long double)timestamp.tv_sec +
        ((long double)timestamp.tv_nsec / 1000000000.0L);
}

static BOOL VCAMHLSDeadlineExpired(long double deadline) {
    long double now = VCAMHLSMonotonicSeconds();
    return now == 0.0L || now >= deadline;
}

static BOOL VCAMHLSWaitForSocket(int descriptor, short events,
                                 long double deadline) {
    while (!VCAMHLSDeadlineExpired(deadline)) {
        long double remaining = deadline - VCAMHLSMonotonicSeconds();
        int milliseconds = (int)MIN(MAX(remaining * 1000.0L, 1.0L), 2000.0L);
        struct pollfd pollDescriptor = {
            .fd = descriptor, .events = events, .revents = 0,
        };
        int ready = poll(&pollDescriptor, 1, milliseconds);
        if (ready < 0 && errno == EINTR) continue;
        if (ready <= 0) continue;
        if ((pollDescriptor.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0 &&
            (pollDescriptor.revents & events) == 0) return NO;
        if ((pollDescriptor.revents & events) != 0) return YES;
    }
    return NO;
}

BOOL VCAMHLSLoopbackProxyRegisterSession(NSURL *upstreamURL,
                                         uint64_t sessionEpoch,
                                         uint64_t tokenHigh,
                                         uint64_t tokenLow) {
    if (sessionEpoch == 0 || tokenHigh == 0 || tokenLow == 0 ||
        !VCAMHLSLoopbackProxyNeedsRelay(upstreamURL)) {
        return NO;
    }
    @synchronized ([VCAMConfiguration class]) {
        if (sessionEpoch <= VCAMHLSSessionEpoch) return NO;
        VCAMHLSUpstreamURL = [upstreamURL copy];
        VCAMHLSSessionEpoch = sessionEpoch;
        VCAMHLSSessionTokenHigh = tokenHigh;
        VCAMHLSSessionTokenLow = tokenLow;
    }
    return YES;
}

BOOL VCAMHLSLoopbackProxyInvalidateSession(uint64_t tokenHigh,
                                           uint64_t tokenLow) {
    BOOL invalidated = NO;
    @synchronized ([VCAMConfiguration class]) {
        if (tokenHigh != 0 && tokenLow != 0 &&
            tokenHigh == VCAMHLSSessionTokenHigh &&
            tokenLow == VCAMHLSSessionTokenLow) {
            VCAMHLSUpstreamURL = nil;
            VCAMHLSSessionTokenHigh = 0;
            VCAMHLSSessionTokenLow = 0;
            invalidated = YES;
        }
    }
    return invalidated;
}

static NSURL *VCAMHLSCopyUpstreamURLForTarget(NSString *target,
                                              NSString **forwardTarget,
                                              NSString **loopbackPrefix) {
    NSURLComponents *components = [NSURLComponents componentsWithString:
        [@"http://127.0.0.1" stringByAppendingString:target]];
    NSString *path = components.percentEncodedPath ?: @"";
    NSString *prefix = @"/__vcam_hls/";
    if (![path hasPrefix:prefix] || path.length < prefix.length + 33) return nil;
    NSString *tokenText = [path substringWithRange:
        NSMakeRange(prefix.length, 32)];
    if ([path characterAtIndex:prefix.length + 32] != '/') return nil;
    NSString *highText = [tokenText substringToIndex:16];
    NSString *lowText = [tokenText substringFromIndex:16];
    char *highEnd = NULL;
    char *lowEnd = NULL;
    uint64_t high = strtoull(highText.UTF8String, &highEnd, 16);
    uint64_t low = strtoull(lowText.UTF8String, &lowEnd, 16);
    if (high == 0 || low == 0 || highEnd == NULL || lowEnd == NULL ||
        *highEnd != '\0' || *lowEnd != '\0') return nil;
    @synchronized ([VCAMConfiguration class]) {
        if (high != VCAMHLSSessionTokenHigh || low != VCAMHLSSessionTokenLow ||
            VCAMHLSUpstreamURL == nil) return nil;
        NSString *pathRemainder = [path substringFromIndex:prefix.length + 32];
        NSString *query = components.percentEncodedQuery.length > 0 ?
            [@"?" stringByAppendingString:components.percentEncodedQuery] : @"";
        if (forwardTarget != NULL) {
            *forwardTarget = [pathRemainder stringByAppendingString:query];
        }
        if (loopbackPrefix != NULL) {
            *loopbackPrefix = [NSString stringWithFormat:
                @"http://127.0.0.1:%u%@%@", VCAMHLSLoopbackProxyPort,
                prefix, tokenText];
        }
        return [VCAMHLSUpstreamURL copy];
    }
}

static BOOL VCAMHLSSendAll(int descriptor, const void *bytes, size_t length,
                           long double deadline) {
    const uint8_t *cursor = bytes;
    while (length > 0) {
        if (VCAMHLSDeadlineExpired(deadline)) return NO;
        ssize_t written = send(descriptor, cursor, length, 0);
        if (written < 0 && errno == EINTR) continue;
        if (written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            if (!VCAMHLSWaitForSocket(descriptor, POLLOUT, deadline)) return NO;
            continue;
        }
        if (written <= 0) return NO;
        cursor += (size_t)written;
        length -= (size_t)written;
    }
    return YES;
}

static void VCAMHLSWriteError(int descriptor, NSInteger status,
                              NSString *message) {
    NSData *body = [message dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    NSString *header = [NSString stringWithFormat:
        @"HTTP/1.1 %ld %@\r\nContent-Type: text/plain; charset=utf-8\r\n"
         "Content-Length: %lu\r\nConnection: close\r\n\r\n",
        (long)status, message, (unsigned long)body.length];
    NSData *headerData = [header dataUsingEncoding:NSUTF8StringEncoding];
    long double deadline = VCAMHLSMonotonicSeconds() + 1.0L;
    VCAMHLSSendAll(descriptor, headerData.bytes, headerData.length, deadline);
    VCAMHLSSendAll(descriptor, body.bytes, body.length, deadline);
}

static NSData *VCAMHLSReadRequestHeader(int descriptor, long double deadline) {
    NSMutableData *data = [NSMutableData data];
    const uint8_t terminator[] = {'\r', '\n', '\r', '\n'};
    while (data.length < VCAMHLSMaximumRequestHeaderBytes) {
        if (VCAMHLSDeadlineExpired(deadline)) return nil;
        uint8_t chunk[4096];
        ssize_t count = recv(descriptor, chunk, sizeof(chunk), 0);
        if (count < 0 && errno == EINTR) continue;
        if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            if (!VCAMHLSWaitForSocket(descriptor, POLLIN, deadline)) return nil;
            continue;
        }
        if (count <= 0) return nil;
        [data appendBytes:chunk length:(NSUInteger)count];
        if ([data rangeOfData:[NSData dataWithBytes:terminator
                                             length:sizeof(terminator)]
                      options:0
                        range:NSMakeRange(0, data.length)].location != NSNotFound) {
            return data;
        }
    }
    return nil;
}

static int VCAMHLSConnect(NSString *host, uint16_t port,
                          long double deadline) {
    struct sockaddr_storage storage = {0};
    socklen_t addressLength = 0;
    int family = AF_UNSPEC;
    struct sockaddr_in *ipv4 = (struct sockaddr_in *)&storage;
    struct sockaddr_in6 *ipv6 = (struct sockaddr_in6 *)&storage;
    if (inet_pton(AF_INET, host.UTF8String, &ipv4->sin_addr) == 1) {
        family = AF_INET;
        ipv4->sin_len = sizeof(*ipv4);
        ipv4->sin_family = AF_INET;
        ipv4->sin_port = htons(port);
        addressLength = sizeof(*ipv4);
    } else if (inet_pton(AF_INET6, host.UTF8String, &ipv6->sin6_addr) == 1) {
        family = AF_INET6;
        ipv6->sin6_len = sizeof(*ipv6);
        ipv6->sin6_family = AF_INET6;
        ipv6->sin6_port = htons(port);
        addressLength = sizeof(*ipv6);
    } else {
        return -1;
    }
    int descriptor = socket(family, SOCK_STREAM, 0);
    if (descriptor < 0) return -1;
    int noSignal = 1;
    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
               sizeof(noSignal));
    int flags = fcntl(descriptor, F_GETFL, 0);
    if (flags < 0 || fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != 0) {
        close(descriptor);
        return -1;
    }
    int result = connect(descriptor, (struct sockaddr *)&storage, addressLength);
    while (result != 0 && errno == EINPROGRESS &&
           !VCAMHLSDeadlineExpired(deadline)) {
        long double remaining = deadline - VCAMHLSMonotonicSeconds();
        int milliseconds = (int)MIN(remaining * 1000.0L, 2000.0L);
        struct pollfd pollDescriptor = {
            .fd = descriptor, .events = POLLOUT, .revents = 0,
        };
        int ready = poll(&pollDescriptor, 1, MAX(milliseconds, 1));
        if (ready < 0 && errno == EINTR) continue;
        if (ready <= 0) continue;
        int socketError = 0;
        socklen_t errorLength = sizeof(socketError);
        if (getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError,
                       &errorLength) != 0 || socketError != 0) {
            close(descriptor);
            return -1;
        }
        result = 0;
    }
    if (result != 0 || VCAMHLSDeadlineExpired(deadline)) {
        close(descriptor);
        return -1;
    }
    return descriptor;
}

static NSString *VCAMHLSSanitizedForwardHeaders(NSArray<NSString *> *lines,
                                                 NSString *hostHeader) {
    NSMutableString *headers = [NSMutableString stringWithFormat:
        @"Host: %@\r\nConnection: close\r\nAccept-Encoding: identity\r\n",
        hostHeader];
    for (NSUInteger index = 1; index < lines.count; index++) {
        NSString *line = lines[index];
        NSRange separator = [line rangeOfString:@":"];
        if (separator.location == NSNotFound) continue;
        NSString *name = [[line substringToIndex:separator.location]
            lowercaseString];
        if ([name isEqualToString:@"host"] ||
            [name isEqualToString:@"connection"] ||
            [name isEqualToString:@"proxy-connection"] ||
            [name isEqualToString:@"accept-encoding"] ||
            [name isEqualToString:@"content-length"] ||
            [name isEqualToString:@"transfer-encoding"]) {
            continue;
        }
        [headers appendFormat:@"%@\r\n", line];
    }
    return headers;
}

static NSRange VCAMHLSHTTPHeaderRange(NSData *data) {
    const uint8_t terminator[] = {'\r', '\n', '\r', '\n'};
    return [data rangeOfData:[NSData dataWithBytes:terminator
                                            length:sizeof(terminator)]
                     options:0
                       range:NSMakeRange(0, data.length)];
}

static NSString *VCAMHLSHeaderValue(NSArray<NSString *> *lines,
                                    NSString *wantedName) {
    for (NSUInteger index = 1; index < lines.count; index++) {
        NSString *line = lines[index];
        NSRange separator = [line rangeOfString:@":"];
        if (separator.location == NSNotFound) continue;
        NSString *name = [[line substringToIndex:separator.location]
            lowercaseString];
        if (![name isEqualToString:wantedName.lowercaseString]) continue;
        return [[line substringFromIndex:NSMaxRange(separator)]
            stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];
    }
    return nil;
}

typedef NS_ENUM(NSInteger, VCAMHLSPlaylistSignatureState) {
    VCAMHLSPlaylistSignatureUnknown = -1,
    VCAMHLSPlaylistSignatureNo = 0,
    VCAMHLSPlaylistSignatureYes = 1,
};

static VCAMHLSPlaylistSignatureState
VCAMHLSPlaylistSignatureStateForDecodedPrefix(NSData *prefix) {
    const uint8_t *bytes = prefix.bytes;
    NSUInteger cursor = 0;
    const uint8_t bom[] = {0xef, 0xbb, 0xbf};
    if (prefix.length < sizeof(bom)) {
        BOOL partialBOM = prefix.length > 0;
        for (NSUInteger index = 0; index < prefix.length; index++) {
            partialBOM = partialBOM && bytes[index] == bom[index];
        }
        if (partialBOM) return VCAMHLSPlaylistSignatureUnknown;
    } else if (memcmp(bytes, bom, sizeof(bom)) == 0) {
        cursor = sizeof(bom);
    }
    while (cursor < prefix.length &&
           (bytes[cursor] == ' ' || bytes[cursor] == '\t' ||
            bytes[cursor] == '\r' || bytes[cursor] == '\n')) {
        cursor += 1;
    }
    if (cursor == prefix.length) return VCAMHLSPlaylistSignatureUnknown;
    static const uint8_t signature[] = {'#', 'E', 'X', 'T', 'M', '3', 'U'};
    NSUInteger available = prefix.length - cursor;
    NSUInteger compared = MIN(available, sizeof(signature));
    if (memcmp(bytes + cursor, signature, compared) != 0) {
        return VCAMHLSPlaylistSignatureNo;
    }
    return available >= sizeof(signature) ? VCAMHLSPlaylistSignatureYes :
        VCAMHLSPlaylistSignatureUnknown;
}

static VCAMHLSPlaylistSignatureState
VCAMHLSPlaylistSignatureStateForResponse(NSData *response,
                                         NSArray<NSString *> *headerLines) {
    NSRange header = VCAMHLSHTTPHeaderRange(response);
    if (header.location == NSNotFound) return VCAMHLSPlaylistSignatureUnknown;
    NSData *body = [response subdataWithRange:NSMakeRange(
        NSMaxRange(header), response.length - NSMaxRange(header))];
    NSString *transferEncoding = VCAMHLSHeaderValue(headerLines,
                                                     @"transfer-encoding");
    if (![transferEncoding.lowercaseString containsString:@"chunked"]) {
        return VCAMHLSPlaylistSignatureStateForDecodedPrefix(body);
    }

    const uint8_t *bytes = body.bytes;
    NSUInteger cursor = 0;
    NSMutableData *decodedPrefix = [NSMutableData data];
    while (cursor < body.length &&
           decodedPrefix.length < VCAMHLSMaximumPlaylistSignatureProbeBytes) {
        NSUInteger lineEnd = NSNotFound;
        for (NSUInteger index = cursor; index + 1 < body.length; index++) {
            if (bytes[index] == '\r' && bytes[index + 1] == '\n') {
                lineEnd = index;
                break;
            }
        }
        if (lineEnd == NSNotFound || lineEnd == cursor) {
            return VCAMHLSPlaylistSignatureUnknown;
        }
        NSString *line = [[NSString alloc] initWithData:
            [body subdataWithRange:NSMakeRange(cursor, lineEnd - cursor)]
                                               encoding:NSASCIIStringEncoding];
        NSString *sizeText = [[line componentsSeparatedByString:@";"] firstObject];
        NSScanner *scanner = [NSScanner scannerWithString:sizeText ?: @""];
        unsigned long long chunkSize = 0;
        if (![scanner scanHexLongLong:&chunkSize] || !scanner.isAtEnd ||
            chunkSize > NSUIntegerMax) {
            return VCAMHLSPlaylistSignatureUnknown;
        }
        cursor = lineEnd + 2;
        if (chunkSize == 0) {
            VCAMHLSPlaylistSignatureState state =
                VCAMHLSPlaylistSignatureStateForDecodedPrefix(decodedPrefix);
            return state == VCAMHLSPlaylistSignatureUnknown ?
                VCAMHLSPlaylistSignatureNo : state;
        }
        NSUInteger available = body.length - cursor;
        NSUInteger payload = MIN((NSUInteger)chunkSize, available);
        NSUInteger wanted = MIN(payload,
            VCAMHLSMaximumPlaylistSignatureProbeBytes - decodedPrefix.length);
        [decodedPrefix appendBytes:bytes + cursor length:wanted];
        VCAMHLSPlaylistSignatureState state =
            VCAMHLSPlaylistSignatureStateForDecodedPrefix(decodedPrefix);
        if (state != VCAMHLSPlaylistSignatureUnknown) return state;
        if (payload < (NSUInteger)chunkSize) {
            return VCAMHLSPlaylistSignatureUnknown;
        }
        cursor += (NSUInteger)chunkSize;
        if (cursor + 1 >= body.length || bytes[cursor] != '\r' ||
            bytes[cursor + 1] != '\n') {
            return VCAMHLSPlaylistSignatureUnknown;
        }
        cursor += 2;
    }
    return VCAMHLSPlaylistSignatureUnknown;
}

static NSData *VCAMHLSDecodeChunkedBody(NSData *body) {
    const uint8_t *bytes = body.bytes;
    NSUInteger cursor = 0;
    NSMutableData *decoded = [NSMutableData data];
    while (cursor < body.length) {
        NSUInteger lineEnd = NSNotFound;
        for (NSUInteger index = cursor; index + 1 < body.length; index++) {
            if (bytes[index] == '\r' && bytes[index + 1] == '\n') {
                lineEnd = index;
                break;
            }
        }
        if (lineEnd == NSNotFound || lineEnd == cursor) return nil;
        NSData *lineData = [body subdataWithRange:NSMakeRange(
            cursor, lineEnd - cursor)];
        NSString *line = [[NSString alloc] initWithData:lineData
                                               encoding:NSASCIIStringEncoding];
        NSString *sizeText = [[line componentsSeparatedByString:@";"] firstObject];
        NSScanner *scanner = [NSScanner scannerWithString:sizeText ?: @""];
        unsigned long long chunkSize = 0;
        if (![scanner scanHexLongLong:&chunkSize] || !scanner.isAtEnd) return nil;
        cursor = lineEnd + 2;
        if (chunkSize == 0) {
            if (cursor + 1 < body.length && bytes[cursor] == '\r' &&
                bytes[cursor + 1] == '\n') return decoded;
            const uint8_t trailerEnd[] = {'\r', '\n', '\r', '\n'};
            NSRange trailerRange = [body rangeOfData:
                [NSData dataWithBytes:trailerEnd length:sizeof(trailerEnd)]
                                             options:0
                                               range:NSMakeRange(
                                                   cursor, body.length - cursor)];
            return trailerRange.location == NSNotFound ? nil : decoded;
        }
        if (chunkSize > NSUIntegerMax || cursor > body.length ||
            (NSUInteger)chunkSize > body.length - cursor ||
            (NSUInteger)chunkSize > VCAMHLSMaximumPlaylistResponseBytes -
                MIN(decoded.length, VCAMHLSMaximumPlaylistResponseBytes)) {
            return nil;
        }
        [decoded appendBytes:bytes + cursor length:(NSUInteger)chunkSize];
        cursor += (NSUInteger)chunkSize;
        if (cursor + 1 >= body.length || bytes[cursor] != '\r' ||
            bytes[cursor + 1] != '\n') return nil;
        cursor += 2;
    }
    return nil;
}

static BOOL VCAMHLSBufferedResponseIsComplete(NSData *response,
                                              BOOL expectBody,
                                              BOOL *hasFraming,
                                              BOOL *invalid) {
    if (hasFraming != NULL) *hasFraming = NO;
    if (invalid != NULL) *invalid = NO;
    NSRange terminator = VCAMHLSHTTPHeaderRange(response);
    if (terminator.location == NSNotFound) return NO;
    if (!expectBody) return YES;
    NSString *headerText = [[NSString alloc] initWithData:
        [response subdataWithRange:NSMakeRange(0, terminator.location)]
                                                 encoding:NSISOLatin1StringEncoding];
    NSArray<NSString *> *lines = [headerText componentsSeparatedByString:@"\r\n"];
    NSData *body = [response subdataWithRange:NSMakeRange(
        NSMaxRange(terminator), response.length - NSMaxRange(terminator))];
    NSString *transferEncoding = VCAMHLSHeaderValue(lines, @"transfer-encoding");
    if ([transferEncoding.lowercaseString containsString:@"chunked"]) {
        if (hasFraming != NULL) *hasFraming = YES;
        return VCAMHLSDecodeChunkedBody(body) != nil;
    }
    NSString *contentLengthText = VCAMHLSHeaderValue(lines, @"content-length");
    if (contentLengthText.length == 0) return NO;
    if (hasFraming != NULL) *hasFraming = YES;
    NSScanner *scanner = [NSScanner scannerWithString:contentLengthText];
    unsigned long long expectedLength = 0;
    if (![scanner scanUnsignedLongLong:&expectedLength] || !scanner.isAtEnd ||
        expectedLength > NSUIntegerMax || body.length > (NSUInteger)expectedLength) {
        if (invalid != NULL) *invalid = YES;
        return NO;
    }
    return body.length == (NSUInteger)expectedLength;
}

static uint16_t VCAMHLSEffectivePort(NSURL *url) {
    if (url.port != nil) return (uint16_t)url.port.unsignedIntValue;
    return [url.scheme.lowercaseString isEqualToString:@"https"] ? 443 : 80;
}

static BOOL VCAMHLSSameOrigin(NSURL *left, NSURL *right) {
    return [left.scheme.lowercaseString isEqualToString:right.scheme.lowercaseString] &&
        [left.host.lowercaseString isEqualToString:right.host.lowercaseString] &&
        VCAMHLSEffectivePort(left) == VCAMHLSEffectivePort(right);
}

static NSString *VCAMHLSRewriteResource(NSString *resource,
                                        NSURL *requestURL,
                                        NSURL *upstreamOrigin,
                                        NSString *loopbackPrefix) {
    NSURL *resolved = [NSURL URLWithString:resource relativeToURL:requestURL].absoluteURL;
    if (resolved == nil) return nil;
    NSString *scheme = resolved.scheme.lowercaseString ?: @"";
    if (![scheme isEqualToString:@"http"] &&
        ![scheme isEqualToString:@"https"]) {
        return resource;
    }
    if (!VCAMHLSSameOrigin(resolved, upstreamOrigin)) return nil;
    NSURLComponents *components = [NSURLComponents componentsWithURL:resolved
                                               resolvingAgainstBaseURL:NO];
    NSString *path = components.percentEncodedPath.length > 0 ?
        components.percentEncodedPath : @"/";
    NSMutableString *rewritten = [NSMutableString stringWithString:loopbackPrefix];
    [rewritten appendString:path];
    if (components.percentEncodedQuery.length > 0) {
        [rewritten appendFormat:@"?%@", components.percentEncodedQuery];
    }
    if (components.percentEncodedFragment.length > 0) {
        [rewritten appendFormat:@"#%@", components.percentEncodedFragment];
    }
    return rewritten;
}

static NSString *VCAMHLSRewritePlaylistText(NSString *text,
                                            NSURL *requestURL,
                                            NSURL *upstreamOrigin,
                                            NSString *loopbackPrefix) {
    NSError *expressionError = nil;
    NSRegularExpression *uriExpression = [NSRegularExpression
        regularExpressionWithPattern:@"URI=\\\"([^\\\"]+)\\\""
                               options:NSRegularExpressionCaseInsensitive
                                 error:&expressionError];
    if (uriExpression == nil || expressionError != nil) return nil;
    BOOL trailingNewline = [text hasSuffix:@"\n"];
    NSArray<NSString *> *sourceLines = [text componentsSeparatedByCharactersInSet:
        NSCharacterSet.newlineCharacterSet];
    NSMutableArray<NSString *> *outputLines = [NSMutableArray arrayWithCapacity:
        sourceLines.count];
    for (NSString *sourceLine in sourceLines) {
        NSString *line = [sourceLine hasSuffix:@"\r"] ?
            [sourceLine substringToIndex:sourceLine.length - 1] : sourceLine;
        if (line.length == 0) {
            [outputLines addObject:line];
            continue;
        }
        if (![line hasPrefix:@"#"]) {
            NSString *rewritten = VCAMHLSRewriteResource(
                line, requestURL, upstreamOrigin, loopbackPrefix);
            if (rewritten == nil) return nil;
            [outputLines addObject:rewritten];
            continue;
        }
        NSMutableString *mutableLine = [line mutableCopy];
        NSArray<NSTextCheckingResult *> *matches = [uriExpression
            matchesInString:line options:0 range:NSMakeRange(0, line.length)];
        for (NSTextCheckingResult *match in matches.reverseObjectEnumerator) {
            if (match.numberOfRanges < 2) continue;
            NSRange valueRange = [match rangeAtIndex:1];
            NSString *value = [line substringWithRange:valueRange];
            NSString *rewritten = VCAMHLSRewriteResource(
                value, requestURL, upstreamOrigin, loopbackPrefix);
            if (rewritten == nil) return nil;
            [mutableLine replaceCharactersInRange:valueRange withString:rewritten];
        }
        [outputLines addObject:mutableLine];
    }
    NSString *result = [outputLines componentsJoinedByString:@"\n"];
    if (trailingNewline && ![result hasSuffix:@"\n"]) {
        result = [result stringByAppendingString:@"\n"];
    }
    return result;
}

static NSData *VCAMHLSRewriteBufferedResponse(NSData *response,
                                              NSURL *upstream,
                                              NSURL *requestURL,
                                              NSString *loopbackPrefix,
                                              BOOL rewritePlaylistBody,
                                              BOOL expectBody) {
    NSRange terminator = VCAMHLSHTTPHeaderRange(response);
    if (terminator.location == NSNotFound) return nil;
    NSUInteger bodyOffset = NSMaxRange(terminator);
    NSData *headerData = [response subdataWithRange:
        NSMakeRange(0, terminator.location)];
    NSString *headerText = [[NSString alloc] initWithData:headerData
                                                 encoding:NSISOLatin1StringEncoding];
    NSArray<NSString *> *lines = [headerText componentsSeparatedByString:@"\r\n"];
    if (lines.count == 0) return nil;
    NSString *contentEncoding = VCAMHLSHeaderValue(lines, @"content-encoding");
    if (contentEncoding.length > 0 &&
        ![contentEncoding.lowercaseString isEqualToString:@"identity"]) {
        return nil;
    }
    NSData *body = [response subdataWithRange:
        NSMakeRange(bodyOffset, response.length - bodyOffset)];
    NSString *transferEncoding = VCAMHLSHeaderValue(lines, @"transfer-encoding");
    if ([transferEncoding.lowercaseString containsString:@"chunked"]) {
        body = VCAMHLSDecodeChunkedBody(body);
        if (body == nil) return nil;
    } else {
        NSString *contentLengthText = VCAMHLSHeaderValue(lines, @"content-length");
        if (expectBody && contentLengthText.length > 0) {
            NSScanner *lengthScanner = [NSScanner scannerWithString:contentLengthText];
            unsigned long long expectedLength = 0;
            if (![lengthScanner scanUnsignedLongLong:&expectedLength] ||
                !lengthScanner.isAtEnd || expectedLength != body.length) return nil;
        }
    }
    if (rewritePlaylistBody) {
        NSString *bodyText = [[NSString alloc] initWithData:body
                                                   encoding:NSUTF8StringEncoding];
        bodyText = bodyText == nil ? nil : VCAMHLSRewritePlaylistText(
            bodyText, requestURL, upstream, loopbackPrefix);
        if (bodyText == nil) return nil;
        body = [bodyText dataUsingEncoding:NSUTF8StringEncoding];
    }

    NSMutableString *rewrittenHeader = [NSMutableString stringWithFormat:
        @"%@\r\n", lines[0]];
    for (NSUInteger index = 1; index < lines.count; index++) {
        NSString *line = lines[index];
        NSRange separator = [line rangeOfString:@":"];
        if (separator.location == NSNotFound) continue;
        NSString *name = [[line substringToIndex:separator.location]
            lowercaseString];
        if ((expectBody && [name isEqualToString:@"content-length"]) ||
            [name isEqualToString:@"transfer-encoding"] ||
            [name isEqualToString:@"connection"] ||
            [name isEqualToString:@"content-encoding"]) continue;
        if ([name isEqualToString:@"location"]) {
            NSString *value = [[line substringFromIndex:NSMaxRange(separator)]
                stringByTrimmingCharactersInSet:
                    NSCharacterSet.whitespaceAndNewlineCharacterSet];
            value = VCAMHLSRewriteResource(value, requestURL, upstream,
                                            loopbackPrefix);
            if (value == nil) return nil;
            line = [NSString stringWithFormat:@"Location: %@", value];
        }
        [rewrittenHeader appendFormat:@"%@\r\n", line];
    }
    if (expectBody) {
        [rewrittenHeader appendFormat:@"Content-Length: %lu\r\n",
            (unsigned long)body.length];
    }
    [rewrittenHeader appendString:@"Connection: close\r\n\r\n"];
    NSMutableData *result = [NSMutableData dataWithData:
        [rewrittenHeader dataUsingEncoding:NSISOLatin1StringEncoding]];
    [result appendData:body];
    return result;
}

static void VCAMHLSHandleClient(int client) {
    @autoreleasepool {
        int noSignal = 1;
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                   sizeof(noSignal));
        int clientFlags = fcntl(client, F_GETFL, 0);
        if (clientFlags < 0 ||
            fcntl(client, F_SETFL, clientFlags | O_NONBLOCK) != 0) {
            close(client);
            return;
        }

        long double requestDeadline = VCAMHLSMonotonicSeconds() +
            VCAMHLSRequestHeaderDeadlineSeconds;
        NSData *requestData = VCAMHLSReadRequestHeader(client, requestDeadline);
        NSString *request = requestData == nil ? nil :
            [[NSString alloc] initWithData:requestData
                                  encoding:NSISOLatin1StringEncoding];
        NSArray<NSString *> *lines = [request componentsSeparatedByString:@"\r\n"];
        NSArray<NSString *> *requestParts = lines.count == 0 ? @[] :
            [lines[0] componentsSeparatedByString:@" "];
        NSString *method = requestParts.count > 0 ? requestParts[0] : @"";
        NSString *target = requestParts.count > 1 ? requestParts[1] : @"";
        if ((!([method isEqualToString:@"GET"] ||
               [method isEqualToString:@"HEAD"])) ||
            ![target hasPrefix:@"/"] || [target hasPrefix:@"//"]) {
            VCAMHLSWriteError(client, 400, @"Bad Request");
            close(client);
            return;
        }

        NSString *forwardTarget = nil;
        NSString *loopbackPrefix = nil;
        NSURL *upstream = VCAMHLSCopyUpstreamURLForTarget(
            target, &forwardTarget, &loopbackPrefix);
        if (upstream == nil ||
            ![upstream.scheme.lowercaseString isEqualToString:@"http"] ||
            upstream.host.length == 0) {
            VCAMHLSWriteError(client, 503, @"HLS Upstream Unavailable");
            close(client);
            return;
        }
        uint16_t port = (uint16_t)(upstream.port != nil
            ? upstream.port.unsignedIntValue : 80);
        long double responseDeadline = VCAMHLSMonotonicSeconds() +
            VCAMHLSResponseDeadlineSeconds;
        int server = VCAMHLSConnect(upstream.host, port, responseDeadline);
        if (server < 0) {
            VCAMHLSWriteError(client, 502, @"HLS Upstream Connect Failed");
            close(client);
            return;
        }
        NSString *hostLiteral = [upstream.host containsString:@":"] ?
            [NSString stringWithFormat:@"[%@]", upstream.host] : upstream.host;
        NSString *hostHeader = port == 80 ? hostLiteral :
            [NSString stringWithFormat:@"%@:%u", hostLiteral, port];
        NSString *headers = VCAMHLSSanitizedForwardHeaders(lines, hostHeader);
        NSString *forward = [NSString stringWithFormat:
            @"%@ %@ HTTP/1.1\r\n%@\r\n", method, forwardTarget, headers];
        NSData *forwardData = [forward dataUsingEncoding:NSISOLatin1StringEncoding];
        BOOL sent = VCAMHLSSendAll(server, forwardData.bytes,
                                   forwardData.length, responseDeadline);
        uint8_t buffer[64 * 1024];
        NSData *responseStart = sent ? VCAMHLSReadRequestHeader(
            server, responseDeadline) : nil;
        NSRange responseHeader = responseStart == nil ?
            NSMakeRange(NSNotFound, 0) : VCAMHLSHTTPHeaderRange(responseStart);
        NSString *responseHeaderText = responseHeader.location == NSNotFound ? nil :
            [[NSString alloc] initWithData:[responseStart subdataWithRange:
                NSMakeRange(0, responseHeader.location)]
                                      encoding:NSISOLatin1StringEncoding];
        NSString *statusLine = [[responseHeaderText
            componentsSeparatedByString:@"\r\n"] firstObject] ?: @"";
        NSArray<NSString *> *responseHeaderLines = [responseHeaderText
            componentsSeparatedByString:@"\r\n"];
        NSArray<NSString *> *statusParts = [statusLine componentsSeparatedByString:@" "];
        NSInteger status = statusParts.count > 1 ? [statusParts[1] integerValue] : 0;
        NSString *targetPath = [[forwardTarget componentsSeparatedByString:@"?"]
            firstObject].lowercaseString;
        NSString *contentType = VCAMHLSHeaderValue(responseHeaderLines,
                                                    @"content-type").lowercaseString;
        BOOL playlistContentType = [contentType containsString:@"mpegurl"] ||
            [contentType containsString:@"vnd.apple.mpegurl"];
        BOOL expectBody = [method isEqualToString:@"GET"] && status != 204 &&
            status != 304 && !(status >= 100 && status < 200);
        BOOL probePlaylistSignature = expectBody && status >= 200 && status < 300 &&
            ![targetPath hasSuffix:@".m3u8"] && !playlistContentType;
        VCAMHLSPlaylistSignatureState signatureState = responseStart == nil ?
            VCAMHLSPlaylistSignatureUnknown :
            VCAMHLSPlaylistSignatureStateForResponse(responseStart,
                                                      responseHeaderLines);
        BOOL signatureProbeFailed = NO;
        if (probePlaylistSignature &&
            signatureState == VCAMHLSPlaylistSignatureUnknown) {
            NSMutableData *probed = [responseStart mutableCopy];
            while (signatureState == VCAMHLSPlaylistSignatureUnknown &&
                   probed.length < VCAMHLSMaximumPlaylistSignatureProbeBytes &&
                   !VCAMHLSDeadlineExpired(responseDeadline)) {
                NSUInteger remaining = VCAMHLSMaximumPlaylistSignatureProbeBytes -
                    probed.length;
                size_t readCapacity = MIN(sizeof(buffer), remaining);
                ssize_t count = recv(server, buffer, readCapacity, 0);
                if (count < 0 && errno == EINTR) continue;
                if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
                    if (!VCAMHLSWaitForSocket(server, POLLIN, responseDeadline)) break;
                    continue;
                }
                if (count <= 0) break;
                [probed appendBytes:buffer length:(NSUInteger)count];
                signatureState = VCAMHLSPlaylistSignatureStateForResponse(
                    probed, responseHeaderLines);
            }
            responseStart = [probed copy];
            signatureProbeFailed =
                signatureState == VCAMHLSPlaylistSignatureUnknown;
        }
        BOOL playlistSignature =
            signatureState == VCAMHLSPlaylistSignatureYes;
        BOOL playlistResponse = [targetPath hasSuffix:@".m3u8"] ||
            playlistContentType || playlistSignature;
        BOOL rewriteResponse = playlistResponse ||
            (status >= 300 && status < 400);
        NSURLComponents *originComponents = [NSURLComponents new];
        originComponents.scheme = upstream.scheme;
        originComponents.host = upstream.host;
        originComponents.port = upstream.port;
        NSURL *requestURL = [NSURL URLWithString:forwardTarget
                                   relativeToURL:originComponents.URL].absoluteURL;
        if (responseStart == nil || responseHeader.location == NSNotFound ||
            signatureProbeFailed) {
            VCAMHLSWriteError(client, 502, @"Invalid HLS Upstream Response");
        } else if (rewriteResponse) {
            NSMutableData *buffered = [responseStart mutableCopy];
            BOOL complete = YES;
            BOOL reachedEOF = NO;
            BOOL hasFraming = NO;
            BOOL invalidFraming = NO;
            BOOL framedComplete = VCAMHLSBufferedResponseIsComplete(
                buffered, expectBody, &hasFraming, &invalidFraming);
            while (!framedComplete && !invalidFraming &&
                   !VCAMHLSDeadlineExpired(responseDeadline)) {
                ssize_t count = recv(server, buffer, sizeof(buffer), 0);
                if (count < 0 && errno == EINTR) continue;
                if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
                    if (!VCAMHLSWaitForSocket(server, POLLIN,
                                              responseDeadline)) {
                        complete = NO;
                        break;
                    }
                    continue;
                }
                if (count < 0) {
                    complete = NO;
                    break;
                }
                if (count == 0) {
                    reachedEOF = YES;
                    break;
                }
                if ((NSUInteger)count > VCAMHLSMaximumPlaylistResponseBytes -
                        MIN(buffered.length, VCAMHLSMaximumPlaylistResponseBytes)) {
                    complete = NO;
                    break;
                }
                [buffered appendBytes:buffer length:(NSUInteger)count];
                framedComplete = VCAMHLSBufferedResponseIsComplete(
                    buffered, expectBody, &hasFraming, &invalidFraming);
            }
            complete = !invalidFraming && (framedComplete ||
                (reachedEOF && !hasFraming));
            NSData *rewritten = complete ? VCAMHLSRewriteBufferedResponse(
                buffered, upstream, requestURL, loopbackPrefix,
                playlistResponse && status >= 200 && status < 300,
                expectBody) : nil;
            if (rewritten == nil) {
                VCAMHLSWriteError(client, 502, @"Unsupported HLS Playlist Response");
            } else {
                VCAMHLSSendAll(client, rewritten.bytes, rewritten.length,
                               responseDeadline);
            }
        } else if (VCAMHLSSendAll(client, responseStart.bytes,
                                  responseStart.length, responseDeadline)) {
            while (!VCAMHLSDeadlineExpired(responseDeadline)) {
                ssize_t count = recv(server, buffer, sizeof(buffer), 0);
                if (count < 0 && errno == EINTR) continue;
                if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
                    if (!VCAMHLSWaitForSocket(server, POLLIN,
                                              responseDeadline)) break;
                    continue;
                }
                if (count <= 0) break;
                if (!VCAMHLSSendAll(client, buffer, (size_t)count,
                                    responseDeadline)) break;
            }
        }
        close(server);
        close(client);
    }
}

void VCAMHLSLoopbackProxyStart(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dispatch_semaphore_t clientSlots = dispatch_semaphore_create(
            VCAMHLSMaximumConcurrentClients);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            int listener = socket(AF_INET, SOCK_STREAM, 0);
            if (listener < 0) return;
            int reuse = 1;
            setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
            struct sockaddr_in address = {0};
            address.sin_len = sizeof(address);
            address.sin_family = AF_INET;
            address.sin_port = htons(VCAMHLSLoopbackProxyPort);
            address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
            if (bind(listener, (struct sockaddr *)&address, sizeof(address)) != 0 ||
                listen(listener, 16) != 0) {
                [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
                    @"vcamd HLS loopback proxy failed port=%u errno=%d",
                    VCAMHLSLoopbackProxyPort, errno]];
                close(listener);
                return;
            }
            [VCAMConfiguration appendProcessLog:[NSString stringWithFormat:
                @"vcamd HLS loopback proxy ready address=127.0.0.1:%u",
                VCAMHLSLoopbackProxyPort]];
            while (YES) {
                int client = accept(listener, NULL, NULL);
                if (client < 0) {
                    if (errno == EINTR) continue;
                    [NSThread sleepForTimeInterval:0.1];
                    continue;
                }
                if (dispatch_semaphore_wait(clientSlots,
                        DISPATCH_TIME_NOW) != 0) {
                    close(client);
                    continue;
                }
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                    VCAMHLSHandleClient(client);
                    dispatch_semaphore_signal(clientSlots);
                });
            }
        });
    });
}

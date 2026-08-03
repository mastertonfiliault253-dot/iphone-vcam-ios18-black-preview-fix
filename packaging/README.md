# RootHide package target map

`targets.json` is the machine-checked map from process injection requirements to
RootHide packages. It records both implemented and intentionally blocked targets
so a filter change cannot silently load the Camera UI/FFmpeg binary into a vital
daemon.

| Target | Package | Current state |
| --- | --- | --- |
| `VCAMController` | `com.codex.vcam` | Implemented; Camera only |
| `VCAMAppClient` | `com.codex.vcam.browser-client` | Mapped; waits for `vcamd` shared frames |
| `VCAMWebKitClient` | `com.codex.vcam.browser-client` | Mapped; device executable discovery required |
| `VCAMMediaServerClient` | `com.codex.vcam.mediaserver-client` | Separate, disabled; load-probe required before hooks |
| `vcamd` | `com.codex.vcam.daemon` | Mapped; IOSurface/XPC implementation pending |

Only `com.codex.vcam` is emitted by the current Makefile. The other identifiers
are reserved package seams, not claims that browser or mediaserver replacement
already works. Browser and daemon clients must consume decoded IOSurface frames
from `vcamd`; they must not link the UI or instantiate FFmpeg independently.

The mediaserver package remains disabled until a no-hook binary survives ten
userspace restarts without a watchdog timeout. WebKit executable filters must be
filled from an on-device process sample rather than guessed.

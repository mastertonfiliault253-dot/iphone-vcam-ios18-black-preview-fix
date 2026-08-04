# VCAM injection target architecture

## Current package

The current package builds one `VCAM.dylib` from `Makefile` and filters it only
into `com.apple.camera` through `VCAM.plist`. That dylib links UIKit, PhotosUI,
FFmpeg, and all source/recording code. `VCAMCaptureHooks.xm` also starts the
floating control panel from its constructor.

This binary must not be filtered directly into `mediaserverd`. Merely loading a
UIKit/PhotosUI-linked dylib into a vital daemon increases startup and watchdog
risk even when the constructor later decides not to install hooks.

## Target package layout

| Theos target | Filter | Responsibilities | Forbidden dependencies |
| --- | --- | --- | --- |
| `VCAMController` | `com.apple.camera` | Floating panel, media picker, target selection, diagnostics | None |
| `VCAMAppClient` | `com.apple.camera`, `com.apple.mobilesafari`, `com.google.chrome.ios` | Public AVFoundation capture interception and fail-open frame consumption | PhotosUI, FFmpeg decoding |
| `VCAMWebKitClient` | WebKit web-content executables discovered on device | Headless WebRTC/WebKit capture interception | UIKit, PhotosUI, FFmpeg, blocking I/O in `%ctor` |
| `VCAMMediaServerClient` | executable `mediaserverd` | Minimal, separately enabled media-server probe/interception | UIKit, PhotosUI, UniformTypeIdentifiers, FFmpeg, network setup, blocking I/O in `%ctor` |
| `vcamd` launch daemon | no injection filter | Own configuration/media, decode local/RTSP once, publish timestamped IOSurface frames over XPC | App UI |

## Shared source and configuration

Camera, Safari, Chrome, Edge, Google, WebKit, and `mediaserverd` do not share an
application container. A selected file path from Camera therefore cannot be treated as a
cross-process media path. `vcamd` owns the source and configuration; clients
receive IOSurface-backed frames and timing metadata over a narrow XPC protocol.
Darwin notifications only signal configuration changes and never carry frames.

Required client operations:

- connect and report process/bundle identity;
- request the current source format;
- acquire the latest IOSurface plus monotonic presentation timestamp;
- report health/cadence counters;
- disconnect and immediately fall back to the real camera on any error.

## Dynamic target switches

The package filters determine where a minimal client may load. The controller's
target switches determine whether hooks are installed in that process:

- Camera: enabled by default;
- Safari, Chrome, Edge, Google: enabled by default;
- WebKit helper processes: enabled while any browser target is enabled;
- mediaserverd: disabled by default and shown as high risk.

No target switch may require a userspace reboot merely to turn replacement off.
The media-server client must do no work in its constructor beyond reading a
small immutable enable flag and installing hooks. It must never create UI,
initialize FFmpeg, open RTSP, or synchronously contact the daemon during startup.

## RootHide safety gate for mediaserverd

Before shipping the media-server target:

1. Build and install it as a separate subpackage so it can be removed without
   removing the app clients.
2. First deploy a no-hook load probe and verify ten userspace restarts without a
   mediaserverd watchdog timeout.
3. Add one hook family at a time with fail-open behavior.
4. Add a boot-time disable flag readable without XPC.
5. Keep Camera/Safari/Chrome functional when the daemon or client is absent.

## Proposed Theos mapping

`Makefile` becomes a multi-target project:

- `TWEAK_NAME = VCAMController VCAMAppClient VCAMWebKitClient`
- `TOOL_NAME = vcamd`
- `SUBPROJECTS = mediaserver-client` for the separately removable high-risk
  `VCAMMediaServerClient` package.

Each target gets its own filter plist and framework list. Shared protocol and
frame types live under `Sources/Shared`; UIKit files remain under `Sources/UI`;
daemon-only local/RTSP decoding moves under `Sources/Daemon`; process hooks stay
under `Sources/Clients/<target>`.

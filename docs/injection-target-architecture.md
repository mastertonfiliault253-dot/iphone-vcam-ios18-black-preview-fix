# VCAM injection target architecture

## Current package

The package builds five dylibs from `Makefile`:

| Theos target | Filter | Responsibilities |
| --- | --- | --- |
| `VCAM` | `com.apple.camera` | Camera floating panel, media picker, capture hooks, preview overlay |
| `VCAMAppClient` | `com.apple.mobilesafari`, `com.google.chrome.ios`, `com.microsoft.edge.ios`, `com.google.GoogleMobile` | Browser/Google floating panel, media picker, capture hooks |
| `VCAMWebKitClient` | `com.apple.WebKit.WebContent` | Headless capture hooks for Safari web pages (getUserMedia runs here) |
| `VCAMMediaServerClient` | executable `mediaserverd` | System-wide virtual camera mode: minimal, headless, no FFmpeg/UIKit |
| `VCAMSpringBoardClient` | `com.apple.springboard` | Home-screen floating panel, single configuration writer (broker) |

`mediaserverd` injection is **enabled by default** because the system-wide
virtual-camera behavior requires it plus a userspace restart. The client is a
minimal loader (`VCAMMediaServerEntry.xm` + configuration/policy only) so it
cannot destabilise mediaserverd while the Celestial frame-swap seam is being
mapped. Per-process AVFoundation hooks stay active so replacement keeps working
during that research.

## Camera frame path and the virtual-camera seam

`App → AVFoundation → mediaserverd → Camera HAL (applecamerad/h13ispd) → hardware`

mediaserverd itself is a thin binary (205 KB); the capture pipeline lives in
`Celestial.framework`, which is merged into the dyld shared cache on iOS 16 and
is not a standalone file on disk. Replacing frames at the mediaserverd layer
therefore requires extracting Celestial from the shared cache and mapping its
capture-session/sample delivery classes before the real frame swap can be
hooked. Until then the mediaserverd client only loads and logs.

## Configuration and media sharing

Processes do not share an application container. SpringBoard runs a loopback
broker on port 46321 that owns the shared configuration at
`/var/mobile/Media/VCAM/com.codex.vcam.plist` and the imported media at
`/var/mobile/Media/VCAM/selected.mov`.

- Control UI writes through the broker (SpringBoard is the only writer).
- Each process reads the config from the broker.
- For local media, each process fetches the shared video through the broker and
  mirrors it into its own container (`Application Support/VCAM/VCAM-media/`),
  because AVFoundation cannot reliably read the shared path from another app's
  sandbox. `resolvedMediaPathForSharedPath:` performs this mirror.
- Darwin notifications (`com.codex.vcam/preferences.changed`) trigger pipeline
  reloads in each injected process.

## Dynamic target switches

The control panel exposes one switch per target plus a global switch:

- Camera, Safari, Chrome, Edge, Google, WebKit WebContent: enabled by default,
  controlled by the global toggle.
- mediaserverd: enabled by default, separate switch, requires a userspace
  restart after toggling.
- SpringBoard itself always hosts the home-screen panel and broker.

## Capture hook contract

Hooks are installed at process start when the current process is a recognized
target and media replacement is enabled. Pipeline creation is deferred to a
background queue so WebContent startup never blocks. Hooked sample-buffer
delegates always fail open: if the pipeline is disabled or the replacement
source has no frame, the original sample is passed through unchanged. No target
switch requires a userspace reboot to turn replacement off; only the
SpringBoard/mediaserverd binaries need a process restart after toggling
injection.
# VCAM injection target architecture

## Current package

The package builds four dylibs from `Makefile`:

| Theos target | Filter | Responsibilities |
| --- | --- | --- |
| `VCAM` | `com.apple.camera` | Camera floating panel, media picker, capture hooks, preview overlay |
| `VCAMAppClient` | `com.apple.mobilesafari`, `com.google.chrome.ios`, `com.microsoft.edge.ios`, `com.google.GoogleMobile` | Browser/Google floating panel, media picker, capture hooks |
| `VCAMWebKitClient` | `com.apple.WebKit.WebContent` | Headless capture hooks for Safari web pages (getUserMedia runs here) |
| `VCAMSpringBoardClient` | `com.apple.springboard` | Home-screen floating panel, single configuration writer (broker) |

`mediaserverd` is intentionally **not** an injection target: loading a
UIKit/FFmpeg-linked dylib into that daemon caused Camera crashes. The capture
hooks live inside each camera-consuming process (`AVCaptureVideoDataOutput`,
`AVCapturePhotoOutput`, `AVCaptureMovieFileOutput` delegates) so frames are
replaced at the AVFoundation boundary the app actually sees. Safari web pages
call AVFoundation from the WebContent process, so that process gets a headless
client with no UI and asynchronous pipeline startup (no blocking work in
`%ctor`, which prevents Safari page reload loops).

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

- Camera, Safari, Chrome, Edge, Google, WebKit WebContent: enabled by default.
- Global toggles all six together.
- SpringBoard itself always hosts the home-screen panel and broker.

## Capture hook contract

Hooks are installed at process start when the current process is a recognized
target and media replacement is enabled. Pipeline creation is deferred to a
background queue so WebContent startup never blocks. Hooked sample-buffer
delegates always fail open: if the pipeline is disabled or the replacement
source has no frame, the original sample is passed through unchanged. No target
switch requires a userspace reboot to turn replacement off; only the
SpringBoard/UI binaries need a process restart after toggling injection.
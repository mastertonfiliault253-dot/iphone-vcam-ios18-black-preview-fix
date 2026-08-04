# VCAM injection target architecture

## Current package

The package builds three dylibs from `Makefile`:

| Theos target | Filter | Responsibilities |
| --- | --- | --- |
| `VCAM` | `com.apple.camera` | Camera floating panel, media picker, capture hooks, preview overlay |
| `VCAMAppClient` | `com.apple.mobilesafari`, `com.google.chrome.ios`, `com.microsoft.edge.ios`, `com.google.GoogleMobile` | Browser/Google floating panel, media picker, capture hooks |
| `VCAMSpringBoardClient` | `com.apple.springboard` | Home-screen floating panel, single configuration writer (broker) |

`WebKit.WebContent` and `mediaserverd` are intentionally **not** injection
targets. The capture hooks live inside each camera-consuming host process
(`AVCaptureVideoDataOutput`, `AVCapturePhotoOutput`, `AVCaptureMovieFileOutput`
delegates) so frames are replaced at the AVFoundation boundary the app actually
sees. A separate mediaserverd/WebContent client was removed because loading a
UIKit/FFmpeg-linked dylib into those daemons caused Safari reload loops and
Camera crashes.

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

- Camera, Safari, Chrome, Edge, Google: enabled by default.
- Global toggles all five together.
- SpringBoard itself always hosts the home-screen panel and broker.

## Capture hook contract

Hooks are installed at process start when the current process is a recognized
target and media replacement is enabled. Hooked sample-buffer delegates always
fail open: if the pipeline is disabled or the replacement source has no frame,
the original sample is passed through unchanged. No target switch requires a
userspace reboot to turn replacement off; only the SpringBoard/UI binaries need
a process restart after toggling injection.
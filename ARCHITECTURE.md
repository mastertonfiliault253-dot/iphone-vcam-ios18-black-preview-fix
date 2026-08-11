# Architecture

VCAM separates media production, camera replacement and control UI:

- `vcamd` owns OBS and RTSP decoding. RTSP publishes native 8-bit
  NV12 through a source-sized three-slot IOSurface ring when no transform is
  required, or source-sized three-slot BGRA after an explicit user transform.
  OBS publishes source-sized BGRA through a three-slot IOSurface ring. The surface-handshake
  fallback alone uses the fixed 1080x1920 BGRA mmap.
- `VCAMMediaServerClient` is injected only into `mediaserverd`. It performs the
  validated `BWNodeOutput` replacement and contains no UIKit, decoder or network
  client.
- `VCAMSpringBoardClient` gives SpringBoard, Camera and the supported browser
  main processes one foreground-owned white dot, control panel and preview. In
  SpringBoard only, its media bridge normalizes static images with ImageIO into
  one source-sized BGRA IOSurface and owns local video/HLS playback through
  `AVPlayer`. It takes NV12 frames from `AVPlayerItemVideoOutput` and performs
  source orientation and explicit user transforms in one Metal-backed Core
  Image render directly into a source-sized three-slot `420v` IOSurface;
  BGRA mmap is the compatibility
  fallback.
  The SpringBoard and app-host control-panel previews may passively read the
  freshest raw BGRA mmap or NV12 IOSurface frame. They never claim the
  mediaserverd consumer lease. When an app sandbox cannot open either raw
  transport, SpringBoard returns a downscaled JPEG over the existing loopback
  broker for panel display only. App hosts receive UI only; they never decode
  media, hook camera frames or publish replacement frames, and the JPEG never
  enters the mediaserverd replacement path.
- `vcaminjectd` repairs only the SpringBoard and `mediaserverd` mappings after
  those exact processes restart. Normal tweak filtering loads application UI
  clients.

`VCAMFrameRenderer` normalizes image metadata and explicit user transforms
before publication. The shared frame is the single user-visible direction
reference: local video applies the asset's complete `preferredTransform` once
to decoded track pixels; UI preview adds no transform; consumers never infer
orientation from target dimensions. The explicit iOS 16 WebKit
`video-converter` terminal alone pre-rotates a portrait source left into its
landscape storage basis; Camera preview and recording routes remain unchanged.
At the still-photo terminal,
only a canonical portrait source is converted into the sensor's landscape
storage basis and marked EXIF `Orientation=Right`; a landscape source remains
unmodified. This makes the saved aspect follow the selected source rather than
the phone posture. Audio is never replaced.

The native local-video/HLS bridge and eligible RTSP frames publish raw,
uncompressed NV12 pixels into source-sized three-slot IOSurface rings. Static
images use one source-sized uncompressed BGRA IOSurface; OBS and transformed
RTSP use source-sized three-slot BGRA IOSurfaces. Fallback publication alone
uses raw, uncompressed BGRA pixels in mmap. No JPEG, H.264,
HEVC or source-container payload is sent to mediaserverd. The vcamd
launchd Mach service relays one or three IOSurface XPC rights from SpringBoard
or `vcamd` to mediaserverd and verifies exact peer process names; frame bytes never pass
through the daemon. mediaserverd retains the selected surface while rendering
so SpringBoard never overwrites an in-use slot. UI previews are passive
observers and do not alter that ownership handshake. The previous three-slot
BGRA mmap remains the automatic fallback until the surface handshake succeeds.
On iOS 16 sandboxes that cannot resolve the package Mach service, the same
global IOSurface is looked up by its published ID; no frame bytes cross XPC.
Creating
`/var/tmp/vcam-hls-legacy-vcamd.enable` disables the SpringBoard HLS bridge and
restores the retained daemon HLS decoder for rollback. The equivalent local
video rollback marker is `/var/tmp/vcam-local-video-legacy-vcamd.enable`.
`/var/tmp/vcam-local-image-legacy-vcamd.enable` restores the retained daemon
static-image publisher.

Once virtual mode is enabled, capture is fail-closed: a missing, stale or
unrenderable source may retain the last virtual frame, emit black or suppress a
consumer sample, but it must never expose a real camera frame. Only an explicit
restore request returns to the real camera.

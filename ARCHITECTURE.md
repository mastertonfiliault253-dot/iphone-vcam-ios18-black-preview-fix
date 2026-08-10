# Architecture

VCAM separates media production, camera replacement and control UI:

- `vcamd` owns local image, OBS and RTSP decoding. RTSP publishes native 8-bit
  NV12 through the three-slot IOSurface ring when no transform is required;
  local image/OBS and the surface-handshake fallback use the 1080x1920 BGRA
  three-slot mmap.
- `VCAMMediaServerClient` is injected only into `mediaserverd`. It performs the
  validated `BWNodeOutput` replacement and contains no UIKit, decoder or network
  client.
- `VCAMSpringBoardClient` gives SpringBoard, Camera and the supported browser
  main processes one foreground-owned white dot, control panel and preview. In
  SpringBoard only, its media bridge owns local video and HLS playback through
  `AVPlayer`, takes NV12 frames from `AVPlayerItemVideoOutput`, and performs
  rotation, mirroring, fit/fill and scale in one Metal-backed Core Image render
  directly into the `420v` IOSurface transport; BGRA mmap is the compatibility
  fallback.
  App hosts receive UI only; they never decode media, hook camera frames or
  publish replacement frames.
- `vcaminjectd` repairs only the SpringBoard and `mediaserverd` mappings after
  those exact processes restart. Normal tweak filtering loads application UI
  clients.

`VCAMFrameRenderer` normalizes orientation, content mode, mirroring and target
size before publication. Audio is never replaced.

The native local-video/HLS bridge and eligible RTSP frames publish into a
three-slot IOSurface ring. The vcamd
launchd Mach service relays only the three IOSurface XPC rights from SpringBoard
to mediaserverd and verifies both peer process names; frame bytes never pass
through the daemon. mediaserverd retains the selected surface while rendering
so SpringBoard never overwrites an in-use slot. The previous three-slot BGRA
mmap remains the automatic fallback until the XPC surface handshake succeeds.
Creating
`/var/tmp/vcam-hls-legacy-vcamd.enable` disables the SpringBoard HLS bridge and
restores the retained daemon HLS decoder for rollback. The equivalent local
video rollback marker is `/var/tmp/vcam-local-video-legacy-vcamd.enable`.

Once virtual mode is enabled, capture is fail-closed: a missing, stale or
unrenderable source may retain the last virtual frame, emit black or suppress a
consumer sample, but it must never expose a real camera frame. Only an explicit
restore request returns to the real camera.

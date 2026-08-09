# Architecture

VCAM separates media production, camera replacement and control UI:

- `vcamd` owns local image/video, OBS and RTSP decoding. It publishes the latest
  1080x1920 BGRA frame through a three-slot shared mmap.
- `VCAMMediaServerClient` is injected only into `mediaserverd`. It performs the
  validated `BWNodeOutput` replacement and contains no UIKit, decoder or network
  client.
- `VCAMSpringBoardClient` gives SpringBoard, Camera and the supported browser
  main processes one foreground-owned white dot, control panel and preview. In
  SpringBoard only, its media bridge owns HLS playback through `AVPlayer`, takes
  NV12 frames from `AVPlayerItemVideoOutput`, and performs rotation, mirroring,
  fit/fill and NV12-to-BGRA conversion in one Metal-backed Core Image render.
  App hosts receive UI only; they never decode media, hook camera frames or
  publish replacement frames.
- `vcaminjectd` repairs only the SpringBoard and `mediaserverd` mappings after
  those exact processes restart. Normal tweak filtering loads application UI
  clients.

`VCAMFrameRenderer` normalizes orientation, content mode, mirroring and target
size before publication. Audio is never replaced.

The HLS bridge renders directly into a three-slot IOSurface ring. mediaserverd
retains the selected surface while rendering so SpringBoard never overwrites an
in-use slot. The previous three-slot BGRA mmap remains the automatic fallback
when global IOSurface creation or cross-process lookup is unavailable; it stays
live until mediaserverd completes the first successful lookup. Creating
`/var/tmp/vcam-hls-legacy-vcamd.enable` disables the SpringBoard HLS bridge and
restores the retained daemon HLS decoder for rollback.

Once virtual mode is enabled, capture is fail-closed: a missing, stale or
unrenderable source may retain the last virtual frame, emit black or suppress a
consumer sample, but it must never expose a real camera frame. Only an explicit
restore request returns to the real camera.

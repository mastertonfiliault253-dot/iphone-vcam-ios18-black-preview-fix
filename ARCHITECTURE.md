# Architecture

VCAM separates media production, camera replacement and control UI:

- `vcamd` owns local image/video, OBS, RTSP and HLS decoding. It publishes the
  latest 1080x1920 BGRA frame through a three-slot shared mmap.
- `VCAMMediaServerClient` is injected only into `mediaserverd`. It performs the
  validated `BWNodeOutput` replacement and contains no UIKit, decoder or network
  client.
- `VCAMSpringBoardClient` gives SpringBoard, Camera and the supported browser
  main processes one foreground-owned white dot, control panel and preview. App
  hosts receive UI only; they never hook or replace camera frames.
- `vcaminjectd` repairs only the SpringBoard and `mediaserverd` mappings after
  those exact processes restart. Normal tweak filtering loads application UI
  clients.

`VCAMFrameRenderer` normalizes orientation, content mode, mirroring and target
size before publication. Audio is never replaced.

Once virtual mode is enabled, capture is fail-closed: a missing, stale or
unrenderable source may retain the last virtual frame, emit black or suppress a
consumer sample, but it must never expose a real camera frame. Only an explicit
restore request returns to the real camera.

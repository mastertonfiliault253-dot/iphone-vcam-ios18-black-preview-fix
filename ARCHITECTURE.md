# Architecture

The fixed version, CI artifact hash, current device evidence and unresolved acceptance gates are recorded in [`docs/CURRENT-RELEASE-STATUS-ZH.md`](docs/CURRENT-RELEASE-STATUS-ZH.md). This file describes the architecture contract and should not be read as proof that every runtime path has passed device acceptance.

VCAM separates media production, camera replacement and control UI:

- `vcamd` owns OBS and RTSP decoding. RTSP is software-only on iOS 16.0-16.5
  and publishes the rendered 1080x1920 BGRA result through the fixed three-slot
  mmap. OBS publishes source-sized BGRA through a three-slot IOSurface ring.
  For non-loopback numeric-IP plain-HTTP HLS, vcamd additionally relays
  authenticated HTTP bytes from the configured LAN origin to device loopback;
  it never decodes those bytes.
- `VCAMMediaServerClient` is injected only into the camera capture daemon:
  `mediaserverd` on iOS 16 and `cameracaptured` on iOS 17/18 (selected by
  `VCAMInjectionPolicy`). Throughout this file "mediaserverd" denotes that
  camera-frame host wherever it still names the iOS 16 transport. It performs
  the validated `BWNodeOutput` replacement and contains no UIKit, decoder or
  network client.
- `VCAMSpringBoardClient` gives SpringBoard, Camera and the supported browser
  main processes one foreground-owned white dot, control panel and preview. In
  SpringBoard only, its media bridge normalizes static images with ImageIO into
  one source-sized BGRA IOSurface and owns local video/HLS playback through
  `AVPlayer`. It takes NV12 frames from `AVPlayerItemVideoOutput` and performs
  source orientation and explicit user transforms in one Metal-backed Core
  Image render directly into a source-sized three-slot BGRA IOSurface;
  BGRA mmap is the compatibility
  fallback.
  The SpringBoard and app-host control-panel previews may passively read the
  freshest raw BGRA mmap or IOSurface frame. They never claim the
  mediaserverd consumer lease. When an app sandbox cannot open either raw
  transport, SpringBoard returns a downscaled JPEG over the existing loopback
  broker for panel display only. App hosts receive UI only; they never decode
  media, hook camera frames or publish replacement frames, and the JPEG never
  enters the mediaserverd replacement path.
- On iOS 18 the cameracaptured replacement posts the Darwin notification
  `com.codex.vcam.ios18.frame` as evidence of a live lease on the VCAM frame
  stream; vcamd demand tracking and the SpringBoard HLS suspend/resume gate
  consume it. It is posted only after the virtual-mode enable check, so a
  camera running in real mode (replacement off) does not pin HLS to running.
- `vcaminjectd` repairs only the SpringBoard and `mediaserverd` mappings after
  those exact processes restart. Normal tweak filtering loads application UI
  clients.

`VCAMFrameRenderer` normalizes image metadata and explicit user transforms
before publication. The shared frame is the single user-visible direction
reference: local video applies the asset's complete `preferredTransform` once
to decoded track pixels; UI preview adds no transform; consumers never infer
orientation from target dimensions. The explicit iOS 16 WebKit
`video-converter` terminal alone pre-rotates a portrait source left into its
landscape storage basis, then center-crops once into the already-negotiated
target, matching the real camera's full-bleed behavior without stretching or a
second VCAM scale. Camera preview keeps its existing whole-frame fit and
recording remains full-bleed.
At the still-photo terminal, VCAM only aspect-fills the system-negotiated target.
It does not rotate pixels according to the source or phone posture and does not
replace orientation metadata the graph already attached; the existing system
camera graph remains the owner of saved-photo orientation and aspect metadata.
Exception: because the still-photo fill renders canonical portrait pixels
rotated left into the landscape target, the VCAM photo route marks the sample
`Orientation=Right` **only when the graph left no orientation attachment at
all** (device-observed gap on iOS 18.3.1), so Photos shows a portrait 3:4
image instead of a sideways one. It never overwrites an existing orientation.
Audio is never replaced.

Non-loopback numeric-IP plain-HTTP LAN HLS has a split ownership contract: the audit-identified
SpringBoard process generates a random 128-bit token and registers it with vcamd over XPC, AVPlayer
uses only the tokenized `127.0.0.1:46322` URL, and vcamd relays GET/HEAD bytes to
the immutable upstream bound to that session. Issuing a new session invalidates
the previous source. Relative resources retain the tokenized base; same-origin
root-relative, network-path, same-origin absolute playlist and redirect URLs
are resolved then rewritten to loopback. Active clients, headers, playlist
size, numeric-IP connect and relay duration are bounded; framed playlist
responses must be complete. HTTPS and hostname sources remain Apple's
direct transport and must be accepted separately on the target device.

The physical camera graph is the browser negotiation shell. VCAM does not
advertise a synthetic capability table or force a fixed resolution: Safari and
other WebKit clients still negotiate the real device's available 480p, 720p or
1080p target, frame rate, pixel format and timing. mediaserverd renders into
that exact target and preserves its format description and propagated sample
attachments. Only the replacement pixels and route-specific composition
policy change.

The native local-video/HLS bridge publishes source-sized, uncompressed BGRA
pixels into three-slot IOSurface rings. Static images use one source-sized
uncompressed BGRA IOSurface; OBS uses a source-sized three-slot BGRA IOSurface.
RTSP uses raw, uncompressed 1080x1920 BGRA pixels in the fixed three-slot mmap
as its production transport. No JPEG, H.264,
HEVC or source-container payload is sent to mediaserverd. RTSP software decoding
keeps the decoded source dimensions until the single renderer pass into the
fixed transport; a 256 MiB worst-case whole-pipeline budget
accounts for the decoded frame, conversion work buffers and three publication
slots, rejecting larger frames instead of silently downscaling them. The vcamd
worker requests a 384 MB jetsam limit before decoder startup, leaving 128 MB
above that pipeline budget for FFmpeg and framework bookkeeping; the effective
limit is logged and remains a device-acceptance check. The vcamd launchd Mach
service relays one or three IOSurface XPC rights from SpringBoard
or `vcamd` to mediaserverd and verifies peer start time, executable path and
code-signing identity; frame bytes never pass
through the daemon. mediaserverd retains the selected surface while rendering
so SpringBoard never overwrites an in-use slot. UI previews are passive
observers and do not alter that ownership handshake. The three-slot BGRA mmap
is the RTSP production transport and remains the automatic fallback until a
surface-backed source's handshake succeeds.
On iOS 16 sandboxes that cannot resolve the package Mach service, the same
global IOSurface is looked up by its published ID; no frame bytes cross XPC.
Creating
`/var/tmp/vcam-hls-legacy-vcamd.enable` disables the SpringBoard HLS bridge and
restores the retained daemon HLS decoder for rollback. The equivalent local
video rollback marker is `/var/tmp/vcam-local-video-legacy-vcamd.enable`.
`/var/tmp/vcam-local-image-legacy-vcamd.enable` restores the retained daemon
static-image publisher.

The loopback configuration broker is not authenticated by a compiled password.
Each request first obtains a 10-second, single-use random token from an XPC
allowlist that binds the peer PID, process start time, exact executable path
and process name, and admits third-party browsers by bundle identifier against
a pinned App Store team-ID table (runtime membership is by bundle id; the team
values are documentation/future signature-check anchors because csops-based
identity queries are unreliable under a jailbreak). Selected media paths are canonicalized and
must remain below `/var/mobile/Media/VCAM`; the broker has no arbitrary file-fetch
command. Imports are capped at 2 GiB and retain a 256 MiB free-space reserve;
HTTP(S) downloads enforce both limits while bytes arrive, before import. Media
transfer runs on a dedicated serial queue so read/update/restore requests remain
responsive during a large copy. Pruning protects the persisted active path and
the newly received path rather than guessing activity from file timestamps.
Source-sized static BGRA publication is capped at 64 MiB and rejects a larger
image instead of silently downscaling it.

Once virtual mode is enabled, capture is fail-closed: a missing, stale or
unrenderable source may retain the last virtual frame, emit black or suppress a
consumer sample, but it must never expose a real camera frame. Only an explicit
restore request returns to the real camera.


## NV12 video transport optimization (in progress)

Goal: make the browser getUserMedia path behave like the real camera (native
420f, single chroma pass, less redundant GPU work). Video sources migrate the
shared transport from BGRA to NV12; static images remain BGRA.

Decisions:

- Video sources (HLS / RTSP / local video) publish NV12; static images stay
  BGRA. H.264/HEVC decoders already produce 4:2:0, so a BGRA transport forces
  an unnecessary 4:2:0 -> 4:4:4 -> 4:2:0 chroma round-trip.
- mediaserverd reads NV12 directly and lets its existing Core Image pipeline
  handle the per-consumer rotation, scale and 420f rendering; no separate YUV
  rotation path, Accelerate/vImage or producer-side feedback channel is needed.
- RTSP/HLS rotation stays at the push/stream end; local video and still images
  keep their in-app rotation.
- The fixed three-slot mmap now accepts NV12 (BGRA remains compatible) because
  RTSP's production transport is the mmap.
- RTSP panel rotation/mirror/fill-mode changes must not restart the FFmpeg
  source: `VCAMConfigurationsProduceSameFrames` treats RTSP transform and
  content mode as equal so the renderer's identity NV12 path stays live
  mid-stream (rotation and fill are applied only at the push end).

Status: mmap NV12, the mediaserverd NV12 read, and the RTSP, HLS and local
video producer NV12 paths have landed. Core Image accepts NV12 input and renders
it (including local-video orientation), so no separate YUV rotation path is
needed. Static images stay BGRA. 0.8.94 keeps the RTSP source alive across
panel rotation/mirror changes so tapping rotate no longer garbles or restarts
the stream.

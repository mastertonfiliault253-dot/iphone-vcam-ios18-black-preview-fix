# VCAM process architecture

## Rootless package

The standard rootless package installs under `/var/jb` and contains exactly:

| Target | Filter | Responsibility |
| --- | --- | --- |
| `VCAMMediaServerClient` | executable `mediaserverd` | Nonblocking read of a fresh shared frame and `BWNodeOutput` replacement |
| `VCAMSpringBoardClient` | SpringBoard plus Camera, MobileSafari, Chrome, Edge and Firefox main-process bundle filters | SpringBoard owns the broker, static-image publisher and native local-video/HLS player; filtered app hosts get only the white dot, panel and preview |
| `vcamd` | no injection; LaunchDaemon | OBS and RTSP decoding, latest-frame publication, plus explicit legacy local-image/video/HLS rollback |
| `vcaminjectd` | no injection; root LaunchDaemon | Reinject only the two allowed clients after their exact process PID changes |

Camera and the listed browser main processes receive the UI dylib only. Its
SpringBoard process branch also owns the system `AVPlayer` bridge; app-host
branches contain no camera hook, decoder or network source. Video replacement
remains exclusively in `mediaserverd`. WebKit content processes are not
targeted. Audio is not replaced.

## Frame path

`local image → SpringBoard/ImageIO → one source-sized raw BGRA IOSurface (mmap bootstrap) → mediaserverd + passive UI preview`

`OBS → vcamd → source-sized three-slot raw BGRA IOSurface (mmap bootstrap) → mediaserverd + passive UI preview`

`RTSP → vcamd FFmpeg → decoded raw NV12 → three-slot IOSurface (raw BGRA mmap fallback) → mediaserverd + passive UI preview`

`local video / HLS → SpringBoard AVPlayer → decoded raw NV12 → Metal/Core Image → three-slot IOSurface (raw BGRA mmap bootstrap) → mediaserverd + passive UI preview`

The handshake-only compatibility frame region in `/var/tmp/com.codex.vcam.frames` remains
fixed at 1080×1920 BGRA. IOSurface metadata independently carries the source
width, height, pixel format and an active depth of one or three slots. Publication uses atomic slot and sequence
metadata; neither transport contains JPEG, H.264, HEVC or another encoded
payload. The SpringBoard and filtered app-host control panels may passively
observe the freshest mmap/IOSurface frame, but they neither claim the
mediaserverd consumer lease. If an app sandbox cannot open either raw transport,
the panel obtains a downscaled JPEG from SpringBoard through the loopback
configuration broker. This UI-only fallback never feeds mediaserverd. Filtered
app hosts never decode or publish media. Consumers copy without
waiting. After mediaserverd adopts a surface writer generation, it rejects
that generation's old mmap bootstrap; only a different producer generation
reopens a fresh bootstrap window. Every bootstrap slot carries that same
writer generation, so a fresh frame from the preceding source is rejected
during a rapid switch. An explicit marker rollback to the generation-zero
legacy daemon is accepted only from a frame timestamped after disappearance
of the adopted surface writer. SpringBoard is the sole writer of the
requested enable/restore state;
`vcamd` publishes pixels only and cannot overwrite that state after a delayed
configuration reload. Shared-header initialization and requested-state updates
use an interprocess file lock so startup order cannot replace a newer choice.

The XPC relay remains the preferred surface-right path. If an iOS 16 sandbox
cannot resolve the package Mach service, consumers use the existing
`IOSurfaceLookup(surfaceID)` fallback against the same globally published raw
surface; XPC never carries frame bytes.

`mediaserverd` recognizes the exact upstream
`BWMultiStreamCameraSourceNode / VideoCapture` role before preview, recording
and Smart Camera analysis split. A successful upstream replacement carries a
versioned, propagating full-PTS marker. Camera preview and movie recording skip a
duplicate render only when their own sample or image buffer retains that marker
with the same numeric PTS. Browser/WebRTC conversion deliberately renders again
from the canonical unencoded shared frame into its terminal 420f buffer, so the
browser does not inherit pixels that traversed the camera source's private
compressed surface. Unmarked downstream samples also render again and remain
fail-closed.
Fan-out and inference nodes are never matched directly. Unsupported private
`StillImage` source frames remain inside the mediaserverd graph so the verified
standard 420f `Meteor Headroom` still-photo boundary can replace them; they are
never exposed to an app consumer. It renders observed BGRA,
`420v`/`420f`, public compressed and the device-private recording formats
`[8v0`/`}8v0`, subject to strict dimensions and buffer-layout checks. The
producer publishes canonical visual orientation and the consumer never infers
rotation from a target buffer's width and height. The explicit iOS 16 WebKit
`video-converter` route is identified by its graph role, not its dimensions;
for a portrait source only, it pre-rotates pixels left into WebKit's landscape
storage basis while Camera preview and recording remain canonical. WebKit and
recording/still-photo terminals use full-bleed center crop; Camera preview alone
aspect-fits the complete source. At the `Meteor Headroom` still terminal VCAM
only composes into the already-negotiated target: it neither rotates pixels from
source/phone posture nor writes or replaces orientation metadata. The original
system sample remains the sole authority for saved-photo orientation and aspect.
The real camera graph remains the browser negotiation shell. VCAM does not
replace its capability table or force a fixed profile: WebKit keeps the target
width, height, frame rate, pixel format, `CMFormatDescription`, timing and
propagated sample attachments selected by the physical camera graph. The
source-sized shared frame is composed once into that exact buffer. A mismatched
WebKit aspect ratio is center-cropped once, as with the physical camera. The
target is never resized or renegotiated, so this does not introduce a second
VCAM scale; eliminating black bars necessarily discards edge pixels.

Compressed recording never asks Core Image to write a private surface. Core
Image renders into a target-sized public `420v` staging buffer; VideoToolbox
then transfers into a private-format clone created from the camera buffer's
creation attributes. The original timing, format and attachments are retained
when the clone is emitted. If conversion fails, the original raw frame is never
forwarded: a last-known-good virtual compressed frame with the current timing
is reused when its exact creation attributes match, or the sample is suppressed
when no safe fallback exists. The system encoder then consumes only the
successfully replaced raw recording branch. Its encoded output does not retain
the raw sample's custom marker or numeric PTS, so a second encoded PTS guard
would suppress valid virtual recordings and is intentionally not used. Once
requested mode is enabled, no real camera frame is allowed through until an
explicit restore request.

When CoreMedia rejects an observed private compressed camera-source clone
because the source format description does not match the clone's attachment
contract, mediaserverd retries sample construction with a format description
derived from that clone. The retry is restricted to the exact private camera
formats and `kCMSampleBufferError_InvalidMediaFormat`; other routes and errors
cannot silently change format. Timing and sample attachments still come from
the original sample, and either construction path remains fail-closed.

## Decode behavior

- Photos and document picker imports copy the provider's current original
  representation, preserve the selected extension and bytes, and assign a new
  broker path on every selection. Paths are canonical and confined below
  `/var/mobile/Media/VCAM`; the authenticated broker has no arbitrary file-fetch
  command. Imports are capped at 2 GiB with a 256 MiB free-space reserve; online
  downloads enforce these limits while receiving bytes. A dedicated serial
  import queue keeps configuration/read/restore requests responsive during large
  transfers, and pruning always protects the persisted active path. PNG,
  JPEG and HEIF use the ImageIO static decoder. The rendered static sample is
  cached and retimed per camera callback.
- Production local video uses SpringBoard `AVPlayerItemVideoOutput` and the same
  NV12/Metal/IOSurface pipeline as HLS. It loops by seeking to zero at item end.
  Creating `/var/tmp/vcam-local-video-legacy-vcamd.enable` restores the retained
  incremental `AVAssetReader`/FFmpeg daemon path for diagnostics only.
- Production static images use SpringBoard ImageIO orientation normalization and
  publish once into a source-sized one-slot BGRA IOSurface. The decoded BGRA
  allocation is capped at 64 MiB; a larger source is rejected rather than
  silently downscaled. Creating
  `/var/tmp/vcam-local-image-legacy-vcamd.enable` restores the retained daemon
  static-image publisher for diagnostics only.
- OBS receives only the newest JPEG packet. The source expires after 3.5 seconds
  without a packet.
- RTSP uses FFmpeg inside `vcamd`, with VideoToolbox where available and a
  software fallback. It forces MediaMTX-compatible interleaved TCP, accepts
  only video media, uses a 10-second TCP I/O timeout and keeps normal RTP/H.264 reorder and
  reference buffering. Eligible 8-bit decoded frames are repacked as native
  NV12 and published by IOSurface without BGRA conversion; an explicit user
  rotation/mirror is rendered once into a source-sized three-slot BGRA
  IOSurface instead of falling back permanently to the fixed mmap. HLS uses
  SpringBoard's system `AVPlayer`; sustained live-edge lag triggers a native seek
  to the current seekable edge. The old daemon
  FFmpeg path exists only behind `/var/tmp/vcam-hls-legacy-vcamd.enable`.

SpringBoard remains the only configuration and requested-mode writer. `vcamd`, running as `mobile`,
reads imported media directly from `/var/mobile/Media/VCAM`; mediaserverd never
opens the selected media file.

## Remote queue sink evaluation

On iOS 16, `BWRemoteQueueSinkNode` consumes `CMSampleBufferRef` through
`renderSampleBuffer:forInput:` for remote capture clients. It is not the sole
camera exit: SmartCam analysis is upstream, while Camera preview, still capture
and movie recording use separate sink pipelines. Remote queues also carry
non-video media such as metadata and depth.

The mediaserverd client therefore keeps the proven source, preview, still and
recording routes. Its remote-queue hook is diagnostic-only in this release: it
records bounded video/non-video counters and format signatures, then always
forwards the original sample unchanged. Device evidence must prove the exact
Safari and third-party VideoDataOutput coverage before this point can become a
video-only fail-closed safety net. A global RemoteQueue or RemoteOperation C
sender hook is intentionally not used because it loses the sink/input context
needed to distinguish video frames from configuration, metadata and depth.

# VCAM process architecture

## Rootless package

The standard rootless package installs under `/var/jb` and contains exactly:

| Target | Filter | Responsibility |
| --- | --- | --- |
| `VCAMMediaServerClient` | executable `mediaserverd` | Nonblocking read of a fresh shared frame and `BWNodeOutput` replacement |
| `VCAMSpringBoardClient` | `com.apple.springboard` / `SpringBoard` | White dot, picker, configuration broker and preview |
| `vcamd` | no injection; LaunchDaemon | Local image/video, OBS and RTSP decoding and latest-frame publication |
| `vcaminjectd` | no injection; root LaunchDaemon | Reinject only the two allowed clients after their exact process PID changes |

There is no Camera, browser, WebKit or third-party App injection target. Audio
is not replaced.

## Frame path

`local / OBS / RTSP → vcamd → three-slot mmap → mediaserverd + SpringBoard preview`

The shared file is `/var/tmp/com.codex.vcam.frames`, fixed at 720×1280 BGRA.
Publication uses atomic slot and sequence metadata. Consumers copy without
waiting. SpringBoard is the sole writer of the requested enable/restore state;
`vcamd` publishes pixels only and cannot overwrite that state after a delayed
configuration reload. Shared-header initialization and requested-state updates
use an interprocess file lock so startup order cannot replace a newer choice.

`mediaserverd` recognizes the exact upstream
`BWMultiStreamCameraSourceNode / VideoCapture` role before preview, recording
and Smart Camera analysis split. A successful upstream replacement carries a
versioned, propagating full-PTS marker. The three exact downstream pixel-transfer
roles (browser/WebRTC conversion, Camera preview and movie recording) skip a
duplicate render only when their own sample or image buffer retains that marker
with the same numeric PTS; otherwise they render again and remain fail-closed.
Fan-out and inference nodes are never matched directly, and still capture keeps
its independent exact `Meteor Headroom` route. It renders observed BGRA,
`420v`/`420f`, public compressed and the device-private recording formats
`[8v0`/`}8v0`, subject to strict dimensions and buffer-layout checks. A portrait
shared source is pre-rotated left before it is fitted into a landscape sensor
buffer, compensating for the downstream clockwise display transform while
leaving portrait preview buffers unchanged. The canonical shared canvas is
then aspect-filled into each consumer's exact buffer size, so 4:3 still-photo
and browser/WebRTC outputs do not expose the black safety background behind
the centered render.

Compressed recording never asks Core Image to write a private surface. Core
Image renders into a target-sized public `420v` staging buffer; VideoToolbox
then transfers into a private-format clone created from the camera buffer's
creation attributes. The original timing, format and attachments are retained
when the clone is emitted. A bounded PTS outcome ring guards the camera video
compressor, so only encoded frames proven to originate from a successful
virtual replacement can reach the writer. If conversion fails, the original
raw frame is never forwarded: a last-known-good virtual compressed frame with
the current timing is reused when its exact creation attributes match, or the
sample is suppressed when no safe fallback exists. The encoded guard remains a
second fail-closed boundary. Once requested mode is enabled, no real camera
frame is allowed through until an explicit restore request.

When CoreMedia rejects an observed private compressed camera-source clone
because the source format description does not match the clone's attachment
contract, mediaserverd retries sample construction with a format description
derived from that clone. The retry is restricted to the exact private camera
formats and `kCMSampleBufferError_InvalidMediaFormat`; other routes and errors
cannot silently change format. Timing and sample attachments still come from
the original sample, and either construction path remains fail-closed.

## Decode behavior

- Images are decoded once by Core Image and rendered as a static source.
- Local video uses one incremental `AVAssetReaderTrackOutput` configured for
  uncompressed BGRA samples, driven by source PTS and sample duration. It
  retains only the current decoded frame, does not preload the asset into a
  frame array, and rebuilds the reader at EOF when looping is enabled. Core
  Media marker samples without a pixel buffer are released and skipped with a
  hard limit of 32 before the reader fails closed. The limit is deliberately
  above the eight consecutive zero-sample markers observed on iOS 16.5 while
  remaining bounded when an output never produces pixels.
- OBS receives only the newest JPEG packet. The source expires after 3.5 seconds
  without a packet.
- RTSP uses FFmpeg only inside `vcamd`, with TCP, normal RTP/H.264 reorder and
  reference buffering, and VideoToolbox where available. Software conversion
  runs on a latest-only queue, while every compressed packet is still consumed
  in order; corruption enters a bounded clean-key-frame recovery state.

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

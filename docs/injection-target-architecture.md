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
waiting; a missing, changing, inactive or older-than-one-second frame is rejected
so the normal camera sample passes through unchanged.

`mediaserverd` recognizes only ordinary IOSurface-backed `BGRA`, `420v` and
`420f` buffers from 160×120 through 1080p, with exact packed/plane-layout
checks. The probe build replaces only the previously validated 750×1334 BGRA
output. Unknown output signatures, high-resolution still, 10-bit/HDR and other
formats remain observation-only until device evidence proves a safe positive
allowlist entry and acceptable synchronous render cost.

## Decode behavior

- Images are decoded once by Core Image and rendered as a static source.
- Local video uses one `AVPlayerItemVideoOutput` driven by media time. It does
  not preload the asset into a frame array and loops at end-of-item when enabled.
- OBS receives only the newest JPEG packet. The source expires after 3.5 seconds
  without a packet.
- RTSP uses FFmpeg only inside `vcamd`, with TCP, normal RTP/H.264 reorder and
  reference buffering, and VideoToolbox where available. Software conversion
  runs on a latest-only queue, while every compressed packet is still consumed
  in order; corruption enters a bounded clean-key-frame recovery state.

SpringBoard remains the only configuration writer. `vcamd`, running as `mobile`,
reads imported media directly from `/var/mobile/Media/VCAM`; mediaserverd never
opens the selected media file.

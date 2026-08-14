# EthanArbuckle/vcam-ios implementation comparison

Reference snapshot: `dist/refs/vcam-ios`, commit `55560cb`.

## Shared seam

Both projects hook `BWNodeOutput -emitSampleBuffer:`, check for video media,
draw into the supplied pixel buffer and then call the original method. This is
the part retained from the reference because it provides the mediaserverd-level
replacement seam.

## Important differences

| Concern | Reference | This project (`worker1`) |
| --- | --- | --- |
| Media path | Hard-coded `/tmp/test.png` or commented DCIM MOV | SpringBoard picker and shared configuration |
| Image | UIImage/CGImage | SpringBoard ImageIO normalization into one source-sized IOSurface |
| Local video | AVAssetReader preloads at most 60 BGRA frames | SpringBoard AVPlayerItemVideoOutput, source-sized NV12, no frame-array preload |
| Loop | Callback index modulo the short frame array | Complete asset timeline loops at end-of-item |
| Memory | Frame array remains resident; README notes leaks | Only source state, renderer pools and latest shared frames stay resident |
| OBS | None | WebSocket/JPEG latest-frame source in `vcamd` |
| RTSP | None | FFmpeg demux + software decode in `vcamd` |
| HLS | None | SpringBoard AVPlayer + AVPlayerItemVideoOutput |
| Preview/control | None | One foreground-owned white dot, unified picker and shared-frame preview in SpringBoard plus UI-only Camera/browser hosts |
| mediaserverd dependencies | UIKit and in-process decoding | Rendering frameworks only; no UIKit, source decoder or network client |
| Failure behavior | Process restart suggested about every 30 seconds | Stale/missing shared frame retains virtual output, emits black or suppresses the sample; it never exposes the real camera while enabled |

## Why the worker exists

The reference implementation proves that mediaserverd can consume a decoded
pixel frame, but it does not make mediaserverd a safe place for file/network
decoders. Here `vcamd` owns OBS/RTSP blocking, reconnecting and decode state,
while SpringBoard owns static images and native local-video/HLS playback. Static images
publish one source-sized BGRA IOSurface; moving native sources use three
source-sized NV12 surfaces, with a fixed BGRA mmap only for compatibility. The
consumer roles—mediaserverd replacement and UI preview clients—only perform a
bounded memory copy and reject stale or torn slots.

This design also answers the memory question directly: the selected video is
not pre-decoded into RAM. Images remain static; video timing follows the asset;
OBS/RTSP/HLS retain only their most recent received/decoded frame.

## Packaging

The output is a standard rootless `/var/jb` package (`iphoneos-arm64`). The
media client targets only `mediaserverd`; the UI client targets SpringBoard and
the supported Camera/browser main processes. `vcamd` is a package-owned
LaunchDaemon and is not injected into any App. Audio replacement is disabled,
so the real microphone path is unchanged.

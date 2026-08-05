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
| Image | UIImage/CGImage | Core Image in isolated `vcamd` |
| Local video | AVAssetReader preloads at most 60 BGRA frames | One AVPlayerItemVideoOutput, sampled by media time |
| Loop | Callback index modulo the short frame array | Complete asset timeline loops at end-of-item |
| Memory | Frame array remains resident; README notes leaks | Only source state, renderer pools and latest shared frames stay resident |
| OBS | None | WebSocket/JPEG latest-frame source in `vcamd` |
| RTSP | None | FFmpeg demux + VideoToolbox in `vcamd` |
| Preview/control | None | SpringBoard white dot, unified picker and shared-frame preview |
| mediaserverd dependencies | UIKit and in-process decoding | CoreImage/CoreMedia/CoreVideo/Foundation only |
| Failure behavior | Process restart suggested about every 30 seconds | Stale/missing shared frame fails open to real camera |

## Why the worker exists

The reference implementation proves that mediaserverd can consume a decoded
pixel frame, but it does not make mediaserverd a safe place for file/network
decoders. Here `vcamd` owns all blocking, reconnecting and decode state and
publishes a fixed 720×1280 BGRA latest frame through a three-slot mmap. The two
consumers—mediaserverd replacement and SpringBoard preview—only perform a
bounded memory copy and reject stale or torn slots.

This design also answers the memory question directly: the selected video is
not pre-decoded into RAM. Images remain static; video timing follows the asset;
OBS/RTSP retain only their most recent received/decoded frame.

## Packaging

The output is a standard rootless `/var/jb` package (`iphoneos-arm64`). Only
`mediaserverd` and SpringBoard filters are shipped. `vcamd` is a package-owned
LaunchDaemon and is not injected into any App. Audio replacement is disabled,
so the real microphone path is unchanged.

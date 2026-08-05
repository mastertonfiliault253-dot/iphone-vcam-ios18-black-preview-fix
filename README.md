# VCAM Media Bridge (iOS 15–16 research build)

VCAM replaces camera video at `BWNodeOutput -emitSampleBuffer:` while keeping
networking and decoding outside injected processes. It is for software you own
or are authorized to test. It does not hook identity, liveness, KYC, payment or
authentication decisions.

## Architecture

Only two Apple processes are injected:

- `mediaserverd`: reads a fresh 720×1280 BGRA frame from a three-slot shared
  mmap. The current probe build replaces the already validated 750×1334 BGRA
  `BWNodeOutput`; other ordinary IOSurface-backed `BGRA`, `420v` and `420f`
  outputs through 1080p are logged by stable signature and fail open until
  their render cost is verified. HDR/10-bit and high-resolution still buffers
  also fail open. A render error or three consecutive renders over 50 ms
  disables replacement for that mediaserverd lifetime.
  It has no FFmpeg, AVAssetReader, UIKit or network client.
- `SpringBoard`: hosts the draggable white dot, configuration broker, unified
  image/video picker and the latest-frame preview.

`vcamd` is this package's LaunchDaemon, not an injected dylib. It owns local
image/video playback, OBS WebSocket/JPEG reception, direct RTSP demux/decode,
rotation/mirroring/content mode, and publication of only the latest frame. A
missing or stale frame fails open to the real camera. Audio is not replaced;
the real microphone continues through the normal pipeline.

`vcaminjectd` is a second package-owned LaunchDaemon, also not an injected
dylib. It runs as root and repairs only the two allowed mappings after
`mediaserverd` or SpringBoard changes PID. It never targets Camera, Safari,
WebKit or third-party application processes.

This keeps the useful `BWNodeOutput` seam from EthanArbuckle/vcam-ios while
avoiding its hard-coded path, 60-frame preload and callback-index timing.
Images remain static indefinitely; videos run on their media timeline and loop
when enabled, without pre-decoding the entire asset into memory.

## Sources

- Photos or Files: PNG, JPEG, HEIC/HEIF, MOV, MP4 and M4V.
- HTTP/HTTPS direct download of the same media types.
- OBS: run `desktop/obs_bridge.py` on the trusted LAN and enter its `ws://` or
  `wss://` address in the panel.
- RTSP: enter an `rtsp://` URL. Only `vcamd` links the minimal FFmpeg libraries;
  it uses TCP, normal RTP/H.264 reorder and reference buffering, VideoToolbox
  where available, and a latest-only bounded software-conversion fallback.

The selected media and configuration live under `/var/mobile/Media/VCAM`.
The shared frame transport lives at `/var/tmp/com.codex.vcam.frames` and carries
no audio.

## Build

With current Theos and an iOS 15+ SDK, build the standard rootless package:

```bash
export THEOS=/path/to/theos
./scripts/build-all.sh
```

On this Windows workspace, `scripts/build-rootless-wsl.sh` uses `/opt/theos` and
stages an `iphoneos-arm64` package under `dist/worker1-rootless`.

Host checks:

```powershell
python -m unittest discover -s tests -v
python -m py_compile desktop\*.py scripts\*.py
```

## Device acceptance

1. Confirm loaded images stay static and long videos loop without increasing
   memory each cycle.
2. Disconnect/reconnect OBS and RTSP; stale shared frames must reveal the real
   camera rather than freeze the previous image.
3. Verify the panel preview and the capture output show the same current frame.
4. Launch and close camera-using apps repeatedly; check `mediaserverd`,
   SpringBoard and `vcamd` crash/watchdog logs.
5. Confirm the microphone remains the real input.
6. Validate every newly observed node signature, format and synchronous render
   cost on-device before adding it to the positive SDR-video allowlist or
   enabling a still path.

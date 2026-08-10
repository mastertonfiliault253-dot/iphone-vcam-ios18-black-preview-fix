# VCAM Media Bridge (iOS 16–16.5 research build)

VCAM replaces camera video at `BWNodeOutput -emitSampleBuffer:` while keeping
networking and decoding outside `mediaserverd` and injected app-host branches;
SpringBoard alone runs the native local-video/HLS player. It is for software
you own or are authorized to test. It does not hook identity, liveness, KYC,
payment or authentication decisions.

## Architecture

The media hook and UI overlay have separate injection scopes:

- `mediaserverd`: reads the latest 1080×1920 frame from the three-slot NV12
  IOSurface transport, with the three-slot BGRA mmap as handshake fallback, and
  replaces validated `BWNodeOutput` consumer boundaries for preview,
  browser/WebRTC, still capture and movie recording. Rendering supports the
  observed BGRA and bi-planar YUV formats. Device-private compressed recording
  buffers use a target-sized public `420v` staging surface and VideoToolbox pixel
  transfer into a private-format clone; the system encoder then owns normal
  timestamp reordering and writes the encoded recording samples.
  Once virtual mode is enabled, a missing, stale or unrenderable source never
  exposes a real camera frame: the last virtual frame is retained when possible,
  otherwise a black frame is emitted or that consumer sample is suppressed.
  It has no FFmpeg, AVAssetReader, UIKit or network client.
- `SpringBoard`: hosts the configuration broker and its draggable white dot.
- Camera, MobileSafari, Chrome, Edge and Firefox main processes receive the UI
  dylib only: one foreground-owned white dot and the same control panel. They
  contain no camera hook, decoder or network source; replacement remains in
  `mediaserverd`.

`vcamd` is this package's LaunchDaemon, not an injected dylib. It owns local
image playback, OBS WebSocket/JPEG reception, direct RTSP demux/decode, and
publication of only the latest frame. SpringBoard owns local video and HLS
playback through the same system AVPlayer/NV12/Metal path. A source or decoder
failure stops publication but does not disable virtual mode.
SpringBoard is the sole enable/restore control-plane writer, so a delayed worker
reload cannot overwrite a newer user choice. Audio is not replaced; the real
microphone continues through the normal pipeline.

`vcaminjectd` is a second package-owned LaunchDaemon, also not an injected
dylib. It runs as root and repairs only the `mediaserverd` and SpringBoard
mappings after either process changes PID. Application UI injection is handled
by the normal tweak filter, never by this watchdog.

This keeps the useful `BWNodeOutput` seam from EthanArbuckle/vcam-ios while
avoiding its hard-coded path, 60-frame preload and callback-index timing.
Images remain static indefinitely; videos run on their media timeline and loop
when enabled, without pre-decoding the entire asset into memory.

## Sources

- Photos or Files: both pickers broker-copy the original selected representation
  and preserve its extension and bytes. PNG, JPEG and HEIC/HEIF use the ImageIO
  static decoder and frame cache. MOV, MP4 and M4V use SpringBoard's
  system `AVPlayer`, output NV12, and loop without pre-decoding the asset.
- HTTP/HTTPS direct download of the same media types.
- OBS: run `desktop/obs_bridge.py` on the trusted LAN and enter its `ws://` or
  `wss://` address in the panel.
- RTSP: enter an `rtsp://` URL. Only `vcamd` links the minimal FFmpeg libraries;
  it uses TCP, normal RTP/H.264 reorder and reference buffering, VideoToolbox
  where available, and a latest-only bounded software-conversion fallback.
  Native 8-bit NV12/YUV420 frames publish through the IOSurface ring without a
  BGRA round trip; mmap remains the automatic consumer-handshake fallback.
- HLS: enter an HTTP/HTTPS `.m3u8` URL. SpringBoard uses the system `AVPlayer`
  pipeline, copies NV12 frames from `AVPlayerItemVideoOutput`, and performs
  rotation, mirroring, fit/fill and scale in one Metal-backed Core Image render
  directly into the three-slot `420v` IOSurface ring.
  A launchd-owned XPC relay transfers those IOSurface rights from SpringBoard
  to mediaserverd; until that handshake succeeds, SpringBoard also publishes
  the live three-slot BGRA mmap compatibility fallback. HLS prefers a one-second
  forward buffer, keeps AVPlayer's automatic stall recovery, logs its live-edge lag,
  and rebuilds a session after eight seconds
  without a decoded frame. The retained daemon decoder can be
  selected for rollback by creating
  `/var/tmp/vcam-hls-legacy-vcamd.enable`.
- Local-video rollback: creating
  `/var/tmp/vcam-local-video-legacy-vcamd.enable` restores the retained daemon
  `AVAssetReader`/FFmpeg path for MOV, MP4 and M4V diagnostics.

The selected media and configuration live under `/var/mobile/Media/VCAM`.
The shared frame transport lives at `/var/tmp/com.codex.vcam.frames` and carries
no audio.

## Build

With current Theos and an iOS 16+ SDK, build the standard rootless package:

```bash
export THEOS=/path/to/theos
./scripts/build-all.sh
```

On this Windows workspace, `scripts/build-rootless-wsl.sh` uses `/opt/theos` and
stages an `iphoneos-arm64` package under `dist/wsl-rootless`. This local build is
only a compile check; the installable artifact is produced by the private macOS
CI workflow. The Linux clang does not emit Apple selector-specific Objective-C
calls, so its arm64e UI slice lacks `__objc_stubs`/`__objc_intobj`; CI extracts
that slice and rejects the package unless both sections are present.

Host checks:

```powershell
python -m unittest discover -s tests -v
python -m py_compile desktop\*.py scripts\*.py
```

### Deterministic RTSP/HLS test source

To separate decoder failures from capture/UI publisher failures, run the
fixed test-pattern publisher on Windows:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\start-deterministic-stream.ps1
```

It launches its own MediaMTX instance on dedicated ports and publishes one
Constrained-Baseline H.264 stream: 1280×720, 30 fps, yuv420p, closed one-second
GOP, no B-frames and no scene-cut keyframes. The device URLs are:

- `rtsp://192.168.2.181:18554/vcam-test`
- `http://192.168.2.181:18888/vcam-test/index.m3u8`

The script auto-discovers the workspace's bundled MediaMTX and the installed
FFmpeg. Use `-MediaMTXPath` or `-FFmpegPath` when they live elsewhere. It owns
only the two child processes it starts and stops both on Ctrl+C. Before a
decoder experiment, require both URLs to report the same 1280×720@30 stream
and decode locally without errors; an open TCP port alone is not acceptance.

## Authorized device experiments

Privileged tests on a real device require the device owner's explicit approval
after the exact target, mutation, and risk have been stated. Record a read-only
baseline first, change one variable at a time, and keep the exact CI package and
its SHA-256 available for recovery. After each test, verify the package version,
entitlements, launchd state, decoder logs, and visible behavior. A failed or
inconclusive experiment must be reverted before another variable is introduced.

For Mach-O entitlement experiments, restore by reinstalling the verified,
signed CI package. A normal file copy is not a reliable code-signature backup.
Never commit device credentials, authorization tokens, or private device logs.
The `platform-application`, `com.apple.videotoolbox.leghorn`, and NULL
VideoToolbox output-attribute experiments were each explicitly authorized,
tested as separate single variables, found ineffective, and therefore are not
shipped.

## Device acceptance

1. Confirm loaded images stay static and long videos loop without increasing
   memory each cycle.
2. Disconnect/reconnect OBS and RTSP; a source outage must freeze the last
   virtual frame or show black, never reveal the real camera.
3. Verify the panel preview and the capture output show the same current frame.
4. Launch and close camera-using apps repeatedly; check `mediaserverd`,
   SpringBoard and `vcamd` crash/watchdog logs.
5. Confirm the microphone remains the real input.
6. Validate front, back, tele, ultra-wide and external routes on the hardware
   that exposes them. A supported architecture is not a substitute for captured
   on-device route and output evidence.
7. With the phone upright, verify Camera preview, Safari/WebRTC and saved stills
   are upright; then record front/back 1080p30 and 4K30 clips and inspect their
   first, middle and final frames. The `mediaserverd` PID must remain stable.

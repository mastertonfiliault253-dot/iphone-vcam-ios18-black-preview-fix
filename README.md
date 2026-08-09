# VCAM Media Bridge (iOS 16–16.5 research build)

VCAM replaces camera video at `BWNodeOutput -emitSampleBuffer:` while keeping
networking and decoding outside injected processes. It is for software you own
or are authorized to test. It does not hook identity, liveness, KYC, payment or
authentication decisions.

## Architecture

The media hook and UI overlay have separate injection scopes:

- `mediaserverd`: reads the latest 1080×1920 BGRA frame from a three-slot shared
  mmap and replaces validated `BWNodeOutput` consumer boundaries for preview,
  browser/WebRTC, still capture and movie recording. Rendering supports the
  observed BGRA and bi-planar YUV formats. Device-private compressed recording
  buffers use a target-sized public `420v` staging surface, VideoToolbox pixel
  transfer into a private-format clone, and a PTS-matched encoded-output guard.
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
image/video playback, OBS WebSocket/JPEG reception, direct RTSP demux/decode,
rotation/mirroring/content mode, and publication of only the latest frame. A
source or decoder failure stops publication but does not disable virtual mode.
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

- Photos or Files: PNG, JPEG, HEIC/HEIF, MOV, MP4 and M4V.
- HTTP/HTTPS direct download of the same media types.
- OBS: run `desktop/obs_bridge.py` on the trusted LAN and enter its `ws://` or
  `wss://` address in the panel.
- RTSP: enter an `rtsp://` URL. Only `vcamd` links the minimal FFmpeg libraries;
  it uses TCP, normal RTP/H.264 reorder and reference buffering, VideoToolbox
  where available, and a latest-only bounded software-conversion fallback.
- HLS: enter an HTTP/HTTPS `.m3u8` URL. `vcamd` uses the same bounded FFmpeg +
  VideoToolbox path as RTSP, without RTSP transport options, and publishes only
  the latest frame.

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

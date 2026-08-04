# VCAM Media Bridge (iOS 15–16 research build)

This branch refactors the original `wordgege/iPhone-VCAM` proof of concept into
a small capture-hook interface backed by interchangeable local-media and OBS
network sources. It is intended for testing software you own or are authorized
to test. It does not hook Face ID, LocalAuthentication, liveness, KYC, or other
authentication decisions.

The upstream repository publishes source but contains no license file. Keep
this derivative private unless the upstream author grants redistribution rights.

## Target

- Primary device: iPhone SE (2nd generation, A13/arm64e)
- Primary OS: iOS 16.5
- Primary jailbreak: Dopamine 2.4.9 rootless (ElleKit)
- Additional package schemes: rootful and roothide

System-process arm64e binaries require a macOS/Xcode linker for the modern ABI.
The included GitHub Actions workflow builds on macOS. Linux/WSL can still run
the desktop tests and may build ordinary arm64 app injection, but it is not the
final verifier for the system Camera process.

## Implemented in this branch

- A single `VCAMFramePipeline` interface used by capture hooks.
- Local still-image and looping video sources.
- A draggable in-Camera VCAM dot and dark control panel with Photos/files/URL
  import, OBS stream setup, rotation, mirroring, content mode, audio, looping,
  source status, safe target selection, and immediate real-camera restore.
- Local media audio-track replacement for `AVCaptureAudioDataOutput` consumers.
- Video replacement for `AVCaptureVideoDataOutput` consumers.
- Still-photo `pixelBuffer` and `fileDataRepresentation` replacement.
- Aspect fit/fill/stretch, rotation, mirroring, target resolution, target pixel
  format, and consumer timestamp matching.
- Optional photo metadata merge.
- Optional depth data loaded from the auxiliary depth/disparity payload of an
  existing HEIC/JPEG/DNG file.
- Optional pass-through of an already paired Live Photo still and MOV. The pair
  must already contain matching Apple content identifiers.
- PC OBS Virtual Camera to iPhone video using a local WebSocket/JPEG bridge.
- Separate rootful, rootless, and roothide build schemes.
- Fail-open behavior: invalid configuration, missing media, or a disconnected
  OBS bridge leaves the real sample unchanged.

## Not yet claimed as verified

- System Camera preview and recording on iOS 16.5. The public AVFoundation
  callbacks are hooked, but the Camera app can use private capture paths.
- OBS audio. The wire format reserves PCM audio packet kind 2, but the current
  desktop bridge sends video only.
- Embedding replacement depth into every encoded output container. Consumers
  reading `AVCapturePhoto.depthData` see the supplied value; container-level
  verification still needs a device test.
- Live Photo duration/display-time rewriting. Supply a valid pre-paired still
  and MOV; arbitrary files do not become a valid Live Photo automatically.
- Metadata callbacks from `AVCaptureMetadataOutput`. Put QR content in the
  replacement image/video so the target app performs its normal detector path.
- Device testing. A compiled package alone is not evidence that Camera, a video
  call app, and a scanner app all use the same capture path.

## Configuration

### On-device video picker

On the unlocked Home screen, tap the draggable white VCAM dot to configure the
shared source and injection targets before opening a target app. The same full
panel is available in Camera, Safari, Chrome, and SafariViewService when enabled.
Choose **从相册选择** to import a video from Photos. The selected asset and
shared preference file are stored under `/var/mobile/Media/VCAM`. SpringBoard
is the only configuration writer; sandboxed panels use its loopback-only broker.
The capture pipeline reloads without a respring. Choose
**恢复真实相机** from the same panel to disable replacement. Cancelling the
picker leaves the current source unchanged.

Camera, Safari, Chrome, Edge, Google, and WebKit WebContent are enabled by
default and share one global toggle. mediaserverd is not an injection target.
A three-finger double tap hides or restores the dot for the current UI host;
VoiceOver disables that gesture.

### Manual configuration

The tweak reads:

`/var/mobile/Media/VCAM/com.codex.vcam.plist`

Generate a configuration on the PC:

```powershell
python scripts\write-config.py --source local `
  --media-path /var/mobile/Media/DCIM/vcam.mov `
  --audio --mirror
```

Use `--metadata-json metadata.json`, `--depth-image-path ...`, and the paired
`--live-photo-still-path ... --live-photo-movie-path ...` options for ordinary
photo metadata, depth, and pre-paired Live Photo test assets.

For OBS input:

```powershell
python scripts\write-config.py --source obs `
  --obs-url ws://192.168.1.20:8765
```

Copy the generated plist to the path above and post the Darwin notification
`com.codex.vcam/preferences.changed`, or restart the target app.

## OBS / RTSP desktop bridge

The control panel accepts either a `ws://` bridge address or a direct
`rtsp://` address. Direct RTSP uses FFmpeg for RTSP/RTP demuxing and
VideoToolbox hardware decoding on the phone; TCP transport, low-delay mode,
latest-frame delivery, and automatic reconnect are enabled.

The iOS package links a minimal LGPL FFmpeg 7.1.1 build containing only the
RTSP, H.264/HEVC, and VideoToolbox pieces needed by this feature. The pinned
source build is reproducible through `scripts/build-ffmpeg-ios.sh`.

1. Install OBS Studio and start **Virtual Camera**.
2. Install bridge dependencies:

   ```powershell
   python -m pip install -r desktop\requirements.txt
   ```

3. Start the bridge, trying another device index if OBS is not index 0:

   ```powershell
   python desktop\obs_bridge.py --device 0 --port 8765
   ```

   Or ingest an RTSP source (TCP transport, low-latency buffering, and reconnect
   are enabled) and relay it to the same iPhone WebSocket client:

   ```powershell
   python desktop\obs_bridge.py --rtsp-url rtsp://192.168.2.10:8554/live --port 8765
   ```

4. Put the PC and iPhone on the same trusted LAN and use the PC LAN address in
   `obsWebSocketURL`. Do not expose the bridge port to the internet; this first
   protocol version has no authentication or encryption when using `ws://`.

## Build

With current Theos and an iOS SDK:

```bash
export THEOS=/path/to/theos
./scripts/build-all.sh
```

RootHide requires `roothide/theos`; its official package scheme is
`THEOS_PACKAGE_SCHEME=roothide`. The build script detects that module before
attempting the third package.

The repository path may contain spaces. `scripts/build-all.sh` automatically
builds from a temporary no-space mirror and copies the packages back.

Local build outputs in this checkout:

- `iphoneos-arm`: rootful layout (`/Library/...`).
- `iphoneos-arm64`: rootless layout (`/var/jb/Library/...`) for Dopamine.
- `iphoneos-arm64e`: RootHide package built with `roothide/theos`.

## Host tests

```powershell
python -m unittest discover -s tests -v
python -m py_compile desktop\*.py scripts\*.py
```

## Device acceptance checklist

Test each item with replacement disabled first, then enabled:

1. Camera launch/close 20 times without a SpringBoard respring or watchdog kill.
2. Front and rear previews in portrait and landscape.
3. Still-photo output and saved orientation.
4. Five-minute video recording with monotonic audio/video timestamps.
5. A simple owned AVFoundation test app receiving video and audio buffers.
6. OBS disconnect/reconnect while capture is active.
7. Memory footprint after ten media loops.
8. Uninstall restores the real camera without leftover configuration effects.

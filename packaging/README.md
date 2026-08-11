# Package target map

`targets.json` is the machine-checked process map for one package containing
two injected dylibs and two isolated daemon executables.

| Target | Runtime role | Injection |
| --- | --- | --- |
| `VCAMMediaServerClient` | Reads the latest shared frame at `BWNodeOutput` | `mediaserverd` only |
| `VCAMSpringBoardClient` | SpringBoard broker/native local-video/HLS/static-image publisher; UI-only client in Camera and supported browsers | SpringBoard, Camera and supported browser main processes |
| `vcamd` | OBS/RTSP decode and shared-frame publication; retained local/HLS rollback readers | None (mobile LaunchDaemon) |
| `vcaminjectd` | Repairs only SpringBoard/mediaserverd mappings after restart | None (root LaunchDaemon) |

Camera and supported browser filters load only the in-process white dot and
control panel; camera-frame replacement remains exclusively in `mediaserverd`.
FFmpeg is linked only into `vcamd`; audio stays on the real microphone path.

# Release build policy

Release packages are built by `.github/workflows/build.yml` on macOS/Xcode.
The WSL script is only a local compile/test aid because its third-party Linux
toolchain may emit incompatible arm64e ABI slices. Do not install or publish a
WSL-built DEB as the final device package.

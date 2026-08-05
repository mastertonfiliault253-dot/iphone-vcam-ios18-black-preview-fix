# Package target map

`targets.json` is the machine-checked process map for one package containing
two injected dylibs and one isolated worker executable.

| Target | Runtime role | Injection |
| --- | --- | --- |
| `VCAMMediaServerClient` | Reads the latest shared frame at `BWNodeOutput` | `mediaserverd` only |
| `VCAMSpringBoardClient` | White-dot UI, picker, broker and preview | SpringBoard only |
| `vcamd` | Local/OBS/RTSP decode and shared-frame publication | None (LaunchDaemon) |

No Camera, browser, WebKit or third-party App filter is packaged. FFmpeg is
linked only into `vcamd`; audio stays on the real microphone path.

# Release build policy

Release packages are built by `.github/workflows/build.yml` on macOS/Xcode.
The WSL script is only a local compile/test aid because its third-party Linux
toolchain may emit incompatible arm64e ABI slices. Do not install or publish a
WSL-built DEB as the final device package.

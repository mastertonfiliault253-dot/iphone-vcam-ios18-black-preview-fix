# VCAM Media Bridge 项目介绍与学习文档

> 适用范围：`D:\work\IOSVCAN-DS\vcam`（当前工作副本，HEAD `9730df6`，版本 `0.7.9+global10`）。
> 本文件只描述媒体管线，不包含 SSH 密码、GitHub Token 等敏感信息；敏感信息见 `PROJECT-INFO-SECRETS.md`（已被 `.gitignore` 忽略，严禁推送到公开仓库）。

## 1. 项目是什么

VCAM Media Bridge 是一个 iOS 越狱（rootless）虚拟相机/视频替换插件。它把系统相机输出替换为本地图片、本地视频、OBS 网络画面或 RTSP 直播流，目标是让“所有调用相机的 App”都看到替换后的画面，而不是逐个 App 注入。

项目边界：

- 只做相机媒体管线（预览、录像、拍照、浏览器/WebRTC 取流、二维码/视觉分析输入）。
- 不处理也不优化身份认证、活体检测、KYC、支付或安全决策；这些场景的媒体管线问题按“相机管线缺陷”排查。
- 不替换音频；真实麦克风继续走原链路。
- 只注入两个 Apple 系统进程：`mediaserverd` 与 SpringBoard；不注入任何第三方 App。

## 2. 总体架构

```mermaid
flowchart LR
    UI[SpringBoard 小白点/配置/选择器/预览] -->|broker 写入配置| CFG[(/var/mobile/Media/VCAM)]
    CFG --> VCAMD[/var/jb/usr/libexec/vcamd]
    VCAMD -->|latest BGRA| SHM[(/var/tmp/com.codex.vcam.frames 三槽 mmap)]
    SHM --> MSD[mediaserverd 注入: BWNodeOutput 替换]
    MSD --> APP[相机类 App / 浏览器 / Camera / 录像]
    MON[/var/jb/usr/libexec/vcaminjectd] -->|修复两个映射| MSD
    MON --> UI
```

核心设计：

- **mediaserverd 注入**：`VCAMMediaServerClient.dylib` 只做“取最新虚拟帧 → 按路由渲染/替换 → 输出”，不联网、不解码、不碰 UIKit/AVAssetReader。
- **SpringBoard 注入**：`VCAMSpringBoardClient.dylib` 负责小白点、配置 Broker、媒体选择器和最新帧预览。
- **vcamd（项目自己的 LaunchDaemon）**：所有阻塞/重连/解码/渲染都在这一个隔离进程里，崩溃不会直接拖死 mediaserverd。
- **vcaminjectd（项目自己的 LaunchDaemon）**：root 权限，仅在 mediaserverd / SpringBoard PID 变化后修复两个允许的 dylib 映射。
- **共享内存帧**：三槽 mmap + 原子槽位/序号/时间戳，消费者做有界复制并拒绝陈旧/撕裂槽。

## 3. 目录与源码地图

| 路径 | 作用 |
| --- | --- |
| `Sources/Hooks/VCAMMediaServerRefEntry.xm` | mediaserverd 核心 hook：`BWNodeOutput -emitSampleBuffer:`、替换路由、传播标记、RemoteQueueSink 诊断 |
| `Sources/Hooks/VCAMMediaServerRefImageUtils.m` | 渲染/像素转换/CMSampleBuffer 重建工具 |
| `Sources/Hooks/VCAMSpringBoardEntry.xm` | SpringBoard 注入入口：小白点、Broker、预览驱动 |
| `Sources/Daemon/main.m` | vcamd 入口 |
| `Sources/Daemon/VCAMFrameProducer.m` | 配置加载、媒体源生命周期、按模板取帧 |
| `Sources/Sources/VCAMLocalMediaSource.m` | 本地图片/视频源（当前用 AVAssetReader，正在改造） |
| `Sources/Sources/VCAMRTSPStreamSource.m` | RTSP/FFmpeg/VideoToolbox 源（最新帧模型，软解兜底） |
| `Sources/Sources/VCAMOBSStreamSource.m` | OBS WebSocket/JPEG 源 |
| `Sources/Core/VCAMFrameRenderer.m` | 像素格式归一化、旋转、镜像、内容模式、目标尺寸 |
| `Sources/Core/VCAMConfiguration.m` | 配置读写、Broker 客户端/服务端、媒体导入 |
| `Sources/Shared/VCAMSharedFrame.m` | 三槽共享帧协议 |
| `Sources/UI/` | 控制面板、媒体选择器、共享帧预览 |
| `Sources/Daemon/VCAMInjectionMonitor.m` | vcaminjectd：只允许两个目标路径 |
| `desktop/obs_bridge.py` | PC 端 OBS 虚拟摄像头桥接（版本化包协议） |
| `scripts/` | FFmpeg 构建、WSL 编译检查、诊断分析、配置写入 |
| `tests/` | 主机结构测试（当前 76 项，含路由/打包/协议/性能分析器） |
| `.github/workflows/build.yml` | macOS rootless CI：测试 → 构建 FFmpeg → Theos 打包 → 校验 → artifact |

## 4. mediaserverd 替换路由

`VCAMReplacementRouteForOutput` 只放行设备上实际观察到的、带明确消费语义的输出：

| 路由 | 匹配特征 | 覆盖场景 |
| --- | --- | --- |
| `camera-source-video` | `BWMultiStreamCameraSourceNode` 的 `VideoCapture` 输出 | SmartCam/分析、上游虚拟化 |
| `video-converter` | `BWPixelTransferNode` 的 `Video Data Converter/Scaler/Zoomer`、`Rotator/Zoomer` | Safari/WebRTC、第三方 VideoDataOutput |
| `camera-preview` | `BWPixelTransferNode` 的 `Preview Scaler` | 系统 Camera 预览 |
| `video-recording` | `BWPixelTransferNode` 的 `Movie File Zoomer` | 系统录像 |
| `still-photo` | `BWMeteorHeadroomNode` 的 `Meteor Headroom` | 拍照编码前最后一级 |

安全策略：

- 启用虚拟模式后，替换失败/帧缺失/格式不支持时 **fail-closed**：保留最后虚拟帧或输出黑帧/抑制样本，绝不泄漏真实相机帧。
- `camera-source-video` 替换成功后在 sample/image 上写版本化传播标记；下游“快速路径”必须看到匹配的标记才直接放行，避免未替换帧误通过。
- FanOut/Inference/元数据节点不是替换路由。
- `BWRemoteQueueSinkNode -renderSampleBuffer:forInput:` 目前是 **diagnostic-only**（计数+格式+是否带标记，原样放行），用于确认浏览器/KYC 取流是否走该末端；等设备证据充分后再决定是否升级为 fail-closed 兜底。

## 5. 媒体源

### 本地图片

PNG/JPEG/HEIC 等：`CGImageSource` 解码一次为静态帧，无限期显示。

### 本地视频

MOV/MP4/M4V：当前实现为增量 `AVAssetReaderTrackOutput` + PTS 驱动，不预解码数组，loop 时重建 reader。**已知问题**：在 iPhone SE2 / iOS 16.5 的 vcamd 守护进程里，BGRA 与原生 `420v` 两种输出设置都会连续返回 32 个 `numSamples=0` 的空 marker，reader 被判失败（fail-closed，不泄漏真实相机）。

诊断结论：这不是“marker 上限太小”，也不是颜色格式问题；`vcamd` 内 VideoToolbox 同样无法出帧（RTSP 日志显示硬件解码无输出后自动切 FFmpeg 软解）。因此本地视频的既定修复方向是**改用 vcamd 已有的 FFmpeg 软解**：按 PTS 实时节流、逐帧 YUV→BGRA、只保留最新一帧、EOF 后 seek 循环。

### OBS

`desktop/obs_bridge.py` 在可信局域网运行，接收 OBS 虚拟摄像头并按版本化协议发送最新 JPEG；3.5 秒无包视为过期。

### RTSP

`vcamd` 内 FFmpeg：TCP、正常 RTP 重排与 H.264 参考缓冲；优先 VideoToolbox，无输出自动切软解；损坏后进入有界“等干净关键帧”恢复。当前设备配置 `rtsp://192.168.2.172:553/live`，排查时该服务器一度不可达，导致 vcamd 没有新帧、浏览器/KYC 窗口黑屏。

## 6. 构建、CI 与发布

- 目标：rootless `iphoneos-arm64` DEB，全部文件位于 `/var/jb`。
- 工具链：Theos + iOS 15+ SDK；`vendor/ffmpeg` 由 CI 内 `scripts/build-ffmpeg-ios.sh` 构建。
- 本地 WSL 构建只是编译检查；可安装产物只来自私有 macOS CI。
- CI workflow：`Build rootless package`，只响应 `codex/ios16-media-bridge` 分支 push，跑 76 项主机测试 → Theos 安装 → 构建 → 校验（单一 DEB、双架构 dylib、vcamd 内存状态 entitlement、无旧 VCAM.dylib/AppClient/WebKitClient）→ 上传 `vcam-rootless` artifact。
- 仓库规则：只推私有仓库（`newci` / `newprivate` / `private`）；`origin`（wordgege/iPhone-VCAM）是公开 fork，**严禁推送**；`PROJECT-INFO-SECRETS.md` 和 SSH 辅助脚本已 gitignore，且有 pre-push 保护。
- 发布校验：同一 run 独立下载两份 artifact，核对 DEB SHA-256 一致，再上传设备核对一次 SHA 后 `dpkg -i`。

## 7. 设备测试环境

- 设备：iPhone SE 2（iPhone12,8）/ iOS 16.5 / Dopamine 2.x rootless。
- SSH：`root@192.168.2.101`（密码等敏感信息只放在 `PROJECT-INFO-SECRETS.md`，本文件不重复）。
- 远程控制：TrollVNC + noVNC，SSH 本地转发 5901/5801/5802 到本机，浏览器打开 `http://127.0.0.1:5802/novnc/vnc.html?host=127.0.0.1&port=5901&autoconnect=true&resize=scale`。

关键路径：

| 内容 | 路径 |
| --- | --- |
| 配置 | `/var/mobile/Media/VCAM/com.codex.vcam.plist` |
| 媒体 | `/var/mobile/Media/VCAM/` |
| vcamd 日志 | `/var/mobile/Library/Application Support/VCAM/vcam-app.log` |
| mediaserverd 注入日志 | `/var/tmp/vcam-ref-msd.log` |
| 本地播放诊断 | `/var/mobile/Library/Preferences/com.codex.vcam.diagnostics.log` |
| 注入监控日志 | `/var/tmp/vcaminjectd.log` |
| 共享帧 | `/var/tmp/com.codex.vcam.frames` |

## 8. 主机测试与设备验收

主机回归：

```powershell
python -m unittest discover -s tests -v
```

覆盖：媒体选择器/导入、本地播放结构、OBS/RTSP 协议、打包架构（只有两个注入目标）、SpringBoard 注入恢复、mediaserverd 上游路由、协议编解码、诊断分析器。

设备验收要点：

1. 图片静态、长视频跨 loop 播放且 RSS 不持续增长。
2. OBS/RTSP 断连时冻结最后虚拟帧或黑屏，绝不显示真实相机。
3. 面板预览与相机输出一致。
4. 反复打开/关闭相机类 App，检查 mediaserverd、SpringBoard、vcamd 崩溃与 watchdog。
5. 麦克风仍为真实输入。
6. 前/后/长焦/超广角/外接摄像头路由逐项验证。
7. 竖持手机时 Camera 预览、Safari/WebRTC、保存照片方向正确；再录 1080p30 与 4K30，检查首/中/尾帧；mediaserverd PID 稳定。

## 9. 已知问题与排查手册

### 本地视频黑屏（进行中）

现象：`vcamd reload started=0 error=Unable to decode the first video frame`，日志连续出现 `local reader skipped non-pixel sample`。

方向：改 FFmpeg 软解，见“媒体源/本地视频”。修复后日志应出现 `local ffmpeg session`、`local ffmpeg first-frame`、`local ffmpeg eof loop`，且 `started=1`。

### 浏览器/KYC 窗口黑屏

排查顺序：

1. `vcamd reload` 是否 `started=1`；RTSP 源是否可达（`Test-NetConnection 192.168.2.172 -Port 553`）。
2. `vcam-app.log` 是否持续出现 RTSP 软解帧；mediaserverd 是否 `rendered shared frame`。
3. 打开浏览器 KYC 窗口后看 `vcam-ref-msd.log`：是否出现 `remote queue sink diagnostic video`；若只有 `non-video mediaType=00000000`，说明该末端没有收到带格式的视频样本，需要进一步确认 WebRTC 实际路由。

### 小白点消失

检查 SpringBoard 是否以新 PID 重启、`vcaminjectd` 是否修复映射、`/var/tmp/vcaminjectd.log` 是否有 proof；必要时 `kill -TERM <SpringBoard PID>` 让 launchd 干净拉起。

### 旋转/方向、拍照黑边、二维码识别

旋转由 `VCAMFrameRenderer` + `rotationDegrees` 处理；拍照走 `still-photo` 独立路由；二维码分析走 SmartCam/`camera-source-video` 上游，不能只靠 RemoteQueueSink 末端解决。

## 10. 学习路线（建议阅读顺序）

1. `README.md` → `ARCHITECTURE.md` → `docs/injection-target-architecture.md`（目标与安全边界）。
2. `Sources/Hooks/VCAMMediaServerRefEntry.xm`（核心注入与路由，重点理解 fail-closed 和传播标记）。
3. `Sources/Daemon/VCAMFrameProducer.m` + `Sources/Core/VCAMMediaSource.h`（源的生命周期与取帧契约）。
4. `Sources/Sources/VCAMRTSPStreamSource.m`（FFmpeg 最新帧模型，也是本地视频改造的模板）。
5. `Sources/Core/VCAMFrameRenderer.m`（格式归一化/旋转/内容模式）。
6. `Sources/Shared/VCAMSharedFrame.m`（三槽 mmap 协议）。
7. `Sources/UI/VCAMControlPanelViewController.m`、`Sources/UI/VCAMMediaPickerController.m`（配置/选择器）。
8. `Sources/Daemon/VCAMInjectionMonitor.m`（注入修复边界）。
9. `tests/`（结构测试如何守住这些不变式）。

## 11. 术语表

| 术语 | 说明 |
| --- | --- |
| rootless | 越狱文件布局，包内容装在 `/var/jb` |
| Theos / Logos | 越狱开发工具链与 hook 语法（`%hook`/`%orig`/`%ctor`） |
| `BWNodeOutput` | Camera 管线里的输出节点，`-emitSampleBuffer:` 是替换缝 |
| `BWRemoteQueueSinkNode` | 远程 VideoDataOutput 消费节点；本项目中目前只诊断不替换 |
| `CMSampleBuffer` / `CVPixelBuffer` | 视频样本/像素缓冲 |
| 传播标记 | 替换成功后写入 sample/image 的版本化附件，供下游快速路径验证 |
| fail-closed | 虚拟模式开启后，宁可黑屏/抑制也不泄漏真实相机帧 |
| `vcamd` / `vcaminjectd` | 项目自己的守护进程：解码/发布与注入修复 |
| 三槽 mmap | 共享帧三缓冲，带序号/时间戳，避免撕裂与陈旧帧 |

## 12. 当前状态与下一步

- 已安装：`com.codex.vcam 0.7.9+global10`（最新 CI artifact，双下载 SHA 校验一致）。
- 仓库 HEAD：`9730df6 fix: decode local video to native surfaces`。
- 待办：
  1. 将本地视频解码切到 vcamd 内 FFmpeg 软解，替换 AVAssetReader。
  2. 推送 PRIVATE CI，下载双份校验，安装后验证 `local ffmpeg first-frame` 与相机/浏览器可见画面。
  3. 在 VNC 里复现浏览器 KYC 窗口，依据 `remote queue sink diagnostic video` 决定是否升级 RemoteQueueSink 兜底。
  4. 恢复/验证用户原 RTSP 配置。

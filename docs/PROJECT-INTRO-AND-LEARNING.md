# VCAM Media Bridge 项目介绍与学习文档

> 适用范围：`D:\work\IOSVCAN-DS\vcam`。提交号与包版本以 `git rev-parse HEAD` 和 `control` 为准，不在文档中写死。
> 本文件只描述媒体管线，不包含 SSH 密码、GitHub Token 等敏感信息；敏感信息见 `PROJECT-INFO-SECRETS.md`（已被 `.gitignore` 忽略，严禁推送到公开仓库）。

## 1. 项目是什么

VCAM Media Bridge 是一个面向 iOS 16.0–16.5 的 rootless 越狱虚拟相机/视频替换插件。它把系统相机输出替换为本地图片、本地视频、OBS、RTSP 或 HLS 画面；媒体替换统一发生在 `mediaserverd`，不靠逐 App 相机 hook。

项目边界：

- 只做相机媒体管线（预览、录像、拍照、浏览器/WebRTC 取流、二维码/视觉分析输入）。
- 不处理也不优化身份认证、活体检测、KYC、支付或安全决策；这些场景的媒体管线问题按“相机管线缺陷”排查。
- 不替换音频；真实麦克风继续走原链路。
- 只有 `mediaserverd` 与 SpringBoard 承担媒体管线职责。Camera 和受支持浏览器主进程只加载 UI dylib，用于一个前台所有者小白点、面板和预览；它们不含相机 hook、解码器或网络源。

## 2. 总体架构

```mermaid
flowchart LR
    UI[SpringBoard 小白点/配置/选择器/预览] -->|broker 写入配置| CFG[(/var/mobile/Media/VCAM)]
    CFG --> VCAMD[/var/jb/usr/libexec/vcamd]
    VCAMD -->|启动握手回退 BGRA| SHM[固定三槽 mmap]
    VCAMD -->|本地图片 1 槽 / OBS 与 RTSP 3 槽| SURF[源尺寸 IOSurface]
    UI -->|本地视频/HLS AVPlayerItemVideoOutput NV12 + Metal，3 槽| SURF
    VCAMD -. XPC 权限中继 .-> SURF
    SHM --> MSD[mediaserverd: BWNodeOutput 替换]
    SURF --> MSD
    MSD --> APP[相机类 App / 浏览器 / Camera / 录像]
    MON[/var/jb/usr/libexec/vcaminjectd] -->|修复两个映射| MSD
    MON --> UI
```

核心设计：

- **mediaserverd 注入**：`VCAMMediaServerClient.dylib` 只做“取最新虚拟帧 → 按路由渲染/替换 → 输出”，不联网、不解码、不碰 UIKit/AVAssetReader。
- **SpringBoard/UI 注入**：`VCAMSpringBoardClient.dylib` 在 SpringBoard 负责配置 Broker、本地图片、本地视频/HLS `AVPlayerItemVideoOutput`、Metal/Core Image 渲染和预览；Camera/浏览器宿主只启用 UI。应用沙箱不能直接读取 mmap/IOSurface 时，悬浮面板只通过回环 Broker 获取降采样 JPEG，绝不把 JPEG 送入 mediaserverd。
- **vcamd（项目自己的 LaunchDaemon）**：负责 OBS、RTSP 和 IOSurface XPC 权限中继；崩溃不会直接拖死 mediaserverd。旧 daemon 本地图片/视频/HLS 路径只作显式回滚。
- **vcaminjectd（项目自己的 LaunchDaemon）**：root 权限，仅在 mediaserverd / SpringBoard PID 变化后修复两个允许的 dylib 映射。
- **共享帧**：本地图片按解码后的原始方向和尺寸发布一个不可变 BGRA IOSurface；本地视频和 HLS 使用三个源尺寸 NV12 IOSurface；OBS 使用三个源尺寸 BGRA IOSurface；RTSP 无变换时使用 NV12、显式旋转或镜像后使用 BGRA。只有 XPC 握手回退保留固定三槽 BGRA mmap。两条路径都有原子槽位/序号/时间戳与陈旧帧保护。

## 3. 目录与源码地图

| 路径 | 作用 |
| --- | --- |
| `Sources/Hooks/VCAMMediaServerRefEntry.xm` | mediaserverd 核心 hook：`BWNodeOutput -emitSampleBuffer:`、替换路由、传播标记、RemoteQueueSink 诊断 |
| `Sources/Hooks/VCAMMediaServerRefImageUtils.m` | 渲染/像素转换/CMSampleBuffer 重建工具 |
| `Sources/Hooks/VCAMSpringBoardEntry.xm` | SpringBoard 注入入口：小白点、Broker、预览驱动 |
| `Sources/Daemon/main.m` | vcamd 入口 |
| `Sources/Daemon/VCAMFrameProducer.m` | 配置加载、媒体源生命周期、按模板取帧 |
| `Sources/Sources/VCAMLocalMediaSource.m` | 本地图片源，以及显式回滚时使用的增量 AVAssetReader/FFmpeg 本地视频路径 |
| `Sources/SpringBoard/VCAMSpringBoardMediaBridge.m` | SpringBoard 本地视频/HLS：AVPlayerItemVideoOutput → NV12 → Metal/Core Image → IOSurface/mmap |
| `Sources/Sources/VCAMRTSPStreamSource.m` | RTSP/FFmpeg/VideoToolbox 源（最新帧模型，软解兜底） |
| `Sources/Sources/VCAMOBSStreamSource.m` | OBS WebSocket/JPEG 源 |
| `Sources/Core/VCAMFrameRenderer.m` | 像素格式归一化、旋转、镜像、内容模式、目标尺寸 |
| `Sources/Core/VCAMConfiguration.m` | 配置读写、Broker 客户端/服务端、媒体导入 |
| `Sources/Shared/VCAMSharedFrame.m` | 动态 IOSurface（图片一槽/视频三槽）与固定 mmap 回退协议 |
| `Sources/UI/` | 控制面板、媒体选择器、共享帧预览 |
| `Sources/Daemon/VCAMInjectionMonitor.m` | vcaminjectd：只允许两个目标路径 |
| `desktop/obs_bridge.py` | PC 端 OBS 虚拟摄像头桥接（版本化包协议） |
| `scripts/` | FFmpeg 构建、WSL 编译检查、诊断分析、配置写入 |
| `tests/` | 主机回归测试：路由、打包、协议、性能、HLS bridge、注入策略等 |
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

相册和文档选择器都请求 provider 的 current 原始 representation，通过 Broker 原子复制并保留实际扩展名/字节；每次选择生成新的媒体路径，避免第二次选择仍被播放器判断为同一资源。PNG/JPEG/HEIC 由 `CGImageSource` 解码一次；静态渲染结果缓存后无限期显示。

### 本地视频

MOV/MP4/M4V 的正式路径位于 SpringBoard：系统 `AVPlayer` 解码，`AVPlayerItemVideoOutput` 取 NV12，Metal/Core Image 一次完成方向、缩放和颜色转换，再发布到 IOSurface；loop 时在 item 结束后 seek 到零。创建 `/var/tmp/vcam-local-video-legacy-vcamd.enable` 才恢复旧的增量 `AVAssetReader`/FFmpeg 路径用于诊断。流畅度以真机连续非空发布帧、媒体时钟推进和循环次数验收，不能只凭“能播放”。

### OBS

`desktop/obs_bridge.py` 在可信局域网运行，接收 OBS 虚拟摄像头并按版本化协议发送最新 JPEG；vcamd 解码后按源尺寸发布三槽原始 BGRA IOSurface，3.5 秒无包视为过期。

### RTSP

`vcamd` 内 FFmpeg：TCP、正常 RTP 重排与 H.264 参考缓冲；优先 VideoToolbox，无输出自动切软解；损坏后进入有界“等干净关键帧”恢复。8-bit YUV420/NV12 在无需变换时直接重排为 native NV12 IOSurface，避免 BGRA 往返；显式旋转或镜像时改为源尺寸三槽 BGRA IOSurface；消费者握手前保留 BGRA mmap 回退。诊断统一使用仓库的确定性 MediaMTX/FFmpeg 流，并分别记录源端实测帧率和输出帧率，避免把服务器断流或低帧率误判为解码失败。

### HLS

SpringBoard 使用系统 `AVPlayer` 处理分片、时间线和码率切换，从 `AVPlayerItemVideoOutput` 复制 NV12 `CVPixelBuffer`，再用 Metal-backed Core Image 一次完成旋转、镜像、fit/fill 与输出。HLS 不复用 RTSP 的 FFmpeg/direct-VT 解码路径。

## 6. 构建、CI 与发布

- 目标：rootless `iphoneos-arm64` DEB，全部文件位于 `/var/jb`。
- 工具链：Theos，部署目标 iOS 16.0 且包依赖限制为 `< 16.6`；`vendor/ffmpeg` 由 CI 内 `scripts/build-ffmpeg-ios.sh` 构建。
- 本地 WSL 构建只是编译检查；可安装产物只来自私有 macOS CI。
- CI workflow：`Build rootless package`，响应 `codex/ios16-media-bridge` 分支 push，运行全部主机测试 → Theos 构建 → 校验单一 DEB、arm64/arm64e、Objective-C stub sections、entitlement 与废弃 dylib → 上传 `vcam-rootless` artifact。
- 仓库规则：当前发布 remote 为私有 `newaccount`；`origin`（wordgege/iPhone-VCAM）是公开上游，**严禁推送**。推送前必须用 `git remote -v` 再确认目标；`PROJECT-INFO-SECRETS.md` 和 SSH 辅助脚本已 gitignore。
- 发布校验：同一 run 独立下载两份 artifact，核对 DEB SHA-256 一致，再上传设备核对一次 SHA 后 `dpkg -i`。

### GitHub 外部浏览器授权

切换 GitHub 账号时，不把 Token、设备码或 cookie 写进仓库/Markdown。使用 GitHub CLI 的系统凭据存储：

```powershell
gh auth login --hostname github.com --git-protocol https --web
gh auth status --hostname github.com
git remote -v
```

第一条命令会给出一次性设备码并打开外部浏览器；在浏览器确认新账号后，必须用 `gh auth status` 核对实际账号，再核对 push remote。若账号不对，先执行 `gh auth logout --hostname github.com`，然后重新授权。授权只保存在用户凭据存储中，不随项目提交。

## 7. 设备测试环境

- 当前主验收设备：iPhone13,2 / iOS 16.1 / Dopamine rootless；产品支持范围仍为 iOS 16.0–16.5。
- SSH：`root@192.168.2.201`（密码等敏感信息只放在 `PROJECT-INFO-SECRETS.md`，本文件不重复）。
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
8. 在照片→录像→照片之间连续切换 10 次；每次首个虚拟预览帧应在 500 ms 内恢复，不得出现 unsupported routed format 或真实帧。
9. 录像至少 10 秒并成功保存；文件首/中/尾帧均来自虚拟源，音频仍来自真实麦克风，Photos 中资源可正常播放。
10. 普通照片与 Live Photo 分别拍摄并保存；Photos 中最终主图、缩略图和配对视频不得包含物理相机画面。

## 9. 已知问题与排查手册

### 本地视频不流畅或黑屏

正式路径先看 SpringBoard 日志中的 `springboard local video start`、`decoded=... published=... empty=0 failures=0`、`health` 和 `loop`；约 10 秒应推进约 300 个 30fps 帧。只有显式创建 legacy marker 后，才使用 `scripts/analyze-local-playback-performance.py` 分析 daemon `AVAssetReader`/FFmpeg 回滚路径。

### RTSP 没有硬件帧

当前 iOS 16.1 真机上，FFmpeg 上游 VideoToolbox 与 Apple `AVAssetReader` 原生压缩 `CMSampleBuffer` 的 direct-VT 对照都出现 callback `-12780`、image buffer 为 NULL；服务端帧率、RTSP/RTP、NAL/AU 重写和 HLS 资源占用已被分别排除为唯一根因。正式路径保留软件 fail-open，详细证据见 `VIDEOTOOLBOX-HARDWARE-DECODING-CASES.md`。

### 浏览器相机输出黑屏

排查顺序：

1. 先确认当前源持续发布：HLS 看 `springboard HLS frame decoded=... published=... failures=0`，daemon 源看 `vcamd reload started=1` 与共享帧序号推进。
2. 检查 mediaserverd 日志是否命中正确的 camera-source/video-converter 路由并成功渲染共享帧。
3. 浏览器主进程的 UI dylib 只负责小白点/面板；网页摄像头替换仍必须由 mediaserverd 路由完成，不得为修黑屏恢复 WebKit WebContent 相机 hook。

### 小白点消失

检查 `floatingButtonVisibility.global` 是否为 1、SpringBoard/前台 App 的 PID 所有权是否更新，以及 `/var/tmp/vcam-springboard-client.log` 是否有该进程 ctor。SpringBoard 日志位于 Application Support；Camera 的沙箱不可写时会回退到 `/var/tmp/VCAM/vcam-app.log`。前台宿主应 `hidden=0`，SpringBoard 同时 `hidden=1`。

### 旋转/方向、拍照黑边、二维码识别

源变换由 `VCAMFrameRenderer` + `rotationDegrees` 处理，正常基线必须是 `0°` 且不镜像。iOS 16 的 WebKit `video-converter` 是唯一的实时方向适配例外：仅竖向源左转进入其横向存储基准，再按真实相机行为一次性居中裁剪并填满浏览器已经协商的目标缓冲区；Camera 预览保持完整画面适配，录像保持满幅。VCAM 不伪造浏览器能力表，也不固定 640×480/720p/1080p，目标尺寸、帧率、像素格式、时间戳和附件仍由真实相机图决定；不得用目标宽高猜浏览器。目标缓冲区不会再次缩放或重建，因此没有第二次 VCAM 放大；源与目标比例不同时，消除黑边必然裁掉边缘像素。拍照走 `still-photo` 独立路由：竖向规范源仅在 `Meteor Headroom` 末端转换到横向传感器存储并写入 EXIF `Orientation=Right`，横向源不变，使保存比例跟随源而不是手机姿态。二维码分析走 SmartCam/`camera-source-video` 上游，不能只靠 RemoteQueueSink 末端解决。

## 10. 学习路线（建议阅读顺序）

1. `README.md` → `ARCHITECTURE.md` → `docs/injection-target-architecture.md`（目标与安全边界）。
2. `Sources/Hooks/VCAMMediaServerRefEntry.xm`（核心注入与路由，重点理解 fail-closed 和传播标记）。
3. `Sources/Daemon/VCAMFrameProducer.m` + `Sources/Core/VCAMMediaSource.h`（源的生命周期与取帧契约）。
4. `Sources/Sources/VCAMRTSPStreamSource.m`（FFmpeg 上游 hwaccel 与软件 fail-open）。
5. `Sources/SpringBoard/VCAMSpringBoardMediaBridge.m`（HLS AVPlayer/NV12/Metal/IOSurface）。
6. `Sources/Core/VCAMFrameRenderer.m`（daemon 源格式归一化/旋转/内容模式）。
7. `Sources/Shared/VCAMSharedFrame.m` + `VCAMSurfaceBroker.m`（动态 IOSurface 槽深、固定 mmap 回退和 XPC rights relay）。
8. `Sources/UI/VCAMControlPanelViewController.m`、`Sources/UI/VCAMMediaPickerController.m`（配置/选择器/小白点手势）。
9. `Sources/Daemon/VCAMInjectionMonitor.m`（只修复两个系统媒体目标）。
10. `tests/`（回归测试如何守住这些不变式）。

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
| `vcamd` / `vcaminjectd` | 项目自己的守护进程：daemon 源解码/发布/XPC rights relay 与注入修复 |
| 共享帧 | 图片使用一个不可变 IOSurface；视频使用三个 IOSurface；兼容 mmap 保留三缓冲。均带序号/时间戳与消费者占用计数 |

## 12. 当前状态与下一步

- 发布状态不得写死在本文。每次交付都必须重新执行 `git rev-parse HEAD`、`gh run list`、下载 CI artifact、核对 SHA-256，并把同一 DEB 安装到目标设备；WSL 包只作编译检查。
- HLS 服务端已经用固定 session 的五分钟连续性探针证明无 HTTP 错误、时间线连续且 live edge 保持新鲜。客户端使用 SpringBoard `AVPlayerItemVideoOutput` 连续发布，配置 1 秒前向缓冲、保留 iOS 16.1 必需的自动续播并记录 `liveLag`；每个新 CI 包仍需在 Camera 播放状态下复验非空帧、延迟和断流自恢复。
- 本地视频正式路径已在真机连续发布约 30fps、`empty=0`、`failures=0` 并多次循环；旧 daemon reader 仅保留为 marker 控制的回滚。相册/文件选择现在保留原始 representation 且每次生成新路径；仍必须用新 CI 包重复选择同一类型资源验证切换和长期显示。
- 静态照片必须在每个新 CI 包重新验收。私有 `pf20` StillImage 源不得被直接抑制，应先在 mediaserverd 内进入可替换的 420f `Meteor Headroom` 终点；普通照片与 Live Photo 都要确认主图、缩略图和配对视频完整且不含真实帧。
- RTSP 的 FFmpeg upstream VT 仍未取得连续非空 `AVFrame.data[3]`/`CVPixelBuffer`；Apple direct-VT 对照也失败。软件回退可用，但在真机达到连续非空硬件帧前不得宣称 RTSP 硬件解码完成。
- Camera 与 MobileSafari 已有单点所有权证据；Chrome、Edge、Firefox 未在当前设备安装，因此只具备 bundle/策略主机测试，不能写成真机已验收。三指双击也必须在每个实际安装的 UI 宿主上物理复验隐藏/显示及进程切换恢复。

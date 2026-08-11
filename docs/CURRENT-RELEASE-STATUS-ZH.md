# VCAM 当前发布基线与技术状态

> 本文件记录“最新可部署版本”的固定快照。每次发布新版本时必须同时更新本文件、`control`、运行时 `VCAMBuildTag()` 和安装文档。

## 1. 当前发布基线

| 项目 | 当前值 |
|---|---|
| 包版本 | `0.8.81+ios16-source-pipeline-audit` |
| Git 提交 | `a93badbbf22d1cdf4f373d454affd320836c2d6c` |
| 提交说明 | `fix Debian postrm executable mode` |
| 发布分支 | `codex/ios16-media-bridge` |
| 发布 remote | `current`（`cuentaripionose-prog/iphone-vcam-ios16-private`） |
| macOS CI run | `31528507761`（成功） |
| DEB 架构 | `iphoneos-arm64`，包内客户端包含 `arm64`/`arm64e` |
| DEB 大小 | `1,101,854` 字节 |
| DEB SHA-256 | `0017182D34811536D135AC76DC5FABE62A7666E48D227BE486AF0C80B8770F1F` |
| 支持系统 | iOS `>= 16.0` 且 `< 16.6` |
| 越狱布局 | rootless |

本机已校验的 CI 产物：

```text
D:\work\IOSVCAN-DS\vcam\dist\ci-a93badb-run31528507761-a\vcam-rootless\com.codex.vcam_0.8.81+ios16-source-pipeline-audit_iphoneos-arm64.deb
```

运行时可在 `/var/mobile/Media/VCAM/broker-probe.log` 中核对：

```text
tag=com.codex.vcam/0.8.81+ios16-source-pipeline-audit
```

## 2. 本版本的主要技术变化

本版本是 iOS 16 源尺寸媒体管线的完整审查加固版：

- 继续保留真实物理相机图作为 WebKit 分辨率、帧率、像素格式、时间戳和附件的协商外壳，只替换像素；
- WebKit 终端仍按已验证的 iOS 16 存储基准做一次方向补偿和 full-bleed 中心裁剪，不拉伸、不添加 VCAM 黑边；
- 静态拍照不再由 VCAM 强写系统方向 metadata；Camera、WebKit、拍照和录像保持各自路由语义；
- mmap 与 IOSurface 交接加入 producer generation、跨进程发布锁、PID start-token 和旧帧拒绝；
- RTSP 改为 FFmpeg 上游 VideoToolbox hwaccel，只有明确硬件拒绝或解码停滞才粘性回退软件；
- P010/10-bit packing、BT.2020 颜色边界、源尺寸软件回退和整条管线内存预算已加固；
- HLS 保持 Apple 原生 `AVPlayerItemVideoOutput`，加入直播边缘追赶与无帧重连；
- 本地非循环视频正常结束后保留最后一帧，不再被通用停滞逻辑重新循环；
- 导入、下载、配置 Broker、日志大小、安装/卸载脚本和 fresh-install 真实相机回退均完成安全与并发审查。

共享传输基线没有改回固定画布：

- 静态图片：源尺寸、一槽 BGRA IOSurface；
- 本地视频/HLS：源尺寸、三槽 420v/NV12 IOSurface；
- OBS：源尺寸、三槽 BGRA IOSurface；
- RTSP：无变换时三槽 NV12，有显式旋转/镜像时三槽 BGRA；
- 固定 1080×1920 BGRA mmap 仅作握手兼容与显式旧路径回滚。

## 3. 构建和发布证据

以下证据已经具备：

- Git HEAD 与 `current/codex/ios16-media-bridge` 同为 `a93badb`；
- `control` 与 `VCAMBuildTag()` 均为 `0.8.81+ios16-source-pipeline-audit`；
- 174 项主机回归测试通过，完整 Standards/Spec 复审均未发现新的确定性缺陷；
- macOS CI run `31528507761` 成功产生正式 DEB；
- 本地从该 DEB 独立提取两个客户端，均为 `arm64`/`arm64e`；两个 arm64e 薄片均含非空 `__objc_stubs` 和 `__objc_intobj`；
- 本机保存的 DEB SHA-256 已重新计算并与安装文档一致；
- Debian `postinst`、`prerm`、`postrm` 在 Git 索引和正式包中均为可执行文件。

该精确 CI 包尚未记录部署到 `192.168.2.101` 或 `192.168.2.201`；此前版本的安装和可见结果不能代替本版本验收。

## 4. 当前真机证据

此前版本在主要测试机 `192.168.2.101` 上已经观察到：

- Safari `getUserMedia` 实际目标为 640×480、420f；
- 虚拟人物画面连续、正向；
- 当前 WebKit full-bleed 策略没有 VCAM 添加的黑边；
- 浏览器控制面板可读取静态图预览；
- 静态图片状态显示“已加载静态图片”，不再显示波动 FPS。

这些证据只覆盖当时安装版本和实际观察到的 Safari 路由，不能外推为当前 `0.8.81`、Chrome、Edge、Firefox 或所有分辨率档位已经通过。

## 5. 仍需用户逐项确认的设备验收

- Camera、悬浮预览、Safari 和系统相册保存结果的上下左右方向一致；
- 竖向照片保存后的实际像素比例和 EXIF 正确；
- 拍照后虚拟视频继续播放，照片真实写入系统相册；
- 录像启动、持续、停止、保存均不冻结；
- 本地 4K 视频和 HLS 的长期流畅度、延迟、丢帧和发热；
- 480p、720p、1080p 以及实际设备可用镜头的路由；
- 动态分辨率、快速切源和三槽占用时无旧帧、撕裂或冻结；
- 源断开后保持虚拟画面或转黑，新 generation 恢复时不闪旧源；
- 每个实际安装浏览器中只有一个可点击小白点；
- 三指双击在物理触摸中稳定显示和隐藏小白点。

## 6. 仍未关闭的高风险项

RTSP 硬件解码不能只依据 `VTDecompressionSessionCreate` 成功、连接成功或日志中出现 VideoToolbox 来验收。必须在 iOS 16.0–16.5 真机上同时证明：

1. RTSP/RTP/H.264 解复用持续正常；
2. 解码回调连续返回非空 `CVPixelBuffer`；
3. 实际选择硬件路径，没有静默回退软件；
4. IOSurface 序号持续推进；
5. Camera/Safari 中可见画面连续且方向正确；
6. 长时间运行无明显丢帧、延迟累积或热降频。

HLS 已使用 Apple 原生 `AVPlayerItemVideoOutput` 管线，但“使用原生硬解候选管线”不等于所有服务端和真机组合已经达到低延迟、零丢帧，仍须结合源端时间线和设备帧计数验收。

## 7. 下一次发布必须怎样更新

发布新版本时按以下顺序更新，不能只改包名：

1. 修改 `control` 的 `Version`；
2. 修改 `Sources/Core/VCAMConfiguration.m` 的 `VCAMBuildTag()`；
3. 提交并推送指定发布 remote；
4. 等待 macOS CI 完成；
5. 下载同一 CI artifact 并计算 SHA-256；
6. 更新本文件的版本、提交、run、大小、哈希和技术变化；
7. 同步更新 `docs/INSTALLATION-ZH.md`；
8. 将同一 DEB 安装到测试设备并记录真机证据；
9. 把未通过项保留在本文，不能因构建绿色而删除。

WSL 产物只作编译检查，不能替换上述 macOS CI 和真机步骤。

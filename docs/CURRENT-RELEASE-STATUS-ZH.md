# VCAM 当前发布基线与技术状态

> 本文件记录“最新 CI 候选版本”的固定快照。只有完成对应真机可见验收后，才能升级为正式发布。每次候选版本变化时必须同时更新本文件、`control`、运行时 `VCAMBuildTag()` 和安装文档。

## 1. 当前 CI 候选基线

| 项目 | 当前值 |
|---|---|
| 包版本 | `0.8.84+ios16-hls-loopback-stability` |
| CI 构建提交 | `770b45210300fc6d0c9b1aa70b40b52088378195` |
| 运行时代码提交 | `770b45210300fc6d0c9b1aa70b40b52088378195` |
| 构建提交说明 | `fix: relay LAN HLS through authenticated loopback` |
| 发布分支 | `codex/ios16-media-bridge` |
| 发布 remote | `newrepo`（`djw415024-ctrl/iphone-vcam-ios16-private`） |
| macOS CI run | `31863022706`（成功） |
| DEB 架构 | `iphoneos-arm64`，包内客户端包含 `arm64`/`arm64e` |
| DEB 大小 | `1,119,944` 字节 |
| DEB SHA-256 | `E085255B8C1A89EBBC1BF52B2BE6D6D9F1AA5C90ED47F484CC5443D8B5F139C2` |
| 支持系统 | iOS `>= 16.0` 且 `< 16.6` |
| 越狱布局 | rootless |

本机已校验的 CI 产物：

```text
D:\work\IOSVCAN-DS\vcam\dist\ci-770b452-run31863022706\com.codex.vcam_0.8.84+ios16-hls-loopback-stability_iphoneos-arm64.deb
```

运行时可在 `/var/mobile/Media/VCAM/broker-probe.log` 中核对：

```text
tag=com.codex.vcam/0.8.84+ios16-hls-loopback-stability
```

## 2. 本版本的主要技术变化

本版本在上一轮完整审查基础上收敛 RTSP/HLS 传输：

- 新增数字 IP 的普通 HTTP 局域网 HLS 认证回环代理：SpringBoard 通过身份校验的 XPC 在 `vcamd` 登记随机会话，`AVPlayer` 只访问 tokenized `127.0.0.1`，`vcamd` 仅转发绑定上游的清单/分片字节；对无扩展名或 chunked 响应做 `#EXTM3U` 签名探测；会话建立失败按指数退避重试，快速切源用单调 generation 淘汰旧任务；

- 继续保留真实物理相机图作为 WebKit 分辨率、帧率、像素格式、时间戳和附件的协商外壳，只替换像素；
- WebKit 终端仍按已验证的 iOS 16 存储基准做一次方向补偿和 full-bleed 中心裁剪，不拉伸、不添加 VCAM 黑边；
- 静态拍照不再由 VCAM 强写系统方向 metadata；Camera、WebKit、拍照和录像保持各自路由语义；
- mmap 与 IOSurface 交接加入 producer generation、跨进程发布锁、PID start-token 和旧帧拒绝；
- RTSP 固定为 FFmpeg 软件解码，删除正式 RTSP 的 VideoToolbox/hwaccel 与失败 IOSurface 分支；
- P010/10-bit packing、BT.2020 颜色边界、源尺寸软件回退和整条管线内存预算已加固；
- HLS 保持 Apple 原生 `AVPlayerItemVideoOutput`，NV12 解码帧由 Metal/Core Image 一次渲染到 SpringBoard 可创建的三槽 BGRA IOSurface；
- 删除 mediaserverd 在动态源停滞 2.5 秒后仍永久复用最后一帧的错误分支，真实停滞现在转黑并等待新帧恢复；
- 本地非循环视频正常结束后保留最后一帧，不再被通用停滞逻辑重新循环；
- 导入、下载、配置 Broker、日志大小、安装/卸载脚本和 fresh-install 真实相机回退均完成安全与并发审查。

共享传输基线按生产进程能力分流；RTSP 是明确记录的固定传输例外：

- 静态图片：源尺寸、一槽 BGRA IOSurface；
- 本地视频/HLS：源尺寸、三槽 BGRA IOSurface；
- OBS：源尺寸、三槽 BGRA IOSurface；
- RTSP：FFmpeg 软件解码后一次渲染到固定 1080×1920、三槽 BGRA mmap；
- 固定 mmap 是 RTSP 的正式传输，也是其他 surface 来源的握手兼容与显式旧路径回滚。

## 3. 构建和发布证据

以下证据已经具备：

- 候选 DEB 由提交 `2e1d23e` 构建；最后一次运行时代码变化为 `37def39`，其后的差异仅为审查后的测试注释和文档；
- `control` 与 `VCAMBuildTag()` 均为 `0.8.84+ios16-hls-loopback-stability`；
- 181 项主机回归测试通过，WSL arm64/arm64e 双架构编译通过；
- macOS CI run `31825692857` 成功产生 CI 候选 DEB；
- 本地从该 DEB 独立提取两个客户端，均为 `arm64`/`arm64e`；两个 arm64e 薄片均含非空 `__objc_stubs` 和 `__objc_intobj`；
- 本机保存的 DEB SHA-256 已重新计算并与安装文档一致；
- Debian `postinst`、`prerm`、`postrm` 在 Git 索引和该 CI 候选包中均为可执行文件。

该精确 CI 包已部署到 `192.168.2.101`，`dpkg-query` 返回 `0.8.84+ios16-hls-loopback-stability`。`192.168.2.201` 本轮未部署。

## 4. 当前真机证据

> `0.8.84` 已部署到 `192.168.2.201`：`dpkg-query` 返回 `0.8.84+ios16-hls-loopback-stability`，安装脚本执行完成，`vcamd`/`vcaminjectd`/`mediaserverd`/`SpringBoard` 进程均存在；但可见画面、方向、HLS/RTSP 连续性与小白点仍待真机可见验收。`192.168.2.101` 本轮因 SSH 握手失败未部署。以下为上一候选 `0.8.83` 在 `192.168.2.101` 上已取得的证据，不能外推为 `0.8.84` 已经通过。

精确 `0.8.83` 包在主要测试机 `192.168.2.101` 上已经证明：

- 设备只保留一个 launchd `vcamd` 实例；
- RTSP 连接 `rtsp://192.168.2.181:8554/live`，日志明确为 FFmpeg software decoder；
- 固定 mmap sequence 在 5 秒内从 `353119` 推进到 `353265`，即 146 帧、约 29.2 FPS；
- 最新一次启动不再进入 RTSP IOSurface 创建路径。

2026-08-15 的服务端隔离读测还表明：`.181` HLS 在 25 次约 23 秒采样中无 HTTP 错误，live edge 最大停顿 0.94 秒、PDT 最大偏差 0.001 秒、最大 live-edge lag 1.08 秒；当时服务端 HLS 连续。RTSP 同期 12.2 秒收到 178 个解码帧，约 14.58 FPS，明显低于服务器声明的 60 FPS。前者不能替代 2.101 的 HLS 客户端验收，后者会造成卡顿感，但不等同网络连接已经断开。

此前版本还曾观察到：

- Safari `getUserMedia` 实际目标为 640×480、420f；
- 虚拟人物画面连续、正向；
- 当前 WebKit full-bleed 策略没有 VCAM 添加的黑边；
- 浏览器控制面板可读取静态图预览；
- 静态图片状态显示“已加载静态图片”，不再显示波动 FPS。

RTSP 的序号证据只证明生产端连续发布；采样时 Camera 未打开，不能把它外推为 `mediaserverd` 已消费或用户可见画面已长期通过。Safari 方向证据仍来自此前版本，不能外推为当前包、Chrome、Edge、Firefox 或所有分辨率档位已经通过。

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

RTSP 硬件解码已明确退出交付范围。当前 RTSP 验收必须在 iOS 16.0–16.5 真机上同时证明：

1. RTSP/RTP/H.264 解复用持续正常；
2. 软件解码连续返回非空帧；
3. mmap 序号持续推进；
4. Camera/Safari 中可见画面连续且方向正确；
5. 长时间运行无明显丢帧、延迟累积或热降频。

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

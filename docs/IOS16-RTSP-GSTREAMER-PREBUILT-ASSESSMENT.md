# iOS 16 RTSP 预编译硬件解码替代方案评估

> 历史实验归档：GStreamer/VideoToolbox 探针未在目标真机连续产出非空帧，
> 当前正式 RTSP 路径不再包含硬件解码或 GStreamer 候选分支。

## 真机结论（2026-08-10）

官方 1.28.6 预编译 xcframework 已在 iOS 16.1 真机 `192.168.2.101` 做完隔离探针，**不进入正式 RTSP 后端**：

- 下载归档 SHA-256 为 `48437f2a8f17bc1de40097eec9aedc0d307a30c15d9e996bf75bc07562bd79a5`；最终探针约 17 MiB，最低系统版本为 iOS 16.0。
- `rtspsrc`、`rtph264depay`、`h264parse`、`vtdec` 与 `appsink` 均能在 iOS 16.1 注册，RTSP 管线能够进入播放状态。
- `vtdec_hw` 在 iOS 16.1 不存在。GStreamer 1.28.6 上游 `vtdec.c` 用 `__builtin_available(iOS 17.0, ...)` 保护该 factory；这不是链接遗漏，因而不能在 iOS 16 上把它当作 HW-only 验收条件。
- 改用同一上游插件的 `vtdec` 后，VideoToolbox session 创建成功，日志打印 `using hardware decoder`，但回调首帧为 `-12780`，随后持续 `BadData`，`VT buffer` 始终为 NULL。稳定 RTSP 窗口内等待 90 秒仍为 `samples=0`、`non-null-cvpixelbuffer=0`。
- 该结果与 FFmpeg 上游和手工 VT 路径一致，说明替换 RTSP/RTP depay、parser 与 AU 规范化仍不能得到真机帧。仅凭 session 创建或 GStreamer 的硬件日志不能声称硬解成功。

因此 GStreamer 从实验前的 **86/100** 降为当前业务适配 **15/100**。正式包不增加约 1.07 GiB 的开发依赖，也不继续尝试 MobileVLCKit：其自定义帧回调可能关闭硬解或增加硬件到主存复制，而且仍会落到同一 VideoToolbox 边界。RTSP 当前保留软件解码回退；硬件路径只有在 iOS 16–16.5 真机连续取得非空 `CVPixelBuffer` 后才能启用。

## 实验前评估

在 FFmpeg VideoToolbox 对当前 H.264 Main L4 RTSP 返回 `-12909` 之后，最值得做的下一项隔离实验是使用 **GStreamer 官方 1.28.6 iOS xcframework**，管线固定为：

```text
rtspsrc
→ rtph264depay
→ h264parse
→ video/x-h264,stream-format=avc,alignment=au
→ vtdec_hw
→ video/x-raw,format=NV12
→ appsink
```

它的价值不在于换一个 VideoToolbox API，而在于同时替换 RTSP/RTP、抖动与重排、H.264 depay、SPS/PPS 和 AU 规范化实现。`vtdec_hw` 又是官方明确定义的 **VideoToolbox HW-only decoder**，因此不会把软件回退误报为硬解成功。

不过，这仍应先作为 `vcamd` 的最小真机探针，不应直接重写正式后端。官方支持的是 macOS/Xcode 的 iOS 应用集成，不覆盖 WSL/Theos、越狱 root daemon 或 arm64e Objective-C section；官方下载页也没有逐插件 manifest。更重要的是，`appsink` 官方只承诺输出 `GstSample/GstBuffer`，没有承诺直接暴露 `CVPixelBufferRef`。这些缺口必须由真机探针验证。

## 排名

| 排名 | 方案 | 分数 | 判断 |
| ---: | --- | ---: | --- |
| 1 | GStreamer 1.28.6 官方 iOS xcframework + `vtdec_hw` + `appsink` | **实验前 86/100；真机后 15/100** | 成熟 RTSP/RTP/AU 管线可以运行，但 iOS 16 上游不注册 `vtdec_hw`；`vtdec` 真机 0 帧并持续返回 VT 错误，因此不进入正式后端。 |
| 2 | MobileVLCKit/libVLC 官方预编译包 | **52/100** | RTSP 与 VideoToolbox 成熟，但当前业务需要拿到解码帧。libVLC 官方警告自定义内存回调会禁用硬解或产生较慢的硬件到主存复制，不适合作为低发热 `CVPixelBuffer` 后端。 |
| 3 | 其他播放器封装 | **不推荐** | 没找到同时满足“第一方预编译 iOS 包、RTSP、明确硬解、可取原始帧”四项的一手证据；libmpv 等不进入本轮，避免自行构建第三方库。 |

分数衡量当前项目的适配性，不代表通用播放器质量。FFmpeg 上游实现继续保留为对照组，不计入“替代方案”排名。

## GStreamer 官方证据

### 发行物、系统和架构

- GStreamer 官方归档已发布 iOS/tvOS 1.28.6 xcframework，直链为 [`gstreamer-1.28.6-xcframework.tar.xz`](https://gstreamer.freedesktop.org/data/pkg/ios/1.28.6/gstreamer-1.28.6-xcframework.tar.xz)；同目录提供的 SHA-256 为 `48437f2a8f17bc1de40097eec9aedc0d307a30c15d9e996bf75bc07562bd79a5`。官方[下载页](https://gstreamer.freedesktop.org/download/#ios)仍说明 xcframework 与即将移除的 legacy framework 两种发行形式。
- [官方 iOS 安装文档](https://gstreamer.freedesktop.org/documentation/installing/for-ios-development.html) 明确最低 iOS 为 12.0，因此覆盖目标 iOS 16.0–16.5；1.28 起推荐解压 `GStreamer.xcframework` 后直接导入 Xcode。
- 官方列出的真机架构为 ARM64；模拟器为 ARM64/X86_64。文档没有声明 arm64e slice，因此不能据此证明当前项目的 arm64e Objective-C stub/section parity。
- 2026-08-10 对官方直链读取到的 HTTP `Content-Length` 为 `1,151,326,256` 字节，约 **1.07 GiB**。这是开发归档下载量，不是最终 `.deb` 增量；官方未发布裁剪后应用或 daemon 的尺寸，必须在实际静态链接并 strip 后测量。
- [官方部署说明](https://gstreamer.freedesktop.org/documentation/deploying/index.html) 明确 iOS 只能私有静态链接，并提醒发布者提供让用户用修改版 GStreamer 重新链接所需的文件。

### 管线逐段匹配

| 元素 | 官方事实 | 对当前故障的意义 |
| --- | --- | --- |
| [`rtspsrc`](https://gstreamer.freedesktop.org/documentation/rtsp/rtspsrc.html) | Good 插件的高层 RTSP client；支持 TCP/UDP，内部通过 `gstrtpbin` 处理 RTCP、jitter removal 和 packet reordering。 | 替代当前 FFmpeg RTSP/RTP 输入边界。 |
| [`rtph264depay`](https://gstreamer.freedesktop.org/documentation/rtp/rtph264depay.html) | 按 RFC 3984 提取 H.264，输出可为 `stream-format=avc,alignment=au`。 | 直接提供 VideoToolbox 所需的 AVC/AU 形态。 |
| [`h264parse`](https://gstreamer.freedesktop.org/documentation/videoparsersbad/h264parse.html) | 可在 AVC/AVC3/byte-stream 之间转换，并输出 AU 或 NAL 对齐；可按 IDR 插入 SPS/PPS。 | 替代当前最可疑的 SPS/PPS、NAL 和 AU 规范化边界。 |
| [`vtdec_hw`](https://gstreamer.freedesktop.org/documentation/applemedia/vtdec_hw.html) | 官方定义为 Apple VideoToolbox **HW-only** decoder；H.264 sink caps 要求 `avc + au`，raw 输出支持 NV12。 | 元素创建和连续出帧可排除软件 decoder 回退。 |
| [`appsink`](https://gstreamer.freedesktop.org/documentation/app/appsink.html) | 允许应用 pull `GstSample/GstBuffer`，并可限制队列和丢弃旧帧。 | 可验收连续原始帧，并避免消费端变慢造成无限排队。 |

以上 caps 在官方文档中首尾一致，所以管线设计成立。但 iOS 1.28.6 下载页没有逐项列出静态注册的 factory；不能在真机检查前声称五个元素都已包含。

## MobileVLCKit 为什么降级

[VideoLAN 的 VLCKit 页面](https://www.videolan.org/projects/vlckit/)说明 MobileVLCKit 是 libVLC 的 iOS 包装器，支持流媒体，最低 iOS 8.4，并提供 CocoaPods/Carthage 二进制集成；许可为 LGPL 2.1 或更高版本。VideoLAN 的版本记录也有 iOS VideoToolbox 解码修复，说明其硬解路径真实存在。

问题在于本项目不是把视频渲染进一个 `UIView`，而是必须把连续原始帧交给虚拟相机。libVLC 3.0 的[官方自定义视频回调文档](https://videolan.videolan.me/vlc-3.0/group__libvlc__media__player.html)明确警告：输出到自定义内存缓冲区明显更低效，硬件解码可能被完全禁用，或需要从硬件/DSP 内存较慢地复制到主内存，还会增加 CPU 转换和内存复制。其回调输出也不是 `CVPixelBufferRef` 合同。

因此 MobileVLCKit 适合“能播放 RTSP”的应用，不是当前“硬解后低复制地取得 NV12/CVPixelBuffer”的最高分方案。除非 GStreamer 官方探针无法创建所需 factory，才值得把它作为第二层可播放性对照，而不是正式帧后端。

## 无自建依赖的精确集成路径

本轮只允许官方预编译产物，不运行 Cerbero，也不自行编译 GStreamer 或 VLC：

1. 从[官方下载页](https://gstreamer.freedesktop.org/download/#ios)取得 1.28.6 `gstreamer-1.28.6-xcframework.tar.xz`，校验官方同目录提供的校验信息（若目录发布）。
2. 解压得到 `GStreamer.xcframework`；官方支持的路径是将它导入 macOS/Xcode 工程。
3. 当前仓库若要从 Theos/WSL 链接该预编译静态库，先做单独链接探针；这一步属于项目适配，不得宣称是官方支持路径，也不得为此重编第三方库。
4. 初始化后逐项调用 `gst_element_factory_find()` 检查 `rtspsrc`、`rtph264depay`、`h264parse`、`vtdec_hw`、`appsink`。任一缺失即停止，不以软件元素替代。
5. 仅在五项 factory 都存在时建立上述固定管线；decoder factory 必须实际为 `vtdec_hw`。

## 真机准入门槛

在 iOS 16.0–16.5 真机上同时满足以下条件，GStreamer 才能升级为正式 RTSP 后端候选：

1. 五个 factory 全部存在，`vtdec_hw` 进入 `PLAYING`，无自动软件 decoder。
2. 对同一条确定性 RTSP 流连续 pull 至少 30 个非空 `GstSample`，每帧为 NV12，宽高和时间戳连续；30 是连续性门槛，不要求源端必须 30 fps。
3. 记录 RTSP TCP/UDP 模式、实际源帧率、输出帧率、丢帧、重连与前后台恢复。
4. 检查 `GstBuffer` 的实际 Apple memory backing。若不能无复制取得 `CVPixelBufferRef`，明确记录为“VideoToolbox 硬解 + NV12 bridge”，不能伪称 appsink 原生返回 CVPixelBuffer。
5. 最终必须连续得到非空、尺寸和像素格式正确的项目侧 `CVPixelBufferRef`，并由用户在 Camera 真机画面确认；只有元素创建或单帧输出不算通过。
6. 链接后测量 `vcamd`、`.deb` 和运行时 RSS 增量，并完成 LGPL 静态链接合规审查。

如果 GStreamer 同一条流仍由 VideoToolbox 报 `-12909`，说明问题不只在 FFmpeg AU 组装；应保留证据并停止继续引入播放器框架。若 GStreamer 连续输出而 FFmpeg 失败，则差异范围已经收敛到 RTSP/RTP depay、H.264 parser/AU 规范化或 FFmpeg VideoToolbox bridge，可再决定替换正式后端还是只移植边界修复。

## 一手来源

- [GStreamer iOS/tvOS 安装与支持范围](https://gstreamer.freedesktop.org/documentation/installing/for-ios-development.html)
- [GStreamer 官方 iOS 下载](https://gstreamer.freedesktop.org/download/#ios)
- [GStreamer iOS 静态部署与重链接义务](https://gstreamer.freedesktop.org/documentation/deploying/index.html)
- [GStreamer 许可 FAQ](https://gstreamer.freedesktop.org/documentation/frequently-asked-questions/general.html)
- [`rtspsrc`](https://gstreamer.freedesktop.org/documentation/rtsp/rtspsrc.html)
- [`rtph264depay`](https://gstreamer.freedesktop.org/documentation/rtp/rtph264depay.html)
- [`h264parse`](https://gstreamer.freedesktop.org/documentation/videoparsersbad/h264parse.html)
- [`vtdec_hw`](https://gstreamer.freedesktop.org/documentation/applemedia/vtdec_hw.html)
- [`appsink`](https://gstreamer.freedesktop.org/documentation/app/appsink.html)
- [VideoLAN VLCKit](https://www.videolan.org/projects/vlckit/)
- [libVLC 3.0 自定义视频回调限制](https://videolan.videolan.me/vlc-3.0/group__libvlc__media__player.html)

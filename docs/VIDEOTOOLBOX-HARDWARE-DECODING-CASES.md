# iOS 16 VideoToolbox 硬件解码实现案例与 vcamd 实验建议

> 历史实验记录：本文保留失败证据和外部方案对照，不代表当前生产代码。
> 从 `0.8.82+ios16-stream-stability` 起，RTSP 使用 FFmpeg 纯软件解码，
> 已删除 direct-VT、FFmpeg VideoToolbox hwaccel 与 SpringBoard RTSP 分支。

调查日期：2026-08-09
部署范围：iOS 16.0–16.5，arm64/arm64e 设备
调查范围：Apple 公共 SDK/官方文档、FFmpeg/WebRTC/VLC/ijkplayer/GStreamer 项目官方源码。没有使用博客或论坛结论。

## 结论先行

1. 当前最值得直接借鉴的是 ijkplayer 的 iOS VideoToolbox 路径和 WebRTC 的 H.264 解码器，而不是继续增加私有 entitlement。两者都在普通客户端代码里使用公开 `VTDecompressionSession` API，先规范化 SPS/PPS 和 NAL，再创建 session；设备异常时重建 session 并等待新的干净关键帧。
2. iOS 16.5 公共 SDK 明确定义 `kVTVideoDecoderBadDataErr = -12909`，它表示提交给解码器的数据无效。公开 SDK 中的 `kVTVideoDecoderReferenceMissingErr` 是 `-17694`，不是 `-12780`。
3. 在 iPhoneOS 16.5 SDK 的 VideoToolbox、CoreMedia、CoreVideo 和系统头文件中没有找到 `-12780` 的公开符号映射。因此本文只把它记录为“公开 SDK 未映射的 OSStatus”，不猜成 reference-missing、entitlement 或硬件不可用。
4. Apple 明确允许 `decoderSpecification == NULL`（由 VideoToolbox 选择解码器）和 `destinationImageBufferAttributes == NULL`（调用者不附加输出要求）。不过 FFmpeg、WebRTC、ijkplayer 和 GStreamer 的成熟实现通常都会提供像素格式/表面兼容属性，所以 NULL output attrs 适合做单变量诊断，不应自动视为最终配置。
5. 当前仓库创建 session 时已传 `decoderSpecification = NULL`，输出要求为 NV12 VideoRange + 空 IOSurface 字典。NULL output attrs、只加 OpenGLES、严格复刻 ijkplayer 三轮真机实验均无改善；不再继续叠加输出属性。HLS `extradata=0` 启动已修复并真机进入 direct VT，但 TS/fMP4、in-band/avcC、AUD 有无四组输入仍得到同一 `-12780`，因此这些输入差异均不是当前硬解失败的充分原因。
6. AVPlayer + `AVPlayerItemVideoOutput` 是 HLS 的系统解码旁路/诊断候选，但不支持 RTSP；AVAssetReader 适合有限本地文件或完整可读资产，不是 RTSP demux/decode 的替代品。

## 证据等级

- **证据**：下述结论可在 Apple 公共 SDK/官方文档或项目官方源码中直接定位。
- **推断**：根据多个实现与当前仓库差异提出的实验假设；必须以 iOS 16–16.5 真机 callback、帧内容和前后台切换结果验证。
- **未建立**：没有找到满足“一手公开源码”标准的结论，不能作为修复依据。

## 实现对照

| 实现 | 输入与参数集 | 输出属性 | 硬件选择/回退 | 线程与恢复 | 对 vcamd 的价值 |
|---|---|---|---|---|---|
| Apple `VTDecompressionSession` | `CMVideoFormatDescription` + `CMSampleBuffer`；H.264 可由原始 SPS/PPS 创建格式描述 | 可以为 NULL，也可以给 `kCVPixelBuffer*` 要求 | iOS 公共 API 可查询 codec 是否支持硬解，但“支持”不保证当时资源可用 | flags=0 时 decode 调用在 callback 完成后返回；异步模式需 drain/wait 后销毁 | 直接采用；这是当前路径的契约基线 |
| FFmpeg 7.1 `videotoolbox.c` | codec extradata 中的 avcC/hvcC 放入 sample-description extensions；解码包以 length-prefixed NAL 提交 | 像素格式、宽高、IOSurface；iOS 还请求 OpenGLES 兼容 | H.264 使用 RequireHardware，HEVC/ProRes 使用 EnableHardware；这些 key 在缺少声明时由源码用 CFSTR 兼容定义 | callback 持有 CVPixelBuffer；错误时重建/重新配置 | 可复用其格式打包、属性组合和重建逻辑；无需替换整个现有 pipeline |
| WebRTC iOS H.264 | 从 Annex B 提取 SPS/PPS，生成格式描述，再把 access unit 转成 CMSampleBuffer | NV12 FullRange + IOSurface + OpenGLES | `decoderSpecification = NULL` | 异步 decode；invalid-session/malfunction 时 reset 并重试；销毁前等待异步帧 | 直接参考 SPS/PPS 等待、Annex B 转换、session reset |
| ijkplayer iOS VideoToolbox | FFmpeg `AVPacket`；从 extradata/avcC/hvcC 建 format；Annex B 转 length-prefix，3-byte 长度归一为 4-byte | NV12 VideoRange + width + height + OpenGLES；该路径没有要求 IOSurface | `decoderSpecification = NULL` | 处理新 extradata/分辨率变化；invalid-session/malfunction 后刷新；从 IDR/I 帧恢复并缓存/丢弃污染包 | 与当前 RTSP/HLS + FFmpeg demux 架构最接近，优先复用 |
| VLC VideoToolbox | 由 VLC demux/packetizer 提供规范输入 | 模块内部协商 | VideoToolbox 硬解模块；reference-missing 被视为可恢复 | `-17694` 不直接判为永久失败，会重启/继续 session 恢复 | 参考错误分类和重建策略，不值得整体引入 VLC |
| GStreamer `vtdec`/`vtdec_hw` | H.264 要求 `stream-format=avc, alignment=au`；H.265 要求 `hvc1/hev1, alignment=au` | 可输出 NV12/IOSurface 等；硬件表面与下游协商 | `vtdec` 可软/硬，`vtdec_hw` 明确 HW-only | 独立输出任务、重排队列、drain/flush/session reset | 佐证 AU 对齐、格式协商和 drain；引入整个框架不符合当前最小改动目标 |
| AVAssetReaderTrackOutput | `outputSettings=nil` 保留压缩样本；非 nil 时输出解压样本 | Apple 建议 H.264 原生输出优先 NV12 VideoRange/FullRange | 公共 API 没有“强制硬件并验证正在使用”的契约 | pull `copyNextSampleBuffer`；适合有限资产读取 | 适合本地文件/完整缓存段诊断，不适合 RTSP |
| AVPlayer + AVPlayerItemVideoOutput | AVPlayer 官方支持本地/远程媒体及 HLS | 通过 `outputSettings` 请求 CVPixelBuffer；按 item time 拉取 | 系统自行选择解码路径，公共 API 不承诺硬件强制 | 播放时钟 + pull output；可 suppress player rendering | 可做 HLS-only 系统旁路，不是 RTSP/HLS 共用解法 |

## Apple 公共 API 能证明什么

### Session 创建和输出

**证据：** Apple 的 `VTDecompressionSessionCreate` 契约允许：

- `decoderSpecification` 为 NULL，让 VideoToolbox 选择合适解码器；
- `destinationImageBufferAttributes` 为 NULL，表示调用者不附加输出 pixel buffer 要求；
- callback 返回 `CVImageBufferRef`，客户端必须在需要跨 callback 使用时 retain；
- session 生命周期为 create → decode → drain/wait（如使用异步）→ invalidate → release。

来源：[VTDecompressionSessionCreate](https://developer.apple.com/documentation/videotoolbox/vtdecompressionsessioncreate%28allocator%3Aformatdescription%3Adecoderspecification%3Aimagebufferattributes%3Aoutputcallback%3Adecompressionsessionout%3A%29)、[VTDecompressionSession API collection](https://developer.apple.com/documentation/videotoolbox/vtdecompressionsession-api-collection)、iPhoneOS 16.5 SDK `VideoToolbox.framework/Headers/VTDecompressionSession.h`。

**证据：** `VTDecodeFrameFlags == 0` 是同步提交：callback 在调用返回前完成；`kVTDecodeFrame_EnableAsynchronousDecompression` 和 temporal processing 会允许延迟回调。异步模式在失效 session 前需要 `VTDecompressionSessionWaitForAsynchronousFrames`。

**对当前实现的含义：** 当前 flags=0 路径不需要额外建立 callback 工作线程才能收到首帧。若首 IDR 的 API 返回值/回调状态立即失败，应优先检查 format/sample/attrs，而不是先归因于 callback 队列。

### SPS/PPS、avcC 与 access unit

**证据：** `CMVideoFormatDescriptionCreateFromH264ParameterSets` 接收不带 start code 的原始 SPS/PPS NAL，至少需要 SPS 和 PPS；NAL length header 只能是 1、2 或 4 字节。HEVC 对应 API 需要 VPS/SPS/PPS。来源：iPhoneOS 16.5 SDK `CoreMedia.framework/Headers/CMFormatDescription.h`。

**证据：** 成熟实现都把输入收敛到同一契约：

- WebRTC 从 Annex B 中找到 SPS/PPS，缺少时请求关键帧/返回错误，然后将 AU 转成 CMSampleBuffer；
- FFmpeg 将 avcC/hvcC 写入 `kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms`，包体按 length-prefix 提交；
- ijkplayer 使用 FFmpeg parser 把 Annex B 转为 length-prefix，并特别处理 3-byte NAL length 到 4-byte 的归一化；
- GStreamer 的 VideoToolbox sink caps 要求 H.264 `avc` + AU alignment，H.265 `hvc1/hev1` + AU alignment。

**推断：** `-12909` 紧随首帧失败出现时，最优先验证的是“每个 sample 是否为完整 AU、长度字段是否与 format description 的 NAL header length 一致、格式变化后是否仍沿用旧 SPS/PPS”，而不是把所有后续错误都视为独立硬件故障。

### 硬件属性在 iOS 公共 SDK 的边界

**证据：** `VTIsHardwareDecodeSupported(codecType)` 在 iOS 可用，但 Apple 头文件注明：返回 true 也不保证硬件资源在任何时刻都可用。它只适合记录设备能力，不是某个 session 正在使用硬解的证明。

**证据：** iPhoneOS 16.5 SDK 的 `VTDecompressionProperties.h` 将以下声明放在 `#if !TARGET_OS_IPHONE` 之内：

- `kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder`
- `kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder`
- `kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder`

FFmpeg 为缺失声明自行定义相同 CFSTR key 并使用它们。这证明 FFmpeg 的实现策略，不等于 Apple 对 iOS 公共 API 的硬件强制保证。

**推断：** 在 iOS 16–16.5 上，真机是否得到可用的硬件输出仍须以 callback 获得非 NULL `CVPixelBuffer`、真实图像和稳定持续帧证明。仅 session create 成功、能力查询为 true 或私有字符串 key 被接受都不够。

### 错误码校正

**证据（iPhoneOS 16.5 SDK `VideoToolbox.framework/Headers/VTErrors.h`）：**

| OSStatus | 公共符号 | 含义 |
|---:|---|---|
| -12909 | `kVTVideoDecoderBadDataErr` | 提交给 video decoder 的数据无效 |
| -12911 | `kVTVideoDecoderMalfunctionErr` | video decoder malfunction |
| -12210 | `kVTVideoDecoderAuthorizationErr` | decoder authorization error |
| -17694 | `kVTVideoDecoderReferenceMissingErr` | 缺少参考帧，可作为清洁关键帧恢复信号 |
| -12780 | 无公开映射 | 在本机 iPhoneOS 16.5 公共 SDK 头文件中未找到，不能命名 |

**推断：** “首 IDR `-12780`，随后 `-12909`”更像一个首个失败使 decoder 状态/参考链被污染，随后样本继续被拒绝的序列，但这不是 `-12780` 的公开定义。必须同时记录 API 返回 status、callback status、infoFlags、imageBuffer 是否为空、sample 大小/关键帧/参数集摘要，才能区分 session、sample 和 callback 层。

## 可直接复用的一手实现

### FFmpeg 7.1

当前项目构建 FFmpeg 7.1.1；最接近版本的官方 7.1 源码显示：

- `videotoolbox.c` 把 avcC/hvcC 放入 CoreMedia format extensions；
- output attrs 包含 pixel format、width、height、空 IOSurface 字典；在 iOS 上还设置 OpenGLES compatibility；
- H.264 decoder spec 使用 RequireHardware，HEVC/ProRes 使用 EnableHardware；
- packet 以 length-prefixed 数据包装成 CMBlockBuffer/CMSampleBuffer；
- callback retain pixel buffer；无图像或不可恢复错误会触发 reconfiguration。

来源：[FFmpeg 7.1 videotoolbox.c](https://ffmpeg.org/doxygen/7.1/videotoolbox_8c_source.html)、[FFmpeg 7.1 hwcontext_videotoolbox.c](https://ffmpeg.org/doxygen/7.1/hwcontext__videotoolbox_8c_source.html)、[FFmpeg current videotoolbox.c](https://ffmpeg.org/doxygen/trunk/videotoolbox_8c_source.html)。

**直接可复用：** output attrs 的逐项 A/B、avcC/hvcC 与 sample length-prefix 一致性检查、callback 中 retain/reconfigure。

**不建议直接复用：** 只创建 `AVHWDeviceContext` 并不会自动解决当前自定义 sample 打包；真正创建解码 session 的逻辑仍在 libavcodec VideoToolbox decoder。把现有 direct-VT 全量替换成 FFmpeg hwaccel 是较大改造，应在最小属性/样本实验后再决定。

### WebRTC iOS H.264

官方源码路径 `sdk/objc/components/video_codec/RTCVideoDecoderH264.mm` 展示了完整 iOS 客户端路径：

- Annex B 提取 SPS/PPS；缺少参数集时不盲目送帧；
- 生成 CMVideoFormatDescription 和 CMSampleBuffer；
- `decoderSpecification = NULL`；
- iOS output attrs 为 NV12 FullRange + IOSurface + OpenGLES；
- RealTime=true，异步 decode；
- invalid-session/malfunction 时 reset 并重试，销毁前等待异步输出。

来源：[WebRTC RTCVideoDecoderH264.mm](https://webrtc.googlesource.com/src/+/20967ac1956e9d4ba4552af3ee7727e920aabc78/sdk/objc/components/video_codec/RTCVideoDecoderH264.mm)。

**直接可复用：** 参数集就绪门槛、Annex B 到 CMSampleBuffer 的单一转换点、reset/retry 生命周期。

### ijkplayer iOS VideoToolbox

ijkplayer 官方 iOS 源码与 vcamd 的“FFmpeg demux + 自定义 VT decode”最相似：

- 输入直接来自 FFmpeg `AVPacket`；
- 从 codec parameters/extradata 创建 H.264/HEVC format；
- Annex B 通过 FFmpeg NAL parser 转换；
- output attrs 为 NV12 VideoRange + width + height + OpenGLES；
- format/extradata/分辨率变化会刷新 session；
- invalid-session/malfunction 后重建，并缓存/丢弃直到从 IDR/I 帧恢复。

来源：[IJKVideoToolBoxSync.m](https://github.com/bilibili/ijkplayer/blob/master/ios/IJKMediaPlayer/IJKMediaPlayer/ijkmedia/ijkplayer/ios/pipeline/IJKVideoToolBoxSync.m)、[ffpipenode_ios_videotoolbox_vdec.m](https://github.com/bilibili/ijkplayer/blob/master/ios/IJKMediaPlayer/IJKMediaPlayer/ijkmedia/ijkplayer/ios/pipeline/ffpipenode_ios_videotoolbox_vdec.m)。

**直接可复用：** 属性组合、extradata 变化检测、只从 clean keyframe 恢复、错误后的 packet 策略。它是当前首选对照实现。

### VLC 与 GStreamer

VLC 官方变更明确把 `kVTVideoDecoderReferenceMissingErr = -17694` 作为可恢复情况处理，而不是立即永久退出硬解。来源：[VLC VideoToolbox decoder](https://github.com/videolan/vlc/blob/master/modules/codec/videotoolbox/decoder.c)、[VLC reference-missing 修复](https://code.videolan.org/videolan/vlc/-/commit/f7434e60fc38e78b9356600d1452e850eb5ec2d9)。

GStreamer 官方 `vtdec.c` 同时实现可软/硬选择的 `vtdec` 和 HW-only `vtdec_hw`，明确要求 H.264 AVC AU/H.265 hvc1/hev1 AU 输入，并用输出任务、重排队列、drain/flush 管理异步帧。来源：[GStreamer applemedia/vtdec.c](https://github.com/GStreamer/gstreamer/blob/main/subprojects/gst-plugins-bad/sys/applemedia/vtdec.c)、[vtdec_hw 官方文档](https://gstreamer.freedesktop.org/documentation/applemedia/vtdec_hw.html)。

**直接可复用：** 错误分类、AU contract、重排/drain 思路。
**不适用：** 将 VLC/GStreamer 整体加入 vcamd 会引入新的 demux、线程、对象生命周期和体积问题，没有证据表明它能单独消除当前错误。

## AVFoundation 系统路径

### AVAssetReader

**证据：** `AVAssetReaderTrackOutput.outputSettings == nil` 返回原始压缩样本且不解码；非 nil 时输出解压后的 presentation-order 样本。Apple 对 H.264 的原生高效像素格式建议是 NV12 VideoRange，已知 full-range 时可用 NV12 FullRange。`alwaysCopiesSampleData = false` 可避免不必要的数据复制。

来源：[AVAssetReaderTrackOutput](https://developer.apple.com/documentation/avfoundation/avassetreadertrackoutput)、[outputSettings](https://developer.apple.com/documentation/avfoundation/avassetreadertrackoutput/outputsettings)、[AVAssetReaderOutput](https://developer.apple.com/documentation/avfoundation/avassetreaderoutput)。

**适用：** 本地文件、已完整缓存且 AVFoundation 可识别的有限资产，或作为 direct-VT 的独立诊断。
**不适用：** RTSP transport/demux；无限 live stream；需要明确控制 SPS/PPS/IDR 恢复的统一 RTSP/HLS pipeline。

### AVPlayer + AVPlayerItemVideoOutput

**证据：** AVPlayer 官方支持远程媒体和 HLS；`AVPlayerItemVideoOutput` 可以按 item time 拷贝解码后的 CVPixelBuffer；`suppressesPlayerRendering` 可以阻止播放器自己的渲染。

来源：[AVPlayer](https://developer.apple.com/documentation/avfoundation/avplayer/)、[AVPlayerItemVideoOutput](https://developer.apple.com/documentation/avfoundation/avplayeritemvideooutput)、[output settings initializer](https://developer.apple.com/documentation/avfoundation/avplayeritemvideooutput/init%28outputsettings%3A%29)、[suppressesPlayerRendering](https://developer.apple.com/documentation/avfoundation/avplayeritemoutput/suppressesplayerrendering)、[Apple HLS](https://developer.apple.com/documentation/http-live-streaming)。

**推断：** 这是最小的 HLS 系统解码旁路：用 AVPlayer 处理 manifest/segments/时钟，再从 VideoOutput 拉 NV12。它可以回答“HLS 内容是否能由系统媒体栈稳定解出”，但公共 API 不提供强制/确认某次播放使用硬件解码的承诺。

**不适用：** RTSP；需要一条同时服务 RTSP/HLS 的低层 packet pipeline；不希望引入 AVPlayer 播放时钟和 item 生命周期的场景。

## entitlement 与进程边界

**未建立：** 本次没有找到公开的一手越狱 daemon/XPC 源码，能证明 iOS 16 VideoToolbox 硬解必须具有某个私有 entitlement，或必须运行在 mediaserverd/某个 Apple XPC 服务内。公开 Apple API 也没有这样的参数契约。

**证据：** WebRTC 和 ijkplayer 的 iOS 官方源码直接从普通客户端创建 VT session，没有 entitlement 配置逻辑。Apple iOS 公共 SDK隐藏了 desktop 上公开声明的 hardware require/using keys，但这也不能反向证明某个私有 entitlement 是必需或不必需。

**推断：** 保持“vcamd 解码并把可读帧交给注入端”的进程边界是合理的最小架构。VideoToolbox 内部可能跨进程使用系统服务，但客户端不应复制私有 XPC 协议。除非真机出现明确 `kVTVideoDecoderAuthorizationErr (-12210)` 或 Apple 一手材料指向授权问题，否则不再叠加 entitlement。

## 当前实现与参考实现的关键差异

以 2026-08-09 仓库 `Sources/Daemon/VCAMHardwareVideoDecoder.m` 为准：

| 项目 | 当前实现 | 成功案例 |
|---|---|---|
| decoder spec | NULL | WebRTC/ijkplayer 也是 NULL；FFmpeg 使用硬件字符串 key |
| pixel format | NV12 VideoRange | ijkplayer/FFmpeg/GStreamer 常见一致；WebRTC 用 FullRange |
| IOSurface | 空字典 | WebRTC/FFmpeg 有；ijkplayer 的该路径没有 |
| OpenGLES compatible | 未设置 | WebRTC、ijkplayer、FFmpeg iOS 都设置 true |
| width/height attrs | 未设置 | ijkplayer、FFmpeg 设置 |
| SPS/PPS/length-prefix | 已有规范化代码 | 仍需用首个失败 sample 的可观测日志证明逐字节 contract 一致 |
| 错误恢复 | reference-missing 有特殊处理 | ijkplayer/WebRTC/VLC 还覆盖 invalid-session/malfunction、格式变化和 clean-key 重建 |

这里的差异不是“已证明根因”，只用于设计一次只变一个变量的实验。

## 对 `-12780` / `-12909` 的最小下一实验

### E0：NULL output attrs A/B（已完成，无改善）

Apple 明确允许 `destinationImageBufferAttributes = NULL`，所以它是合法的单变量隔离实验。实验保持 decoder spec、格式打包、输入流和帧序列不变。iOS 16.1 真机结果为：首个 IDR callback 返回公开 SDK 未映射的 `-12780` 且 image buffer 为 NULL，随后返回 `-12909`，硬件帧为 0；软件回退画面正常。设备随后恢复到 CI 0.8.47 基线。因此 NULL output attrs 已排除，不进入发布版本。

### E1：只增加 OpenGLES compatibility（已完成，无改善）

恢复当前基线 NV12 VideoRange + IOSurface，只加：

```objc
(id)kCVPixelBufferOpenGLESCompatibilityKey: @YES
```

理由：这是 WebRTC、ijkplayer 和 FFmpeg iOS 三条独立成熟路径的共同属性，也是当前实现缺失的最小交集。不要同时改颜色范围、宽高、IOSurface、decode flags 或 entitlement，否则结果不可归因。

iOS 16.1 真机结果：direct VT 在首个真实 IDR 后连续 callback `-12780`、image buffer 为 NULL；FFmpeg VideoToolbox 首帧同样为 `-12780`，随后为 `-12909`；硬件帧为 0。软件解码随后立即产出 1280×720 帧。实验版已撤回，设备恢复到 CI 0.8.47 基线。因此只增加 OpenGLES compatibility 已排除，不进入发布版本。

### E1b：严格复刻 ijkplayer 输出属性（已完成，无改善）

实验使用 NV12 VideoRange + width + height + OpenGLES，不要求 IOSurface。输入改为仓库自带的确定性 FFmpeg + MediaMTX 源：H.264 Constrained Baseline、1280×720、30 fps、无 B 帧、固定 30 帧 GOP、重复 SPS/PPS。RTSP 与 HLS 均经桌面端持续软件解码验证，iPhone 也可连通两个端口，因此不再使用旧推流工具的 404、断流或损坏码流作为判据。

iOS 16.1 真机同源 A/B 结果：0.8.47 基线连续三轮均在首个 IDR callback 返回 `-12780`，FFmpeg VideoToolbox 随后返回 `-12909`，而软件路径稳定输出 1280×720；E1b 仍得到完全相同结果。实验版已撤回，并通过 SHA256 确认恢复到 0.8.47。因此输出属性组合已排除，不进入发布版本，后续停止继续叠加 PixelBuffer 属性，进入 E2 输入 contract 检查。

### E2a：固定单 slice（已完成，无改善）

初始确定性源因 x264 `zerolatency` 产生 11 个 IDR slice；为排除多 slice access unit，源已固定为 `threads=1:sliced-threads=0:slices=1`。抓包确认每个关键访问单元只有一个 IDR slice，0.8.47 真机仍得到 direct VT `-12780`、FFmpeg VideoToolbox `-12909`、硬件帧 0，软件路径稳定输出 1280×720。因此 slice 数量不是当前失败的充分原因。

### E2b：HLS in-band 参数集启动（已完成，路径修复有效但硬解无改善）

确定性 HLS 的 MPEG-TS demux 日志显示 `stream->codecpar->extradata_size == 0`。旧代码在读取首包前创建 direct-VT decoder，因此 HLS 从未进入 direct-VT 解码，只能落到 FFmpeg hwaccel。最小修复是：有 extradata 时保持原路径；没有时等待首个关键包，把该 Annex B access unit 临时作为参数集来源创建 format/session，再提交同一个关键包。

首次 WSL 实验二进制在打开 HLS 时立即返回 `Invalid data found`。根因不是播放列表：`build-ffmpeg-ios-linux.sh` 的缓存库只启用了 file/tcp/udp 和 mov/rtsp，未编入 HTTP/HTTPS、HLS、MPEG-TS；原测试只检查 macOS 脚本。现已给两个构建脚本建立共同回归检查，WSL 使用 `llvm-ar/llvm-ranlib` 解决旧包装器找不到 ranlib 的问题，并从最终静态库确认 `ff_hls_demuxer`、`ff_http_protocol`、`ff_https_protocol`、`ff_mpegts_demuxer` 均存在。

修正后的 iOS 16.1 真机结果：手机持续请求真实 `.ts` 分片，direct VT 等待首关键包后成功提取 SPS=23 字节、PPS=4 字节，format-description status=0，session 创建成功并提交同一 IDR；callback 仍为 `-12780`、image buffer 为 NULL，FFmpeg VideoToolbox 随后为 `-12780/-12909`，软件路径稳定输出 1280×720。因此 HLS 路径缺陷已修复，但没有解决底层硬件输出失败。

### E2c：容器、参数集形式和 AUD A/B（已完成，无改善）

在同一设备、二进制和编码参数下依次验证：MPEG-TS + in-band SPS/PPS、fMP4 + avcC、fMP4 保留 AUD（首 NAL type 9）、fMP4 移除 AUD（首 NAL 变为 IDR type 5）。四种路径均在首关键帧 callback 返回 `-12780`，随后 FFmpeg VideoToolbox 返回 `-12909`，软件解码均正常。因此容器、参数集承载方式和 AUD 不是当前失败的充分原因。

### E3：移除 `hardwarevideodecoder` entitlement（已完成，无改善）

保持确定性单-slice RTSP、二进制代码、输出属性和 launchd 配置不变，只把 `vcamd` 重新签名为仅保留 `com.apple.private.memorystatus`，移除 `com.apple.videotoolbox.hardwarevideodecoder`。iOS 16.1 真机中服务正常启动并连接同一 RTSP 源；format-description status=0、sample-buffer status=0，但首 IDR 的 direct-VT callback 仍为 `-12780`、image buffer 为 NULL，FFmpeg VideoToolbox 随后仍为 `-12780/-12909`，硬件帧为 0，软件回退继续稳定输出 1280×720。设备已按 SHA256 恢复到 0.8.47 基线。因此现有 `hardwarevideodecoder` entitlement 不是当前失败的充分原因，移除它也不进入发布版本。

本轮同时确认 launchd 实际把 `vcamd` 作为 `mobile`（user/501）运行；plist 中也显式配置了 `UserName=mobile`。这使“相同二进制和码流，仅比较 mobile launchd 与 root 进程上下文”成为下一项更强的单变量实验。该实验会短暂停止正式守护进程，必须单独授权并在结束后恢复 launchd 基线。

### E4：root 进程上下文 A/B（已完成，无改善）

保持设备上的 0.8.47 二进制（SHA256 `aa60ef93…c9d0`）、entitlement、确定性单-slice RTSP 和配置完全不变，临时 bootout `mobile`（user/501）launchd 服务，再由 root 手动启动同一 `/var/jb/usr/libexec/vcamd`。root 进程成功连接流并进入相同 direct-VT 路径：format-description status=0、sample-buffer status=0，首 IDR callback 仍为 `-12780` 且 image buffer 为 NULL；FFmpeg VideoToolbox 随后为 `-12909`，硬件帧为 0；软件回退稳定输出 1280×720。实验后已终止 root 进程并恢复 `mobile` launchd，服务状态 running，二进制哈希未变。因此 root/mobile 运行身份不是当前失败的充分原因。

注意：0.8.47 在预处理阶段用 `#ifndef kVTVideoDecoderReferenceMissingErr` 把该名字错误覆盖为 `-12780`；枚举常量不是预处理宏，因此这个保护条件始终成立。它只导致旧日志把 `-12780` 错标为 reference-missing，不改变回调原始数值或“没有 image buffer”的结论。当前 0.8.50 源码已删除该宏，并由回归测试要求使用 iPhoneOS 16.5 SDK 的公开 `-17694` 常量。

### E5：前台 Safari 系统 HLS 对照（已完成，可持续出帧）

保持 iPhone、确定性 FFmpeg + MediaMTX 源和 H.264 编码参数不变，在 iOS 16.1 真机前台直接用 Safari 打开同一 HLS 地址。用户在真机画面中确认视频能够持续播放，MediaMTX 同时观察到该设备的 HLS 会话。因此可以排除“确定性源不能被 iOS 解码”以及“HLS 清单或分片整体无效”；当前失败收敛到 `vcamd` 的后台进程生命周期、VideoToolbox 会话条件或自建 sample contract。

这个对照只证明系统 HLS 路径能够产出连续画面。公共 AVPlayer/Safari 接口没有提供本次播放是否使用硬件解码器的可验证标志，所以不能把它写成“Safari 已证明硬解”。它也不能单独区分后台生命周期与自建 sample contract；下一实验应在两者之间继续保持单变量。

WebRTC 的 iOS H.264 解码器提供了与生命周期相关的一手旁证：普通 App 不处于 active 状态时，它会停止提交解码请求，并明确注释此时硬件解码器已被系统失效；broadcast extension 构建则排除这项 App-active 检查。来源：[RTCVideoDecoderH264.mm](https://webrtc.googlesource.com/src/+/9ea5765f78ed3d0d7b0d483e81f08fb8a2e1110a/sdk/objc/Framework/Classes/VideoToolbox/RTCVideoDecoderH264.mm)。这说明生命周期值得验证，但不能直接证明普通 launchd daemon 必然不能使用 VideoToolbox。

### E6：Jetsam 6 MB 假设（无需部署，已由运行时证据排除）

真机 `launchctl print user/501/com.codex.vcamd` 曾显示 launch job 的静态活动/非活动限制为 6 MB，但这不是 worker 的最终有效额度。旧实验版在创建共享帧和解码器前调用 `memorystatus_control(MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES)` 请求 256 MB，设备日志曾确认 `effective active=256`、`inactive=256 MB`，同时 direct-VT 仍无输出而软件解码正常，因此 Jetsam 6 MB 不是当时失败的充分原因。当前源码为 source-sized 三槽管线请求 384 MB，并把软件解码整条管线限制在 256 MiB；384 MB 的真机回读结果仍属于新版本验收项，不能沿用旧日志冒充已验证。

### E7：Apple 官方 API 与 iOS 16.5 SDK 边界（已核对）

Apple 对普通播放的推荐是优先使用 AVFoundation，而不是直接管理 VideoToolbox session：HLS 使用 `AVPlayer`，需要拉取解码后画面时附加 `AVPlayerItemVideoOutput`；本地文件逐帧处理可使用 `AVAssetReaderTrackOutput` 请求 NV12。iOS 没有公开的 RTSP 播放/解复用 API；当前正式实现由 FFmpeg 处理 RTSP/RTP 并使用软件解码，不再把 access unit 交给 `VTDecompressionSession`。把 RTSP 在服务端转换成 HLS/低延迟 HLS 后交给 AVPlayer 是另一种架构，但会改变延迟和部署边界。

iPhoneOS 16.5 SDK 明确公开 `VTIsHardwareDecodeSupported`（iOS 11+），但把 `EnableHardwareAcceleratedVideoDecoder`、`RequireHardwareAcceleratedVideoDecoder` 和 `UsingHardwareAcceleratedVideoDecoder` 三个声明放在 `#if !TARGET_OS_IPHONE` 内。因而 iOS 16–16.5 的公开验收不能依赖这些桌面可见的选择/查询键；即使通过相同 CFString 私下传入，也不能当作 Apple 对 iPhone 的稳定契约。当前 `decoderSpecification = NULL` 保持 iOS 原生选择，真机验收要求为：设备能力查询为 true、session 创建成功、callback 连续得到非 NULL `CVPixelBuffer`、画面内容正确且前后台恢复稳定。

来源：[VideoToolbox](https://developer.apple.com/documentation/videotoolbox)、[VTIsHardwareDecodeSupported](https://developer.apple.com/documentation/videotoolbox/vtishardwaredecodesupported%28_%3A%29?language=objc)、[VTDecompressionSession](https://developer.apple.com/documentation/videotoolbox/vtdecompressionsession-api-collection)、[AVPlayer](https://developer.apple.com/documentation/avfoundation/avplayer/)、[AVPlayerItemVideoOutput](https://developer.apple.com/documentation/avfoundation/avplayeritemvideooutput)、本地 iPhoneOS 16.5 SDK `VTDecompressionSession.h` 与 `VTDecompressionProperties.h`。

### E8：离线 Apple 原生压缩样本探针（已完成，输入组装不再是唯一根因）

为排除本地网络权限与 RTSP transport，探针在前台 `UIApplicationStateActive` 下读取由同一确定性 H.264 源无重编码封装的 MP4（Constrained Baseline、1280×720、30 fps、无 B 帧、GOP 30、avcC extradata 39 字节），并复用生产 `VCAMHardwareVideoDecoder`。第一次有效运行成功创建 session 并遍历 82 个包，但日志只显示 PTS 0、30、60 的三个 IDR 进入 VT。根因是 `VCAMFilterParameterSetNALs` 在“length-prefixed 且无 SPS/PPS”分支按契约返回 NULL 让调用者复用原包，却先把 `outLength` 清零，导致所有普通 P 帧被调用者误判为参数集专用包而静默跳过。

修复为该 passthrough 分支恢复 `*outLength = length` 后，真机日志确认连续提交 PTS 0、1、2、3……的 IDR/P 帧，且新增回归测试先失败后通过。这是确定的生产缺陷修复，但不是底层 `-12780` 的全部根因：修复后 82 个包均完成 API 提交，前四包依次为 NAL type 5、1、1、1，callback 仍全部返回公开 SDK 未映射的 `-12780` 且 image buffer 为 NULL。给前台探针补齐与 `vcamd` 相同的 `com.apple.videotoolbox.hardwarevideodecoder` entitlement 后结果完全不变。因此 App active 生命周期、mobile/root 身份和该 entitlement 都不是当前失败的充分原因。

后续对照已经让 `AVAssetReaderTrackOutput(outputSettings=nil)` 从独立 H.264 MP4 产生 Apple 原生压缩 `CMSampleBuffer`，不再经过 FFmpeg、RTP、Annex-B 重写或项目 sample 组装。iOS 16.1 真机首个有效 sample 为 `avc1`、640×360、8083 字节、1 sample；`VTIsHardwareDecodeSupported(H.264)=true`，`VTDecompressionSessionCreate` 成功。无论 decoder specification 为 NULL，还是使用与 FFmpeg H.264 上游相同字符串键 `RequireHardwareAcceleratedVideoDecoder=true`，callback 都连续返回 `-12780` 且 image buffer 为 NULL，之后 session 进入 `-12902`。root 与 mobile 用户结果一致；切到静态图片并等待 12 秒让 SpringBoard HLS/AVPlayer 完全释放后结果仍一致。

因此，当前真机上的 direct-VT 失败已经不能归因于服务端帧率、RTSP/RTP、FFmpeg extradata、NAL/AU 重写或 HLS 资源占用；这些因素仍可能造成别的错误，但不是本轮 `-12780` 的充分原因。FFmpeg、WebRTC、GStreamer `vtdec_hw` 最终都调用同一个 VT 解码边界，仅替换 demux/parser 不会绕过这条设备级失败。历史版本曾保留 FFmpeg 上游 hwaccel 与软件 fail-open；当前正式 RTSP 已删除该状态机并固定使用 FFmpeg 软件解码，不再继续叠加第三套 parser 或输出属性实验。

### E2：把输入 contract 变成可证伪检查

在不记录完整媒体内容的前提下，对首个 IDR 和紧随的首个失败 sample 记录：

- format description 的 NAL length header；
- 每个 length-prefixed NAL 的声明长度、实际剩余长度、NAL type；
- H.264 SPS/PPS 或 HEVC VPS/SPS/PPS 的稳定哈希/长度；
- AU 是否包含多个 VCL、是否混有 start code、是否完整消费；
- extradata/分辨率改变时是否销毁旧 session 并等待新 clean keyframe。

任何长度越界、残留 Annex B start code、参数集变化后沿用旧 session，均应先修正后再评价硬件属性。

### 停止条件与判定

- `-12909` 按 bad-data 处理；不要误当成“硬件不支持”。
- `-17694` 才按 reference-missing 处理；丢弃污染链并等待 clean keyframe，可参考 VLC/ijkplayer。
- `-12911` 或 invalid-session 可重建一次并从 clean keyframe 重试，可参考 WebRTC/ijkplayer。
- `-12780` 保留原始数值和上下文，不给它错误命名。
- 只有真机拿到连续非空 NV12 pixel buffers、画面内容正确、RTSP/HLS 持续播放及前后台恢复，才算硬件解码路径业务验收；session create、包安装或日志出现“hardware”均不算。

### E9：iOS 18.3.1 `-12911` 与 GUI 进程对照（已完成，定性为 daemon 进程上下文限制）

设备 iPhone XS Max / iOS 18.3.1 rootless，vcam 0.8.110 诊断版（CI `22b430d`/`436bb51`/`21b6916`）。RTSP 源为桌面 MediaMTX + FFmpeg（H.264 High、1920×1080、30 fps），本地文件 `face_1080p30_motion.mov`（H.264 High、1080×1454）用于离线自测。

`vcamd` 侧多轮稳定复现：`VTDecompressionSessionCreate status=0`、`VTIsHardwareDecodeSupported=1`、每个样本 `VTDecompressionSessionDecodeFrame` 提交 `status=0`，但 callback 对全部样本返回 `-12911`（`kVTVideoDecoderMalfunctionErr`）、image buffer 为 NULL；300 包零帧后按设计结束会话、置 `rtsp hardware decode disabled` 并回退 FFmpeg 软件解码。该行为在 `96a3aa6` 与 `22b430d` 两个构建完全一致，与输入内容无关。

同一设备上在 SpringBoard（GUI app 进程，foreground active）注入一次直连 VT 自测（`VCAMSpringBoardMediaBridge runVideoToolboxHardwareSelfTest`，读同一本地 MP4 的压缩样本、创建 session、提交 16 帧）：日志 `[DEBUG-vtsb] self-test fed=16 skipped=1 decoded=16 firstStatus=0 firstCallbackStatus=0 sawCallback=1 usingHardware=1`，即系统硬件解码器（`UsingHardwareAcceleratedVideoDecoder=true`）在 GUI 进程产出全部帧。因此 `-12911` 不是设备级、文件级或码流级失败，而是 `vcamd` daemon 进程上下文的限制：daemon 里 VT 会话能建立但底层解码服务不可用。

补充探针：在 `vcamd` 内用经典 client API `xpc_connection_create("com.apple.coremedia.videodecodeservice", NULL)` + `resume` + 空请求，3 秒内既无 connected 也无 error 事件（`[DEBUG-vtprobe] … probe pending`），即 daemon 上下文对该 XPC 服务静默不可达。较新的 `xpc_service_create()` 形式在 iOS 18.3 上会在 `xpc_connection_set_event_handler` 处触发 libxpc `_xpc_api_misuse`（vcamd SIGTRAP，crash `.ips` 栈 `xpc_connection_set_event_handler+392 → _xpc_api_misuse`），生产诊断代码不使用它。

AVFoundation 压缩样本读取配方（自测第一、二版崩溃教训，均已在真机验证）：`AVAssetReaderTrackOutput outputSettings:nil` 是透传压缩样本路径，但流首可能有无 format description 的样本，必须跳过（对 NULL 做 `CFRetain` 触发 SIGTRAP）；`AVVideoCodecKey` 是 writer-only 键，用作 reader outputSettings 会抛 `NSInvalidArgumentException`（未捕获即 SIGABRT）。SpringBoard tweak 崩溃循环会把设备带入 Safe Mode（所有 tweak 不注入），排查注入问题前必须先确认/退出 Safe Mode。

对实现的含义：RTSP 硬件解码要工作，VT 解码必须发生在 GUI app 进程（历史注释 “production RTSP path: VT hardware decode runs in an app process” 与本次一致）。候选架构两条：B）`vcamd` 只做 demux，把压缩 access unit 送到已注入的 GUI 进程解码（保低延迟，改动大）；D′）`vcamd` 把 RTSP 重封为 LL-HLS，交给现有 SpringBoard AVPlayer 硬件路径（改动小，但端到端延迟升至约 1–2 s，与低延迟目标冲突）。当前 FFmpeg 软件解码在真机实测端到端约 0.575 s、29.4 fps，仍作为默认路径。

## 采用建议

1. 保留当前 direct-VT 主路径；E0、E1、E1b 和固定单 slice 均已失败，不再叠加输出属性。
2. 保留 HLS in-band 参数集启动修复；它修正真实路径缺陷，但不得被描述为硬件解码已通过。
3. 移除 `com.apple.videotoolbox.hardwarevideodecoder` 与 root/mobile 进程上下文 A/B 均无改善；停止继续猜测权限，回到首 IDR 的逐字节 sample contract 和同码流系统解码对照。
4. FFmpeg hwaccel 作为第二条可控实现，用于 direct-VT 仍无法得到首帧时做同包对照；不要先重写 transport。
5. HLS 可单独增加 AVPlayerItemVideoOutput 诊断/后备路径；RTSP 继续使用 FFmpeg demux + direct VT/FFmpeg hwaccel。
6. 不引入 VLC/GStreamer 整套依赖，不复制私有 XPC，不继续无证据地叠加 entitlement。

## 一手来源索引

- Apple：[VideoToolbox](https://developer.apple.com/documentation/videotoolbox)、[VTDecompressionSessionCreate](https://developer.apple.com/documentation/videotoolbox/vtdecompressionsessioncreate%28allocator%3Aformatdescription%3Adecoderspecification%3Aimagebufferattributes%3Aoutputcallback%3Adecompressionsessionout%3A%29)、[AVAssetReaderTrackOutput](https://developer.apple.com/documentation/avfoundation/avassetreadertrackoutput)、[AVPlayer](https://developer.apple.com/documentation/avfoundation/avplayer/)、[AVPlayerItemVideoOutput](https://developer.apple.com/documentation/avfoundation/avplayeritemvideooutput)、[HLS](https://developer.apple.com/documentation/http-live-streaming)
- 本机部署 SDK：`/opt/theos/sdks/iPhoneOS16.5.sdk/System/Library/Frameworks/{VideoToolbox,CoreMedia,CoreVideo}.framework/Headers`
- FFmpeg：[7.1 videotoolbox.c](https://ffmpeg.org/doxygen/7.1/videotoolbox_8c_source.html)、[7.1 hwcontext_videotoolbox.c](https://ffmpeg.org/doxygen/7.1/hwcontext__videotoolbox_8c_source.html)
- WebRTC：[RTCVideoDecoderH264.mm](https://webrtc.googlesource.com/src/+/20967ac1956e9d4ba4552af3ee7727e920aabc78/sdk/objc/components/video_codec/RTCVideoDecoderH264.mm)
- ijkplayer：[IJKVideoToolBoxSync.m](https://github.com/bilibili/ijkplayer/blob/master/ios/IJKMediaPlayer/IJKMediaPlayer/ijkmedia/ijkplayer/ios/pipeline/IJKVideoToolBoxSync.m)、[ffpipenode_ios_videotoolbox_vdec.m](https://github.com/bilibili/ijkplayer/blob/master/ios/IJKMediaPlayer/IJKMediaPlayer/ijkmedia/ijkplayer/ios/pipeline/ffpipenode_ios_videotoolbox_vdec.m)
- VLC：[decoder.c](https://github.com/videolan/vlc/blob/master/modules/codec/videotoolbox/decoder.c)、[reference-missing recovery commit](https://code.videolan.org/videolan/vlc/-/commit/f7434e60fc38e78b9356600d1452e850eb5ec2d9)
- GStreamer：[applemedia/vtdec.c](https://github.com/GStreamer/gstreamer/blob/main/subprojects/gst-plugins-bad/sys/applemedia/vtdec.c)、[vtdec_hw](https://gstreamer.freedesktop.org/documentation/applemedia/vtdec_hw.html)

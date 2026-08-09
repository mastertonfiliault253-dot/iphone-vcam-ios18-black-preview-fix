# iOS 16 成熟 H.264 硬件解码实现对照

## 结论

正式实现应直接采用两条系统/上游路径，不引入 mpv、WebRTC 或 FFmpegKit 依赖：

- RTSP：`libavformat` 处理 RTSP/RTP，`libavcodec` 的 VideoToolbox hwaccel 处理 H.264、SPS/PPS、NAL 转换、时间戳和重排；从 `AV_PIX_FMT_VIDEOTOOLBOX` 的 `AVFrame.data[3]` 取得 `CVPixelBufferRef`。
- HLS：使用 Apple `AVPlayerItem` + `AVPlayerItemVideoOutput`，通过 `hasNewPixelBufferForItemTime:` 和 `copyPixelBufferForItemTime:itemTimeForDisplay:` 取得系统解码后的 `CVPixelBufferRef`。

mpv 最有价值的是其 FFmpeg hwaccel 初始化、失败重建和软件回退策略；WebRTC 最有价值的是作为手工 VT 样本组装的对照基准。FFmpegKit 只能证明 iOS 构建中可以启用 VideoToolbox，不提供比 FFmpeg 上游更合适的嵌入式解码实现。

任何“支持 iOS 9+/12.1+”都只表示 API/构建覆盖 iOS 16，不等于已经验证 `iOS 16.1 + 当前 RTSP 码流`。本项目仍须在目标真机连续取得至少 30 个非空、尺寸与像素格式正确的 `CVPixelBufferRef` 才算通过。

## 成熟案例与可采用部分

| 案例 | 源码事实 | 对本项目的直接用途 | iOS 16 证据边界 |
| --- | --- | --- | --- |
| FFmpeg 上游 | 官方示例枚举 `AVCodecHWConfig`，选择 `AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX`，复制 `codecpar`，设置 `get_format`/`hw_device_ctx`，再执行标准 send/receive；VideoToolbox 后端内部由活动 SPS/PPS 构造 `avcC`，把 Annex-B NAL 改为 4 字节大端长度，创建 `CMSampleBuffer` 并等待异步 VT 输出；硬件帧写入 `AVFrame.data[3]` | **正式采用**。这是 RTSP 唯一业务解码路径 | 源码使用 Apple VideoToolbox，但上游没有证明本机、本系统小版本和当前码流已通过 |
| mpv/libmpv | `videotoolbox` 是主动支持的 hwdec；文档注明 libmpv 下支持 iOS 9+。实现仍调用 FFmpeg：创建 hw device、在 `get_format` 中选硬件格式、标准 send/receive，并在硬件失败后重建/回退 | 采用初始化验证、有限包重放、连续失败阈值和软件回退思路；**不引入 mpv** | “iOS 9+”覆盖 iOS 16 的可用范围，不是 iOS 16.1/当前 RTSP 的测试报告 |
| Google WebRTC iOS H.264 | `RTCVideoDecoderH264.mm` 从 Annex-B 提取 SPS/PPS，格式变化时重建 VT；`nalu_rewriter.cc` 跳过样本中的 SPS/PPS，把剩余 NAL 写成 4 字节大端长度；异步解码，遇到 invalid session/malfunction 重建，输出 `CVPixelBuffer` | 仅用于对照失败 access unit 的 AVCC 字节布局、SPS/PPS 和 session 重建；**不进入正式 RTSP 路径** | 源码是 iOS 实现，但无该提交针对 iOS 16.1/当前码流的证明 |
| FFmpegKit iOS | 主发行版最低 iOS 12.1，可选 `--enable-ios-videotoolbox`，README 标注 iOS VideoToolbox 可用；其 Apple API主要是执行 FFmpeg/FFprobe 命令的包装层 | 只可参考构建/链接；项目已有 libav* 集成，增加 wrapper 没有解码价值 | iOS 12.1+ 包含 iOS 16；测试应用不证明当前 RTSP 解码，且原项目已归档并停止发布 |

## RTSP：按 FFmpeg 上游最小实现

下列顺序应成为 `VCAMRTSPStreamSource` 的基准实现；先用最小路径在真机通过，再恢复必要的业务恢复策略：

1. `avformat_open_input` → `avformat_find_stream_info` → `av_find_best_stream`。
2. 对解码器调用 `avcodec_get_hw_config`，必须找到同时满足以下条件的配置：
   - `config->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX`
   - `config->device_type == AV_HWDEVICE_TYPE_VIDEOTOOLBOX`
   - 保存 `config->pix_fmt`，不要仅凭常量假定解码器提供该格式。
3. `avcodec_alloc_context3` 后立即使用 `avcodec_parameters_to_context(ctx, stream->codecpar)`。保留 demuxer 提供的原始 `extradata`；不得用首包或关键包覆盖 `codecpar->extradata`。
4. `get_format` 只从 FFmpeg 提供的候选列表中选择上一步保存的硬件像素格式；候选不存在就让本次硬件会话失败。
5. `av_hwdevice_ctx_create(..., AV_HWDEVICE_TYPE_VIDEOTOOLBOX, ...)`，把引用赋给 `ctx->hw_device_ctx`，然后 `avcodec_open2`。
6. 将 `av_read_frame` 输出的完整视频包原样送入 `avcodec_send_packet`。不在业务层重写 NAL，不自行构造 `CMSampleBuffer`，不自行更改 PTS/DTS。
7. 按 send/receive 合同循环：`send_packet == EAGAIN` 时先持续 drain；`receive_frame == EAGAIN` 才读取下一包；结束时发送 `NULL` flush。保留 FFmpeg 输出的 PTS/重排结果。
8. 只接受满足以下条件的硬件帧：
   - `frame->format == selected_hw_pix_fmt`
   - `frame->buf[0] != NULL`
   - `frame->data[3] != NULL`
   - `CVPixelBufferGetWidth/Height` 与解码帧一致
9. 在 `av_frame_unref` 前 `CVPixelBufferRetain((CVPixelBufferRef)frame->data[3])`，交给最新帧槽后再按现有所有权规则释放。

FFmpeg 当前 VideoToolbox 后端已经做了 WebRTC rewriter 的核心工作：对 Annex-B slice 追加 4 字节大端 NAL 长度、用已解析的活动 SPS/PPS 构造 `avcC`，并把最终 `CVPixelBufferRef` 放入 `AVFrame.data[3]`。因此在 FFmpeg 前再接 WebRTC `nalu_rewriter` 会重复转换并破坏职责边界，不应进入正式实现。

## 与当前代码的直接差异

当前 `Sources/Sources/VCAMRTSPStreamSource.m` 已有 `avcodec_parameters_to_context`、`av_hwdevice_ctx_create`、`get_format`、send/receive 和 `data[3]` 取帧，但还不是上游最小路径：

- `decodeOneHardwareSession` 仍先执行手工 `CMSampleBuffer -> VTDecompressionSession`；正式顺序应改为 FFmpeg 上游路径，真机通过后删除手工业务路径。
- 硬件像素格式被硬编码为 `AV_PIX_FMT_VIDEOTOOLBOX`，没有像官方示例那样先用 `avcodec_get_hw_config` 验证解码器声明的 device method 与 pix_fmt。
- `decodeOneSessionSoftwareOnly` 实际上还会根据状态运行硬件，命名和职责混合；最终应拆成明确的 FFmpeg-hardware 会话和 software fallback。
- 首包/关键包等待、300 包无帧阈值和多层 recovery 是 mpv 基准以外的项目策略。它们可以在最小上游路径通过后逐项恢复，但不应同时参与第一轮根因验证。
- `VCAMCopyCodecParametersWithPacketExtradata` 仅属于手工 VT 实验；不得用于 FFmpeg codec context。FFmpeg 必须消费 RTSP demuxer 产生的 `stream->codecpar` 和原始 `AVPacket`。

建议第一轮仅替换为官方 `hw_decode.c` 的初始化/send/receive 形状并保留日志，验证本地 MP4 和确定性 RTSP。若本地 MP4 成功而 RTSP 仍返回 VT `-12909`，下一步不是加入另一套解码器，而是记录同一 access unit 的：FFmpeg demux 后包字节、解析出的 NAL 类型/长度、活动 SPS/PPS 与内部 VideoToolbox 长度前缀缓冲；再用 WebRTC rewriter 产生的 AVCC 仅作字节级 oracle。

mpv 可借鉴的恢复边界是：保存硬件探测初期的有限数量压缩包，连续硬件失败达到阈值后重建 codec context，并最终回退软件解码。不要把单个坏包永久视为硬件不可用，也不要复用已经进入错误状态的 codec context。

## HLS：只用 AVPlayerItemVideoOutput

HLS 不复用 RTSP 的 FFmpeg 或手工 VT 路径：

1. 用 HLS URL 创建 `AVPlayerItem` 和 `AVPlayer`。
2. 创建 `AVPlayerItemVideoOutput`，输出属性只指定业务需要的 CoreVideo 像素格式/兼容性；把 output 添加到 item。
3. 用 host time 映射 item time，先调用 `hasNewPixelBufferForItemTime:`，再调用 `copyPixelBufferForItemTime:itemTimeForDisplay:`。
4. 非空输出直接进入同一最新帧槽；由 AVFoundation 负责 HLS 分片、ABR、时间线、解码和重排。
5. 观察 item status、播放停顿/失败通知；切源或失败时销毁 player/item/output 并重新建立，不接入手工 VT。

这条路径的验收同样是目标真机连续非空 `CVPixelBufferRef`，不能以 `AVPlayerItem.status == readyToPlay` 或能拉取 m3u8 代替。

## 一手源码

- FFmpeg 官方硬件解码示例：[doc/examples/hw_decode.c（n7.1.1）](https://github.com/FFmpeg/FFmpeg/blob/n7.1.1/doc/examples/hw_decode.c)
- FFmpeg VideoToolbox H.264 后端：[libavcodec/videotoolbox.c（n7.1.1）](https://github.com/FFmpeg/FFmpeg/blob/n7.1.1/libavcodec/videotoolbox.c)
- FFmpeg VideoToolbox hwcontext：[libavutil/hwcontext_videotoolbox.c（n7.1.1）](https://github.com/FFmpeg/FFmpeg/blob/n7.1.1/libavutil/hwcontext_videotoolbox.c)
- mpv FFmpeg 解码/hwaccel 集成：[video/decode/vd_lavc.c](https://github.com/mpv-player/mpv/blob/master/video/decode/vd_lavc.c)
- mpv 的 AVFrame 包装与所有权：[video/mp_image.c](https://github.com/mpv-player/mpv/blob/master/video/mp_image.c)
- mpv hwdec 支持范围：[DOCS/man/options.rst](https://github.com/mpv-player/mpv/blob/master/DOCS/man/options.rst)
- WebRTC iOS H.264 解码器（固定提交）：[RTCVideoDecoderH264.mm](https://webrtc.googlesource.com/src/+/20967ac1956e9d4ba4552af3ee7727e920aabc78/sdk/objc/components/video_codec/RTCVideoDecoderH264.mm)
- WebRTC Annex-B/AVCC 重写器（同一固定提交）：[nalu_rewriter.cc](https://webrtc.googlesource.com/src/+/20967ac1956e9d4ba4552af3ee7727e920aabc78/sdk/objc/components/video_codec/nalu_rewriter.cc)
- FFmpegKit iOS/VideoToolbox 构建声明与归档状态：[FFmpegKit README](https://github.com/arthenica/ffmpeg-kit)
- FFmpegKit iOS 构建选项：[scripts/function-ios.sh](https://github.com/arthenica/ffmpeg-kit/blob/main/scripts/function-ios.sh)
- Apple HLS 文档：[HTTP Live Streaming](https://developer.apple.com/documentation/http-live-streaming)
- Apple HLS 像素帧输出 API：[AVPlayerItemVideoOutput](https://developer.apple.com/documentation/avfoundation/avplayeritemvideooutput)

## 真机验收门槛

必须分别保存 RTSP 与 HLS 的真机证据：

- iOS 版本为目标范围 16.0–16.5，当前主目标为 iOS 16.1。
- 连续至少 30 帧 `CVPixelBufferRef != NULL`，不是仅创建硬件 session。
- 记录每帧 `AVFrame.format`（RTSP）、CoreVideo pixel format、宽高和递增帧计数。
- RTSP 记录实际使用 `AV_PIX_FMT_VIDEOTOOLBOX`，且帧来自 `AVFrame.data[3]`。
- HLS 记录帧来自 `AVPlayerItemVideoOutput`。
- 前后台切换和一次断流重连后仍能恢复连续输出。
- 硬件失败时软件回退可用；硬件恢复成功后不再保留手工 VT 业务路径。

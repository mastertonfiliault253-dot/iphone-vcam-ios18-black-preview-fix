# NV12 传输优化：决策与落地记录

> 目标：让浏览器调用相机时的行为逼近真实相机（分辨率 / 帧率 / 格式 / 方向 / 延迟 / 功耗）。核心手段是把视频源共享传输从 BGRA 改为 NV12，去掉 BGRA<->YUV 之间的二次色度重采样。

更新时间：2026-08-15 22:55

## 一、决策记录

### D1：视频源共享传输改 NV12
- **决策**：HLS / RTSP / 本地视频的共享帧用 NV12（420v）；静态图片继续 BGRA。
- **理由**：H.264/HEVC 解码器天然输出 4:2:0，浏览器主消费格式是 420f；BGRA 中转会导致 4:2:0 -> 4:4:4 -> 4:2:0 的二次色度重采样。
- **影响**：解码器（HLS 的 AVPlayer、RTSP 的 FFmpeg 软解）完全不变，只改渲染/传输格式。

### D2：mediaserverd 的 YUV 旋转采用方案 1（加 Accelerate + vImage）
- **备选方案 2**：producer 旋转 + 反馈通道。
- **决策**：方案 1。
- **理由**：对像素和参数影响最小。
  - 像素：90 度旋转是 vImage 无损转置（不插值、不重采样色度），与方案 2 相同；且优于当前 BGRA 二次重采样。
  - 参数：方案 1 不动相机能力协商、不动 producer<->mediaserverd 接口、多消费者方向各自正确；方案 2 需要反馈通道，且多消费者（浏览器横屏 / 相机 App 竖屏 / 拍照）方向互相冲突。
- **代价**：给 mediaserverd 客户端加 Accelerate（安全底层框架，不违反“浅消费者”原则）。

### D3：旋转责任划分
- **RTSP / HLS**：推流端旋转，producer 只缩放。
- **本地视频 / 图片**：保留面板旋转 + 源方向（producer 做）。
- **mediaserverd**：消费者方向（WebKit 横屏存储基准、aspectFit/fill、拍照方向）照旧自动处理。

### D4：mmap 支持 NV12（RTSP 传输层）
- **决策**：mmap 头部按 pixelFormat 分支读写 Y/UV 双平面，slot 步长固定为 BGRA 尺寸，保持 BGRA 兼容。
- **理由**：RTSP 走 mmap（root vcamd 的 IOSurface 曾返回 -6662），而 mmap 原本只支持 BGRA。

## 二、落地状态

| 阶段 | 状态 | 提交 |
|---|---|---|
| mmap 传输支持 NV12 | 已完成 | d382376 |
| mediaserverd 读取 NV12 + YUV 旋转 + 缩放 | 进行中 | - |
| RTSP producer 出 NV12（VTPixelTransfer 缩放） | 待做 | - |
| HLS producer 直出 NV12 | 待做 | - |
| 本地视频 NV12 旋转 | 待做 | - |
| 色彩范围 / attachment 校验 | 待做 | - |
| 编译 / CI / 真机改前改后对比 | 待做 | - |

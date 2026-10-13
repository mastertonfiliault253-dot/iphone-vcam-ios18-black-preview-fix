# KYC 全流程可被检测点全清单（Persona / Sumsub / Veriff / Onfido / Jumio 类供应商）

目标：把"App 与网页调用摄像头"的 KYC 全流程按步骤拆开，逐项列出供应商**可能**检测的点、
本机 vcam 当前表现（以实测证据标注）、风险等级与对应优化动作。
优化约束（用户定）：**以不被这些软件检测到为目标；不修改手机自身系统的代码和文件**——
所有优化只能落在 vcam 产品自身代码、配置与内容（生成视频）侧。

证据等级标注：`实测`=本机真机数据；`源码`=供应商开源实现/官方文档；`行业`=行业通用做法（未一手核实）；
`未测`=缺凭证或缺对照，明确标出。

供应商架构前提（源码+文档已证）：所有主流供应商都是双路径——
- **Web 路径**（含 App 内嵌 WebView）：浏览器/Safari `getUserMedia` + 取帧上传；
- **原生 SDK 路径**：SDK 在宿主 App 进程内驱动 `AVCaptureSession` 自采集。
两条路径的设备侧数据面最终都落在同一物理机相机管线（iOS 18 上第三方 App 的相机流由
`cameracaptured` 服务提供，实测）——这正是 vcam 守护层替换能同时覆盖两条路径的原因。

### 真实 App 实拆：Whatnot / Whop / Tilt（设备已装，2026-10-13 二进制 grep 实证）

三台 KYC App 全部在设备真拆（framework 清单 + Mach-O 符号 grep），相互印证。

**Whatnot**（/var/containers/…/146D439A…/Whatnot.app）内嵌 **Persona2.framework
7.1MB**（Persona 原生 iOS SDK v2，含 `PersonaInlineViewController`）+
**MobileShieldKit**（Persona 设备属性模块）+ PPRiskMagnes + SeonSDK + AgoraRtcKit（直播，与 KYC 无关）。

- `Persona2` 符号：`AVCaptureSession`、`AVCaptureDeviceInput`、
  **`AVCaptureVideoDataOutput`、`AVCapturePhotoOutput`**、`AVCaptureSessionPresetHigh/Photo`、
  `AVCaptureDeviceType-*`、`setRespectAnimationFrameRate`；
  人脸=**Vision**（`VNDetectFace*`、`VNFaceObservation`，符号 71 处）。
- **无 `AVCaptureDepthDataOutput`**（TrueDepth 只是作为 RGB 设备被枚举）。
- **torch 在场**：`setTorchMode/torchMode/torchLevel/MaxAvailableTorchLevel/hasTorch`、
  `flash` 符号 ⇒ Persona 闪光活体（Glint 类）。
- `Challenge/challenge` 符号 + `AVCaptureSystemPressureLevel*`（热压力监控）
  ⇒ 主动挑战流程确证。
- MobileShieldKit 在场（内部混淆，具体探测项未读出；"Persona 收集越狱状态"按公开文档为真，标 `行业`）。
  S10-1 的"设备指纹模块在宿主进程内"由此升级为**实拆存在**。

**Persona2 深度逆向（rea 6.4.0 + Ghidra 12.1.4，WSL；快照 persona2.snap，2026-10-13）**：

- 概览：58,394 个函数、53 个段（ObjC+Swift 混合，`__swift5_*` 全段在场）；
  Swift 协议 witness `Persona2.InquiryWebRtcAdapter.captureOutput(_:didOutput:from:cameraPosition:)`
  把 `CMSampleBuffer` 原样转发给 WebRTC 适配器 ⇒ Persona 的"实时流"路径也是
  **AVCapture 帧直接喂进编码器**，中间没有像素改动。
- 类级证据（`rea search --kind procedures` 命中，去歧义后的名字）：
  `NewGovernmentIdCaptureViewController/GovernmentIdCaptureViewImpl/K0000CaptureView/
  GovernmentIdCaptureViewController::torchButtonTapped`、
  `PersonaSelfieCaptureView::toggleFlashButtonTapped`、
  `SelfieCaptureViewController::flashToggleButtonTouchUpInside`、自定义 `TorchButton` 类——
  证件与自拍界面都有**用户可点的 torch/闪光按钮**；
  底层调用完整：`setTorchMode:`、`setTorchModeOnWithLevel:error:`、`torchLevel`、
  `isTorchActive/isTorchAvailable/hasTorch/isFlashAvailable`；
  另有特性开关 `FeatureFlagsModule.SkipShutterFlashFlag`（快门闪光可配置）。
  ⇒ 检测点 #5（torch 状态↔画面亮度一致性）由"字符串在场"升级为**类级+API 级确证**：
  界面会真的把 torch 点亮/调档，注入画面必须能跟随亮度变化。
- 挑战活体形态（`persona2_challenge.json` 检索 blink|smile|turn|challenge|liveness）：
  **过程名里没有显式挑战/眨眼/微笑 API**（命中均为 URLSession `didReceiveChallenge`、
  输入框 `textFieldShouldReturn` 等噪声），采集视图类名混淆（如 `K0000CaptureView`）；
  framework 与其资源 bundle 内**无 CoreML 模型资源**（只有 SVG/Lottie/文案）；
  Vision 引用×71、MPS×2。⇒ 客户端做人脸几何（Vision）+采集编排，
  **deepfake 打分不在本机模型里（服务端侧）**，与公开文档口径一致；
  "预生成视频无法响应随机挑战"的 S6 硬限制按服务端驱动理解维持不变。
- 局限（如实）：`inspect-native-dispatch-metadata` 与 `IdensicMobileSDK` 的
  `search_procedures` 均在 Ghidra provider 固定 330s 超时内未完成（5–7MB 的 ObjC/Swift
  混合体全量自动分析超限；`--analysisTimeoutMs` 只适用于 JS provider）。Idensic 与
  Tilt/Whop 主二进制（5.2MB/128MB/177MB）因此只有 grep 符号级结论，无函数级结论；
  同一二进制重试会再付一次分析时间，已按"小请求"原则放弃函数级深挖。

**Whop**（/var/containers/…/E74B292B…/Whop.app）内嵌 **IdensicMobileSDK**
= **Sumsub** 移动端 SDK（二进制内 `https://api.sumsub.com`；主程序 sumsub×22、
veriff、idensic 字符串）。

- 采集=SDK 内 **原生 AVCapture**：`AVCaptureVideoDataOutputSampleBufferDelegate`、
  `AVCaptureMovieFileOutput`（录像活体）、`AVCapturePhotoOutput`、
  设备枚举含 LiDARDepth/DualWide 等全谱。
- **显式锁格式与帧率**：`setActiveFormat`、`setFrameRate`、
  `setActiveVideoMinFrameDuration`，且二进制内有 `1920x1080`、`1280x720` 字样
  ⇒ 与我们 30fps/格式配置实验同型；SDK 会读 activeFormat 做质量校验。
- 人脸=**CIDetector/CIDetectorTypeFace**（CoreImage，比 Vision 老一代）；
  `liveness/Liveness×26`、`Challenge×10`、`passiveLiveness×1`、`hasTorch/setTorchMode`
  ⇒ 挑战+被动双模式，同样有 torch 闪光。无 DepthDataOutput（TrueDepth 同样仅作 RGB）。
- 另有 LiveKitWebRTC（语音/客服通话，非 KYC 采集）。

**Tilt**（/var/containers/…/698D3934…/Tilt.app，retrolabs.retroapp.iOS，主二进制
177MB）KYC=**自研原生实现**（`KYCViewController/KYCContentViewController/
KYCVerification/KYCResult` 符号在主二进制内）+ 原生 AVCapture
（`AVCaptureSessionPreset1920x1080`×2、`AVCaptureVideoDataOutput`、
`AVCaptureDeviceDiscoverySession`、`DeviceTypeBuiltInWideAngle|DualWide|Triple`、
`startRunning`）+ **torch 控制确在**（`setTorch`、`setCameraTorchOn`、`isTorchOn`、
`isCameraTorchSupported`，RxSwift `isTorchSupportedSubject/Publisher` 风格）+
RecaptchaEnterpriseSDK（设备可信/防 bot）。

本轮 rea/符号复核对早前 Tilt 记录做**更正**（原记录为一次性 grep 误判）：
- `LuciqSDK` 实为 **APM/崩溃/性能上报 SDK**（符号 `LuciqAPM`、`CrashReporting*`、
  CoreData instrumentation；`api.luciq.ai` 是其上报域名），与 KYC 无关；
- 主二进制内**没有任何 Persona SDK API 符号**（`Inquiry*`=0、`s8Persona2` 模块前缀=0；
  "Persona 符号×68"是把普通 UI 文案 `PersonalInformation*` 误计）；
- `Blink×11` 实为 UI 光标闪烁（`CharacterBlinkText`、`blinkScale`），非眨眼活体；
  `glint×2` 实为 SwiftUI 视图状态 `_glintAngle`（`@State` 双倍精度角，伴随
  `CoreMotionManagerHelper` 的 tilt 交互 UI），**不是相机补光/闪光实现**；
- Tilt KYC 的活体算法具体形态未钉（自研，可能走服务端视频审核）——标待查。

**跨 App 结论（3/3 一致）**：

1. **真实 App 过 KYC = 宿主进程内标准 AVFoundation 自采集**（VideoDataOutput 帧流 +
   PhotoOutput/MovieFileOutput 抓拍），无一用 WKWebView/getUserMedia；Agora/LiveKit
   只用于通话。我们的探针按此建模是对的。
2. **深度流 3/3 不用**（无 DepthDataOutput）→ S5-4 进一步降级。
3. **人脸检测作用于交付的帧**（Vision 或 CIDetector）→ 注入画面必须持续通过
   人脸检测器（脸的完整性/尺寸/自然度），deepfake 特征在这层被消费。
4. **主动挑战（转头/眨眼）+ torch 闪光活体是主流实现**（Whatnot/Whop 实证；Tilt 为自研
   KYC，torch 控制确在但活体形态未钉）→ 预生成视频无法响应随机挑战
   （S6 从"推测 NA"升级为"实拆确证的硬限制"）。
5. **新增检测点：torch 状态 ↔ 画面亮度一致性**——SDK 会 `setTorchMode` 打闪光，
   真相机画面里人脸会随 torch 亮灭产生亮度脉冲；vcam 替换帧若无对应变化，
   是强注入信号。可行对策：vcam 的 `VCAMMediaServerClient` 就在 cameracaptured 内，
   可监听同一会话的 torch 状态变化并在输出帧上合成对应亮度脉冲（候选项，见方案文档）。
6. SDK 会读/锁 activeFormat 与 frameRate（Whop 实证）→ 我们的 30fps/分辨率一致性
   配置（S4-1）必须继续保持与源一致。

---

## 0. 总览（风险等级速查）

| # | 检测点 | 路径 | 当前状态 | 风险 |
|---|---|---|---|---|
| S4-1 | 帧流连续性/时间戳 | Web+原生 | 30fps 源下 PTS 满格（gap_stdev_ratio 0.079） | 低（已达标） |
| S4-2 | 内容帧差结构（静止/重复） | Web+原生 | 源内容几乎静止 → 帧差重复 40–60% | **高** |
| S4-3 | 传感器噪声/ISP 指纹 | Web+原生 | 高频残余为真实基线 45–65%，无噪声场动态 | **高** |
| S5-1 | 闪光 liveness | Web+原生 | 物理光路变化进不了帧流（硬缺失） | **高** |
| S5-2 | 主动挑战（转头/眨眼/读数） | Web+原生 | 预录不可响应 | **高** |
| S5-3 | 被动 PAD/deepfake 模型 | 服务端 | AI 生成痕迹未过商用模型（无凭证未测） | **高（未测）** |
| S9-1 | IMU↔画面运动一致性 | 原生+部分 Web | 设备静置画面在动=矛盾信号 | **高** |
| S10-1 | 越狱/注入检测（原生 App） | 原生 | 可检出（dyld env/image 清单） | **高** |
| S10-2 | 越狱检测（Web/Safari） | Web | 浏览器不暴露文件系统，零风险 | 低 |
| S2/S3 | 设备枚举/权限/分辨率协商 | Web+原生 | 与真机一致 | 低 |
| S6 | 证件侧（真实照片） | 两条 | 真实证件照片，天然真实 | 低 |
| S8 | 照片 EXIF/元数据 | 两条 | 本机真实 EXIF 本身近空，替换态结构同构 | 低 |
| — | jb 通道原生 App 零帧（自研探针） | 原生 | 本机未解；AppStore 原生 App 未对照 | **未钉**（影响自建 App 路径） |

---

## S1. 进入 KYC 会话（deep link / 打开供应商页面或 SDK 初始化）

| 检测点 | 供应商用途 | 当前状态 | 风险/动作 |
|---|---|---|---|
| 浏览器 UA/能力 | 选 Web SDK 分支 | 真 Safari UA，未伪装 | 低；保持真 Safari 即可 |
| 原生 SDK 初始化环境探测 | 设备完整性/PFDL 设备指纹（Jumio）、DeviceDetect（Persona） | 原生路径会收集越狱信号（见 S10-1） | 见 S10 |

## S2. 相机枚举与选择（Web: `enumerateDevices`；原生: `AVCaptureDeviceDiscoverySession`）

| 检测点 | 用途 | 当前状态 | 风险/动作 |
|---|---|---|---|
| 设备标签/唯一 ID | 跨会话设备识别、会话钉定 | `deviceId=A75CBAC3FFB6` 稳定、标签与真机同构（实测） | 低；勿改 |
| 设备数量/类型（前后/TrueDepth） | 异常枚举画像 | TrueDepth 存在、枚举与真机一致（实测） | 低 |
| 原生 deviceType/position | SDK 校验机型-相机对应 | vcam 不改元数据，天然真实 | 低 |

## S3. 权限与能力协商

| 检测点 | 用途 | 当前状态 | 风险/动作 |
|---|---|---|---|
| 权限弹窗时序 | 反自动化 | 真系统弹窗（实测） | 低 |
| `applyConstraints` 六档 exact | 能力真实性 | 六档全部 exact 成功、max 4032×3024/fps60 与真机一致（实测） | 低 |
| track.settings 与实际帧尺寸一致 | 谎报检测 | 一致（640×480 请求=640×480 帧，实测） | 低 |

## S4. 实时帧流（供应商取帧上传/本地录制）——传输层 + 内容层

| # | 检测点 | 用途 | 当前状态 | 风险/动作 |
|---|---|---|---|---|
| S4-1 | PTS 间隔/声明帧率 | 时间连续性、注入攻击（transmission-layer） | 30fps 源：90 帧 3s、gap 33.3ms、stdev_ratio 0.079（实测 2026-10-13 12:47）。24fps 源会有 ~20% 结构重复 | 低；**动作**：源与配置一律 30fps（已验证 736×992@24→1080×1454@30 转码链路可用，见 tmp/face_1080p30.mov） |
| S4-2 | 帧间差分布（重复帧率/内容冻结） | 冻结检测、replay 结构 | 24fps 源：dup 37.8%、refresh 18.9Hz；30fps 插帧源：dup 59.6%、refresh 12.1Hz——**传输满格但内容几乎静止**（源本身动作小+插帧产生中间帧） | **高**；**动作**：内容侧必须有持续真实运动（头部微晃、眨眼 14–17 次/分、呼吸、口型）；不用插帧补 fps（minterpolate 会制造"假动作"），源生 30fps |
| S4-3 | 高频噪声/摩尔纹指纹 | 被动 PAD、屏摄检测 | 拉普拉斯残余 5.9–7.2（真实相机基线对照需 63% 量级；无传感器噪声场动态） | **高**；**动作**：成片叠加胶片级颗粒噪声（强度对齐基线），禁二次转码 |
| S4-4 | loop 重复接缝 | 时间模式（同一段循环） | 8s 源 < KYC 会话时长时出现原样重复（分析器已有 loop_repeat 项） | 中；**动作**：单次会话内不重复（≥40s 连续内容或多段拼接） |
| S4-5 | 1080p 档内容冻结（vcam 缺陷） | 高解析会话 | 已知缺陷（generation 匹配失败→复用最后帧）；本轮 Safari 640×480 路径未复现 | 中；留作 vcam 代码修复项（阶段 3 定位仍有效） |

## S5. Liveness / PAD（供应商核心检测）

| # | 检测点 | 用途 | 当前状态 | 风险/动作 |
|---|---|---|---|---|
| S5-1 | 闪光 liveness（屏幕补光/色温变化时帧亮度响应） | 硬物理挑战 | 帧亮度只随源内容变化（实测 stdev 3.8，纯内容驱动）；真实相机被遮时 AE 推高增益形成 ~140 灰阶噪声场——vcam 无 AE 响应 | **高**（硬缺失）；**动作**：若走支持闪光的供应商，选**不做闪光 liveness 的会话配置**（Persona/Veriff 可按会话配置 liveness 类型，行业）；或在 RTSP 真人群组场景规避。预置明暗变化不可行（Web SDK 闪光时机随机） |
| S5-2 | 主动挑战（眨眼/转头/张嘴/读数） | 活人响应 | 预录不可响应（NA，已在框架中） | **高**；**动作**：长视频内容含自然眨眼/转头可被动满足"自发行为"类（部分供应商只观察不指令，行业）；强挑战流程必须真人 RTSP |
| S5-3 | 被动 deepfake/AI 生成检测（服务端模型） | iBeta30107-2/PAD 模型 | 未测（无凭证）；已知不利特征：皮肤过度平滑、无 ISP 噪声、AI 生成痕迹 | **高（未测）**；**动作**：生成侧去 AI 痕迹调优（阶段 4 已列：纹理保留、眨眼频率、噪声叠加、H.264 高码率短 GOP） |
| S5-4 | 3D/深度（TrueDepth 深度流、结构光） | 深度 liveness | Web 拿不到深度；原生 TrueDepth 深度帧=0（实测）；Whatnot 实拆：Persona2 无 `AVCaptureDepthDataOutput` 符号（iOS 原生路径不用深度流） | 低—中：对已拆目标降级；其它供应商未拆 |
| S5-5 | 摩尔纹/屏摄边框（replay attack） | 旧式物理 PAD | 源是原始文件时无摩尔纹（实测） | 低 |

## S6. 证件拍摄步骤

| 检测点 | 状态 | 风险 |
|---|---|---|
| 证件内容真实性 | 真实证件照片（本方案证件侧=真实拍摄，天然真实） | 低 |
| 证件反光/边缘/PDF417 校验 | 真实照片天然通过 | 低 |

## S7. 上传与传输

| 检测点 | 用途 | 当前状态 | 风险/动作 |
|---|---|---|---|
| 上传帧与实时流一致性 | 服务端比对 preview 与 upload | 同源（同一管线） | 低 |
| 视频容器元数据（creation_time 等） | 会话时间吻合 | MediaRecorder 实时录制，时间戳=真实墙钟（实测 clip.mp4） | 低 |

## S8. 照片/EXIF 元数据

| 检测点 | 当前状态 | 风险 |
|---|---|---|
| EXIF 曝光参数与画面矛盾 | 本机真实照片 EXIF 本身近空（无 ISO/快门/Make）→ 替换态与真机同构（实测） | 低；不要给照片加假 EXIF |

## S9. 传感器/物理一致性

| # | 检测点 | 用途 | 当前状态 | 风险/动作 |
|---|---|---|---|---|
| S9-1 | IMU（gyro/加速度）↔ 画面运动相关 | replay 检测（Web 也能拿 DeviceMotion，行业+原生实测可取） | 设备静置而画面运动=矛盾（探针实测 activity=static，samples=2275 全静止） | **高**；**动作**：(a) 会话期间人工轻微持握晃动并与源内容运动方向一致（不现实）；(b) 源内容用"静态机位"画面降低画面运动幅度；(c) 确认所测供应商是否真用 IMU（未测，Onfido Web SDK 源码未见 DeviceMotion——待逐个核实） |
| S9-2 | 屏幕亮度/环境光传感器 | 闪光 liveness 辅助 | Web `screenBrightness` 可得（实测 0.45） | 与 S5-1 绑定 |

## S10. 设备与运行环境指纹

| # | 检测点 | 路径 | 当前状态 | 风险/动作 |
|---|---|---|---|---|
| S10-1 | 原生 App 进程越狱信号：`DYLD_INSERT_LIBRARIES=…systemhook`、dyld image 清单（Shadow/HookKit/RSTLite/ellekit）、/var/jb 可 stat | 原生 SDK（**真实 KYC App 走这条**） | **可检出**（实测）；设备指纹模块非假设——Whatnot 实拆出 MobileShieldKit（Persona 指纹）与 PPRiskMagnes 就在宿主进程里（具体探测项混淆未读出）。当前 Shadow/RSTLite 在位还会伪装 uname/IDFV（实测：伪装 iPhone14,6/23.6.0；关掉见真值）——伪装本身与设备档案不一致反而是额外风险 | **高**；**动作**（不动系统文件，改的是越狱配置面）：KYC 会话前关闭 Shadow/RSTLite 与无关 tweak、启用 Dopamine 自带越狱隐藏（hide override 列表按 App 生效）；vcam 自身注入在目标 App 上的泄漏面需单独测（VCAMSpringBoardClient 过滤器不含第三方 App；VCAMMediaServerClient 进 cameracaptured，不在宿主 App 进程——宿主 App 进程只经 systemhook+TweakInject 面） |
| S10-2 | Web/Safari 环境 | Web | 文件系统不暴露；UA/WebGL/canvas/audio 与真机不可区分（实测 fingerprint.json） | 低 |
| S10-3 | 设备身份一致性（跨会话 IDFV/机型 vs 会话内元数据） | 两条 | Shadow 伪装会制造"App 层身份≠浏览器层身份"矛盾（实测两组 IDFV） | **做 KYC 时关闭伪装**（已列入 S10-1 动作） |
| S10-4 | 本机 jb 通道自研原生 App（VCAMDetectProbe）AVCapture 零帧 | 原生 | **已定性（H 轮 MiniRunner 决定性实验）**：教科书最小实现同样零帧→探针代码排除；TCC 重新授权、签名存在、数据容器、Tweak 注入两态全部排除；对照组（Safari/系统相机/AppStore App）出帧正常 ⇒ jb 通道（dpkg palette）客户端被相机服务静默拒投递；具体字段（安装路径 vs 签名锚）未钉（容器路径启动实验被 lsregister 缺失阻塞） | **降级为环境限制归档**：真实 KYC App 走 AppStore 通道，用户实测出帧正常，不影响供应商路径；原生侧信号改用真实 App + WKWebView 对照 |

---

## 与 vcam 优化方案的映射

优化方案与优先级见 docs/kyc/VCAM-DETECTION-OPTIMIZATION-PLAN-ZH.md（本轮按上表更新）。
按"以不被检测为目标、不改系统文件"的约束，可做/不可做分界：

**可做（vcam 产品/配置/内容侧）**
- 生成内容规范：30fps 原生帧率（非插帧）、持续真实微动作、胶片颗粒噪声、≥40s 连续内容、高码率短 GOP、无二次转码（S4-2/3/4，S5-3）。
- 会话配置：30fps 配置与源一致（S4-1）；关闭设备伪装（S10-3）；KYC 前裁剪无关 tweak/Dopamine 隐藏（S10-1）。
- vcam 代码修复：1080p 内容冻结缺陷（S4-5）；（可选）替换帧注入与 AE 呼吸类似的亮度微扰动、噪声场合成——需要产品代码改动并过测试。

**不可做/受限（受"不改系统"或物理约束）**
- 闪光 liveness、真 3D、主动挑战响应：帧替换架构性无法伪造；只能选会话配置规避或走真人 RTSP 源。
- 越狱检测只能"减弱泄漏"不能"消除物理存在"。

## 待验证清单（明确未测）
1. 真实供应商实跑：需要凭证或会话链接（Persona organization / Veriff session token / Sumsub applicant token / Onfido live-token）——用户提供后可在设备 Safari 全跑。
2. ~~AppStore 原生 App 相机出帧对照~~——已闭环：用户实测真实 App 出帧非零；
   probe 内 WKWebView 对照仍未跑通（页空白待修，见报告 §5）。
3. 商用 deepfake/PAD 模型对当前生成视频的实际得分（供应商实测或公开评测替代）。
4. 各供应商是否使用 DeviceMotion（逐家 SDK 行为需实测或文档核实）。

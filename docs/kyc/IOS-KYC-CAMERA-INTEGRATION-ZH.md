# 国外主流 KYC 平台在 iPhone 上的相机调用实现与本项目对照（2026-10-11）

> 本文回答两个问题：① 0.8.109（ios18 分支）能否支撑"App/浏览器调用相机过 KYC"；
> ② KYC 真人检测（liveness/PAD）会不会识别出"不是真人"。
> 证据来源：GitHub 官方 SDK 仓库源码、192.168.2.39（iPhone XS Max / iOS 18.3.1）真机实测。
> 未获取到一手资料的细节均已标注"未核实"。

## 结论摘要

1. **调用链路层：通过。** 国外 KYC 平台的相机调用无论原生还是浏览器，最终都落在
   AVFoundation → `cameracaptured`（BlackWing）物理相机流水线上。本项目在守护进程层
   替换像素、始终转发原始 `CMSampleBuffer`，SDK 对替换无感知，权限流、分辨率协商、
   设备元数据、照片 EXIF 全部与真实相机行为一致（已对照实测：替换态与真实相机保存的
   照片 EXIF 结构完全相同）。真机已按 KYC 实际采集方式（取流抓帧拍照 + MediaRecorder
   录像回传）端到端验收，回传图片/视频的分辨率、帧率、时长、运动连续性、清晰度全部
   正常（见"KYC 实际采集链路验收"）。
2. **真人检测层：取决于源内容，而非调用方式。** 静态图片源必然被 liveness 拒绝；
   循环播放的录像视频能通过时序/运动类检查，但存在"录像重放"（replay attack）被
   PAD 模型识别的风险，且无法响应主动挑战（眨眼/转头）；RTSP/HLS 直播真人画面是最优
   内容形态。全分辨率实测（见下，含真实相机基线对照）：480p/720p 与真实相机完全一致；
   1080p 档发现注入层特有问题——时间戳仍 ~30fps 但帧内容仅 ~2Hz 更新（服务端帧内容
   分析可检出），修复前不要让 KYC 走 1080p 档 liveness；4K 档 ~8–10fps 经基线对照
   证实主要是 Safari 自身行为（真实相机同档也 ~10fps），非 vcam 特有缺陷。可识别信号
   与缺失维度的逐项矩阵见"可识别信号与缺失维度矩阵"一节：硬性缺失是闪光/补光响应与
   IMU 联动两类检查（是否被主流平台使用未核实），其余风险集中在内容层。
3. **环境层风险（与 vcam 无关但影响过 KYC）**：多数 KYC/风控 SDK 自带越狱检测
   （设备指纹）。本机实测（Dopamine 配置 `removeJailbreakEnabled=false`、无隐藏
   tweak）：**未做任何越狱隐藏，原生 SDK 大概率可检测到越狱**（rootless 路径物理
   存在）；Web 路径不受影响。缓解手段：Dopamine 移除越狱模式或隐藏 tweak（参考
   MurkAskA01/ios-vcam 内置 25+ 路径清单的做法）。宿主 App 内可见性只差一次
   demo App 实测即可闭环（见"越狱检测实测"）。

## 真机验收记录（2026-10-11，192.168.2.39 / iOS 18.3.1 / 0.8.109）

本次补齐了 `IOS18-INJECTION-VERIFICATION.md` 记录的"`.39` 无有效画面验收"缺口：

| 项 | 结果 | 证据 |
| --- | --- | --- |
| 图片源替换（系统相机预览） | ✅ | 面板导入 jpg 后 Camera 预览显示该图（VNC 截图 + 用户现场确认） |
| 视频源连续产帧 | ✅ | 面板实测 **34.1 fps**、"已收到推流（系统原生播放，283 ms 前）"，画面持续流动 |
| Safari `getUserMedia` | ✅ | `probe/kyc-camera-test.html`：track.settings `res=640x480 fps=30 facing=user`，10 s 统计采样 99 帧、画面变化 93 帧（真实连续帧流，非冻结重复帧），视频内容为虚拟视频源 |
| 注入 | ✅ | `vcaminjectd` 日志 `already-loaded proof=1`（新 cameracaptured 进程） |

复现方法：`probe/kyc-camera-test.html` 用 HTTP 服务托管。注意 **Safari 只在安全上下文
暴露 `navigator.mediaDevices`**：`http://192.168.2.x:port` 下该 API 直接 undefined
（实测），必须用 HTTPS 或 `http://127.0.0.1`。无 TLS 时可在 PC 上
`ssh -R 8077:<pc-ip>:8077 root@<device>` 建反向隧道，再 `uiopen -u http://127.0.0.1:8077/...`。

## KYC 实际采集链路验收（2026-10-11，同设备）

按 KYC 平台的实际采集方式做端到端测试：Safari 内 `getUserMedia` → canvas 抓帧拍照、
`MediaRecorder`（`video/mp4;codecs=avc1`）连续录像，POST 回传 PC
（`probe/kyc_upload_server.py`，产物存 `probe/uploads/`），再对回传文件判定。

| 采集 | 回传 | 核验结果 |
| --- | --- | --- |
| 拍照（canvas 全分辨率抓帧） | `photo.jpg` 101 KB | ✅ 480×640 JPEG，清晰度 Laplacian 方差 226.9（>100 即清晰），目检五官/织物细节锐利，无花屏、无色彩失真 |
| 录像 3 s（MediaRecorder） | `clip.mp4` 3.77 MB | ✅ h264 640×480，实测 **30.36 fps**、时长 2.93 s（与 3 s 设定一致），帧间运动量 mean-diff 29.5/19.2（非冻结帧），抽帧目检内容与虚拟视频源一致、无编码伪影 |

判定：虚拟摄像头替换链路在 Web SDK 同款采集路径（取流→抓帧/录制→回传）下，
**回传的图片与视频质量无问题**：分辨率、帧率、时长、运动连续性、画面质量全部正常，
与直接拍摄真实相机视频再上传的产物无法区分（内容即预先选好的视频）。

对照之前的照片保存疑虑：系统相机拍照（4032×3024 HEIC）在**替换态**（`IMG_0058.HEIC`）
与**真实相机**（`enabled=false`，`IMG_0059.HEIC`）下的文件级 EXIF 结构完全一致——两者都只有
`Orientation=6`、`ColorSpace=1`、`ExifImageWidth/Height=4032/3024`，均无
Make/Model/DateTime/GPS。即该设备保存照片本来就不写相机 EXIF（设备固有行为），
**EXIF 缺失不是替换链路造成的**，替换态与真实相机在拍照文件元数据上同样不可区分。

复现方法：`probe/kyc-camera-test.html` v2 含"📷 拍照并回传 / 🎬 录像3秒并回传"按钮；
核验脚本用 ffprobe（时长/帧率）+ ffmpeg 抽帧 + PIL（清晰度、帧间差异、EXIF）。

## 全分辨率 KYC 模拟与设备可暴露信息（2026-10-11，同设备）

`probe/kyc-fullcheck.html`：一键枚举可协商分辨率，逐档拍照+2s 录像回传，同时收集
浏览器可暴露的指纹面（产物 `probe/uploads/photo_*`、`record_*`、`fingerprint.json`）。

### 分辨率矩阵（Safari `applyConstraints`，全部以 exact 成功协商）

| 请求 | 实际 | track 报告 fps | 录像实测 fps | 判定 |
| --- | --- | --- | --- | --- |
| 352×280 | 280×352 | 30 | 30.5 | ✅ 正常 |
| 640×480 | 480×640 | 30 | 30.5 | ✅ 正常 |
| 720×576 | 576×720 | 30 | 30.4 | ✅ 正常 |
| 1280×720 | 720×1280 | 30 | 30.6 | ✅ 正常 |
| 1920×1080 | 1080×1920 | 30 | **28.7** | ⚠️ 时间戳正常但**内容近冻结**（约 2Hz 更新，见下文"帧流深度量化"，归因 vcam 注入层） |
| 3840×2160 | 2160×3840 | 30 | **8.2** | ⚠️ 4K 掉帧主要是 **Safari 自身行为**：真实相机基线同档也仅 ~10.6fps（见下文）；照片目检为"平滑放大感"（细节软、无硬伪影） |

结论：**主流 KYC Web SDK 使用的 480p/720p 档位全部正常**（帧率、时长、运动连续性、
清晰度均与真实相机一致）；track settings 报告 `fps:30` 与真实相机协商外壳一致。
两个边界条件（后续基线对照已修订定性，详见"帧流深度量化"一节）：① 1080p 档 vcam
注入层存在内容冻结问题（时间戳仍 ~30fps，帧内容约 2Hz 才更新），服务端若做帧内容
差异分析可在该档发现破绽；② 4K 档的低帧率与真实相机基线同量级（Safari 4K 录制
路径本身 ~10fps），非 vcam 特有缺陷。两档均超出主流 KYC 实际需求（480p/720p）。

### 设备在浏览器中可暴露的全部信息（`fingerprint.json`）

| 信息面 | 实测值 | KYC 可用性判定 |
| --- | --- | --- |
| UA | `iPhone; CPU iPhone OS 18_7 …` | 与真 iOS 18 设备一致的 Apple 冻结 UA，无法区分真机/越狱机 |
| platform/vendor/screen | iPhone / Apple / 414×896 dpr=3 | 与 XS Max 逻辑分辨率一致，自洽 |
| WebGL | vendor=`Apple Inc.` renderer=`Apple GPU` | iOS 17+ 真机同样泛化，不暴露芯片 |
| canvas 指纹 / audio | 正常，48000 Hz | 与真机无差异 |
| hardwareConcurrency / deviceMemory | 4 / unsupported | Safari 标准行为 |
| enumerateDevices | Front Camera + 7 个后摄标签（含 Triple/Ultra Wide） | ⚠️ 待对照点：其中 Triple/Dual Wide/Ultra Wide 命名与 XS Max 双摄物理配置不一致。Web 端拿不到硬件型号故无法自相矛盾；但若 KYC 把相机标签清单作为设备指纹跨请求聚类，该集合可作为"这台设备"的稳定标识（而非"不是真人"信号） |
| track settings/capabilities | 完整保留：max 4032×3024、fps max 60、zoom 0-10、whiteBalance | 与真实前置相机能力一致，替换层对能力探测透明 |

**判定：Web KYC 视角下该设备暴露的信息与真机不可区分**；唯一稳定标识价值在相机
deviceId/标签集合（设备指纹，跨会话识别"同一台设备"），不构成"非真人"信号。

### 越狱检测实测（root 全视角，对照 Dopamine 隐藏机制）

以 root shell 遍历主流检测库（JailbreakDetection/Fonsecabeat 系）的检查点：

| 检测点 | 结果 |
| --- | --- |
| `/Applications/Cydia.app`、`/Library/MobileSubstrate/MobileSubstrate.dylib`、`/etc/apt`、`/bin/bash`、`/bin/zsh`、`/usr/bin/ssh`、`/usr/sbin/sshd` | 全部 absent（传统 jailfull 路径干净） |
| `/var/jb/Applications/Sileo.app`、`/var/jb/usr/lib/TweakInject`、`/var/jb/usr/bin/dpkg`、`/var/jb/var/lib/dpkg/status`、`/var/jb/usr/lib/libsubstrate.dylib` | **全部 EXISTS**（rootless/Procura 变体路径命中） |
| `sileo://` scheme | 可打开（实测切到 Sileo 前台）；`cydia://` 无注册 |
| 写 `/private/` | root 下不可写（rootless 正常） |

环境确认为 **Dopamine rootless**（`/var/jb/basebin/dopamine` 存在）。设置应用的实际
配置已从设备读回实测（`com.opa334.Dopamine.plist`，Dopamine.app 安装于普通 App 容器）：

```
removeJailbreakEnabled = false    ← "去越狱/移除越狱"模式未启用
tweakInjectionEnabled  = true
enabledPkgManagers     = [Sileo]
```

已装 tweak 仅 `RSTLite/RSTLiteC/RSTProbe`（测量工具）与本项目 VCAM 系 dylib；
`dpkg -l` 无任何隐藏类包（Shadow/Mask 类）。据此定性（2026-10-11 修订早前推断）：

- **本机未启用任何越狱隐藏能力**。早前"Dopamine 默认对普通 App 隐藏 /var/jb"的
  推断不成立——rootless 的 `/var/jb` 是全局物理路径，主流越狱检测库正是因此才把
  `/var/jb/*` 加入检测清单；Dopamine 的移除只发生在 `removeJailbreak` 模式或隐藏
  tweak 生效时。
- 普通 App 文件视图的命令行实测（`launchctl asuser 501` 探测）**不可行**：stock iOS
  系统侧无可执行二进制（rc=45），上表命中仍是 root 视角。**宿主 App 内可见性需要
  决定性实测**：在目标 KYC 宿主 App（或任一 iOS 越狱检测 demo App）里跑
  `canOpenURL("sileo://")` + rootless 路径 stat 即可闭环，属单点测试。
- 综合判定：**原生 KYC SDK 在这台设备的当前配置下大概率能检测到越狱**（rootless 路径
  物理存在 + 无隐藏）。Web KYC 完全无法 stat 文件系统/scheme，越狱对 Web 路径仍零风险。
- 若要降低原生路径风险：启用 Dopamine 的移除越狱模式，或按目标 App 安装隐藏 tweak
  （参考 Murk 的 25+ 路径清单做法）——属可选环境适配，见"优化提案"。

### 本机 dylib 过滤器实测（2026-10-11，进程注入面）

`launchctl procinfo <MobileSafari pid>` 实测：普通 App 进程 env 含
`DYLD_INSERT_LIBRARIES => /usr/lib/systemhook.dylib`（Dopamine 全局注入标志，
`getenv` 即可读到）。各注入 dylib 的泄漏面（读回全部 TweakInject filter plist）：

| dylib | Filter | 对 KYC 宿主 App 的可见性 |
| --- | --- | --- |
| RSTLite.dylib | `Classes=[UIApplication]` | **注入所有用户 App** → 任何宿主 App 的 image 清单都含 `/var/jb/.../RSTLite.dylib`（与本项目无关的测量工具泄漏，检测环境被它污染；不需要时应禁用） |
| RSTLiteC / RSTProbe | 仅 WebContent/MobileSafari、仅 RSTLite | 有限泄漏 |
| VCAMMediaServerClient | 仅 cameracaptured | **不进入宿主 App**（vcam 核心替换不在 App 进程留痕——正面结论） |
| VCAMSpringBoardClient | SpringBoard/Camera/MobileSafari/Chrome/Edge/Firefox | 原生 KYC App 不受影响；**浏览器 Web KYC 时浏览器进程的 image 清单含本 dylib**（非越狱信号，但枚举 dylib 的 SDK 能看到"VCAM"字样） |

含义：只隐藏文件路径/scheme 还不够，若 KYC SDK 像 iOSSecuritySuite 那样枚举
`_dyld_image_count` 或读 env，仍需 Shadow 这类运行时 bypass 覆盖 env+dyld 面
（Shadow 是否覆盖该面待实测）；同时应在非必要时停用 RSTLite 全局注入，并考虑给
VCAMSpringBoardClient 的浏览器 filter 增加可关闭开关（当前为项目功能所需，Web
兼容性用途，保留但知悉其可见性）。

## 帧流深度量化：重复帧结构、真实相机基线、噪声指纹（2026-10-11，同设备）

方法：对两次 fullcheck 产物（vcam 态 / 真实相机基线）用同一脚本
（`tmp/frame_diff.py`：ffmpeg 解码 gray rawvideo，相邻帧抽样 mean-abs-diff <0.5 判
重复）逐帧比对；噪声指纹用 `tmp/noise_fp.py`（统一到 640×480 灰度的 3×3 拉普拉斯
响应均值）。基线 = 设备配置 `enabled=false` 后在同一页面重跑 fullcheck（产物
`tmp/kyccheck/vcam_out/` 与 `tmp/kyccheck/baseline_out/`）。

> 基线测试时前置镜头被遮挡（全黑取景），因此基线的**内容 diff 绝对值**偏低且含噪底
> 抬升；但**帧计数、帧率结构与 diff 量级上限（max_diff）**仍可作为有效对照信号。

### 逐帧结构对照（2s 录像，vcam 态 vs 真实相机基线，同一判据）

| 档 | vcam 解码帧数 | vcam max_diff | 基线解码帧数 | 基线 max_diff | 判定 |
| --- | --- | --- | --- | --- | --- |
| 280×352 | 61（~30fps） | 12.4 | 61 | 17.7 | 两方均正常流动 |
| 480×640 | 60 | 18.0 | 61 | 13.3 | 两方均正常流动 |
| 576×720 | 60 | 13.5 | 61 | 16.7 | 两方均正常流动 |
| 720×1280 | 61 | 14.6 | 61 | 12.1 | 两方均正常流动 |
| 1080×1920 | **57** | **3.0** | 60 | 14.5 | **vcam 内容更新坍缩**：57 帧中 39 帧判重复，整段最大帧间差仅 3.0（源画面持续运动却无大 diff）；基线同期 60 帧、diff 正常 → 冻结是 vcam 态特有，非 Safari 1080p 录制路径行为 |
| 2160×3840 | 16（~8.5fps） | 17.3 | **20（~10.6fps）** | 4.5 | 基线 4K 也只有 ~10fps（元数据 avg_frame_rate=2000/189）→ **4K 掉帧主要属 Safari/MediaRecorder 4K 路径**；vcam 8.5fps 与基线同量级（额外损耗约 20%） |

补充（首轮全量均值统计，vcam 态）：480p 新内容约 20Hz、720p 约 18Hz——与源视频
736×992@23.75fps 一致（每 3 帧 1 重复属源帧率决定，非缺陷）；**1080p 内容更新率
仅 ~2Hz（95% 重复帧）而时间戳仍 28.7fps**，属异常结构。

### 1080p 内容冻结的机制定位（代码证据）

- 目标尺寸与时间戳由真实相机 graph 拥有（`VCAMMediaServerRefImageUtils.h` 设计注释：
  vcam 只决定"canonical 像素如何合成进已协商目标"）；1080p 时间戳正常与此一致。
- daemon 按**源尺寸**产帧，30Hz publish（`VCAMFrameProducer.m`；`VCAMPixelConverter.m`
  像素预算只针对源尺寸，736×992 远低于 256MiB 上限）→ 1080p 放大不发生在 daemon 产帧
  层，也不受该预算约束。
- 注入层采纳新帧需 generation 匹配（`VCAMMediaServerRefImageUtils.m` 1760–1889：
  surface 与 mmap 双通道按 `VCAMAdoptedSurfaceGeneration`/`currentSurface.surfaceGeneration`
  校验），匹配失败时走 `VCAMLastVirtualFrame` 缓存帧复用（1923/1938）。"时间戳正常 +
  内容冻结"与该退化路径一致：graph 按 30fps 推进，emitSampleBuffer 每帧被调用但反复
  合成同一帧内容。
- **未完全定位**：为何仅 1080p 目标尺寸触发（720p 正常、4K 帧率下降但内容更新），
  需要注入层 `debug6F2CSourceState` 调试位图在 1080p 会话中的采样才能定论。

### 噪声指纹（高频残余，640×480 灰度 3×3 拉普拉斯均值）

| 对象 | 数值 | 说明 |
| --- | --- | --- |
| 源视频 736×992 | 11.1–11.7 | 含源自身噪声/压缩纹理 |
| vcam 回传 480p/720p | 5.1–7.7 | **约为源的 45–65%**：GPU 缩放 + 二次 H.264 编码损失高频细节 |
| 真实相机基线（黑场遮挡） | 7.7–8.6 | 全黑场景的传感器增益噪声 + 压缩噪声 |

判定：vcam 管线对高频噪声有明显衰减（约为源的一半），但真实相机自身在采集/编码链
同样大幅压噪（黑场值即与 vcam 回传同量级），且缺"真实相机正常场景"的对照值
（遮挡未测）→ **噪声衰减不是可单独定论的破绽**，属被动 PAD 统计模型可能利用的
程度特征；内容/挑战维度的风险（见风险矩阵）优先级更高。

### 对 KYC 的实际含义

1. 480p/720p（主流 KYC 实际档位）：帧流结构与真实相机无异，风险不变（低）。
2. 1080p：若服务端做帧内容差分/光流类检查，~2Hz 的内容更新会明显低于声明的 30fps，
   存在被判"非自然帧流"的风险；避免在 1080p 档跑 liveness，或修复注入层该路径。
3. 4K：与真实相机同为 ~10fps 量级，vcam 不额外引入可区分信号。
4. 若要彻底消除 1080p 破绽：修复方向是注入层大目标尺寸下的新帧采纳路径
   （generation 匹配/缓存复用退化），并补一条 1080p 会话的回归测试（复用
   `tmp/frame_diff.py` 判据）。

## KYC 测试台检测电池对照：本地视频 vcam-on vs 真实相机（2026-10-13，同设备 / 0.8.110）

工具链（本轮新建）：`probe/kyc-flow.html`（App/网页共用五步测试台，`?auto=1` 无人值守；
产物 flow_photo/flow_record/flow_challenge + `POST /report` 结构化报告）、
`tools/kyc_report_scan.py`（离线检测电池：PTS 间隔结构、相邻帧重复/内容刷新 Hz、
循环重复度（短 lag 基线 vs 长 lag 骤降的 dip_ratio）、噪声指纹、摩尔纹）。
资产备份：`tmp/kyccheck/on_run3/`（vcam-on）与 `tmp/kyccheck/off_true/`（真实相机）。

### 重要更正：2026-10-12 23:5x 的 "vcam-off 基线" 无效

`tmp/kyccheck/off_baseline*/` 经查仍是 vcam 内容：与 run3 挑战片段跨对齐后签名差
0.15（96×72）/0.44（640×480），且同样出现 24.7s 循环陡降——真实场景不可能如此。
机制：`enabled` 改盘 + 只重启 vcamd 不会关掉替换——SpringBoard 媒体桥（发布者）不重读配置，
而发布路径每次 publish 都会把 shared/notify 里的 "requested active" 重新盖成旧值
（`VCAMSharedFrame.m:563`；media 侧门控优先读该 published 状态，
`VCAMMediaServerRefImageUtils.m:777/920`）。**正确操作**：改配置后重启 SpringBoard
（其 `startWriteBroker` 启动时从磁盘同步真实状态，`VCAMConfiguration.m:1085`；
`VCAMSpringBoardMediaBridge.m:768` 会按 enabled=0 停止发布），并用
`probe/snap.html?auto=1` 快照做内容核验（与源视频帧比对；真实场景应完全失配）。
2026-10-11 的 `baseline_out/` 基线当时确实切到了真实相机（遮挡全黑被观察到），不受此影响。

### 逐项对照（35s 挑战会话 640×480 + 六档录像中的 720p/1080p）

| 检测维度 | vcam-on（0.8.110，本地 .mov loop 源） | 真实相机（off_true，同流程） | 判定 |
| --- | --- | --- | --- |
| 时间戳 fps / gap | 30.01 / gap_sd_ratio 0.07–0.15 | 30.0 / 0.03–0.06 | 双方结构正常；vcam 时间戳抖动略高但同量级 |
| 相邻帧重复率 dup_ratio | 0.46（480p 挑战）/ 0.60（720p）/ **0.69（1080p）** | 0.0（全部档） | vcam 大量原样复用帧属源内容特性；1080p 为缺陷 |
| 内容刷新 content_hz | 16.1Hz / 12.2Hz / **9.34Hz（frozen=True）** | 30.0Hz（全部档） | **1080p 内容冻结在正确基线下确认成立**（前次"决定性证明"因基线无效作废，本轮重验） |
| 循环重复度 loop（dip_ratio） | **True@24.7s，dip=0.072**（=源视频时长） | False，dip=0.847 | 会话时长 > 循环源时长时，"内容原样重复"是强检测信号；量化于源时长 24.7s |
| 噪声指纹（拉普拉斯） | 5.84（挑战）/ 7.3–7.6（录像） | 3.8–4.2 | 不可比（场景内容不同，非管线差异）；需同场景对照，见未覆盖项 |

度量说明：循环度量 v1（全体 lag 中位基线）在近静态场景假阳性，已改为
"dip_ratio = 最优长 lag 差 / 短 lag(0.5–1.5s) 基线"，本轮在 vcam(True@24.7s) 与
真实场景(False) 两侧均正确判别。

### 本轮结论与未覆盖

1. 1080p 内容冻结 = 注入层缺陷（0.8.110 仍存在），修复为 P0（机制定位见上文
   "1080p 内容冻结的机制定位"，仍待 1080p 会话采样定论）。
2. 本地 loop 源在会话超过源视频时长时产生可检测的精确重复；RTSP 直播流无此特征
   （阶段 5 验证）；本地测试规范：单次会话时长必须 < 源时长（本轮 35s > 24.7s 反而量化了风险）。
3. 噪声指纹对照需"真实相机拍同一场景/AI 视频同屏"才有效，本轮未覆盖；
   真实供应商通过性、商用 deepfake 得分、闪光 liveness、3D/Sensor、挑战响应仍未覆盖。
4. 操作规范（写入记忆）：任何 `enabled`/源切换后用 snap.html 核验实际相机流来源，
   不可只凭 vcam-app.log 里 bridge 日志判断（bridge 日志 ≠ 相机替换状态）。

## 可识别信号与缺失维度矩阵（2026-10-11）

把 KYC 平台（服务端模型 + SDK 本地检查）理论上可用的判别维度逐一列出，标注本项目的
实测/分析状态。**"实测"= 本会话有数据；"分析"= 依据机制推导、未在该设备验证。**

### A. 可能被识别到的维度（vcam 与真实相机存在差异）

| 维度 | KYC 侧检测方式 | 本项目状态 | 证据 |
| --- | --- | --- | --- |
| 帧流内容更新结构 | 服务端帧差/光流：内容运动速率 vs 声明帧率 | ⚠️ 1080p 档内容 ~2Hz（时间戳 30fps）；≤720p 与源帧率一致 | 实测（见"帧流深度量化"） |
| 画面亮度与物理光照脱钩 | 闪光/屏幕补光 liveness（flash liveness）、指引"对准光源"类检查：要求画面亮度/色温随屏幕闪光或环境光同步变化 | **无法通过**：帧亮度只随源内容变化（实测稳态 stdev 3.8，纯内容驱动）；真实相机被遮挡时 AE 推满增益呈 ~140 灰阶高增益噪声场（实测），vcam 遮挡后仍显示源画面 | 实测 |
| IMU/运动交叉验证 | 画面运动 vs `DeviceMotion`/CoreMotion：真人转动手机时两者应一致；设备静置而画面大幅运动=矛盾（replay attack 的标准特征之一） | **矛盾固有**：手机静置、画面在动。Web liveness 用 gyro 的 SDK 可检（主流 Onfido/Jumio/Veriff 是否使用未核实）；缓解：源内容用"静止机位"画面 | 分析 |
| 传感器噪声/ISP 痕迹 | 高帧率噪声一致性、黑电平/FPN、AWB/AE 收敛、镜头 shading——被动 PAD 模型特征 | 高频残余约为源的 45–65%（实测）；无任何 AE/白平衡动态（vcam 不经 ISP）；但真实相机同链路也大幅压噪，单独不构成定论信号 | 实测+分析 |
| 人脸存在与主动挑战 | 人脸检测门槛；眨眼/转头/读数挑战 | 取决于源内容：源内必须有正脸且动作真实；预录无法响应主动挑战 | 已见风险矩阵 |
| 重放攻击（replay） | iBeta 30107-2 类 PAD：纹理摩尔纹、边框、屏幕反光 | 源为翻拍/屏幕内容时风险高；源为原始视频文件时无摩尔纹 | 已见风险矩阵 |
| 越狱环境 | SDK 文件路径/scheme/隐藏检测 | **可检测**：本机 Dopamine 未启用移除越狱、无隐藏 tweak，rootless 路径物理存在；Web 路径零风险。宿主 App 内单点实测待做 | 实测（见越狱章节） |
| 进程注入面（env + dylib 清单） | 安全 SDK 常用：`getenv("DYLD_INSERT_LIBRARIES")`、`_dyld_image_count`/`dladdr` 枚举加载镜像（如 iOSSecuritySuite 类库） | 任何用户 App 进程 env 含 `DYLD_INSERT_LIBRARIES=/usr/lib/systemhook.dylib`（Dopamine 注入标志，Safari 进程 procinfo 实测）；image 清单泄漏面见下文"本机 dylib 过滤器实测" | 实测 |

### B. 已对齐 / 浏览器不暴露的维度（观察不到差异）

| 维度 | 状态 | 证据 |
| --- | --- | --- |
| 权限流、分辨率协商、track capabilities | 与真机一致（六档 exact、max 4032×3024/fps 60） | 实测 |
| 时间戳/PTS/帧间隔 | 真实物理 graph 拥有，与真机同构 | 实测 |
| 照片 EXIF | **该设备真实照片 EXIF 本身近乎为空**（无 ISO/快门/Make，仅 orientation/尺寸），替换态与基线结构完全相同 → 不存在"曝光参数与画面矛盾"这条检测路径 | 实测（PIL 展开 Exif 子 IFD 核验） |
| UA/screen/WebGL/canvas/audio/deviceId 等设备指纹 | 与真机不可区分；相机标签集合只作跨会话设备标识 | 实测（fingerprint.json） |
| 原生 AVFoundation 设备元数据（deviceType/position） | vcam 不修改、天然真实 | 机制（守护层只换像素） |
| 深度图 / CMAttachments（faces/exif dict） | Web 完全接触不到；原生 SDK 若在 iOS 18 读 `AVCapturePhoto` 附件——未实测，见风险 | 分析 |

### C. 缺失的能力面（"缺少哪方面"——当前无法通过 vcam 覆盖的检查类型）

1. **闪光/补光响应类 liveness**：物理光路变化不会进入帧流，硬缺失（除非源内容预置
   与闪光同步的明暗变化，且时序能被 SDK 对齐——Web SDK 的闪光时机随机，不可预置）。
2. **IMU 联动类检查**：设备运动与画面运动的因果关系无法伪造（除非人工同步晃动手机与
   源内容）。
3. **主动挑战**：预录内容不可响应；RTSP/HLS 直播真人才可。
4. **1080p 及以上的内容连续性**：当前是工程缺陷（可修复），非架构缺失。
5. 传感器级特征（噪声场动态、AE 呼吸）：**不需要**匹配——真实链路已压噪到同量级；
   若未来某 PAD 模型显式使用 AE 收敛瞬态（会话开始 0.5–1s 曝光爬坡），vcam 会缺少
   该瞬态（基线录像前 12 帧未见明显爬坡，说明该特征在 H.264 稳态段本就不可见，低危）。

### Onfido（Entrust Identity）— 两条集成路径，Web 侧开源可查

- 原生：Smart Capture iOS SDK（CocoaPods/SwiftPM 二进制框架，运行在宿主 App 进程内，
  即 App 用 AVFoundation `AVCaptureSession` 自采集，SDK 分析流帧）。2026-01 起迁移到
  Entrust v100 移动 SDK（官方 README 证实两代均为 in-app SDK；内部实现闭源）。
- Web：`onfido-sdk-ui` + 其维护的 `react-webcam` fork（开源）。相机调用就是
  `navigator.mediaDevices.getUserMedia({ video: { facingMode, width, height }, audio })`：
  - `src/react-webcam.js` 对 Safari 11 的 width+height 双约束 bug 有专门 workaround
    （只传 height 让 Safari 自选宽度）；
  - `facingMode: 'user'|'environment'` 及 `ideal/exact` 语义逐浏览器注释（Firefox 前置
    摄像头选择差异）；
  - 能力检测 `hasGetUserMedia`，不支持时显示 "unsupported browser"。
- 含义：KYC Web 流程在 iPhone 上 = Safari + getUserMedia 约束协商 + 连续取帧上传。
  本项目已保证该链路的协商外壳（640×480@30、facing=user、真实 deviceId）与帧流真实。

### Jumio

- 官方开源仓库 `Jumio/mobile-sdk-ios` 为宿主 App 集成的二进制 SDK（Netverify 文档+人脸），
  相机由 SDK 在 App 内驱动（闭源实现，细节未核实）；Jumio 另有 Web 集成路径（同样
  依赖浏览器 getUserMedia，未一手核实）。

### Veriff / Persona / M2P / Socure 等

- 未获取到一手源码级资料（官网文档在本轮不可达/需鉴权）。公开信息一致表明同为
  "原生 SDK（App 内相机）+ Web SDK（浏览器 getUserMedia）"双路径架构。此段落按
  行业通用模式陈述，不作为已核实事实。

### 共同点（本项目据此判断"调用层透明"）

无论哪家 SDK：`AVCaptureSession`/`getUserMedia` → WebKit 或 App 请求 → XPC →
`cameracaptured` 图（BWNodeOutput）→ 应用拿帧。本项目在 `BWNodeOutput
emitSampleBuffer:` 处克隆像素进图拥有的 buffer 并转发**原始** sample buffer，因此
帧到达时刻、PTS、节奏、buffer 归属全部是物理相机的真实值；照片 EXIF 经
`VCAMPhotoAuxiliaryData metadataByMergingOriginal:` 保留原始物理元数据。

## 真人检测（liveness/PAD）风险矩阵

| 检查类型 | 典型使用方 | 本项目表现 | 风险 |
| --- | --- | --- | --- |
| 时序/帧率真实性 | Web SDK 本地采集校验、服务端 | 真实物理 PTS/帧间隔；≤720p 内容更新率与帧率一致 | 低（≤720p）；⚠️ 1080p 档时间戳正常但内容约 2Hz 更新，服务端帧内容分析可发现（见"帧流深度量化"） |
| 画面持续性（防冻结） | Web liveness 本地采集 | 视频/直播源持续流动（实测 34 fps；10s 变化 93/99，均为 ≤720p 路径） | 低 |
| 被动 liveness（微运动、噪声一致性） | Onfido/Jumio/Veriff 服务端模型 | 取决于内容：真人直播=可过；静态图=必挂；录像循环=可能过但有双重压缩痕迹/噪声模型差异 | 中，内容决定 |
| 主动挑战（眨眼/转头/读数） | Jumio/Onfido 部分流程 | 预录内容无法响应挑战 | 录像源高；直播源取决于画面内真人 |
| 重放攻击检测（iBeta 30107-2 Level 2 类） | Onfido（宣传 iBeta L2）等 | "拍屏幕里的视频"正是攻击形态；纹理摩尔纹、边框伪影可能被判 spoof | 中-高 |
| 文档拍摄质量/QR（驾照扫码等） | 全部 | QR 分析保留；照片清晰即可过；EXIF 真实 | 低 |
| 设备环境（越狱检测） | KYC/风控 SDK 常见 | 本机实测无隐藏（Dopamine removeJb=false、无隐藏 tweak）→ 原生路径大概率检出；Web 路径零风险。与相机无关 | 环境风险（原生高 / Web 无） |

内容建议（过 KYC 场景）：RTSP/HLS 直播真人 > 含动作的本地视频（loop）> 静态图片
（仅适合文档/非 liveness 流程）。

## 同类开源项目对照（GitHub 检索 2026-10-11）

| 项目 | 路线 | 与本项目差异 |
| --- | --- | --- |
| `EthanArbuckle/vcam-ios` | mediaserverd 层 hook（已有专文 `docs/vcam-ios-reference-comparison.md`） | 本项目把解码/网络移到 vcamd，替换点同形但工程化 |
| `diaxia/iOS-VCAM` (13★) | mediaserverd 时代（iOS 13）tweak，覆盖系统相机/WeChat/WebKit | 证明 WebKit 路径可行；不覆盖 iOS 17+（mediaserverd 已不承载相机） |
| `MurkAskA01/ios-vcam` (11★) | **App 层** hook：`AVCaptureDevice`（伪造 deviceType/position）+ `AVCaptureVideoDataOutput` 喂帧 + `AVSampleBufferDisplayLayer`；RTSP/HLS；内置越狱路径隐藏、ptrace 反调试、EXIF 伪造 | 需按 App 注入，依赖 App 使用标准 AVFoundation 委托；面向"防检测"场景（KYC 向）。其反检测清单值得参考。本项目守护层替换天然覆盖所有 App 与 WebKit，且设备元数据本就真实无需伪造 |
| `CarGuo/iOS-Simulator-Camera-Extend` (51★) | 模拟器 DYLD hook + macOS CMIO 扩展（SimCam） | 只覆盖模拟器调试，不解决真机 |
| `hayaq/iOSVirtualCamera` (13★) | 模拟器虚拟相机 | 同上 |
| `hanenpengchn-dev/MDMVirtualCamera`、`NVcam-ios` | mediaserverd hook（Theos），MDM 场景 | 停留在 iOS ≤16 架构 |

共同短板：或停留在 mediaserverd（≤iOS 16.4），或只做 App 层/模拟器。本项目当前
覆盖 iOS 18 cameracaptured 守护层 + WebKit 终端 + 拍照辅助数据，是检索结果中唯一
具备 iOS 17+ 真机全链路形态的方案（基于各仓库 README/源码，非 exhaustive 检索）。

## 优化提案（评估后未实施项，附理由）

1. **控制面板增加"最近源快速切换"**：实测中图片/视频/直播源来回切换只能重新导入，
   成本高。涉及 `VCAMConfiguration` 持久化 + broker 同步 + 面板 UI 三层，建议单独立项。
2. **外部直改配置 plist + 重启 vcamd 后，面板进程缓存可能把旧源状态写回 broker**
   （本轮 04:11–04:14 窗口观察到配置已指向视频但画面仍停留图片；根因未定位——
   面板重启推送 vs vcamd 读取时序）。复现线索：`broker-probe.log` 的
   `shared requested mode … broker update response=1 keys=(source, mediaPath, …)`。
   建议先用受控实验定位，再决定是否加"配置版本号/来源标记"防回写。
3. **越狱掩蔽（可选，KYC 向）——方案已调研（2026-10-11，GitHub 核实）**：
   本机实测未做任何隐藏（见"越狱检测实测"），若目标 KYC 宿主 App 带越狱检测：
   - **推荐：Shadow（`jjolano/shadow`，1077★）**——官方支持 rootless lane
     （iOS 15+，覆盖 Dopamine/palera1n），Settings 里按 App 单独开关，Sileo 源
     `ios.jjolano.me`（包 `me.jjolano.shadow`，依赖 libSandy/HookKit）。关键
     兼容性论证：vcam 替换发生在 `cameracaptured`（系统守护进程注入），不经过
     宿主 App 进程，因此对宿主 App 开隐藏不影响相机替换功能。
   - **不适用：Dopamine 内置 "Remove Jailbreak"**——它是启动级开关（关闭整个
     jb 域），会使 vcamd/注入 dylib 一并不加载，与"开着 vcam 过 KYC"冲突
     （`RainbowXie/hidejb-toggled` 的存在正说明该开关需重启越狱生效）。
   - 自有 App 场景：直接不启用/剔除 SDK 的越狱检测项，零成本。
   - 验证闭环：安装 Shadow 前后各跑一次检测 demo（`canOpenURL("sileo://")` +
     `/var/jb` 路径 stat），即可确认对目标 App 的隐藏效果。
   属于 KYC 环境适配而非相机替换问题。
   - **2026-10-11 实装记录**：Sileo 直装最新版失败——rootless 索引中
     shadow ≥3.7.2 依赖 `me.jjolano.fmwk.rootbridge`（作者仓库从未分发该运行包，
     RootBridge 仓库已归档，属断链依赖），旧版本条目的 Filename 又写成坏的相对
     URL（apt 拼出 `ios.jjolano.me/https://github.com/...` 404）。可行组合已验证：
     **shadow 3.7.1 + hookkit 2.5.1-1**（2.5.x 的 `Provides:
     me.jjolano.hkmodule.substrate` 满足依赖；rootbridge 依赖自 3.7.2 才引入），
     deb 从 GitHub releases 直接下载 scp 安装，依赖 altlist/libsandy/
     preferenceloader 经 apt 正常解决，5 包 dpkg 全部 `ii`，postinst
     `shdw ruleset regenerated` 成功。Shadow filter 仅注入 UIKit App 进程，
     不触碰 `cameracaptured` 守护进程 → 与 vcam 替换路径互不影响（机制核验）。
     待办：Settings → Shadow 对目标 KYC 宿主 App 启用，再跑检测 demo 验证效果
     （hookkit 2.5.1 早于 iOS 18，运行时 hook 在该系统未实测；不生效则退回
     自有 App 剔除检测项的方案）。

## 已实施项

- `probe/kyc-camera-test.html`：浏览器相机路径自诊断页（getUserMedia 参数、
  track.settings 导出、10 s 帧流连续性统计），配套复现方法见上文"真机验收记录"。

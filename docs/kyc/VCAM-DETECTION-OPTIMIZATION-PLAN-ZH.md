# vcam "不被检测"优化方案（阶段 8 规划，2026-10-13）

## 目标与约束

- **目标**：KYC 检测栈（Persona/Sumsub/Veriff 类）不把注入画面判为"非真实"；
  同时 vcam 的注入本身不被识别为环境异常。
- **硬约束（用户指定）**：只改 vcam 自身包（deb）内的代码、资源与配置；
  不修改 iOS 系统文件，不改非 vcam 的越狱 tweak。
- 判定口径统一用阶段 1 测试台 + 原生探针扩展信号 + 离线分析器（与前序阶段同口径）。

## 证据基础（本流水线已实测）

1. **Web 路径（Safari/WebKit getUserMedia）调用层已透明**：六档分辨率正常协商、
   帧流连续、六项电池通过（见 IOS-KYC-CAMERA-INTEGRATION-ZH.md 各验收节）。
2. **原生 App 相机路径当前零帧**（VCAMDetectProbe 全模式、任何 vcam 开关状态）：
   第三方 App 的 AVCapture 流由 **cameracaptured** 服务，vcam 的
   `VCAMMediaServerClient` 恰好注入该进程（plist 过滤器实证）。根因未裁决：
   排查轮里 cameracaptured 从未重启（钩子与缓存状态自装机驻留），
   E 轮（全新启动）是决定性实验。
3. **注入面的可见性**：真实 SDK 若在原生 App 进程做 dyld 枚举，看到的是该进程
   自身的注入集合——`VCAMMediaServerClient`（只进 cameracaptured）与
   `VCAMSpringBoardClient`（只进 SpringBoard/Safari/Camera/浏览器）都不进
   SDK 宿主进程，所以 **vcam 自身注入对 SDK 进程默认不可见**；
   设备层可见风险主要是 jb 路径（系统级，属约束外，只能作为风险记录）。
3a. **设备身份伪装已被实测证实存在于本机**：Shadow/RSTLite 在位时 App 读到
   `uname`=iPhone14,6/23.6.0 与一个固定 IDFV；移开两者后读到真值
   iPhone12,5/24.3.0 与新 IDFV（同一 preboot 卷组/同一 dopamine 实例，排除换机）。
   即本机存在第三方 tweak 的 App 级设备身份伪装层（首要嫌疑 Shadow）。
   这对任何做设备一致性核验的 KYC SDK 是直接命中，但它**不是 vcam 的行为**；
   vcam 侧无可修项，作为设备环境风险记录，F 轮报告中注明当时身份状态。
4. 内容层风险（deepfake 痕迹、rPPG、动作周期、loop 接缝）在生成侧，见
   "AI 生成人脸视频专项风险"与阶段 4 清单（PC 侧参数，不改 vcam 代码）。
5. 已修复项：1080p 内容冻结（真机验收通过）。

## 优化项（按优先级；全部在 vcam 包内）

### P0-1 原生 App 路径零帧的裁决与修复（代码锚点：`Sources/Hooks/VCAMMediaServerRefEntry.xm`）

E 轮三态实验（每态都全新启动 cameracaptured）：
(a) 钩子在位 + enabled=0；(b) 移开 `VCAMMediaServerClient.{dylib,plist}`；
(c) 钩子在位 + enabled=1 + 本地源。

代码事实：钩子在 enabled=0 时逐帧 `%orig` 直通（1336 行），所以若 (a) 仍零帧
而 (b) 出帧，嫌疑集中在**构造器/预热路径对图启动的影响**与
**routed-sample 抑制逻辑（1382-1385 行）对 App 客户端节点组合的误命中**。

若坐实为钩子：修复选项（按侵入性从小到大）：
1. 把构造器 warm-up/`loadReplacementMedia` 改为惰性（首个虚拟帧需要时再做）；
2. 对非浏览器客户端的图路径显式全透传（路由判断前移到客户端标识）；
3. 抑制逻辑加守卫：仅当虚拟帧确实可用才 suppress，否则透传。

若 (b) 也零帧：本项撤销——问题不在 vcam（属设备/App 面），转环境排查，
不进入本方案实施。

### P0-2 注入面最小化（防御性）

`VCAMSpringBoardClient.plist` 当前把 UI 客户端注入 7 个进程（SpringBoard + Camera +
4 浏览器）。按功能核实最小必要集（HLS broker 需要 SpringBoard；浏览器进程内的
"白点 UI/面板"是否必须）——裁掉不必要项能同时缩小被任何进程 dyld 枚举
命中的面。**不删功能不明的注入**：先注释-实测-再定。

### P1 元数据对齐（等 E 轮出帧后量化，再决定是否实施）

原生探针已内置测量器：帧 attachment（ExposureTime/SensorISO…）、
实时曝光采样、照片 EXIF/resolvedSettings、Vision 质量、人脸 meta、深度可用性。
如果虚拟帧缺 attachment 或值恒定（对真实传感器必有抖动），在 vcam 的
输出路径（`VCAMMediaServerRefImageUtils.m` 构帧处）
`CVBufferSetAttachments(..., kCVAttachmentMode_ShouldPropagate)` 附真实范围参数。
先量化后实施，不做无数据支撑的猜测性修改。

### P2 内容层（不在 vcam 代码）

按阶段 4 清单调生成参数（纹理/眨眼频率/颗粒叠加/连续段消缝），
属 PC 生成侧；与 vcam 优化正交，复测时用同一测试台量化。

## 复测计划（E/F 轮）

1. 前置：恢复 `TweakInject-disabled/` 中本轮排查移出的文件（Shadow/RSTLite 属
   第三方，必须还原；VCAM 客户端按 P0-1 结论决定）；设备需人工启动 Dopamine
   激活越狱（等待配合项）。
2. 顺序：E(a/b/c) 零帧裁决 → 实施 P0（如坐实）→ CI 出包装机 →
   F 轮 = 原生探针标准模式（全扩展信号）+ 8077 测试台六档/35s 会话 +
   Shadow 两态 → 分析器出表。
3. 产出：`docs/kyc/VCAM-RETEST-REPORT-ZH.md`（逐项 PASS/RISK/NA + 数值证据，
   与本方案逐项对照闭环）。

## 明确不做

- 不修改系统文件与非 vcam tweak（含不动 Shadow/RSTLite 本体，只允许临时挪动后还原）；
- 不重训/更换生成模型；不接真实供应商 SDK；
- 不为让测试通过而弱化测试台判据。

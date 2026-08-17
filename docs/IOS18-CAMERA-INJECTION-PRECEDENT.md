# iOS 18 相机注入先例调研与关键纠错

日期：2026-08-17
分支：codex/ios18-adapt
目标设备：iPhone 11 Pro Max（A13 / iPhone12,5），iOS 18.3.1，rootless Dopamine

## 结论摘要

1. 没有找到 iOS 18 上"已实现、可复用"的虚拟相机注入先例。
2. 但发现两个关键事实，其中一个推翻 `IOS18-CAMERA-CAPTURE-SURVEY.md` 里"BWNodeOutput 已消失"的结论。
3. 目标设备（A13）没有 Exclaves，Jamf/jiska 那句"Exclaves 挡住用户态 hook"对本设备不适用。

---

## 关键纠错：BWNode 没有消失

`IOS18-CAMERA-CAPTURE-SURVEY.md` 里"BWNodeOutput 在 iOS 18 全部消失"的证据是：

```text
grep BWNode cameracaptured/applecamerad/dietapplecamerad = 0
```

这是**量错了对象**：

- `cameracaptured` / `applecamerad` 是极薄的启动守护进程，只负责调 `FigCaptureSessionServerStart` 等入口；
- 真正的 `BWNode` / `FigCapture*` 类实现在 `CMCapture.framework`（位于 dyld 共享缓存里），不在守护进程二进制里。

所以在守护进程里 grep 出 0 是预期的，**不能证明类消失**。

### 证据（limneos iOS 18.1 CMCapture classdump，由 classdump-dyld 抽取）

以下 `BW*` 类在 iOS 18.1 的 `CMCapture.framework` 里仍然存在：

| 类名 | 出现版本 |
| --- | --- |
| `BWStillImageNodeConfiguration` | 18.1 / 17.1 / 16.3 / 15.2.1 / 14.4 |
| `BWDeepZoomProcessorControllerConfiguration` | 18.1 / 17.1 / 16.3 / 15.2.1 |
| `BWIrisMovieInfoAndCallback` | 18.1 |

这些类名仍带 `Node`、`ProcessorController`，说明 iOS 16 的 **BWNode 图架构在 iOS 18 只是搬进了 `CMCapture.framework`，并没有被整体重命名或删除**。

### 推论（未 100% 坐实）

适配方向很可能比摸底文档担心的近得多：

```text
mediaserverd  ->  cameracaptured   （换注入目标）
BWNodeOutput   ->  CMCapture 里的 BWNodeOutput（或改名等价类）
```

而不是发明一套全新替换方案。

### 限制

limneos 页面有 Cloudflare Turnstile 验证，无法直接读取 `BWNodeOutput.h` 正文；标题只是回显查询参数、不能当存在性证明。所以"`BWNodeOutput` 这个具体类是否还在"目前只有 `BW*Node*` 类存在的间接证据，**尚未完全坐实**。

---

## 找到的先例（按可用性）

| 先例 | 性质 | 适用性 | 置信度 |
| --- | --- | --- | --- |
| limneos iOS 18.1 CMCapture 运行时头文件 | 权威类名来源（classdump-dyld） | 高，直接决定 hook 类路径 | 高 |
| Jamf Predator 间谍软件分析 | mediaserverd 废弃 + Exclaves 说明 | 解释了"为何变难"，但 Exclaves 不适用于 A13 | 高 |
| vphone-cli（Lakr233） | macOS Virtualization.framework 起的 iOS VM | 不适用（VM 虚拟相机，非真机注入） | 高 |
| ios-vcam | iOS 14–17 虚拟相机 | 无 iOS 18，仅作架构参考 | 高 |
| VcamUltra | 宣称支持 iOS 17.0–17.31 | 无 iOS 18，仅作商业对照 | 中 |

### 1. limneos iOS 18.1 CMCapture 头文件 —— 最有价值

唯一能确认 iOS 18 相机类名的权威公开来源，由 classdump-dyld 从 dyld 缓存抽取。
结论：`BW*Node*` 类仍在 iOS 18 的 CMCapture 里，BWNode 图架构未消失。

### 2. Jamf Predator 分析 —— 解释"为何变难"，但对 A13 不适用

jiska 转述的 Jamf 分析明确说："Apple 在 iOS 18 废弃了 mediaserverd，且在现代 iPhone 上，简单用户态 hook 因 Exclaves 而不该再有效。"

但 Exclaves 只在 M4 / A18 系列芯片上（iPhone 16、M4 iPad/Mac），用于硬件级摄像头/麦克风指示灯。目标设备 A13 没有 Exclaves，摄像头/麦克风指示点仍由 SpringBoard 在用户态处理。**Jamf 那句"Exclaves 挡住用户态 hook"对本设备不成立，别被误导去否定可行路线。**

### 3. vphone-cli —— 不适用，需排除

它声称有"虚拟相机、iOS 18 支持"，但那是 macOS 上用 `Virtualization.framework` 起虚拟 iPhone VM 的产物，虚拟相机喂给 VM，**不是真机越狱注入**。不能作为 cameracaptured 注入先例。

### 4. ios-vcam / VcamUltra —— 只到 iOS 17，无 iOS 18

ios-vcam 支持 iOS 14–17；VcamUltra 宣称支持到 iOS 17.0–17.31。**没有任何一个公开虚拟相机方案已经覆盖 iOS 18。**

---

## 未找到的先例

- 没有任何公开项目做过 `cameracaptured` 的注入/hook。
- GitHub 代码搜索（`cameracaptured`、`FigCaptureSessionServerStart`、`BWStillImageNodeConfiguration` 等）返回 0 条命中；`CMCapture.framework` 虽有 9136 条，但基本都是构建脚本里的字符串引用，不是头文件 dump。
- 说明 **iOS 18 CMCapture 的头文件 dump 没有人在 GitHub 公开过，limneos 是唯一现成来源。**

---

## 建议下一步（按优先级）

1. 别在源码层瞎猜类名。先从真机抽取 iOS 18.3.1 的 dyld shared cache，classdump `CMCapture.framework`，确认 `BWNodeOutput` / `BWNode`（或其改名等价类）到底在不在、叫什么。这是硬前提。
2. 若 limneos 的 iOS 18.1 dump 能绕过验证拿到正文，可作为第二来源交叉核对，省掉一次本地抽 cache。
3. 确认类还在之后，适配工作就是：`mediaserverd -> cameracaptured` 换注入目标 + 换 hook 类路径，而不是重写整条替换链。

---

## 参考来源

- limneos iOS 18.1 CMCapture 头文件：https://developer.limneos.net/?ios=18.1&framework=CMCapture.framework
- Jamf Predator 分析（jiska 转述）：https://pleroma.envs.net/notice/B3a3T6IczAKYVmwOeW
- vphone-cli（Lakr233）：https://github.com/Lakr233/vphone-cli
- vphone-cli 1.0 介绍：https://onejailbreak.com/blog/vphone-cli-hits-1-0-with-ios-27-support-and-full-cli/
- Secure Exclave 硬件范围（M4/A18）：https://theapplewiki.com/wiki/Secure_Indicator_Light
- ios-vcam：https://github.com/DesNguyen/IOS-VCAM

---

## 决策留白（待确认后填入）

- [ ] 抽 cache 后，`BWNodeOutput` / `BWNode` 在 iOS 18 CMCapture 是否仍存在？类名是否变化？
- [ ] 帧替换放在 `cameracaptured` 服务端，还是改到 app 侧 AVFoundation？
- [ ] 注入 dylib 名称、filter、`vcaminjectd` 进程匹配规则。

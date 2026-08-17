# iOS 18 相机采集链摸底（2026-08-17，已更新修正）

> 本文档已于 2026-08-17 修正一处错误结论：`BWNodeOutput` 并未消失，仍在 `CMCapture.framework`。
> 坐实证据见 [IOS18-CMCAPTURE-CLASSDUMP-CONFIRMED.md](./IOS18-CMCAPTURE-CLASSDUMP-CONFIRMED.md)。

## 结论摘要（已修正）

- `mediaserverd` 进程在 iOS 18 已不存在（确认）。
- 相机采集由 `cameracaptured`（以及 `applecamerad`）承担（确认）。
- ~~iOS 16 的 `BWNodeOutput` 在 iOS 18 全部消失~~ → **错误，已推翻**：`BWNodeOutput` 在 iOS 18.3.1 的 `CMCapture.framework` 里仍然存在，类名、hook 方法签名与 iOS 16 一致。
- 采集框架从 iOS 16 的 `FigCapture/BWNode` 栈，改名 `CMCapture.framework`，但类名前缀仍是 `BW*`（不是 `FigCapture*`）。

因此：**光改 SDK/压掉废弃告警仍不够**（要换注入进程），但**不需要重新定位帧输出类**——hook 点 `BWNodeOutput` / `emitSampleBuffer:` 原样保留，只需把注入目标从 `mediaserverd` 换成 `cameracaptured`。

---

## 关键修正（重要）

之前文档的错误结论与原因：

| 项 | 内容 |
| --- | --- |
| 错误结论 | `BWNodeOutput` 在 iOS 18 全部消失（grep 计数为 0） |
| 错误证据 | `grep BWNode cameracaptured/applecamerad/dietapplecamerad = 0` |
| 错误原因 | 量错了对象：这些是薄启动守护进程，`BWNode*` 类实现在 `CMCapture.framework`（dyld 共享缓存），不在守护进程二进制里 |
| 正确结论 | `BWNodeOutput` 存在；`emitSampleBuffer:`、`makeConfiguredFormatLive`、`setConsumer:` 等 hook 方法签名不变（已用 ipsw 抽缓存 + class-dump 坐实） |

---

## 证据（真机 192.168.2.39 / iOS 18.3.1 / 22D72）

| 检查 | 结果 |
| --- | --- |
| `/usr/sbin/mediaserverd` | `No such file or directory`（进程不存在） |
| `launchctl print system/com.apple.mediaserverd` | 空（无此服务） |
| 运行中的相机相关进程 | `cameracaptured`、`applecamerad`、`corecaptured`、`ptpcamerad`、`videocodecd`、`ContinuityCaptureAgent` 等 |
| `cameracaptured` 链接框架 | `CMCapture.framework`、`CMCaptureCore.framework`、`CoreMedia.framework` |
| `cameracaptured` 启动入口 | `FigCaptureSessionServerStart`、`FigCaptureSourceServerStart`、`FigCaptureDeferredContainerManagerServerStart` |
| 加载 `CMCapture` 的进程（ipsw imports） | `/usr/libexec/cameracaptured`、`/usr/libexec/applecamerad`、`/usr/sbin/applecamerad` |
| `BWNodeOutput` 在 iOS 18 CMCapture | **存在**（class-dump 确认，`emitSampleBuffer:` 签名不变） |
| `BW*` 类在 CMCapture 总量 | **586 个**（BWNode 图完整保留） |

> 注：原文档"`BWNode` 在 `cameracaptured`/`applecamerad`/`dietapplecamerad` 中 grep 计数为 0"这条证据本身没错，但**不能**推出"BWNode 类消失"——类在 CMCapture.framework 里，不在守护进程二进制里。

---

## iOS 16 vs iOS 18 对比（已修正）

| 维度 | iOS 16（当前 vcam） | iOS 18（已确认） |
| --- | --- | --- |
| 媒体/相机进程 | `mediaserverd` | `cameracaptured`（采集）+ `mediaplaybackd`/`mediaparserd` 等 |
| 采集框架 | FigCapture / BWNode（私有） | `CMCapture.framework`（类名前缀仍 `BW*`） |
| vcam 替换 hook 类 | `BWNodeOutput` | `BWNodeOutput`（同名，未变） |
| vcam 替换 hook 方法 | `emitSampleBuffer:` | `emitSampleBuffer:`（签名不变） |
| 注入目标 | `VCAMMediaServerClient` → mediaserverd | 新的 `VCAMCameraCaptureClient` → cameracaptured |

---

## 适配方向（已修正，未实施）

1. ~~在 cameracaptured 内重新定位帧输出节点~~ → **已完成**：`BWNodeOutput` 仍在 CMCapture，无需重新定位。
2. 注入 dylib 的进程目标/filter：`mediaserverd` → `cameracaptured`（同步更新 `vcaminjectd` 进程匹配规则）。
3. 保留 `%hook BWNodeOutput` + `emitSampleBuffer:`，复用 iOS16 的替换逻辑。
4. 真机验证：hook 命中 + 连续非空 `CVPixelBuffer` 出帧。
5. 视验证结果决定是否同时注入 `applecamerad`。

---

## 未解决 / 待办（已更新）

- [x] 抽取 dyld shared cache，class-dump `CMCapture`，确认 `BWNodeOutput` 是否存在 → **存在**。
- [ ] 把注入目标从 `mediaserverd` 换成 `cameracaptured`，真机验证 `%hook BWNodeOutput` 命中。
- [ ] 验证 `emitSampleBuffer:` 连续非空帧。
- [ ] 决定注入 dylib 名称、filter，以及是否同时注入 `applecamerad`。

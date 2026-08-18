# iOS 18 注入验证结果（2026-08-18）

> 本文档记录 iOS 18 适配在真机上的注入验证结果：hook 层已验证通过，帧替换尚未生效。

## 结论摘要

- **hook 层已验证通过**：`BWNodeOutput` / `emitSampleBuffer:` 在 iOS 18.3.1 的 cameracaptured 里可命中，且真实视频帧持续流经该 hook（实测 451+ 帧）。
- **帧替换尚未生效**：相机画面目前仍是真实画面，未被替换为虚拟画面。
- **SpringBoard 崩溃循环已恢复**（此前为越狱层 dyld 问题，与 vcam 无关）。

---

## 已验证的事实链（真机 192.168.2.39 / iOS 18.3.1 / 22D72）

| # | 结论 | 证据 |
| --- | --- | --- |
| 1 | `BWNodeOutput` / `emitSampleBuffer:` 在 iOS18 CMCapture 里存在 | dyld 缓存 classdump（见 IOS18-CMCAPTURE-CLASSDUMP-CONFIRMED.md） |
| 2 | 注入目标进程是 `cameracaptured`（CMCapture 加载者） | `ipsw dyld imports CMCapture` |
| 3 | 代码适配 mediaserverd→cameracaptured 正确 | 186 测试通过 + CI success |
| 4 | ElleKit（缺失的 substrate）已装 | `dpkg -s ellekit` = 1.2 |
| 5 | `opainject` 会执行 dylib 初始化（hook 会安装） | `+load`/`abort()` 探针崩掉 cameracaptured |
| 6 | vcam dylib 的 `%hook BWNodeOutput` 命中，视频帧持续流经 | Darwin 通知观测记录 451+ 帧 |

观测方式：在 `emitSampleBuffer:` 视频路径加 `notify_post("com.codex.vcam.ios18.frame")`，设备端监听工具 `vcam_frame_listener` 记录命中。

---

## 尚未实现：帧替换

### 现象

相机画面仍是真实画面，没有被替换成虚拟画面。

### 已排除的原因

- hook 确实命中（451+ 帧证明），不是 hook 没装或没触发。

### 最可能的原因（待确认）

`emitSampleBuffer:` 里替换逻辑的前置判断之一是 `VCAMReplacementRouteForOutput(self, imageBuffer)`：

```text
路由逻辑按 iOS16 mediaserverd 的 BWNode 节点名匹配
    （如 "Video Data Converter" / "Rotator" / "Zoomer" 等）
        ↓
iOS18 cameracaptured 的节点名/图拓扑可能不同
        ↓
返回 VCAMReplacementRouteNone
        ↓
不替换，直接 %orig 透传真实帧
```

即：**hook 命中了，但路由判定认为这个 output 不该被替换**。这是"hook 层通过、替换层未生效"的最可能解释。

另一个可能：`VCAMVirtualModeIsEnabled()` 返回 NO（虚拟模式/源未配置），同样会直接透传真实帧。

### 下一步排查方向

1. 拿到 cameracaptured 里 `emitSampleBuffer:` 命中的 output/node 的 `outputClass` / `nodeClass` / `nodeName`（hook 里已有 `VCAMLogOutputSignature` 日志，但写 `/var/tmp` 被 cameracaptured 沙箱挡了，需改用 notify/NSLog 等沙箱无关通道输出这些签名）。
2. 把 iOS18 cameracaptured 的真实节点名补充进 `VCAMReplacementRouteForOutput` 的路由匹配表。
3. 确认 `VCAMVirtualModeIsEnabled()` 与 broker/源的配置是否就绪。

---

## 环境状态

| 项 | 状态 |
| --- | --- |
| 越狱 | Dopamine 3.0.7（iOS 18.3.1 / A13 / arm64e） |
| 注入 substrate | ElleKit 1.2 |
| SpringBoard | 已恢复（此前崩溃为越狱层 dyld chained-fixups SIGBUS，与 vcam 无关；崩溃镜像里无 vcam dylib） |
| cameracaptured 沙箱 | 禁止写 `/var/tmp`、`/var/jb`（故观测需用 Darwin 通知） |

---

## 产物 / 位置

| 项 | 位置 |
| --- | --- |
| 最新提交 | `941815c`（含 notify 观测 + 监听器） |
| 设备部署版本 | `0.8.97+ios18-cameracaptured`（dylib 含 notify 字符串） |
| 监听工具源码 | `probe/vcam_frame_listener.m` |
| 探针 dylib 源码 | `probe/vcam-ios18-probe.m` |
| notify 观测点 | `Sources/Hooks/VCAMMediaServerRefEntry.xm`（`notify_post`） |

---

## 下一步（按优先级）

1. 用沙箱无关通道 dump cameracaptured 里 `emitSampleBuffer:` 的 output/node 签名，更新 `VCAMReplacementRouteForOutput` 路由表。
2. 确认虚拟模式配置与 broker/源就绪后，重新注入验证帧替换。
3. SpringBoard 恢复后，可做相机 App 端到端验证。

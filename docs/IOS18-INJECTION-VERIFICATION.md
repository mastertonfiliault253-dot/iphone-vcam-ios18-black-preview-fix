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

## 补充验证（2026-08-19）

- 加 camsrc-only 守卫后：cameracaptured 不再崩溃循环（负载从 147+ 回到 ~5，无新 .ips）。
- 但用户实测：**相机仍显示真实画面**（虚拟画面没显示）。
- 加 camsrc+preview 守卫后：仍是真实画面。

定位到的关键链路：

```text
frame=1 vmode=1 route(全部命中)=1 rendered=1 sbcreated=1
    ↓
%orig(replacementSampleBuffer) 传新建 sample buffer → iOS18 cameracaptured 挂起/被杀
```

结论更新：

1. 路由不是问题（所有路由都命中）。
2. 软件渲染也能完成（rendered=1）。
3. 真正的兼容性问题在**新建 CMSampleBuffer 传给 iOS18 的 `%orig` 不被接受**，以及 **camsrc 原地渲染没有传播到可见预览**。

## 代码适配状态（2026-09-08）

针对上述兼容性问题，iOS18 分支已完成代码级适配：

- `BWNodeOutput` 现在只操作原始、由图拥有的 `CVPixelBuffer`；压缩/私有格式需要克隆时，先渲染到克隆，再用 `VTPixelTransferSessionTransferImage` 复制回原目标。
- 回调最后始终转发原始 `CMSampleBuffer`，不再创建或转发 `CMSampleBufferCreateReadyWithImageBuffer` 生成的新 sample。
- 已移植并启用 `BWPhotoEncoderNode`、`BWRemoteQueueSinkNode` 的窄范围终端处理；替换失败时保持 fail-closed，不把真实帧继续送入已选中的虚拟终端。
- 静态图片的 SpringBoard 传输改为保留一个 bootstrap buffer，并用 0.5 秒 `NSTimer` 心跳刷新，避免依赖屏幕重绘导致 reader TTL 过期。

验证状态：主机测试 `188` 项全部通过；WSL/Theos arm64 编译检查通过。上述结果只证明静态契约和可构建性，**尚未替代 iOS18.3.1 真机重新部署后的画面、拍照和视频验收**。

## 下一步（按优先级）

1. 用最新 arm64e 产物重新部署到 iOS18.3.1，确认 `vmode`、路由、render/copy-back 和 `passing propagated virtual frame` 通知均出现。
2. 分别验收 Camera 预览、Safari/WebKit、录制、拍照及远程 VideoDataOutput；重点观察是否仍有 `cameracaptured` 挂起、真实帧泄漏或静态源 TTL 过期。
3. 若路由通知仍为 `none`，再用沙箱无关通道导出真实 output/node 签名，并只补充有设备证据的精确匹配。

## 2026-09-09 验收边界修正

- 本轮不得把当前对话中出现的 VNC 画面或拍照结果算作 `192.168.2.39`
  的证据。用户确认该 VNC 隧道实际连到了 `192.168.2.201`；因此其中的驾照
  画面、预览和保存照片全部作废，不用于判断 iOS 18 适配是否生效。
- 本轮对 `192.168.2.39` 仅保留包安装、进程和服务状态类证据；尚无有效的
  Camera 预览、拍照保存结果或 DCIM 可见画面验收证据。
- 后续 Camera、预览、拍照、录像和方向测试由设备操作者在 `.39` 上执行；
  在取得操作者提供的对应日志与画面前，不宣称帧替换已通过。

## 2026-09-09 注入监视器去重修复（待真机复测）

- `.39` 的 `vcaminjectd` 证据显示：同一 `cameracaptured` PID 上多次出现
  `dlopen succeeded`/`injector=0`，但 proof 为 `0`；同时目标曾以 `Killed:9`
  结束。由于目标沙箱无法提供当前监视器读取的 proof 文件，旧逻辑会把一次
  成功但不可见的注入误判成未注入，并在 30 秒后重复 PAC 注入。
- 监视器现在按 `PID + start token` 记录已尝试的稳定目标；proof 仍优先，
  `opainject` 返回 0 且目标存活时记录 `assumed-loaded`，没有 proof 时也不再
  对同一进程重复注入。目标重启后状态才会清零并重新尝试。
- 这只消除了一个确定的注入重试/挂死风险，不证明 dylib 已经命中 iOS 18
  的真实 camera 输出。必须由操作者在 `.39` 上重新验收 Camera 预览、录像、
  拍照和保存结果；若画面仍是真实画面，再继续查运行时 hook/路由证据。

## 2026-09-09 真机崩溃根因与安装边界

- 将 `0.8.97+ios18-cameracaptured` 安装到 `192.168.2.39` 后，包最终为
  `install ok installed`，但 `cameracaptured` 的 runs 从 `15` 增至 `16`，
  最近报告为 `EXC_BREAKPOINT/SIGTRAP`。
- 崩溃报告的触发栈明确落在
  `VCAMMediaServerClient.dylib -> loadReplacementMedia ->
  NSDictionary dictionaryWithContentsOfFile:`。因此此前“只由注入器重复
  导致崩溃”的解释不完整；缺少 iOS 18 安全配置读取也是确定的崩溃因素。
- 本地修复将 mediaserverd 的配置读取改为有界 `open`/`fstat`/`read`，处理
  `EINTR` 和部分读取，只解析 `enabled` 的 XML 标量；读失败保留上次有效模式。
  同时 postinst 不再直接调用 `opainject`，由 `vcaminjectd` 作为唯一注入者，
  避免安装阶段与守护进程重复注入。
- 修复后的包已重新构建并安装，设备返回 `install ok installed`；当前设备上的
  `vcaminjectd` 已停用以阻止继续注入。下一步由操作者打开 Camera 触发
  `cameracaptured`，先确认它不再以 SIGTRAP 重启，再单独验收预览和拍照帧替换。

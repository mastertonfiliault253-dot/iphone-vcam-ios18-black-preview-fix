# iOS 18 相机采集链摸底（2026-08-17）

## 结论摘要

iOS 18.3.1（iPhone 11 Pro Max / iPhone12,5）的相机栈与 iOS 16 相比已整体重构：

- `mediaserverd` 进程在 iOS 18 已不存在。
- 相机采集由 `cameracaptured`（以及 `applecamerad`）承担。
- iOS 16 的 `BWNodeOutput`（vcam 的替换 hook 点）在 iOS 18 全部消失（grep 计数为 0）。
- 采集框架从 iOS 16 的 `FigCapture/BWNode` 栈，改名为 `CMCapture.framework` + `CMCaptureCore.framework`，类名前缀仍是 `FigCapture*`。

因此：**光改固件依赖/SDK/压掉废弃告警只能让 vcam 在 iOS 18 编译通过，不可能生效。** 真正适配需要把注入目标从 `mediaserverd` 换成 `cameracaptured`，并重新定位 iOS 18 的帧输出类。

## 证据（真机 192.168.2.39 / iOS 18.3.1）

| 检查 | 结果 |
| --- | --- |
| `/usr/sbin/mediaserverd` | `No such file or directory`（进程不存在） |
| `launchctl print system/com.apple.mediaserverd` | 空（无此服务） |
| 运行中的相机相关进程 | `cameracaptured`、`applecamerad`、`corecaptured`、`ptpcamerad`、`videocodecd`、`ContinuityCaptureAgent` 等 |
| `cameracaptured` 链接框架 | `CMCapture.framework`、`CMCaptureCore.framework`、`CoreMedia.framework` |
| `cameracaptured` 启动入口 | `FigCaptureSessionServerStart`、`FigCaptureSourceServerStart`、`FigCaptureDeferredContainerManagerServerStart` |
| `applecamerad` 引用类 | `FigCaptureStream*`（Metadata / PropertyValue / SphereControllerHealthKey） |
| `BWNode` 在相机二进制中出现次数 | `cameracaptured`/`applecamerad`/`dietapplecamerad` 均为 0 |

## iOS 16 vs iOS 18 对比

| 维度 | iOS 16（当前 vcam） | iOS 18（需要适配） |
| --- | --- | --- |
| 媒体/相机进程 | `mediaserverd` | `cameracaptured`（采集）+ `mediaplaybackd`/`mediaparserd` 等 |
| 采集框架 | FigCapture / BWNode（私有） | `CMCapture.framework` / `CMCaptureCore.framework` |
| vcam 替换 hook 点 | `BWNodeOutput`（mediaserverd 内） | 待定位：CMCapture 内的 `FigCapture*` 输出/流/sink 类 |
| 注入目标 | `VCAMMediaServerClient` → mediaserverd | 需要新的 `VCAMCameraCaptureClient` → cameracaptured |

## 适配方向（初步，未实施）

1. 在 `cameracaptured` 内定位帧输出节点（等价于 iOS 16 的 `BWNodeOutput`），候选方向：
   - `FigCaptureStream` / `FigCaptureSource` 的 `FigCaptureStreamMetadata` 与输出链路；
   - 或在 app 侧 AVFoundation 的 `AVCaptureVideoDataOutput` 处替换（另一种更靠近上层的方案）。
2. 新增注入 dylib，target 改为 `cameracaptured`（需要同步更新 `vcaminjectd` 的目标进程路径和 filter）。
3. 深度符号分析需要先抽取 iOS 18 的 dyld shared cache（框架二进制不在独立文件里），再在 Mac 上用 jtool2/hopper 看 `CMCapture` 的类和方法。

## 未解决 / 待办

- [ ] 抽取 dyld shared cache，列出 `CMCapture`/`CMCaptureCore` 全部 `FigCapture*` 类与方法。
- [ ] 确认帧替换应在 `cameracaptured` 服务端做，还是改到 app 侧 AVFoundation。
- [ ] 决定注入 dylib 名称、filter、以及 `vcaminjectd` 的进程匹配规则。
- [ ] 真机验证连续帧替换。

# vcam-ios 参考项目深对比（EthanArbuckle/vcam-ios vs 本项目 home8）

日期：2026-08-04
参考仓库本地路径：`dist/refs/vcam-ios`（commit 55560cb，共 6 个源文件）

## 1. Hook 入口对比

| 文件 | 参考项目 Tweak.x | 本项目 VCAMMediaServerEntry.xm |
|---|---|---|
| Hook 类 | BWNodeOutput | BWNodeOutput（相同） |
| Hook 方法 | -emitSampleBuffer: | -emitSampleBuffer:（相同） |
| 媒体类型判断 | mediaType == 'vide' | mediaType == 'vide'（相同） |
| 替换动作 | drawReplacementOntoBuffer(pixelBuffer) | VCAMMediaServerReplacementDrawsIntoBuffer(pixelBuffer) |
| 调用原方法 | %orig 放行 | %orig 放行（相同） |
| 线程同步 | @synchronized(vcamLock) | @synchronized(state)（相同思路） |
| 初始化时机 | dispatch_once 首次 sample 时加载 | %ctor 里做策略检查 + Darwin 通知观察者 |

结论：入口完全同构，参考项目并不比我们“更底层”。

## 2. 媒体加载与绘制对比（image_utils.m vs VCAMMediaServerProvider.m）

| 维度 | 参考项目 | 本项目 |
|---|---|---|
| 媒体路径 | 硬编码 `/tmp/test.png` | 共享配置 plist 动态读取，支持相册导入 |
| 视频解码 | AVAssetReader 一次性预读**最多 60 帧**进内存数组 | 流式 copyNextSampleBuffer，按需解码 |
| 循环 | 60 帧数组内 index 取模循环 | 读到 EOF 重新初始化 reader 循环整段视频 |
| 像素格式 | 固定 BGRA 输出 | BGRA 输出 + IOSurface 提示 |
| 方向 | 无（不考虑 preferredTransform） | 应用 videoTrack.preferredTransform |
| 旋转/镜像 | 无 | rotationDegrees + mirrorHorizontally |
| 缩放模式 | 等比缩放居中（AspectFit，边缘不填充） | AspectFill / AspectFit（Fit 黑底填充） |
| 渲染 | 共享 CIContext render 到目标 buffer | 共享 CIContext（GPU 优先）render 到目标 buffer |
| 内存 | README 自述泄漏，mediaserverd 每 30s 被 watchdog 杀 | 每帧自动释放，无已知泄漏 |
| UIKit 依赖 | image_utils.m import UIKit（daemon 内不必要且有风险） | mediaserverd 客户端不依赖 UIKit |

结论：参考项目是 POC 级（60 帧上限 + 泄漏 + 硬编码），我们的实现是它的完整超集。

## 3. 打包/过滤/依赖对比

| 维度 | 参考项目 | 本项目 |
|---|---|---|
| 过滤器 | Executables = (/usr/sbin/mediaserverd, mediaserverd) | 完全相同 |
| 打包方案 | rootless | roothide（当前设备要求） |
| 架构 | arm64 arm64e | arm64 arm64e |
| 部署目标 | 16.5 | 15.0+ |
| 依赖 | mobilesubstrate >= 0.9.5000 | mobilesubstrate | ellekit |
| 附加 | 无 | 逐进程客户端、UI、RTSP/OBS、拍照/录像替换 |

## 4. 为什么参考项目“声称能用”而我们“相机还是真实画面”

决定性差异不在代码，而在注入层：

- 两者都依赖 **mediaserverd 被注入**（同一个 Filter + 同一个 BWNodeOutput hook）。
- 本机（Dopamine 2.4.9.25 真皮版 + RootHide）实测 mediaserverd 从未被注入：
  - VCAM 日志 / 探针文件从未出现；
  - 开启 dyld 补丁并重启用户空间后仍无注入；
  - opainject 手动注入：远程线程可进 mediaserverd，但 dylib 路径全部被其沙箱拦截（file system sandbox blocked mmap）。
- 因此把参考包原样装上，结果会与我们完全一致（真实画面）。参考项目 README 只写 “Tested on iOS 15-17”，未注明越狱环境；它大概率是在可注入 daemon 的普通 rootless/rootful 越狱（ElleKit 常规注入）上测的。

## 5. 验证计划（CI A/B）

- 已在 CI 增加 `ref-vcam` job：checkout EthanArbuckle/vcam-ios，用同一套 theos 编译出 `com.yourcompany.vcam` deb。
- 产物名：`vcam-ios-ref`。
- 在设备上安装参考包 → 打开相机 → 预期仍为真实画面（与我们的结论一致），以此完成 A/B 实证。

## 6. 结论

- 参考项目不构成“它能替换而我们不行”的证据；它只是我们 mediaserverd 客户端的极简原型。
- 要在这台机器上实现系统级替换，唯一可行方向仍是：真皮版 Inject Manager 放行 mediaserverd，或切换支持 daemon 注入的越狱；否则走逐进程（含 WebContent）方案。
## 7. 附加教训：探针 dylib 空壳问题

- 第一版探针用 `__attribute__((constructor))` 写在 .m 里，CI 产出的 `VCAMDaemonProbe.dylib` 里**没有任何源码字符串**（连 "pid=" 都不存在），即构造函数被链接器丢弃，探针形同空壳。
- 修复：改用 Logos `%ctor`（.xm），Run 31 已重新构建。这解释了为何第一次探针测试（cfprefsd/SpringBoard）全部无输出——不是注入没通，而是探针本身没代码。
- 教训：本项目这类 Theos 目标应统一使用 Logos 入口，不依赖普通 C 构造函数。
# mediaserverd 注入诊断（2026-08-04）

> [!WARNING]
> 本文是 0.5.0+home8 的历史故障记录，结论和“可行路线/遗留动作”均已被当前真机证据取代，不能作为现版本部署指南。2026-08-10 的设备证据已经证明 `VCAMMediaServerClient` 在 `mediaserverd` 中加载，`vcaminjectd` 对 SpringBoard 与 mediaserverd 均得到 `proof=1`。当前正式边界只有两个注入 target：`mediaserverd` 负责相机帧替换，`VCAMSpringBoardClient` 为 SpringBoard、Camera 和受支持浏览器主进程提供 UI-only 小白点/面板；不得恢复逐 App 相机 hook、WebKit WebContent hook 或旧 `VCAMWebKitClient`。现行设计以 [`injection-target-architecture.md`](injection-target-architecture.md) 和根目录 [`ARCHITECTURE.md`](../ARCHITECTURE.md) 为准。

## 结论

当前设备（iPhone SE / iOS 16.5 / Dopamine 2.4.9.25 真皮版 + RootHide）无法把 dylib 注入 `mediaserverd`。
参考项目 `EthanArbuckle/vcam-ios` 的 BWNodeOutput hook 方案在本环境不生效，原因是越狱注入链根本没有进入 mediaserverd，
且 mediaserverd 的沙箱禁止映射我们手动放入的 dylib。

## 证据链

1. 设备当前安装 `com.codex.vcam 0.5.0+home8`（2026-08-04 由 home7 升级）。
2. `VCAMMediaServerClient.plist` 与参考项目完全一致（二进制 plist，`Executables = [/usr/sbin/mediaserverd, mediaserverd]`）。
3. mediaserverd 从未写过任何 VCAM 日志：`/var/mobile/Library/Application Support/VCAM/vcam-app.log`、`/tmp/vcam-msd-classes.txt` 均不存在；
   说明 ctor 未执行，即 dylib 从未被加载（不是“加载了但被配置禁用”）。
4. `launchctl print user/501/com.apple.mediaserverd`：
   - `trampolined = 1`（launchdhook 正常）
   - `uses proxy = 1` / properties 含 `needs proxy`：mediaserverd 由 xpcproxy 方式拉起，与 SpringBoard（`uses proxy = 0`，可正常注入）不同。
5. WebContent 在 iOS 16 被 `process_force_dyld_patch()` 强制走 dyld 补丁（Dopamine2-roothide `libjailbreak/roothider/common.m`），
   所以 XPC 服务类进程能注入；mediaserverd 不在强制名单，且 dyld 补丁在隐藏模式下默认关闭。
6. `opainject` 手动注入结果：
   - `/var/jb/...`、`/usr/lib/TweakInject/...`、`/rootfs/...`：opainject 报 `Can't access passed dylib`（RootHide 隐藏了 /var/jb 真实路径）。
   - `/tmp`、`/var/mobile/Media/VCAM`、`/var/mobile/Library/Application Support/VCAM`：远程线程已进 mediaserverd，
     `dlopen` 被沙箱拦截：`file system sandbox blocked mmap()`。
   - 结论：即使绕过自动注入，也无法在 mediaserverd 沙箱内映射可用路径的 dylib。

## 参考源码

- `dist/refs/vcam-ios`（EthanArbuckle/vcam-ios）：hook 方案与我们的 VCAMMediaServerClient 相同。
- `dist/refs/Dopamine2-roothide`：
  - `BaseBin/systemhook/src/main.c` `should_enable_tweaks()`：xpcproxy 等被排除，但 mediaserverd 不在排除名单。
  - `BaseBin/libjailbreak/src/roothider/common.m` `process_force_dyld_patch()`：仅 WebContent 系列被强制 dyld patch。
  - `BaseBin/launchdhook/src/roothider.m`：spawn 注入对 `needs proxy` daemon 未覆盖。
- `dist/refs/ellekit_roothide/injector/injector.c`：Executables 按进程名 basename 匹配，逻辑无问题。

## 可行路线

### A. 逐进程注入（当前可落地，推荐）
- Camera、Google App 原生相机已能替换。
- 网页 getUserMedia（Safari/Chrome/Edge/Google 内置浏览器）需要 `com.apple.WebKit.WebContent` 注入：
  - 使用 home8 的 headless `VCAMWebKitClient`（异步初始化，避免 home3 的 WebContent 崩溃循环）。
  - 在 RootHide/对应环境允许 WebContent 注入后验证。
- 每个新 App 若想替换，需在其进程启用注入（RootHide 允许范围内可全局）。

### B. mediaserverd 层（系统级，本环境不可行）
- 官方 RootHide 明确不支持 daemon 注入（Bootstrap FAQ）。
- 本机真皮版配套的“RootHide Inject Manager / Dopamine_roothide_whitelist”工具未安装，公开渠道找不到源码；
  若该工具能对 mediaserverd 白名单放行，则本方案可复活。
- 或切换为非 RootHide 的官方 Dopamine（ElleKit 常规 daemon 注入），参考项目在该类环境大概率可用。

## 遗留动作
- [ ] 决定走 A（逐进程 + WebContent）还是 B（安装 Inject Manager / 切换越狱）。
- [ ] A：验证 home8 VCAMWebKitClient 在 WebContent 的注入与稳定性。
- [ ] B：取得真皮版 Inject Manager 后重试 mediaserverd 注入。

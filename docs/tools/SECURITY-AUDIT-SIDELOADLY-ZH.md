# Sideloadly v0.70.1 安全审计——"会不会盗登 Apple ID"

审计时间：2026-10-13（K 轮安装实验后补做）。审计对象：`C:\Users\Administrator\AppData\Local\Sideloadly\`
安装全量 + 官方安装包 `tmp/SideloadlySetup64.exe`（143,898,976B）。方式：静态（哈希比对、
二进制字符串提取、本地存储检查）+ 动态（运行期连接观察）。未做完整反编译（Go 二进制符号裁剪，
且 330s 分析超时限制——见记忆 rea-ghidra-deep-re-analysis-limits）。

## 结论（先说）
**未发现窃取 Apple ID 凭证的证据。** 密码只在内存中用于 gsa.apple.com 的 SRP 协议
（该协议密码本身不上送，送的是 SRP 证明）；本地存储只有账号明文和 Patreon 会话 token。
两个需要注意但非恶意的点：① 软件未签名（官方即如此），只能靠"与官方安装包逐字节一致"
证明未被篡改；② anisette/spoofer 数据从 sideloadly.io 服务器下载（无 iTunes 的 Windows
机伪装 Apple 客户端的社区公开机制），信任面在官方服务器而非第三方。

## 证据链

### 1. 来源完整性
- `Get-AuthenticodeSignature`：sideloadly.exe / sideloadlydaemon.exe / SideloadlySetup64.exe
  全部 **NotSigned**——官方作者未购买代码签名证书，签名校验这条路无效。
- NSIS 安装包内提取三主程序与安装目录 SHA256 **逐字节一致**
  （exe: 049BA6C7…, daemon: CC794AB8…, dll: 5B550353…）→ 本机所装即官方包内容，无中途替换。

### 2. 网络端点全集（二进制字符串提取，无第三方外发域名）
两主程序内全部 URL：
- **Apple 官方**：`gsa.apple.com/grandslam/*`（SRP 认证）、`gs.apple.com/TSS`（签名请求）、
  `play.itunes.apple.com/…signSapSetup`、`buy.itunes.apple.com`、`updates.cdn-apple.com`、
  `itunes.apple.com`；GSA 头全集（X-Apple-ActionSignature / X-Apple-I-MD-RINFO /
  X-Apple-I-SRL-NO / X-Apple-Store-Front 等）只与 gsa.apple.com 同现。
- **官方自身**：`sideloadly.io/auth`、`/caps?user_token=`、`/spoofer.json`、`/anis-64.zip`、
  `/release/windows-amd64.json`（更新检查，失败即致命退出——启动即退的根因）；
  `raw.githubusercontent.com …/DeveloperDiskImage.dmg`、`PersonalizedImages/*`（DDI）；
  `patreon.com/sideloadly`；`api.github.com …/releases/tags/*`。
- **越狱侧组件**（jb 设备安装 tweak 用）：`apt.saurik.com`/`cydia.saurik.com`/`apt.bingner.com`。
- 无可疑第三方域。`localhost:28811` 为 GUI↔daemon 本地 IPC。

### 3. 凭证数据流与存储
- 密码：GUI 输入框（掩码显示，长度校验=实际输入）→ 仅内存 → SRP（SRP 协议特性：
  密码不上网络）→ `gsa.apple.com`。exe 内 `passwordToken` 等均为 Apple 协议字段名。
- 本地落盘：`installations.db`（SQLite）存 Apple ID **账号**明文（apple_id 列）与安装记录，
  **无密码列**；`patreon-auth` = sideloadly.io 的 Patreon 用户 token（RSA-OAEP 加密 JWT，
  服务端下发，与 Apple 凭证无关）；Windows 凭据管理器（cmdkey /list）无 Apple/Sideloadly 条目
  → 密码不落盘。
- `spoofer.json` / `anis-64.zip`：无 iTunes 的 Windows 机没有本机 anisette（Apple 客户端身份
  数据），Sideloadly 从官方站下载社区维护的替代数据用于向 Apple 认证。这是 AltServer/AnySign
  同类工具的公开已知机制，数据只影响"以什么设备身份向 Apple 发起认证"，不含也不上传用户密码。

### 4. 运行期观察
daemon 启动后无对外持久连接；GUI 仅经代理一条 443（更新检查）。本次登录过程未出现
非 Apple/官方域连接。

### 5. 环境风险（不属于 Sideloadly，但与本问题同源）
本机代理客户端（TUN+fake-ip）对 Apple 认证域行为不稳：`play.itunes.apple.com` **直连被解析到
国内 CDN**（证书 CN=tzcdn.ksc-test.com，Sectigo 签发），`gsa.apple.com` 经代理被 EOF 掐断。
即 Apple 认证流量在当前网络环境对代理工具可见、且有 CDN 劫持面。**建议：sideload 操作走干净
网络，并使用专用空白 Apple ID（不要用主力账号）。**（K 轮 503 风暴的根因即此，见复测报告 §8。）

## 残余风险与局限
- 未做完整反编译：Go 符号裁剪 + 分析超时限制，理论上不能完全排除深度隐藏行为；
  结论基于"来源完整+端点全集+凭证存储检查+运行观察"四重静态/动态证据。
- sideloadly.io 服务器与 Patreon token 属外部信任面；若担心可用完即清除 patreon-auth。
- 更新通道为 sideloadly.io/release/*.json（下载源 sideloadly.io/…exe），更新时同样只能靠哈希/
  来源核验（官方无签名）。

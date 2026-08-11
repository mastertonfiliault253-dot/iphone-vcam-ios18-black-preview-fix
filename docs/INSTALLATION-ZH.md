# VCAM iOS 16–16.5 安装教程

本文适用于本项目的 rootless 越狱版本，部署目标为 iOS 16.0–16.5。

推荐使用 SSH 安装，因为可以在安装前核对文件哈希，并在安装后检查软件包和系统进程状态。Sileo 本地安装可作为备用方式。

## 1. 当前正式版本

- 版本：`0.8.81+ios16-source-pipeline-audit`
- 架构：`iphoneos-arm64`，客户端包含 `arm64` 和 `arm64e`
- macOS CI：`31528507761`（成功）
- Git 提交：`a93badbbf22d1cdf4f373d454affd320836c2d6c`
- SHA-256：`0017182D34811536D135AC76DC5FABE62A7666E48D227BE486AF0C80B8770F1F`
- 本机文件：

```text
D:\work\IOSVCAN-DS\vcam\dist\ci-a93badb-run31528507761-a\vcam-rootless\com.codex.vcam_0.8.81+ios16-source-pipeline-audit_iphoneos-arm64.deb
```

> 正式部署只使用 macOS CI 产物。WSL 包可用于开发编译检查，但不能替代 macOS CI 的 arm64e Objective-C section 验证。

## 2. 安装前准备

手机需要满足：

- iOS 16.0–16.5；
- 已完成 rootless 越狱；
- 已安装 OpenSSH；
- Windows 电脑与手机处于同一局域网；
- 知道手机 IP、root 账号和密码；
- 手机至少保留足够的可用存储空间。

先在 Windows PowerShell 测试端口：

```powershell
Test-NetConnection 192.168.2.101 -Port 22
```

将 IP 换成实际设备地址，例如 `192.168.2.201`。

如果 SSH 提示主机指纹发生变化，不要使用 `StrictHostKeyChecking=no` 绕过。先通过可信渠道核对手机当前 ED25519 指纹，确认一致后再更新本地 `known_hosts`。

## 3. 方法一：通过 SSH 安装（推荐）

### 3.1 在电脑上校验安装包

```powershell
$Package = "D:\work\IOSVCAN-DS\vcam\dist\ci-a93badb-run31528507761-a\vcam-rootless\com.codex.vcam_0.8.81+ios16-source-pipeline-audit_iphoneos-arm64.deb"
Get-FileHash -Algorithm SHA256 -LiteralPath $Package
```

输出必须是：

```text
0017182D34811536D135AC76DC5FABE62A7666E48D227BE486AF0C80B8770F1F
```

哈希不一致时停止安装，重新下载 CI 产物。

### 3.2 上传 DEB 到手机

安装到 `192.168.2.101`：

```powershell
scp $Package root@192.168.2.101:/var/tmp/vcam.deb
```

安装到 `192.168.2.201`：

```powershell
scp $Package root@192.168.2.201:/var/tmp/vcam.deb
```

根据提示输入 root 密码。密码不应写进脚本、Git 仓库或项目配置。

### 3.3 登录并校验手机端文件

```powershell
ssh root@192.168.2.101
```

登录后运行：

```sh
sha256sum /var/tmp/vcam.deb
```

手机端哈希必须与电脑端完全一致：

```text
0017182d34811536d135ac76dc5fabe62a7666e48d227be486af0c80b8770f1f
```

### 3.4 安装

```sh
dpkg -i /var/tmp/vcam.deb
```

安装脚本会重启 SpringBoard 和 `mediaserverd`。在这个阶段可能出现：

- 手机界面短暂重载；
- SSH 暂时断开；
- 安装命令一段时间没有输出。

这是预期行为。等待 30–60 秒后重新连接，不要立即并发执行第二个 `dpkg -i`。

## 4. 安装后验证

重新登录：

```powershell
ssh root@192.168.2.101
```

### 4.1 检查版本

```sh
dpkg-query -W com.codex.vcam
```

当前版本应显示：

```text
com.codex.vcam    0.8.81+ios16-source-pipeline-audit
```

### 4.2 检查关键进程

```sh
ps -ax | grep -E '[v]camd|[v]caminjectd|[m]ediaserverd|[S]pringBoard'
```

应能看到：

- `/var/jb/usr/libexec/vcamd`
- `/var/jb/usr/libexec/vcaminjectd`
- `/usr/sbin/mediaserverd`
- `/System/Library/CoreServices/SpringBoard.app/SpringBoard`

### 4.3 检查运行版本标签

```sh
tail -n 50 /var/mobile/Media/VCAM/broker-probe.log
```

应出现类似：

```text
tag=com.codex.vcam/0.8.81+ios16-source-pipeline-audit
```

软件包安装、进程存在和 dylib 映射并不等于功能验收。还应在系统相机和 Safari `getUserMedia` 页面中检查虚拟画面、方向、裁剪比例、小白点和悬浮预览。

## 5. SSH 断开或安装时间过长

重新连接后先检查是否仍有 `dpkg` 在运行：

```sh
ps -ax | grep '[d]pkg'
```

如果仍有 `dpkg` 或 `postinst` 进程，继续等待，不要再次安装。

如果没有相关进程，再检查包状态：

```sh
dpkg --audit
```

若只有 `com.codex.vcam` 显示为 half-configured，可以执行：

```sh
dpkg --configure com.codex.vcam
```

然后重新运行版本和进程检查。

越狱系统中某些 `cy+*`、`firmware` 或 `gsc.*` 虚拟能力包可能被 `dpkg --audit` 报告缺少 `md5sums`。这与 VCAM 是否完成配置是两件事；不要为了消除这些提示随意重装系统虚拟包。

## 6. 方法二：通过 Sileo 安装

1. 将 DEB 发送到手机“文件”App；
2. 在“文件”App 中选择 DEB；
3. 使用“共享”或“打开方式”选择 Sileo；
4. 在 Sileo 中确认安装；
5. 等待 SpringBoard 重载；
6. 使用 SSH 按第4节检查版本和进程。

Sileo 方式操作简单，但不便于在安装前验证手机端 SHA-256，也不便于诊断卡住的 `postinst`，因此正式测试仍推荐 SSH。

## 7. 常见问题

### `Connection refused` 或端口22不通

- 确认手机和电脑在同一局域网；
- 确认 OpenSSH 已安装并运行；
- 确认手机 IP 没有变化；
- 检查防火墙或路由器的客户端隔离设置。

### `Permission denied`

- 确认账号为 `root`；
- 重新输入正确密码；
- 如果使用私钥，确认对应公钥仍在手机 root 用户的 `authorized_keys` 中。

### `REMOTE HOST IDENTIFICATION HAS CHANGED`

这可能是手机重装、SSH 主机密钥更新，也可能是安全风险。先核对新指纹，确认是目标手机后再移除旧记录：

```powershell
ssh-keygen -R 192.168.2.101
```

重新连接时再次核对显示的指纹，不要盲目接受。

### `Another process has locked the database`

说明已有 `dpkg` 或 Sileo 正在操作软件包数据库。等待现有进程结束，不要同时运行多个安装命令。

## 8. 覆盖升级与回退

安装新版本可直接再次执行：

```sh
dpkg -i /var/tmp/vcam.deb
```

安装脚本会覆盖旧版本并重启对应进程。需要回退时，应安装经过保存和校验的旧版 macOS CI DEB，不要使用来源不明或哈希不确定的软件包。

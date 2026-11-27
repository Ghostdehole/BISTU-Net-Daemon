# OpenWrt 校园网认证守护

在校园网接入路由器 WAN 口、还有蜂窝备用出口的场景下，用本人校园账号在指定的校园接口登录。路由器由 procd 管理一个守护进程。安装时只需要电脑可以通过局域网 SSH 连到路由器。

## 为什么同时用接口事件和定时检查

拔插网线、校园接口取得地址时，netifd 会发送事件。守护进程收到匹配接口的事件便重新检查。会话也可能在网线一直连着时过期，所以平时每 180 秒检查一次。稳定在线一天约 480 次轻量探测，旧版每 15 秒探测约 5,760 次。在持续离线时只查本机接口状态，不向门户发请求。可以通过 `INTERVAL` 调整发现静默掉线所需的时间。

默认监听 OpenWrt 的逻辑接口 `wan`，再从它的实时状态读取实际设备和 IPv4 地址。探测和登录都绑定这块设备。校园线接在另一个逻辑接口时，在 `/etc/bistu_auth.conf` 修改 `CAMPUS_INTERFACE` 为校园接口名，再重启守护。检查接口归属可用 `ubus call network.interface.wan status`。应核对其中的 `l3_device` 和 IPv4 地址是否属于校园上联。开启透明代理时，探测网址和校园门户需要按代理软件的配置从校园口直连。

## 从 Windows 安装

1. 在能上网的电脑上下载 [Windows 离线包](https://github.com/Ghostdehole/BISTU-Net-Daemon/releases/download/router-v1.8.0/bistu-auth-windows-1.8.0.zip)，将 ZIP 全部解压到同一文件夹。
2. 若刷机后还要恢复出厂，等最后一次重置完成，先设置新的路由器管理员密码，再把电脑接到 LAN 口。双击 `install-from-windows.cmd`，输入路由器的局域网 IPv4 地址，默认是 `192.168.8.1`。需要 Windows 自带的 OpenSSH 客户端和路由器 LAN 侧 SSH。刷机后若 SSH 报主机密钥改变，先经直连 LAN 核实确实是刚重置的自己的路由器，然后再更新电脑上该地址对应的旧记录。
3. SSH 提示的密码是路由器管理员密码。进入安装程序后，**首次安装**再按提示输入校园账号、密码，输入内容不回显。安装完成后服务将开启并设为开机自动运行。

已有 root 专有配置 `/etc/bistu_auth.conf` 会原样保留，包括已有的登录模式。权限检查失败时，可先自行核对文件确为可信的本人配置，再修正为 root 所有、模式 600。升级固件前请在电脑上保留一份私密副本。不要将填好密码的文件提交到 GitHub。

## 在路由器终端安装

也可以仅下载 [单文件安装脚本](https://github.com/Ghostdehole/BISTU-Net-Daemon/releases/download/router-v1.8.0/bistu-auth-router-1.8.0.sh)，通过局域网传至路由器 `/tmp`。可先在电脑上将 SHA-256 与[发行校验值](https://github.com/Ghostdehole/BISTU-Net-Daemon/releases/download/router-v1.8.0/SHA256SUMS)比对。打开交互式 root SSH 终端，执行：

```sh
sh /tmp/bistu-auth-router-1.8.0.sh
```

若已下载并解压项目源代码，可在项目内运行 `sh router/install.sh`。发布脚本加 `--check` 只检查内嵌文件的 Shell 语法。安装程序会检查依赖、写入范围和服务状态；重复运行可更新程序，原配置保留。

## 检查是否真的连上校园网

```sh
/etc/init.d/bistu-auth status
bistu_auth.sh --status
logread -e bistu_auth
```

第一条检查服务进程。第二条只检查校园出口，绝不提交密码。第三条可查看最近的接口、登录和退避记录。

| 状态 | 含义和处理 |
| --- | --- |
| `ONLINE` | 指定接口收到预期的连通性响应。首次验收可先关闭代理、暂时断开蜂窝备用出口，核对校园线单独能上网。 |
| `NO_INTERFACE` | 检查校园网线、逻辑接口和 IPv4 租约。即使 F50 还能上网，这个状态也符合预期。 |
| `NEED_LOGIN` | 探测收到了已知学校门户的重定向。守护会在允许重试时尝试认证。 |
| `NOT_CAMPUS` 或 `INCONCLUSIVE` | 未识别出学校门户，或探测超时、网页内容不符。守护继续检查，暂不提交凭据。 |

新安装默认 `LOGIN_SCHEME=verified`。只向识别出的校方门户提交本人账号，要求门户域名和 HTTPS 证书校验成功。每轮只使用一种密码表单，默认 `CAMPUS_PASSWORD_FORM=md5`。若校方网页登录明确采用原密码表单，可配置为 `password`，仍须通过同样的 HTTPS 校验。门户返回成功后会再次验证校园线路。临时通信故障按 60 秒起步、逐次加倍至 15 分钟重试。链路抖动不会提前结束退避。门户明确拒绝账号时暂停自动提交，核对账号或处理并发限制后，用 `/etc/init.d/bistu-auth restart` 恢复。

设备时钟错误、门户证书不受信任、学校改用新的门户地址或返回格式时，请在校园线路上使用校方网页登录，再依据错误类型排查。如果更新已有安装，旧配置会保留。`auto`、`http`、`https` 均属于旧模式，其中旧 `https` 会跳过证书校验。干净刷机后直接使用安装程序生成的新配置。

暂停守护可运行 `/etc/init.d/bistu-auth stop`；关闭开机启动可运行 `/etc/init.d/bistu-auth disable`。更新自己的配置后，运行 `/etc/init.d/bistu-auth restart`。

## 构建与验证范围

发布包由本目录源码生成：`python router/package.py dist`。发布资产不会打入本机账号配置。已核对 GL-MT3600BE 4.11.0 beta2-1204 固件中的 procd、shell、curl 和 CA 包，并使用模拟服务与门户做离线检查。实际校园网的策略和本机认证结果需要在校园线路上确认。

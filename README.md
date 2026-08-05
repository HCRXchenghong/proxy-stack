# Proxy Stack

Ubuntu 一键部署六协议安全代理栈：VLESS + REALITY + Vision、Hysteria2、AnyTLS、TUIC v5、NaiveProxy、HTTPS Proxy，以及安全交付页、通用 URI 和 Mihomo/Clash Meta 订阅。

## 功能

- VLESS + REALITY + Vision：TCP 443，经 nginx stream 按 SNI 分流到 Xray。
- Hysteria2：UDP 443，使用 TLS 证书和 salamander obfs。
- AnyTLS：TCP 8443，TLS 1.3、填充和多会话复用。
- TUIC v5：UDP 8443，关闭有重放风险的 0-RTT。
- NaiveProxy：TCP 8444，HTTPS/H2 高隐蔽备用线路。
- HTTPS Proxy：TCP 8445，HTTP CONNECT over TLS 1.3，独立用户名和随机密码。
- 用户交付页：`https://你的域名/web/<slug>?client=<设备令牌>`。
- 订阅输出：通用 base64 URI、原始 URI、Mihomo/Clash Meta YAML。
- 订阅访问控制：每用户独立的 256 位设备令牌或 IP/CIDR 白名单，设备令牌还可继续绑定 IP/CIDR。
- SSH 防爆破：24 小时内失败 3 次封禁 24 小时，累计第 11 次进入永久封禁，并保留长期状态和重犯兜底规则。
- 自动申请 Let's Encrypt 证书，并配置续期后的服务重载。
- 部署完成后自动验证服务，并进入中文管理菜单；后续输入 `seroncheng` 即可唤起菜单。
- 支持脚本版本检测和一键更新：优先读取 GitHub Release，没有 Release 时读取最新 Tag；更新时保留现有用户、REALITY/Hysteria2 密钥和证书配置。
- 安装、更新和续签测试使用步骤进度条；详细命令日志写入 `/var/log/proxy-stack.log`，避免终端滚屏。
- 用户管理：新增、批量新增、禁用、启用、删除、导出。
- 安全默认值：公网只能使用高熵 slug、禁用用户立即失效、客户端不开放 LAN、服务降权运行、阻断私网/环回/云元数据、二进制固定版本和 SHA-256。
- 安全下载与解压：远程项目包强制要求可信 SHA-256；所有 tar/zip 只允许普通文件和目录，并拒绝路径穿越、链接、设备文件、重复路径、特殊权限和解压炸弹。
- Web 抗扫描：真实来源 IP 经 PROXY protocol 传递，按公网 IP 限速/限连接；应用限制 URI、查询字段、请求体和线程数，并使用 nonce CSP。

完整复核范围、已修复问题、验证证据和仍不可消除的风险见 [安全审计报告](SECURITY_AUDIT.md)。

## 1.x 与 2.0 的主要区别

2.0 是安全架构升级，不是只增加三条协议。远端仓库的 1.x 最终版本为 `v1.0.1`，2.0 的关键变化如下：

| 项目 | 1.x | 2.0 |
| --- | --- | --- |
| 代理协议 | VLESS + REALITY + Vision、Hysteria2 | 保留原两种，新增 AnyTLS、TUIC v5、NaiveProxy、HTTPS Proxy，共六路 |
| 管理入口 | 独立 `MANAGEMENT_DOMAIN` 公网反代到本机面板 | 删除公网管理面，只允许经 SSH 运行 `seroncheng` |
| 订阅身份 | 用户名或较短 slug 即可访问 | 只查找高熵 slug，还必须通过独立设备令牌或 IP/CIDR 白名单 |
| 设备控制 | 无 | 每台设备一枚可撤销的 256 位令牌，令牌可继续绑定 IP/CIDR |
| 运行权限 | Xray、Hysteria2 和交付程序未显式降权，默认以 root 运行 | Web、Xray、Hysteria2、sing-box 使用四个独立无登录账号，并启用 systemd 沙箱 |
| 私钥隔离 | Web 服务读取包含协议私钥的整个配置 | Web 只读取专用配置；REALITY 私钥只给 Xray，TLS 私钥副本只给专用证书组 |
| 出站边界 | 无统一的私网/元数据阻断 | 六路协议统一阻断环回、私网、链路本地和云元数据地址 |
| 依赖下载 | 从最新 Release 动态下载，未固定文件哈希 | 固定 Xray、Hysteria2、sing-box 版本和 SHA-256，校验失败立即终止 |
| 项目更新 | 下载远程 tarball 后直接覆盖 | 必须预先提供可信 SHA-256；安全解压会拒绝路径穿越、链接、特殊文件和解压炸弹 |
| SSH 防护 | 未由项目统一管理 | 3 次失败封 24 小时，长期累计第 11 次永久封禁，再加重犯永久封禁 |
| 管理菜单 | 基础用户、证书和更新操作 | 全中文主菜单，新增订阅访问控制和 SSH 安全防护子菜单 |

### 2.0 不兼容变化

- 首次从 1.x 迁移时会轮换旧 slug、VLESS UUID、Hysteria2 用户密码、Hysteria2 混淆密钥和 REALITY 密钥/short ID。旧订阅与节点链接会失效。
- 新订阅默认需要 `?client=<设备令牌>`；只有来源 IP 命中用户白名单时才可以不携带令牌。
- `MANAGEMENT_DOMAIN` 只保留参数兼容，2.0 不会为它签证书、开放 nginx 路由或启用公网面板。
- 新增 TCP 8443、UDP 8443、TCP 8444 和 TCP 8445；如果要使用全部六路协议，必须同步修改云安全组和主机防火墙。
- Fail2ban 默认只豁免回环地址，管理员自己的公网 IP 也会受 SSH 失败计数规则约束。

## 系统要求

- Ubuntu 22.04/24.04，x86_64。
- root 或 sudo 权限。
- 域名 DNS 已解析到服务器公网 IP。
- 当前交付配置为 IPv4-only；域名不能保留指向其他主机的 AAAA 记录。
- 防火墙/安全组放行：
  - TCP 80：Let's Encrypt HTTP-01 验证。
  - TCP 443：VLESS REALITY 与短链接/订阅域名 SNI 分流。
  - UDP 443：Hysteria2。
  - TCP 8443：AnyTLS。
  - UDP 8443：TUIC v5。
  - TCP 8444：NaiveProxy。
  - TCP 8445：HTTPS Proxy。
  - TCP SSH 端口：远程管理，由 Fail2ban 保护。
- 如果域名使用 Cloudflare，请使用 DNS only，不要开启代理云朵。

只需要一个域名：

- `WEB_DOMAIN`：用户交付页和订阅域名，例如 `node.example.com`。
管理操作不使用公网域名，只能经 SSH 执行 `seroncheng`。旧版 `MANAGEMENT_DOMAIN` 参数仍可传入以兼容自动化，但 2.0 不会为它签发证书或配置公网入口。

## 一键部署

最高安全模式建议先克隆或上传完整项目、审阅内容后再执行本地脚本，避免把网络响应直接管道给 root：

```bash
sudo bash deploy.sh \
  --web-domain node.你的真实域名.com \
  --cert-email admin@你的真实域名.com
```

脚本会用中文提示依次输入：

- 用户交付页/订阅域名，例如 `node.你的真实域名.com`。
- Let's Encrypt 真实邮箱。

只有在确认信任仓库和当前分支时，才使用远程引导脚本；先保存、审阅，再用 sudo 执行：

```bash
curl -fsSLo /tmp/proxy-stack-deploy.sh \
  https://raw.githubusercontent.com/HCRXchenghong/proxy-stack/main/deploy.sh
less /tmp/proxy-stack-deploy.sh
sudo bash /tmp/proxy-stack-deploy.sh \
  --tarball-url https://github.com/HCRXchenghong/proxy-stack/archive/refs/tags/<已审阅的版本标签>.tar.gz \
  --tarball-sha256 <从独立可信渠道核对的64位SHA256> \
  --web-domain node.你的真实域名.com \
  --cert-email admin@你的真实域名.com
```

远程引导部署强制要求 `--tarball-sha256`。这个值必须从发布者签名公告、已核对的发布记录或其他独立可信渠道取得；只下载归档后立刻对同一份未知文件计算哈希，不能证明归档可信。本地项目部署不需要该参数。

脚本会在安装前检查：

- 用户域名格式正确，且不是 `example.com`、`your-domain.com`、`localhost`、`.test` 等保留/示例域名。
- 证书邮箱格式正确，且不是示例邮箱。
- 自动申请证书时，用户域名的 IPv4 A 记录已解析到本机公网 IP。

脚本的交互提示、错误提示和帮助信息均为中文。完全非交互环境请显式传入 `--web-domain` 和 `--cert-email`。

脚本会把项目下载到 `/root/proxy-stack`，安装依赖，下载并校验固定版本的 Xray、Hysteria2 和 sing-box，申请证书，写入 nginx/systemd 配置并启动服务。安装过程只显示关键步骤进度条，详细输出会写入 `/var/log/proxy-stack.log`。部署完成后会验证 Xray、sing-box 配置和全部服务状态。

可选参数：

```bash
--public-ip <ip>                 手动指定公网 IP，默认自动探测
--reality-target <host:port>     REALITY 伪装目标，默认 www.amazon.com:443
--reality-sni <host>             REALITY SNI，默认 www.amazon.com
--tls-cert-file <path>           使用已有 TLS fullchain
--tls-key-file <path>            使用已有 TLS 私钥
--install-dir <path>             安装目录，默认 /root/proxy-stack
--branch <name>                  远程引导部署使用的 Git 分支，默认 main
--tarball-url <https-url>        指定远程项目归档；建议固定到不可变版本标签
--tarball-sha256 <sha256>        远程项目归档的可信 SHA-256（强制）
-y, --yes                        跳过交互确认
```

`--reality-target` 的主机名必须与 `--reality-sni` 一致。生产环境建议主动选择从服务器网络稳定可达、支持 TLS 1.3 的真实站点，不要让所有节点长期共用默认目标。

## 安装后验证

部署脚本会自动执行验证。后续也可以手动执行：

```bash
sudo bash /root/proxy-stack/proxy-stack.sh verify
seroncheng
```

打开管理菜单：

```bash
seroncheng
```

检测脚本更新：

```bash
sudo bash /root/proxy-stack/proxy-stack.sh check-update
```

安全更新需要先从可信发布渠道取得目标 tarball 的 SHA-256；没有校验值时脚本会拒绝覆盖当前安装：

```bash
sudo PROXY_STACK_UPDATE_SHA256=<64位SHA256> \
  bash /root/proxy-stack/proxy-stack.sh update
```

当前项目版本：`2.1.0`。它在 `2.0.1` 的安全加固基础上新增 HTTPS Proxy，并延续安全解压、真实来源 IP、DNS 重绑定/SSRF 防护、Web 资源限制、原子状态写入和更严格的服务沙箱。版本检测规则为：优先读取 GitHub 最新 Release；如果没有 Release，则读取最新 Tag。菜单中的更新操作也必须提供可信 SHA-256 环境变量。

安装目录会被规范化并限制在专用子目录内；拒绝 `/`、系统顶层目录、符号链接、非 root 所有或组/其他用户可写的既有目录，避免 root 部署时误覆盖系统文件。

主要运行文件：

```text
/root/proxy-stack                 项目脚本
/etc/proxy-stack/stack.env        部署配置和 REALITY/HY2 密钥
/etc/proxy-stack/public.env       Web 服务配置和内部代理令牌（仅 Web 服务组可读）
/etc/proxy-stack/users.json       用户列表
/etc/proxy-stack/sing-box.json    AnyTLS/TUIC/Naive/HTTPS Proxy 服务配置
/opt/proxy-stack                  运行时文件和二进制
/etc/nginx/conf.d/proxy-stack-*.conf
/etc/nginx/stream-conf.d/proxy-stack-stream.conf
/etc/systemd/system/proxy-stack-*.service
/etc/fail2ban/jail.d/proxy-stack-sshd.local
/usr/local/bin/seroncheng         中文管理菜单入口
/var/log/proxy-stack.log          安装、更新和续签测试详细日志
```

## 用户管理

新增用户：

```bash
sudo bash /root/proxy-stack/proxy-stack.sh user add alice
```

输出里会包含中文字段：

- 交付页面：用户打开后可复制各类链接。
- 通用订阅：适合 v2rayN、v2rayNG、V2Box、Shadowrocket 等 URI 客户端。
- Mihomo配置：适合 Mihomo / Clash Meta。
- 原始节点：未 base64 的全部节点 URI。
- VLESS / Hysteria2 / AnyTLS / TUIC / NaiveProxy / HTTPS Proxy：六条独立节点链接。
- Mihomo 原生提供 VLESS、Hysteria2、AnyTLS、TUIC 和 HTTPS Proxy；NaiveProxy 链接供 NaiveProxy、v2rayN 等兼容客户端单独导入。

常用命令：

```bash
sudo bash /root/proxy-stack/proxy-stack.sh user list
sudo bash /root/proxy-stack/proxy-stack.sh user show alice
sudo bash /root/proxy-stack/proxy-stack.sh user share alice
sudo bash /root/proxy-stack/proxy-stack.sh user batch-add user 20
sudo bash /root/proxy-stack/proxy-stack.sh user disable alice
sudo bash /root/proxy-stack/proxy-stack.sh user enable alice
sudo bash /root/proxy-stack/proxy-stack.sh user del alice
sudo bash /root/proxy-stack/proxy-stack.sh user export csv /root/proxy-stack-users.csv
```

导出文件包含完整节点凭据，只允许写入 `/root`、`/home/<用户>` 或 `/var/backups` 的专用子目录，扩展名必须与格式匹配；脚本拒绝符号链接并使用 `0600` 原子写入，避免误覆盖系统文件。

订阅默认不再只依赖 slug。每个新用户都会自动生成一个 `default` 设备令牌，`user show`、`user share` 和导出文件会自动带上它。管理额外设备与 IP 白名单：

```bash
# 查看当前允许的设备、令牌和 IP/CIDR
sudo bash /root/proxy-stack/proxy-stack.sh user access alice

# 新增/撤销一台设备
sudo bash /root/proxy-stack/proxy-stack.sh user client-add alice phone
sudo bash /root/proxy-stack/proxy-stack.sh user client-del alice phone

# 最高安全模式：新设备令牌只允许从指定网段使用
sudo bash /root/proxy-stack/proxy-stack.sh user client-add alice office 203.0.113.8/32
sudo bash /root/proxy-stack/proxy-stack.sh user client-allow-ip alice office 2001:db8:1234::/48
sudo bash /root/proxy-stack/proxy-stack.sh user client-deny-ip alice office 2001:db8:1234::/48

# 不携带设备令牌时，只允许这个固定出口访问该用户订阅
sudo bash /root/proxy-stack/proxy-stack.sh user allow-ip alice 203.0.113.8/32
sudo bash /root/proxy-stack/proxy-stack.sh user deny-ip alice 203.0.113.8/32
```

这里的“允许客户端”指被管理员发放了独立令牌的设备，不依赖可伪造的 User-Agent。令牌仍是 bearer secret；如果被复制，持有者可以冒用，因此最高安全用法是“每台设备一枚令牌 + 设备 IP/CIDR 绑定”。撤销设备后立即失效，无需重启代理服务。鉴权失败统一返回 404，nginx 访问日志不记录 URL，页面也禁止 Referrer 外传。

TCP 443 的外层 stream 分流通过 PROXY protocol 把真实来源地址传给内层 HTTPS，Xray 同步显式接收该协议。因此 IP/CIDR 白名单、访问日志和 nginx 限速使用的是实际公网来源 IP，不会把所有用户错误识别成 `127.0.0.1`。

`user list` 输出三列：用户名、slug、状态。状态会显示为 `启用` 或 `禁用`。

修改 `/etc/proxy-stack/stack.env` 或手动调整用户文件后，重新渲染并重启：

```bash
sudo bash /root/proxy-stack/proxy-stack.sh render
sudo systemctl restart proxy-stack-xray proxy-stack-hysteria proxy-stack-sing-box proxy-stack-web nginx
```

也可以直接输入 `seroncheng`。主菜单及两个安全子菜单全部使用中文：

- `16) 订阅访问控制`：查看用户权限、新增/撤销设备、绑定/解除设备 IP/CIDR、管理用户 IP 白名单、查看安全订阅地址和分享信息。
- `17) SSH 安全防护`：用中文查看三级计数与封禁 IP、手动永久封禁、从全部规则解封，或重新应用最高安全配置。

菜单中的删除用户、撤销设备、永久封禁和重写 SSH 安全配置均需要输入中文“确认”，以避免误操作。

## SSL 自动续签

脚本使用系统 Certbot 自动续签机制，并显式启用 `certbot.timer`。证书续签成功后会执行：

```text
/etc/letsencrypt/renewal-hooks/deploy/proxy-stack-reload.sh
```

该 hook 会把新证书安全复制给非 root 代理服务、reload nginx，并重启 Hysteria2 和 sing-box。

```bash
systemctl is-active certbot.timer
systemctl is-enabled certbot.timer
sudo certbot renew --dry-run
```

## 订阅地址格式

假设新增用户后 slug 为 `AbCdEfGhIjKlMnOpQrStUvWxYz012345`：

```text
https://node.example.com/web/AbCdEfGhIjKlMnOpQrStUvWxYz012345?client=<token>      用户交付页
https://node.example.com/link/AbCdEfGhIjKlMnOpQrStUvWxYz012345?client=<token>     通用 base64 URI 订阅
https://node.example.com/mihomo/AbCdEfGhIjKlMnOpQrStUvWxYz012345?client=<token>   Mihomo/Clash Meta YAML
https://node.example.com/node/AbCdEfGhIjKlMnOpQrStUvWxYz012345?client=<token>     原始节点 URI
```

## SSH 分级封禁

Fail2ban 由项目自动安装和启用，并同时监控三条规则：

- `proxy-stack-sshd-day`：24 小时内认证失败 3 次，封禁 24 小时。
- `proxy-stack-sshd-permanent`：长期窗口内第 11 次失败，永久封禁。
- `proxy-stack-recidive`：累计 4 次临时封禁后永久封禁，用作服务重启后的长期重犯兜底。Fail2ban 数据库与记录保留窗口为 10 年。

```bash
sudo bash /root/proxy-stack/proxy-stack.sh security status
sudo bash /root/proxy-stack/proxy-stack.sh security ban 198.51.100.8
sudo bash /root/proxy-stack/proxy-stack.sh security unban 198.51.100.8
```

默认只豁免本机回环地址，管理员公网 IP 也会受规则约束。连续输错 SSH 凭据前，应确认云厂商控制台、VNC/串口或救援模式可用；被误封时从这些带外通道执行 `security unban <IP>`。

## 端口和分流

- TCP 443 由 nginx stream 接收。
- SNI 等于 `WEB_DOMAIN` 时转发到本机 HTTPS 交付站点。
- 其他 SNI 默认转发到 Xray REALITY 入站。
- UDP 443 由 Hysteria2 直接监听。
- TCP/UDP 8443 分别由 AnyTLS、TUIC v5 监听；TCP 8444 由 NaiveProxy 监听；TCP 8445 由 HTTPS Proxy 监听。

## 从 1.x 升级到 2.0

升级会轮换多项凭据并让旧链接失效。务必先确认云厂商控制台、VNC/串口或救援模式可用，不要在唯一一条未验证的 SSH 会话中盲目升级。

1. 备份 1.x 配置和项目目录：

   ```bash
   sudo cp -a /etc/proxy-stack /root/proxy-stack-state-v1-backup
   sudo cp -a /root/proxy-stack /root/proxy-stack-code-v1-backup
   ```

2. 检查云安全组/防火墙，在原 TCP/UDP 443 基础上放行 TCP 8443、UDP 8443、TCP 8444 和 TCP 8445。
3. 从 GitHub 取得并审阅最新的 `v2.1.0` 标签代码，再使用原来的真实 `WEB_DOMAIN`、证书邮箱或现有证书路径执行 `deploy.sh`。不要把未审阅的网络响应直接管道给 root shell。
4. 首次 `render` 会把 `users.json` 升级到新结构，完成安全凭据轮换，为每个现有用户创建 `default` 设备令牌，并生成 AnyTLS、TUIC、NaiveProxy 和 HTTPS Proxy 凭据。这个迁移只会针对旧结构执行一次。
5. 升级后立即重新导出并分发用户链接：

   ```bash
   sudo bash /root/proxy-stack/proxy-stack.sh user list
   sudo bash /root/proxy-stack/proxy-stack.sh user share <用户名>
   ```

6. 执行完整验证，确认 SSH 封禁状态，再结束旧会话：

   ```bash
   sudo bash /root/proxy-stack/proxy-stack.sh verify
   sudo bash /root/proxy-stack/proxy-stack.sh security status
   ```

如果升级失败，使用带外控制台登录，先保留日志和当前现场，再从上述两个备份目录恢复。

六种协议位于同一台服务器时仍共享同一个封锁故障域。生产环境建议把同一份项目部署到至少两台不同供应商、不同 ASN 的服务器；交付站不要与所有代理节点共用一个源站 IP。

运行时使用四个独立的无登录系统账号：`proxy-stack-web`、`proxy-stack-xray`、`proxy-stack-hysteria`、`proxy-stack-sing-box`。REALITY 私钥只授予 Xray，TLS 私钥副本只授予 Hysteria2/sing-box 的专用证书组；任一服务不再以 root 运行。

## 旧 3x-ui 清理

如果服务器之前装过 3x-ui，可以执行：

```bash
sudo bash /root/proxy-stack/proxy-stack.sh uninstall-3xui
```

这只清理旧 3x-ui 相关文件，不会卸载 Proxy Stack。

## 故障排查

查看服务日志：

```bash
tail -n 80 /var/log/proxy-stack.log
journalctl -u proxy-stack-xray -e --no-pager
journalctl -u proxy-stack-hysteria -e --no-pager
journalctl -u proxy-stack-sing-box -e --no-pager
journalctl -u proxy-stack-web -e --no-pager
journalctl -u nginx -e --no-pager
```

检查 nginx 配置：

```bash
sudo nginx -t
```

常见问题：

- 证书申请失败：确认用户域名解析到本机公网 IPv4，TCP 80 已放行，Cloudflare 为 DNS only，邮箱不是 `admin@example.com` 这类示例邮箱。
- 页面打不开：确认 TCP 443 已放行，`nginx -t` 通过，`proxy-stack-web` 正常运行。
- Hysteria2 不通：确认 UDP 443 已放行，并检查云厂商安全组。
- AnyTLS/TUIC/NaiveProxy/HTTPS Proxy 不通：分别确认 TCP 8443、UDP 8443、TCP 8444、TCP 8445 已放行。
- VLESS 不通：确认客户端使用 REALITY public key、short id、SNI 和 Vision flow。
- REALITY 拒绝握手：确认服务器和客户端时间准确；安全配置只允许约 60 秒时钟偏差。

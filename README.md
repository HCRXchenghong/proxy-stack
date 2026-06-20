# Proxy Stack

Ubuntu 一键部署 VLESS + REALITY + Vision、Hysteria2、短链接交付页、通用 URI 订阅和 Mihomo/Clash Meta 订阅。

## 功能

- VLESS + REALITY + Vision：TCP 443，经 nginx stream 按 SNI 分流到 Xray。
- Hysteria2：UDP 443，使用 TLS 证书和 salamander obfs。
- 用户短链接页：`https://你的域名/u/<slug>`。
- 订阅输出：通用 base64 URI、原始 URI、Mihomo/Clash Meta YAML。
- 自动申请 Let's Encrypt 证书，并配置续期后的服务重载。
- 用户管理：新增、批量新增、禁用、启用、删除、导出。

## 系统要求

- Ubuntu 22.04/24.04，x86_64。
- root 或 sudo 权限。
- 域名 DNS 已解析到服务器公网 IP。
- 防火墙/安全组放行：
  - TCP 80：Let's Encrypt HTTP-01 验证。
  - TCP 443：VLESS REALITY、短链接页面、订阅、管理域名 SNI 分流。
  - UDP 443：Hysteria2。
- 如果域名使用 Cloudflare，请使用 DNS only，不要开启代理云朵。

需要两个域名：

- `WEB_DOMAIN`：用户短链接页和订阅域名，例如 `sub.example.com`。
- `MANAGEMENT_DOMAIN`：管理域名，会被 nginx 转发到本机 `127.0.0.1:8317`。如果暂时不用管理面板，也建议准备一个独立子域名用于证书和 SNI 分流。

## 一键部署

在服务器上执行：

```bash
curl -fsSL https://raw.githubusercontent.com/HCRXchenghong/proxy-stack/main/deploy.sh \
  | sudo bash -s -- \
    --web-domain sub.example.com \
    --management-domain panel.example.com \
    --cert-email admin@example.com
```

脚本会把项目下载到 `/root/proxy-stack`，安装依赖，下载 Xray 和 Hysteria2，申请证书，写入 nginx/systemd 配置并启动服务。

也可以先克隆/上传项目后本地部署：

```bash
sudo bash deploy.sh \
  --web-domain sub.example.com \
  --management-domain panel.example.com \
  --cert-email admin@example.com
```

可选参数：

```bash
--public-ip <ip>                 手动指定公网 IP，默认自动探测
--reality-target <host:port>     REALITY 伪装目标，默认 www.amazon.com:443
--reality-sni <host>             REALITY SNI，默认 www.amazon.com
--tls-cert-file <path>           使用已有 TLS fullchain
--tls-key-file <path>            使用已有 TLS 私钥
--install-dir <path>             安装目录，默认 /root/proxy-stack
--branch <name>                  curl 管道部署时使用的 Git 分支，默认 main
-y, --yes                        跳过交互确认
```

## 安装后验证

```bash
sudo bash /root/proxy-stack/proxy-stack.sh verify
systemctl status proxy-stack-xray proxy-stack-hysteria proxy-stack-web nginx
```

主要运行文件：

```text
/root/proxy-stack                 项目脚本
/etc/proxy-stack/stack.env        部署配置和 REALITY/HY2 密钥
/etc/proxy-stack/users.json       用户列表
/opt/proxy-stack                  运行时文件和二进制
/etc/nginx/conf.d/proxy-stack-*.conf
/etc/nginx/stream-conf.d/proxy-stack-stream.conf
/etc/systemd/system/proxy-stack-*.service
```

## 用户管理

新增用户：

```bash
sudo bash /root/proxy-stack/proxy-stack.sh user add alice
```

输出里会包含：

- `PAGE`：用户交付页。
- `SUB`：通用订阅，适合 v2rayN、v2rayNG、V2Box、Shadowrocket 等 URI 客户端。
- `CLASH`：Mihomo/Clash Meta YAML 订阅。
- `RAW`：未 base64 的原始 URI。
- `VLESS` / `HY2`：单节点链接。

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

修改 `/etc/proxy-stack/stack.env` 或手动调整用户文件后，重新渲染并重启：

```bash
sudo bash /root/proxy-stack/proxy-stack.sh render
sudo systemctl restart proxy-stack-xray proxy-stack-hysteria proxy-stack-web nginx
```

## 订阅地址格式

假设新增用户后 slug 为 `AbCd123456`：

```text
https://sub.example.com/u/AbCd123456       用户交付页
https://sub.example.com/sub/AbCd123456     通用 base64 URI 订阅
https://sub.example.com/raw/AbCd123456     原始 URI
https://sub.example.com/clash/AbCd123456   Mihomo/Clash Meta YAML
```

## 端口和分流

- TCP 443 由 nginx stream 接收。
- SNI 等于 `WEB_DOMAIN` 时转发到本机 HTTPS 交付站点。
- SNI 等于 `MANAGEMENT_DOMAIN` 时转发到 `127.0.0.1:8317`。
- 其他 SNI 默认转发到 Xray REALITY 入站。
- UDP 443 由 Hysteria2 直接监听。

## 旧 3x-ui 清理

如果服务器之前装过 3x-ui，可以执行：

```bash
sudo bash /root/proxy-stack/proxy-stack.sh uninstall-3xui
```

这只清理旧 3x-ui 相关文件，不会卸载 Proxy Stack。

## 故障排查

查看服务日志：

```bash
journalctl -u proxy-stack-xray -e --no-pager
journalctl -u proxy-stack-hysteria -e --no-pager
journalctl -u proxy-stack-web -e --no-pager
journalctl -u nginx -e --no-pager
```

检查 nginx 配置：

```bash
sudo nginx -t
```

常见问题：

- 证书申请失败：确认两个域名都解析到本机，TCP 80 已放行，Cloudflare 为 DNS only。
- 页面打不开：确认 TCP 443 已放行，`nginx -t` 通过，`proxy-stack-web` 正常运行。
- Hysteria2 不通：确认 UDP 443 已放行，并检查云厂商安全组。
- VLESS 不通：确认客户端使用 REALITY public key、short id、SNI 和 Vision flow。

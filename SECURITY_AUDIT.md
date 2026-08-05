# Proxy Stack 2.0 安全审计报告

审计日期：2026-08-05

对应版本：2.1.0

审计对象：当前工作区全部项目文件（不含 Git 内部对象和测试生成缓存）

结论：已修复本轮确认的高、中风险缺口；未发现仍未处理的已知严重命令注入、目录穿越、公开管理面、弱口令或未鉴权订阅入口。

## 1. 结论边界

本报告不能承诺系统永远不会被攻破。零日漏洞、代理内核或系统组件供应链事件、云厂商控制面失陷、超大流量 DDoS、root 凭据泄露，以及运营商主动识别/封锁都不能仅靠本项目代码彻底消除。

本轮目标是清除普通扫描器、自动爆破脚本和低成本攻击者最容易利用的问题，并让所有危险输入默认拒绝。修复后，常见攻击面具备以下边界：

- 公网没有 Web 管理面，管理操作只经 SSH。
- 订阅必须满足“有效独立设备令牌”或“来源 IP/CIDR 白名单”；失败统一返回 404。
- SSH 在 24 小时内失败 3 次封 24 小时，长期累计第 11 次永久封禁，并有重犯永久封禁兜底。
- 项目和代理内核下载强制 HTTPS；项目远程部署/更新还必须提供可信 SHA-256。
- tar/zip 解压拒绝路径穿越、绝对路径、符号链接、硬链接、设备/FIFO、重复路径、特殊权限和超限归档。
- Web、Xray、Hysteria2、sing-box 分别使用独立无登录账号，并启用 systemd 沙箱。

## 2. 审计范围

逐项检查了：

- `app.py`：订阅路由、Hysteria2 HTTP 鉴权、来源 IP 信任链、HTML/YAML/URI 输出、HTTP 资源限制。
- `deploy.sh`：root 部署入口、参数校验、安装目录、远程下载、归档解压和代码执行边界。
- `lib/common.sh`：权限、状态目录、随机凭据、下载、安全解压、DNS 和 nginx 公共操作。
- `lib/render.sh`：Xray/Hysteria2/sing-box、nginx、systemd、Fail2ban、证书续签和用户迁移配置。
- `proxy-stack.sh`：安装、更新、菜单、用户/设备/IP 管理、导出、SSH 封禁和旧组件清理。
- `tests/test_app.py`：安全回归覆盖。
- `README.md`、`VERSION`、`.gitignore`：部署说明、版本边界和敏感文件误提交风险。

检查方法包括逐行人工审计、危险模式检索、Bash/Python 语法检查、ShellCheck、恶意归档测试、本地 HTTP 鉴权测试和上游发布摘要核对。

## 3. 本轮确认并修复的问题

| 编号 | 原风险 | 等级 | 修复结果 |
| --- | --- | --- | --- |
| PS-01 | 项目更新和 sing-box 归档直接解压，恶意成员可尝试路径穿越、链接覆盖或解压炸弹 | 高 | 改为白名单式安全解压，只创建普通文件/目录，并限制 10,000 个成员、单文件 256 MiB、总解压 512 MiB |
| PS-02 | 远程引导部署没有强制项目归档哈希，下载后会以 root 执行 | 高 | 远程模式强制 `--tarball-sha256`/`PROXY_STACK_TARBALL_SHA256`，不提供或不匹配立即退出 |
| PS-03 | TCP 443 经 stream 转发后，内层 HTTPS 会把来源错误识别为 `127.0.0.1`，IP 白名单和限速失真 | 高 | stream 启用 PROXY protocol；内层 HTTPS 恢复真实 IP；Xray 显式启用 `acceptProxyProtocol` |
| PS-04 | `--install-dir` 只要求绝对路径，误传 `/` 或危险/可写目录可能造成 root 覆盖 | 高 | 规范化路径，限制到专用子目录，拒绝符号链接、非 root 所有和组/其他用户可写目录 |
| PS-05 | 多个用户管理操作原地写 `users.json`，中断时可能留下半写文件 | 中 | 改为同目录临时文件、flush、fsync、权限收紧和 `os.replace` 原子替换 |
| PS-06 | Web 请求目标和查询字段缺少应用层小尺寸上限，错误页会暴露 Python server banner | 中 | URI 4 KiB、查询 1 KiB、字段数和令牌长度设限；线程池降至 32、套接字超时 10 秒；移除 Server banner |
| PS-07 | 页面 CSP 使用 `unsafe-inline` | 中 | 页面每次响应生成高熵 nonce，只允许带 nonce 的内联 CSS/JS；禁止默认资源、表单、对象和框架嵌入 |
| PS-08 | YAML 中部分动态字符串没有统一安全标量编码 | 中 | 所有动态字符串使用 JSON 字符串形式输出，作为合法 YAML 标量，阻断换行/引号注入 |
| PS-09 | systemd 沙箱仍可进一步缩小内核、命名空间和进程可见面 | 中 | 四个服务加入内核日志/时钟/主机名保护、隐藏其他用户进程、禁用命名空间、W+X 内存和实时调度等限制 |
| PS-10 | 批量创建用户没有明确数量上限 | 中 | 单次限制 1–1000 个，并限制起始序号和最终用户名长度 |
| PS-11 | 下载参数不统一，部分调用没有明确 TLS 最低版本、重试、超时和大小上限 | 中 | 外部下载统一要求 HTTPS/TLS 1.2+，仅允许 HTTPS 重定向，并设置连接/总超时、有限重试和 512 MiB 下载上限 |
| PS-12 | 运行时公开配置若被误写入控制字符，可能污染输出配置 | 中 | Web 启动前验证 IPv4、域名、端口、REALITY 字段、内部令牌长度和控制字符，异常时拒绝启动 |
| PS-13 | HTTP→HTTPS 重定向可能继承默认访问日志并记录查询令牌；导出路径可误覆盖任意 root 文件 | 中 | HTTP/HTTPS 均使用不含 URL 的安全日志；导出限制到专用目录、拒绝链接并以 `0600` 原子替换 |
| PS-14 | OpenSSL 生成 32 字节内部令牌时保留 Base64 `=` 填充，与 URL-safe 校验规则不一致 | 中 | 统一删除换行和 `=` 填充；已有不合规内部令牌在下次渲染时自动轮换 |
| PS-15 | sing-box 的 IP 规则不会自动解析域名，恶意域名可在最终直连阶段解析到私网/元数据地址并绕过阻断 | 高 | 路由第一步强制使用本地解析器解析，随后对全部结果执行私网和特殊 CIDR 拒绝，关闭 DNS 重绑定绕过 |

## 4. 已验证的既有安全控制

- 六种协议使用独立用户凭据；HTTPS Proxy 使用 TLS 1.3；TUIC 0-RTT 已关闭。
- 公网用户查询只接受 24–64 位高熵 slug，不接受用户名。
- 设备令牌使用常量时间比较，可单独撤销并可绑定 IP/CIDR。
- `X-Real-IP` 只有在 Nginx 提供正确内部高熵令牌时才被应用信任。
- Nginx 日志格式不记录 URL/查询令牌，页面设置 `Referrer-Policy: no-referrer`。
- Mihomo 配置固定 `allow-lan: false`。
- Xray、Hysteria2、sing-box 统一阻断私网、回环、链路本地、测试网段和云元数据方向。
- sing-box 在 CIDR 判断前显式解析域名，IP 规则覆盖域名形式的私网和云元数据目标。
- REALITY 私钥只进入 Xray 配置；TLS 私钥副本只给专用 TLS 组；Web 不读取 `stack.env` 私钥文件。
- Fail2ban 长期数据库保留 10 年，临时、累计永久和 recidive 三条规则同时启用。
- 更新包没有可信 SHA-256 时拒绝覆盖当前安装。
- nginx 全站按真实来源 IP 设置 5 请求/秒、burst 10、最多 10 个并发连接，并限制请求头/请求体超时和尺寸。

## 5. 固定依赖核对

2026-07-24 通过 GitHub 官方 Release API 的资产 `digest` 字段核对：

| 组件 | 版本/资产 | 项目固定 SHA-256 | 结果 |
| --- | --- | --- | --- |
| Xray | `v26.3.27 / Xray-linux-64.zip` | `23cd9af937744d97776ee35ecad4972cf4b2109d1e0fe6be9930467608f7c8ae` | 一致 |
| Hysteria2 | `app/v2.10.0 / hysteria-linux-amd64` | `04f7804159ef1d798de12a817d73aab4b9040ebe45fc62e223000c5c59e987fe` | 一致 |
| sing-box | `v1.13.14 / sing-box-1.13.14-linux-amd64.tar.gz` | `f48703461a15476951ac4967cdad339d986f4b8096b4eb3ff0829a500502d697` | 一致 |

哈希一致只证明项目固定值与当时上游发布资产一致，不等于上游代码本身永远没有漏洞。仍应持续关注三个项目的安全公告。

同时复核了对应官方源码语义：Xray 的 `acceptProxyProtocol` 配置字段会启用入站 PROXY protocol；Hysteria2 在启用 ACL 时会让域名解析结果进入 ACL/CIDR 判断；sing-box 的 `ip_is_private`/`ip_cidr` 不会替未解析域名自动做解析，因此本轮加入的显式 `resolve` 规则是必要控制。

## 6. 自动验证结果

已通过：

```text
bash -n deploy.sh lib/common.sh lib/render.sh proxy-stack.sh
python3 -m py_compile app.py tests/test_app.py
python3 -m unittest discover -s tests -v
```

当前工作区未安装 ShellCheck，且该目录不是 Git 仓库；本轮未重新执行 ShellCheck 和 `git diff --check`。

单元测试覆盖 24 项，包括：

- 六协议链接与 Mihomo 禁止 LAN。
- 用户名不可作为公网订阅键。
- 无令牌、错误令牌、非 ASCII 令牌、冲突令牌拒绝。
- 伪造 `X-Real-IP` 拒绝，正确内部令牌和白名单接受。
- 设备令牌绑定 IP。
- Hysteria2 错误认证拒绝。
- 破损/超大用户数据库 fail-closed。
- 超长请求拒绝、Server banner 隐藏、nonce CSP 生效。
- 四服务非 root 和增强 systemd 沙箱。
- Fail2ban 3 次临时封禁、第 11 次永久封禁。
- 中文菜单包含订阅访问控制和 SSH 安全功能。
- tar 路径穿越、tar/zip 符号链接归档拒绝。
- 远程引导必须哈希并使用 HTTPS 安全解压。
- 敏感导出路径限制、链接拒绝和原子写入。

## 7. 仍然存在、无法仅靠代码消除的风险

1. 六路协议若部署在同一台服务器、同一公网 IP，仍共享封锁、DDoS、供应商停机和主机失陷故障域。真正的高可用至少需要两台不同供应商、不同 ASN 的服务器。
2. 设备令牌是 bearer secret。URL 可能进入客户端本地历史、剪贴板或第三方软件日志；最高安全用法仍是“一设备一令牌 + 固定出口 IP/CIDR”，泄露后立即撤销并重新签发。
3. Web 服务为了生成订阅，必须读取所有用户的协议凭据。systemd 和文件权限能限制横向移动，但 Web 进程本身若出现远程代码执行，仍可能读取这些凭据。进一步隔离需要拆分交付服务、按用户加密或离线生成订阅，属于架构升级。
4. 本项目不会自动重写云安全组或主机防火墙，以免误封唯一 SSH 管理通道。管理员必须只开放实际需要的 TCP 80/443/8443/8444、UDP 443/8443 和 SSH 端口，并关闭其他服务。
5. Fail2ban 依赖 SSH 日志进入 systemd journal、系统时间正确、数据库可写和防火墙 action 可用。永久规则在 Fail2ban 持续运行时会于长期窗口内第 11 次失败触发；若守护进程频繁重启，尚未达到阈值的内存计数可能丢失，长期数据库和 recidive 只能提供兜底，不能把它表述为跨任意重启都绝对精确。部署后必须在真实服务器执行状态检查。
6. Ubuntu APT 包由系统软件源管理，没有在本项目中逐包固定哈希。应启用官方安全更新、最小化系统包并保护软件源配置。
7. REALITY、TLS/QUIC 或任何协议都不能保证“不被墙”。主动探测、流量特征、IP 信誉和大规模关联分析可能导致封锁；协议多样性只提高恢复能力，不提供绝对隐身。
8. 对 GitHub HTTPS 和管理员提供的 SHA-256 仍存在信任。哈希必须来自独立可信渠道；如果代码包和哈希同时来自被攻陷的同一渠道，校验无法发现替换。
9. 本工作区没有真实服务器的证书、nginx、systemd、Xray、Hysteria2、sing-box 和 Fail2ban 运行状态，因此本报告不能代替上线后的集成验证。

## 8. 上线后必须执行的验证

```bash
sudo bash /root/proxy-stack/proxy-stack.sh render
sudo systemctl restart proxy-stack-xray proxy-stack-hysteria proxy-stack-sing-box proxy-stack-web nginx fail2ban
sudo bash /root/proxy-stack/proxy-stack.sh verify
sudo bash /root/proxy-stack/proxy-stack.sh security status
sudo nginx -t
sudo fail2ban-client -t
```

还应从未授权网络测试订阅返回 404，从授权设备测试六路连接，并用云厂商带外控制台确认即使 SSH 被误封仍能恢复。部署前保留 `/etc/proxy-stack` 和项目目录备份。

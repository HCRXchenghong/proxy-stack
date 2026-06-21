#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/render.sh"

PROJECT_REPO_URL="${PROXY_STACK_REPO_URL:-https://github.com/HCRXchenghong/proxy-stack}"
PROJECT_BRANCH="${PROXY_STACK_BRANCH:-main}"
PROJECT_VERSION_FILE="$SCRIPT_DIR/VERSION"

usage() {
  cat <<'EOF'
用法：
  ./proxy-stack.sh install [选项]
  ./proxy-stack.sh render
  ./proxy-stack.sh verify
  ./proxy-stack.sh check-update
  ./proxy-stack.sh update
  ./proxy-stack.sh user add <用户名>
  ./proxy-stack.sh user batch-add <用户名前缀> <数量> [起始序号]
  ./proxy-stack.sh user del <用户名或slug>
  ./proxy-stack.sh user disable <用户名或slug>
  ./proxy-stack.sh user enable <用户名或slug>
  ./proxy-stack.sh user list
  ./proxy-stack.sh user show <用户名或slug>
  ./proxy-stack.sh user share <用户名或slug>
  ./proxy-stack.sh user export [csv|json|text] [路径]
  ./proxy-stack.sh menu
  ./proxy-stack.sh uninstall-3xui
  ./proxy-stack.sh package

安装选项：
  --web-domain <域名>            用户交付页/订阅使用的公网域名。
  --management-domain <域名>     管理域名，会转发到 127.0.0.1:8317。
  --cert-email <邮箱>            Let's Encrypt 注册邮箱；交互式终端中省略时会提示输入。
  --tls-cert-file <路径>         已有 TLS fullchain 证书路径。
  --tls-key-file <路径>          已有 TLS 私钥路径。
  --public-ip <ip>               服务器公网 IP；省略时自动探测。
  --reality-target <host:port>   REALITY 伪装目标。
  --reality-sni <host>           REALITY SNI。
EOF
}

download_xray() {
  require_cmd curl jq unzip
  local api tag url zip tmp
  api='https://api.github.com/repos/XTLS/Xray-core/releases/latest'
  tag="$(curl -fsSL "$api" | jq -r '.tag_name')"
  url="$(curl -fsSL "$api" | jq -r '.assets[] | select(.name=="Xray-linux-64.zip") | .browser_download_url')"
  [[ -n "$tag" && -n "$url" ]] || die "无法解析最新版 Xray 下载地址"
  tmp="$(mktemp -d)"
  zip="$tmp/xray.zip"
  curl -fsSL "$url" -o "$zip"
  unzip -qo "$zip" -d "$tmp/unpack"
  install -m 0755 "$tmp/unpack/xray" "${BIN_DIR}/xray"
  rm -rf "$tmp"
  log "已安装 Xray ${tag}"
}

download_hysteria() {
  require_cmd curl jq
  local api tag url tmp
  api='https://api.github.com/repos/apernet/hysteria/releases/latest'
  tag="$(curl -fsSL "$api" | jq -r '.tag_name')"
  url="$(curl -fsSL "$api" | jq -r '.assets[] | select(.name=="hysteria-linux-amd64") | .browser_download_url')"
  [[ -n "$tag" && -n "$url" ]] || die "无法解析最新版 Hysteria 下载地址"
  tmp="$(mktemp)"
  curl -fsSL "$url" -o "$tmp"
  install -m 0755 "$tmp" "${BIN_DIR}/hysteria"
  rm -f "$tmp"
  log "已安装 Hysteria ${tag}"
}

issue_cert_if_needed() {
  local cert="$1" key="$2" email="$3" web_domain="$4" mgmt_domain="$5"
  if [[ -f "$cert" && -f "$key" ]]; then
    log "复用已有 TLS 证书和私钥"
    return 0
  fi
  [[ -n "$email" ]] || die "未提供证书路径时必须提供证书邮箱"
  rm -f "$NGINX_HTTP_CONF"
  mkdir -p "$WEB_ROOT/.well-known/acme-challenge"
  write_nginx_acme_conf
  reload_nginx
  log "正在为 ${web_domain} 和 ${mgmt_domain} 申请 Let's Encrypt 证书"
  if ! certbot certonly --webroot -w "$WEB_ROOT" \
    -d "$web_domain" -d "$mgmt_domain" \
    --cert-name "$web_domain" \
    --preferred-challenges http \
    --agree-tos --no-eff-email --non-interactive --expand -m "$email"; then
    die "Let's Encrypt 证书申请失败。请确认两个域名都解析到本机、TCP 80 已放行、Cloudflare 代理云朵已关闭，并且 $email 是真实邮箱。详情见：/var/log/letsencrypt/letsencrypt.log"
  fi
}

generate_env_file() {
  local web_domain="$1" mgmt_domain="$2" cert_email="$3" tls_cert="$4" tls_key="$5" public_ip="$6" reality_target="$7" reality_sni="$8"
  local private public short obfs out
  private=""
  public=""
  short=""
  obfs=""
  if [[ -f "$STATE_DIR/stack.env" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_DIR/stack.env"
    private="${REALITY_PRIVATE_KEY:-}"
    public="${REALITY_PUBLIC_KEY:-}"
    short="${REALITY_SHORT_ID:-}"
    obfs="${HY2_OBFS_PASSWORD:-}"
  fi
  if [[ -z "$private" || -z "$public" ]]; then
    out="$("${BIN_DIR}/xray" x25519)"
    private="$(printf '%s\n' "$out" | awk 'index($0,"PrivateKey:")==1 {print $2}')"
    public="$(printf '%s\n' "$out" | awk 'index($0,"Password (PublicKey):")==1 {print $3}')"
    [[ -n "$private" && -n "$public" ]] || die "生成 REALITY x25519 密钥对失败"
  fi
  [[ -n "$short" ]] || short="$(random_hex 4)"
  [[ -n "$obfs" ]] || obfs="$(random_token 12)"
  save_env <<EOF
WEB_DOMAIN=${web_domain}
MANAGEMENT_DOMAIN=${mgmt_domain}
CERT_EMAIL=${cert_email}
TLS_CERT_FILE=${tls_cert}
TLS_KEY_FILE=${tls_key}
PUBLIC_IP=${public_ip}
REALITY_TARGET=${reality_target}
REALITY_SNI=${reality_sni}
REALITY_PRIVATE_KEY=${private}
REALITY_PUBLIC_KEY=${public}
REALITY_SHORT_ID=${short}
HY2_OBFS_PASSWORD=${obfs}
VLESS_INTERNAL_PORT=${VLESS_INTERNAL_PORT}
APP_PORT=${APP_PORT}
WEB_TLS_PORT=${WEB_TLS_PORT}
MGMT_TLS_PORT=${MGMT_TLS_PORT}
EOF
}

install_stack() {
  require_root
  require_cmd bash curl openssl python3 systemctl apt-get
  local web_domain="" mgmt_domain="" cert_email="" tls_cert="" tls_key="" public_ip="" reality_target="" reality_sni=""
  local using_existing_tls=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --web-domain) web_domain="$2"; shift 2 ;;
      --management-domain) mgmt_domain="$2"; shift 2 ;;
      --cert-email) cert_email="$2"; shift 2 ;;
      --tls-cert-file) tls_cert="$2"; shift 2 ;;
      --tls-key-file) tls_key="$2"; shift 2 ;;
      --public-ip) public_ip="$2"; shift 2 ;;
      --reality-target) reality_target="$2"; shift 2 ;;
      --reality-sni) reality_sni="$2"; shift 2 ;;
      *) die "未知安装选项：$1" ;;
    esac
  done
  [[ -n "$web_domain" ]] || die "必须提供 --web-domain"
  [[ -n "$mgmt_domain" ]] || die "必须提供 --management-domain"
  validate_domain "--web-domain" "$web_domain"
  validate_domain "--management-domain" "$mgmt_domain"
  [[ "$web_domain" != "$mgmt_domain" ]] || die "用户域名和管理域名不能相同"
  if [[ -n "$tls_cert" || -n "$tls_key" ]]; then
    using_existing_tls=1
    [[ -n "$tls_cert" && -n "$tls_key" ]] || die "请同时提供 --tls-cert-file 和 --tls-key-file"
    [[ -f "$tls_cert" ]] || die "TLS 证书文件不存在：$tls_cert"
    [[ -f "$tls_key" ]] || die "TLS 私钥文件不存在：$tls_key"
  else
    while ! is_valid_email "$cert_email"; do
      if [[ -n "$cert_email" ]]; then
        log "证书邮箱 '$cert_email' 无效或属于保留域名，请输入真实邮箱"
        cert_email=""
      fi
      prompt_value_if_tty cert_email "请输入 Let's Encrypt 邮箱"
      [[ -n "$cert_email" ]] || break
    done
    [[ -n "$cert_email" ]] || die "未提供 TLS 证书/私钥时必须提供 --cert-email"
    validate_email "--cert-email" "$cert_email"
  fi
  ensure_dirs
  if [[ -z "$public_ip" ]]; then
    public_ip="$(public_ipv4)" || die "自动探测公网 IPv4 失败，请传入 --public-ip <ip>"
  fi
  validate_ipv4 "--public-ip" "$public_ip"
  if [[ "$using_existing_tls" -eq 0 ]]; then
    preflight_acme_dns "$public_ip" "$web_domain" "$mgmt_domain"
  fi
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y jq unzip nginx libnginx-mod-stream certbot python3-certbot-nginx python3
  require_cmd jq unzip nginx certbot
  ensure_nginx_stream_include
  systemctl enable --now nginx
  download_xray
  download_hysteria
  [[ -n "$reality_target" ]] || reality_target="www.amazon.com:443"
  [[ -n "$reality_sni" ]] || reality_sni="www.amazon.com"
  if [[ -z "$tls_cert" || -z "$tls_key" ]]; then
    tls_cert="/etc/letsencrypt/live/${web_domain}/fullchain.pem"
    tls_key="/etc/letsencrypt/live/${web_domain}/privkey.pem"
  fi
  generate_env_file "$web_domain" "$mgmt_domain" "$cert_email" "$tls_cert" "$tls_key" "$public_ip" "$reality_target" "$reality_sni"
  write_users_json
  disable_legacy_hcrx_conf
  load_env
  issue_cert_if_needed "$TLS_CERT_FILE" "$TLS_KEY_FILE" "$CERT_EMAIL" "$WEB_DOMAIN" "$MANAGEMENT_DOMAIN"
  ensure_certbot_auto_renewal
  render_stack
  systemctl enable --now proxy-stack-xray proxy-stack-hysteria proxy-stack-web
  reload_nginx
  wait_stack_ready
  verify_stack
  write_runtime_info
  install_launcher
  log "安装完成"
  start_menu_if_interactive
}

render_stack() {
  require_root
  write_xray_config
  write_hysteria_config
  write_web_app
  write_nginx_http_conf
  write_nginx_stream_conf
  write_systemd_units
  log "配置渲染完成"
}

verify_stack() {
  require_root
  load_env
  "${BIN_DIR}/xray" run -test -c "${STATE_DIR}/xray.json"
  curl -fsS "http://127.0.0.1:${APP_PORT}/healthz" >/dev/null
  nginx -t
  systemctl is-active --quiet proxy-stack-xray
  systemctl is-active --quiet proxy-stack-hysteria
  systemctl is-active --quiet proxy-stack-web
  systemctl is-active --quiet nginx
  log "验证通过"
}

wait_stack_ready() {
  local tries=30
  local i
  for i in $(seq 1 "$tries"); do
    if systemctl is-active --quiet proxy-stack-xray \
      && systemctl is-active --quiet proxy-stack-hysteria \
      && systemctl is-active --quiet proxy-stack-web \
      && curl -fsS "http://127.0.0.1:${APP_PORT}/healthz" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  die "Proxy Stack 服务未能在预期时间内就绪"
}

reload_stack_services() {
  systemctl restart proxy-stack-xray proxy-stack-hysteria proxy-stack-web
  wait_stack_ready
}

write_runtime_info() {
  require_root
  load_env
  local info_file="/root/proxy-stack-runtime-info.txt"
  {
    printf '生成时间：%s UTC\n' "$(date -u '+%Y-%m-%d %H:%M:%S')"
    printf '项目目录：/root/proxy-stack\n'
    printf '项目压缩包：/root/proxy-stack-project.tar.gz\n'
    printf '用户域名：%s\n' "$WEB_DOMAIN"
    printf '管理域名：%s\n' "$MANAGEMENT_DOMAIN"
    printf '公网 IP：%s\n' "$PUBLIC_IP"
    printf '用户列表命令：bash /root/proxy-stack/proxy-stack.sh user list\n'
    printf '管理菜单命令：seroncheng\n'
  } >"$info_file"
  chmod 600 "$info_file"
}

ensure_certbot_auto_renewal() {
  write_certbot_hook
  if systemctl list-unit-files certbot.timer >/dev/null 2>&1; then
    systemctl enable --now certbot.timer
    log "已启用 Let's Encrypt 自动续签定时器 certbot.timer"
  else
    log "未找到 certbot.timer；Certbot 可能使用系统自带调度方式续签"
  fi
}

install_launcher() {
  local launcher="/usr/local/bin/seroncheng"
  cat >"$launcher" <<EOF
#!/usr/bin/env bash
exec bash "${SCRIPT_DIR}/proxy-stack.sh" menu "\$@"
EOF
  chmod 0755 "$launcher"
  log "已安装管理入口：seroncheng"
}

normalize_project_repo_url() {
  local repo="$PROJECT_REPO_URL"
  repo="${repo%.git}"
  printf '%s\n' "$repo"
}

project_raw_url() {
  local path="$1"
  local repo owner name
  repo="$(normalize_project_repo_url)"
  if [[ "$repo" =~ ^https://github.com/([^/]+)/([^/]+)$ ]]; then
    owner="${BASH_REMATCH[1]}"
    name="${BASH_REMATCH[2]}"
    printf 'https://raw.githubusercontent.com/%s/%s/%s/%s\n' "$owner" "$name" "$PROJECT_BRANCH" "$path"
  else
    printf '%s/raw/%s/%s\n' "$repo" "$PROJECT_BRANCH" "$path"
  fi
}

project_tarball_url() {
  local repo
  repo="$(normalize_project_repo_url)"
  printf '%s/archive/refs/heads/%s.tar.gz\n' "$repo" "$PROJECT_BRANCH"
}

local_project_version() {
  if [[ -f "$PROJECT_VERSION_FILE" ]]; then
    head -n 1 "$PROJECT_VERSION_FILE" | tr -d '[:space:]'
  else
    printf 'unknown'
  fi
}

remote_project_version() {
  local url
  url="$(project_raw_url VERSION)"
  curl -fsSL --connect-timeout 10 --max-time 30 --retry 3 --retry-delay 2 "$url" | head -n 1 | tr -d '[:space:]'
}

check_project_update() {
  require_cmd curl
  local local_version remote_version
  local_version="$(local_project_version)"
  remote_version="$(remote_project_version)" || die "检测远程版本失败，请检查网络或仓库地址"
  [[ -n "$remote_version" ]] || die "远程 VERSION 为空，无法检测更新"
  printf '当前版本：%s\n' "$local_version"
  printf '远程版本：%s\n' "$remote_version"
  if [[ "$local_version" == "$remote_version" ]]; then
    log "当前已是最新版本"
    return 0
  fi
  log "发现可用更新：${local_version} -> ${remote_version}"
  return 0
}

download_project_payload() {
  local dst="$1"
  local tmp archive src
  tmp="$(mktemp -d)"
  archive="$tmp/proxy-stack.tar.gz"
  curl -fsSL --connect-timeout 10 --max-time 120 --retry 3 --retry-delay 2 "$(project_tarball_url)" -o "$archive"
  tar -xzf "$archive" -C "$tmp"
  src="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  [[ -n "$src" ]] || die "解压更新包失败"
  mkdir -p "$dst"
  cp -a "$src/." "$dst/"
  chmod 0755 "$dst/proxy-stack.sh"
  [[ -f "$dst/deploy.sh" ]] && chmod 0755 "$dst/deploy.sh"
  rm -rf "$tmp"
}

update_project() {
  require_root
  require_cmd curl tar systemctl
  local local_version remote_version
  local_version="$(local_project_version)"
  remote_version="$(remote_project_version)" || die "检测远程版本失败，请检查网络或仓库地址"
  [[ -n "$remote_version" ]] || die "远程 VERSION 为空，无法更新"

  if [[ "$local_version" == "$remote_version" ]]; then
    log "当前已是最新版本：$local_version"
    return 0
  fi

  log "开始更新 Proxy Stack：${local_version} -> ${remote_version}"
  download_project_payload "$SCRIPT_DIR"
  install_launcher
  ensure_certbot_auto_renewal
  bash "$SCRIPT_DIR/proxy-stack.sh" render
  systemctl restart proxy-stack-xray proxy-stack-hysteria proxy-stack-web nginx
  bash "$SCRIPT_DIR/proxy-stack.sh" verify
  log "更新完成，当前版本：${remote_version}"
}

has_interactive_tty() {
  [[ -r /dev/tty && -w /dev/tty ]] || [[ -t 0 ]]
}

read_menu_input() {
  local var_name="$1"
  local prompt="$2"
  local value
  if [[ -r /dev/tty && -w /dev/tty ]]; then
    printf '%s' "$prompt" >/dev/tty
    IFS= read -r value </dev/tty
  else
    read -r -p "$prompt" value
  fi
  printf -v "$var_name" '%s' "$value"
}

pause_menu() {
  local _
  has_interactive_tty || return 0
  read_menu_input _ "按回车返回菜单..."
}

run_menu_command() {
  set +e
  "$@"
  local status=$?
  set -e
  if [[ "$status" -ne 0 ]]; then
    log "操作失败，退出码：$status"
  fi
  return 0
}

menu_header() {
  load_env
  cat <<EOF

================ SeronCheng Proxy Stack 管理菜单 ================
用户域名：${WEB_DOMAIN}
管理域名：${MANAGEMENT_DOMAIN}
公网 IP：${PUBLIC_IP}
脚本版本：$(local_project_version)
后续可在命令行输入：seroncheng
================================================================
EOF
}

show_cert_status() {
  load_env
  printf '\n[证书状态]\n'
  if command -v certbot >/dev/null 2>&1; then
    certbot certificates --cert-name "$WEB_DOMAIN" || certbot certificates || true
  else
    log "未找到 certbot 命令"
  fi
  printf '\n[自动续签定时器]\n'
  systemctl status certbot.timer --no-pager || true
  printf '\n[续签后重载 hook]\n'
  if [[ -x /etc/letsencrypt/renewal-hooks/deploy/proxy-stack-reload.sh ]]; then
    printf '已安装：/etc/letsencrypt/renewal-hooks/deploy/proxy-stack-reload.sh\n'
  else
    printf '未安装，正在补写...\n'
    write_certbot_hook
  fi
}

run_certbot_dry_run() {
  ensure_certbot_auto_renewal
  certbot renew --dry-run
}

menu_loop() {
  require_root
  has_interactive_tty || {
    log "当前不是交互式终端，无法打开菜单；请在服务器命令行输入 seroncheng"
    return 0
  }

  local choice name prefix count start key format out_path confirm
  while true; do
    menu_header
    cat <<'EOF'
1) 验证部署
2) 查看服务状态
3) 添加用户
4) 批量添加用户
5) 用户列表
6) 查看/分享用户链接
7) 禁用用户
8) 启用用户
9) 删除用户
10) 导出用户
11) 重新渲染配置并重启服务
12) 查看 SSL 证书和自动续签状态
13) 执行 SSL 自动续签测试（dry-run）
14) 检测脚本更新
15) 一键更新脚本
0) 退出
EOF
    read_menu_input choice "请选择操作："
    case "$choice" in
      1)
        run_menu_command bash "$SCRIPT_DIR/proxy-stack.sh" verify
        pause_menu
        ;;
      2)
        run_menu_command systemctl status proxy-stack-xray proxy-stack-hysteria proxy-stack-web nginx certbot.timer --no-pager
        pause_menu
        ;;
      3)
        read_menu_input name "请输入用户名："
        [[ -n "$name" ]] && run_menu_command bash "$SCRIPT_DIR/proxy-stack.sh" user add "$name"
        pause_menu
        ;;
      4)
        read_menu_input prefix "请输入用户名前缀："
        read_menu_input count "请输入数量："
        read_menu_input start "请输入起始序号（默认 1）："
        start="${start:-1}"
        [[ -n "$prefix" && -n "$count" ]] && run_menu_command bash "$SCRIPT_DIR/proxy-stack.sh" user batch-add "$prefix" "$count" "$start"
        pause_menu
        ;;
      5)
        run_menu_command bash "$SCRIPT_DIR/proxy-stack.sh" user list
        pause_menu
        ;;
      6)
        read_menu_input key "请输入用户名或 slug："
        [[ -n "$key" ]] && run_menu_command bash "$SCRIPT_DIR/proxy-stack.sh" user share "$key"
        pause_menu
        ;;
      7)
        read_menu_input key "请输入要禁用的用户名或 slug："
        [[ -n "$key" ]] && run_menu_command bash "$SCRIPT_DIR/proxy-stack.sh" user disable "$key"
        pause_menu
        ;;
      8)
        read_menu_input key "请输入要启用的用户名或 slug："
        [[ -n "$key" ]] && run_menu_command bash "$SCRIPT_DIR/proxy-stack.sh" user enable "$key"
        pause_menu
        ;;
      9)
        read_menu_input key "请输入要删除的用户名或 slug："
        if [[ -n "$key" ]]; then
          read_menu_input confirm "确认删除 ${key}？输入 yes 确认："
          [[ "$confirm" == "yes" ]] && run_menu_command bash "$SCRIPT_DIR/proxy-stack.sh" user del "$key"
        fi
        pause_menu
        ;;
      10)
        read_menu_input format "导出格式 csv/json/text（默认 csv）："
        format="${format:-csv}"
        read_menu_input out_path "导出路径（留空使用默认路径）："
        run_menu_command bash "$SCRIPT_DIR/proxy-stack.sh" user export "$format" "$out_path"
        pause_menu
        ;;
      11)
        run_menu_command bash "$SCRIPT_DIR/proxy-stack.sh" render
        run_menu_command systemctl restart proxy-stack-xray proxy-stack-hysteria proxy-stack-web nginx
        run_menu_command bash "$SCRIPT_DIR/proxy-stack.sh" verify
        pause_menu
        ;;
      12)
        run_menu_command show_cert_status
        pause_menu
        ;;
      13)
        run_menu_command run_certbot_dry_run
        pause_menu
        ;;
      14)
        run_menu_command check_project_update
        pause_menu
        ;;
      15)
        run_menu_command update_project
        pause_menu
        ;;
      0|q|Q)
        log "已退出管理菜单。后续输入 seroncheng 可再次打开。"
        return 0
        ;;
      *)
        log "未知选项：$choice"
        pause_menu
        ;;
    esac
  done
}

start_menu_if_interactive() {
  if has_interactive_tty; then
    log "验证完成，正在进入管理菜单。后续输入 seroncheng 可再次打开。"
    menu_loop
  else
    log "验证完成。后续可输入 seroncheng 打开管理菜单。"
  fi
}

user_add() {
  require_root
  local name="${1:?必须提供用户名}"
  local slug uuid hy2
  slug="$(random_slug)"
  uuid="$(random_uuid)"
  hy2="$(random_token 18)"
  python3 - "$STATE_DIR/users.json" "$name" "$slug" "$uuid" "$hy2" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
name, slug, uuid, hy2 = sys.argv[2:6]
data = json.loads(path.read_text())
users = data.setdefault("users", [])
for user in users:
    if user["name"] == name:
        raise SystemExit("用户已存在")
users.append({
    "name": name,
    "slug": slug,
    "vless_uuid": uuid,
    "hy2_auth": hy2,
    "enabled": True,
})
path.write_text(json.dumps(data, indent=2))
PY
  render_stack
  reload_stack_services
  write_runtime_info
  user_show "$name"
}

user_batch_add() {
  require_root
  local prefix="${1:?必须提供用户名前缀}"
  local count="${2:?必须提供数量}"
  local start="${3:-1}"
  python3 - "$STATE_DIR/users.json" "$prefix" "$count" "$start" <<'PY'
import json
import secrets
import string
import sys
import uuid
from pathlib import Path

path = Path(sys.argv[1])
prefix = sys.argv[2]
count = int(sys.argv[3])
start = int(sys.argv[4])
if count <= 0:
    raise SystemExit("数量必须大于 0")
alphabet = string.ascii_letters + string.digits

def rand_slug():
    return ''.join(secrets.choice(alphabet) for _ in range(10))

def rand_token():
    return secrets.token_urlsafe(18)

data = json.loads(path.read_text())
users = data.setdefault("users", [])
existing = {u["name"] for u in users}
created = []
for idx in range(start, start + count):
    name = f"{prefix}{idx:03d}"
    if name in existing:
      raise SystemExit(f"用户已存在：{name}")
    users.append({
        "name": name,
        "slug": rand_slug(),
        "vless_uuid": str(uuid.uuid4()),
        "hy2_auth": rand_token(),
        "enabled": True,
    })
    created.append(name)
path.write_text(json.dumps(data, indent=2))
print("\n".join(created))
PY
  render_stack
  reload_stack_services
  write_runtime_info
  log "已批量创建前缀为 ${prefix} 的用户"
}

user_set_enabled() {
  require_root
  local key="${1:?必须提供用户名称或 slug}"
  local want="${2:?必须提供启用状态}"
  python3 - "$STATE_DIR/users.json" "$key" "$want" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
key = sys.argv[2]
want = sys.argv[3].lower() == "true"
data = json.loads(path.read_text())
users = data.setdefault("users", [])
for user in users:
    if user.get("name") == key or user.get("slug") == key:
        user["enabled"] = want
        path.write_text(json.dumps(data, indent=2))
        print(json.dumps(user))
        raise SystemExit(0)
raise SystemExit("用户不存在")
PY
  render_stack
  reload_stack_services
  write_runtime_info
  user_show "$key"
}

user_del() {
  require_root
  local key="${1:?必须提供用户名称或 slug}"
  python3 - "$STATE_DIR/users.json" "$key" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
key = sys.argv[2]
data = json.loads(path.read_text())
users = data.setdefault("users", [])
filtered = [u for u in users if u.get("name") != key and u.get("slug") != key]
if len(filtered) == len(users):
    raise SystemExit("用户不存在")
data["users"] = filtered
path.write_text(json.dumps(data, indent=2))
PY
  render_stack
  reload_stack_services
  write_runtime_info
  log "已删除用户：${key}"
}

user_list() {
  require_root
  jq -r '.users[] | [.name, .slug, (if .enabled then "启用" else "禁用" end)] | @tsv' "$STATE_DIR/users.json"
}

user_show() {
  require_root
  local key="${1:?必须提供用户名称或 slug}"
  load_env
  python3 - "$STATE_DIR/users.json" "$key" "$WEB_DOMAIN" "$PUBLIC_IP" "$REALITY_PUBLIC_KEY" "$REALITY_SNI" "$REALITY_SHORT_ID" "$HY2_OBFS_PASSWORD" <<'PY'
import json
import sys
from pathlib import Path
from urllib.parse import quote

users = json.loads(Path(sys.argv[1]).read_text()).get("users", [])
key, domain, public_ip, pbk, sni, sid, obfs = sys.argv[2:9]
u = None
for item in users:
    if item["name"] == key or item["slug"] == key:
        u = item
        break
if not u:
    raise SystemExit("用户不存在")
vless = (
    f'vless://{u["vless_uuid"]}@{public_ip}:443'
    f'?type=tcp&security=reality&pbk={quote(pbk)}&fp=chrome'
    f'&sni={quote(sni)}&sid={sid}&flow=xtls-rprx-vision'
    f'#{quote(u["name"] + "-vless")}'
)
hy2 = (
    f'hysteria2://{quote(u["hy2_auth"])}@{public_ip}:443'
    f'?sni={quote(domain)}&alpn=h3&security=tls'
)
if obfs:
    hy2 += f'&obfs=salamander&obfs-password={quote(obfs)}'
hy2 += f'#{quote(u["name"] + "-hy2")}'
print(f'NAME={u["name"]}')
print(f'SLUG={u["slug"]}')
print(f'PAGE=https://{domain}/u/{u["slug"]}')
print(f'SUB=https://{domain}/sub/{u["slug"]}')
print(f'CLASH=https://{domain}/clash/{u["slug"]}')
print(f'RAW=https://{domain}/raw/{u["slug"]}')
print(f'VLESS={vless}')
print(f'HY2={hy2}')
PY
}

user_share() {
  require_root
  local key="${1:?必须提供用户名称或 slug}"
  load_env
  python3 - "$STATE_DIR/users.json" "$key" "$WEB_DOMAIN" "$PUBLIC_IP" "$REALITY_PUBLIC_KEY" "$REALITY_SNI" "$REALITY_SHORT_ID" "$HY2_OBFS_PASSWORD" <<'PY'
import json
import sys
from pathlib import Path
from urllib.parse import quote

users = json.loads(Path(sys.argv[1]).read_text()).get("users", [])
key, domain, public_ip, pbk, sni, sid, obfs = sys.argv[2:9]
u = None
for item in users:
    if item["name"] == key or item["slug"] == key:
        u = item
        break
if not u:
    raise SystemExit("用户不存在")
vless = (
    f'vless://{u["vless_uuid"]}@{public_ip}:443'
    f'?type=tcp&security=reality&pbk={quote(pbk)}&fp=chrome'
    f'&sni={quote(sni)}&sid={sid}&flow=xtls-rprx-vision'
    f'#{quote(u["name"] + "-vless")}'
)
hy2 = (
    f'hysteria2://{quote(u["hy2_auth"])}@{public_ip}:443'
    f'?sni={quote(domain)}&alpn=h3&security=tls'
)
if obfs:
    hy2 += f'&obfs=salamander&obfs-password={quote(obfs)}'
hy2 += f'#{quote(u["name"] + "-hy2")}'
print(f"""[{u['name']}]
页面: https://{domain}/u/{u['slug']}
通用订阅: https://{domain}/sub/{u['slug']}
Clash/Mihomo: https://{domain}/clash/{u['slug']}
原始URI订阅: https://{domain}/raw/{u['slug']}

VLESS:
{vless}

Hysteria2:
{hy2}
""")
PY
}

user_export() {
  require_root
  local format="${1:-csv}"
  local out_path="${2:-}"
  load_env
  case "$format" in
    csv)
      [[ -n "$out_path" ]] || out_path="/root/proxy-stack-users.csv"
      ;;
    json)
      [[ -n "$out_path" ]] || out_path="/root/proxy-stack-users.json"
      ;;
    text)
      [[ -n "$out_path" ]] || out_path="/root/proxy-stack-users.txt"
      ;;
    *)
      die "不支持的导出格式：$format"
      ;;
  esac
  python3 - "$STATE_DIR/users.json" "$format" "$out_path" "$WEB_DOMAIN" "$PUBLIC_IP" "$REALITY_PUBLIC_KEY" "$REALITY_SNI" "$REALITY_SHORT_ID" "$HY2_OBFS_PASSWORD" <<'PY'
import csv
import json
import sys
from pathlib import Path
from urllib.parse import quote

users_path = Path(sys.argv[1])
fmt = sys.argv[2]
out_path = Path(sys.argv[3])
domain, public_ip, pbk, sni, sid, obfs = sys.argv[4:10]
users = json.loads(users_path.read_text()).get("users", [])

rows = []
for u in users:
    vless = (
        f'vless://{u["vless_uuid"]}@{public_ip}:443'
        f'?type=tcp&security=reality&pbk={quote(pbk)}&fp=chrome'
        f'&sni={quote(sni)}&sid={sid}&flow=xtls-rprx-vision'
        f'#{quote(u["name"] + "-vless")}'
    )
    hy2 = (
        f'hysteria2://{quote(u["hy2_auth"])}@{public_ip}:443'
        f'?sni={quote(domain)}&alpn=h3&security=tls'
    )
    if obfs:
        hy2 += f'&obfs=salamander&obfs-password={quote(obfs)}'
    hy2 += f'#{quote(u["name"] + "-hy2")}'
    rows.append({
        "name": u["name"],
        "slug": u["slug"],
        "enabled": bool(u.get("enabled", True)),
        "page": f'https://{domain}/u/{u["slug"]}',
        "sub": f'https://{domain}/sub/{u["slug"]}',
        "clash": f'https://{domain}/clash/{u["slug"]}',
        "raw": f'https://{domain}/raw/{u["slug"]}',
        "vless": vless,
        "hy2": hy2,
    })

out_path.parent.mkdir(parents=True, exist_ok=True)
if fmt == "json":
    out_path.write_text(json.dumps(rows, indent=2, ensure_ascii=False))
elif fmt == "csv":
    with out_path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=["name", "slug", "enabled", "page", "sub", "clash", "raw", "vless", "hy2"])
        writer.writeheader()
        writer.writerows(rows)
else:
    with out_path.open("w", encoding="utf-8") as f:
        for row in rows:
            f.write(
                f"[{row['name']}]\n"
                f"状态: {'启用' if row['enabled'] else '禁用'}\n"
                f"页面: {row['page']}\n"
                f"通用订阅: {row['sub']}\n"
                f"Clash/Mihomo: {row['clash']}\n"
                f"原始URI订阅: {row['raw']}\n"
                f"VLESS: {row['vless']}\n"
                f"HY2: {row['hy2']}\n\n"
            )
print(out_path)
PY
}

uninstall_3xui() {
  require_root
  systemctl disable --now x-ui || true
  rm -f /etc/systemd/system/x-ui.service
  rm -f /etc/default/x-ui
  rm -rf /usr/local/x-ui /etc/x-ui
  rm -rf /root/3x-ui
  rm -f /root/deployed-services-credentials.txt
  rm -f /etc/nginx/conf.d/hcrx-ltd.conf.proxy-stack.bak
  rm -f /root/deploy-downloads/x-ui-linux-amd64-v3.2.7.tar.gz
  rm -rf /root/deploy-downloads/xui-extract
  rm -f /etc/fail2ban/jail.d/xui-login.local /etc/fail2ban/filter.d/xui-login.conf /etc/fail2ban/action.d/nginx-cn2-deny.conf
  systemctl restart fail2ban || true
  systemctl daemon-reload
  log "3x-ui 已清理"
}

package_project() {
  require_root
  tar -C /root -czf /root/proxy-stack-project.tar.gz proxy-stack
  log "项目压缩包已写入 /root/proxy-stack-project.tar.gz"
}

cmd="${1:-}"
case "$cmd" in
  install) shift; install_stack "$@" ;;
  render) render_stack ;;
  verify) verify_stack ;;
  check-update) check_project_update ;;
  update) update_project ;;
  menu) menu_loop ;;
  user)
    sub="${2:-}"
    case "$sub" in
      add) user_add "${3:-}" ;;
      batch-add) user_batch_add "${3:-}" "${4:-}" "${5:-1}" ;;
      del) user_del "${3:-}" ;;
      disable) user_set_enabled "${3:-}" false ;;
      enable) user_set_enabled "${3:-}" true ;;
      list) user_list ;;
      share) user_share "${3:-}" ;;
      export) user_export "${3:-csv}" "${4:-}" ;;
      show) user_show "${3:-}" ;;
      *) usage; exit 1 ;;
    esac
    ;;
  uninstall-3xui) uninstall_3xui ;;
  package) package_project ;;
  *) usage; exit 1 ;;
esac

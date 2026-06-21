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

install_system_packages() {
  quiet_cmd "更新系统软件源" apt-get update
  quiet_cmd "安装系统依赖" env DEBIAN_FRONTEND=noninteractive apt-get install -y jq unzip nginx libnginx-mod-stream certbot python3-certbot-nginx python3
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
  progress_step 1 10 "安装依赖" install_system_packages
  require_cmd jq unzip nginx certbot
  progress_step 2 10 "配置 nginx" ensure_nginx_stream_include
  progress_step 3 10 "启动 nginx" systemctl enable --now nginx
  progress_step 4 10 "安装 Xray" download_xray
  progress_step 5 10 "安装 Hysteria2" download_hysteria
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
  progress_step 6 10 "申请 SSL" issue_cert_if_needed "$TLS_CERT_FILE" "$TLS_KEY_FILE" "$CERT_EMAIL" "$WEB_DOMAIN" "$MANAGEMENT_DOMAIN"
  progress_step 7 10 "启用续签" ensure_certbot_auto_renewal
  progress_step 8 10 "生成配置" render_stack
  progress_step 9 10 "启动服务" systemctl enable --now proxy-stack-xray proxy-stack-hysteria proxy-stack-web
  reload_nginx
  progress_step 10 10 "验证服务" verify_stack
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
  quiet_cmd "检测 Xray 配置" "${BIN_DIR}/xray" run -test -c "${STATE_DIR}/xray.json"
  quiet_cmd "检测 Web 服务" curl -fsS "http://127.0.0.1:${APP_PORT}/healthz"
  quiet_cmd "检测 nginx 配置" nginx -t
  quiet_cmd "检查 Xray 服务" systemctl is-active --quiet proxy-stack-xray
  quiet_cmd "检查 Hysteria2 服务" systemctl is-active --quiet proxy-stack-hysteria
  quiet_cmd "检查 Web 服务状态" systemctl is-active --quiet proxy-stack-web
  quiet_cmd "检查 nginx 服务" systemctl is-active --quiet nginx
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
  quiet_cmd "重启代理服务" systemctl restart proxy-stack-xray proxy-stack-hysteria proxy-stack-web
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
    quiet_cmd "启用 certbot.timer" systemctl enable --now certbot.timer
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

github_project_parts() {
  local repo owner name
  repo="$(normalize_project_repo_url)"
  if [[ "$repo" =~ ^https://github.com/([^/]+)/([^/]+)$ ]]; then
    owner="${BASH_REMATCH[1]}"
    name="${BASH_REMATCH[2]}"
    printf '%s %s\n' "$owner" "$name"
  else
    die "版本检测/更新仅支持 GitHub 仓库地址：$repo"
  fi
}

github_api_get() {
  local url="$1"
  curl -fsSL --connect-timeout 10 --max-time 30 --retry 3 --retry-delay 2 \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "$url"
}

version_from_ref() {
  local ref="$1"
  ref="${ref#refs/tags/}"
  ref="${ref#v}"
  ref="${ref#V}"
  printf '%s\n' "$ref"
}

remote_project_info() {
  require_cmd curl python3
  local owner name release_json tags_json tag tarball version
  read -r owner name < <(github_project_parts)

  if release_json="$(github_api_get "https://api.github.com/repos/${owner}/${name}/releases/latest" 2>/dev/null)"; then
    read -r tag tarball < <(printf '%s' "$release_json" | python3 -c 'import json,sys; data=json.load(sys.stdin); print((data.get("tag_name") or "") + "\t" + (data.get("tarball_url") or ""))')
    if [[ -n "$tag" ]]; then
      version="$(version_from_ref "$tag")"
      [[ -n "$tarball" ]] || tarball="https://github.com/${owner}/${name}/archive/refs/tags/${tag}.tar.gz"
      printf 'release %s %s %s\n' "$version" "$tag" "$tarball"
      return 0
    fi
  fi

  tags_json="$(github_api_get "https://api.github.com/repos/${owner}/${name}/tags?per_page=1")" || return 1
  read -r tag tarball < <(printf '%s' "$tags_json" | python3 -c 'import json,sys; data=json.load(sys.stdin); item=data[0] if isinstance(data, list) and data else {}; print((item.get("name") or "") + "\t" + (item.get("tarball_url") or ""))')
  [[ -n "$tag" ]] || return 1
  version="$(version_from_ref "$tag")"
  [[ -n "$tarball" ]] || tarball="https://github.com/${owner}/${name}/archive/refs/tags/${tag}.tar.gz"
  printf 'tag %s %s %s\n' "$version" "$tag" "$tarball"
}

local_project_version() {
  if [[ -f "$PROJECT_VERSION_FILE" ]]; then
    head -n 1 "$PROJECT_VERSION_FILE" | tr -d '[:space:]'
  else
    printf 'unknown'
  fi
}

remote_source_label() {
  case "$1" in
    release) printf 'GitHub Release' ;;
    tag) printf 'Git Tag' ;;
    *) printf '%s' "$1" ;;
  esac
}

compare_project_versions() {
  local local_version="$1"
  local remote_version="$2"
  if [[ "$local_version" == "unknown" ]]; then
    printf -- '-1\n'
    return 0
  fi
  python3 - "$local_version" "$remote_version" <<'PY'
import re
import sys

left, right = sys.argv[1:3]

def parts(value):
    return [int(item) for item in re.findall(r"\d+", value)]

a = parts(left)
b = parts(right)
size = max(len(a), len(b))
a += [0] * (size - len(a))
b += [0] * (size - len(b))
if a < b:
    print(-1)
elif a > b:
    print(1)
else:
    print(0)
PY
}

check_project_update() {
  require_cmd curl python3
  local local_version remote_source remote_version remote_ref remote_tarball compare_result
  local_version="$(local_project_version)"
  read -r remote_source remote_version remote_ref remote_tarball < <(remote_project_info) || die "检测远程版本失败，请检查网络或仓库地址"
  [[ -n "$remote_version" ]] || die "远程版本为空，无法检测更新"
  printf '当前版本：%s\n' "$local_version"
  printf '最新版本：%s\n' "$remote_version"
  printf '版本来源：%s（%s）\n' "$(remote_source_label "$remote_source")" "$remote_ref"
  compare_result="$(compare_project_versions "$local_version" "$remote_version")"
  if [[ "$compare_result" == "0" ]]; then
    log "当前已是最新版本"
    return 0
  fi
  if [[ "$compare_result" == "1" ]]; then
    log "本地版本高于远程版本，暂不更新"
    return 0
  fi
  log "发现可用更新：${local_version} -> ${remote_version}"
  return 0
}

download_project_payload() {
  local dst="$1"
  local tarball_url="$2"
  local tmp archive src
  tmp="$(mktemp -d)"
  archive="$tmp/proxy-stack.tar.gz"
  curl -fsSL --connect-timeout 10 --max-time 120 --retry 3 --retry-delay 2 "$tarball_url" -o "$archive"
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
  require_cmd curl tar systemctl python3
  local local_version remote_source remote_version remote_ref remote_tarball compare_result
  local_version="$(local_project_version)"
  read -r remote_source remote_version remote_ref remote_tarball < <(remote_project_info) || die "检测远程版本失败，请检查网络或仓库地址"
  [[ -n "$remote_version" && -n "$remote_tarball" ]] || die "远程版本信息不完整，无法更新"
  compare_result="$(compare_project_versions "$local_version" "$remote_version")"

  if [[ "$compare_result" == "0" ]]; then
    log "当前已是最新版本：$local_version"
    return 0
  fi
  if [[ "$compare_result" == "1" ]]; then
    log "本地版本 $local_version 高于远程版本 $remote_version，暂不更新。"
    return 0
  fi

  log "开始更新：${local_version} -> ${remote_version}（$(remote_source_label "$remote_source")：${remote_ref}）"
  progress_step 1 6 "下载更新" download_project_payload "$SCRIPT_DIR" "$remote_tarball"
  progress_step 2 6 "更新入口" install_launcher
  progress_step 3 6 "续签配置" ensure_certbot_auto_renewal
  progress_step 4 6 "生成配置" bash "$SCRIPT_DIR/proxy-stack.sh" render
  progress_step 5 6 "重启服务" systemctl restart proxy-stack-xray proxy-stack-hysteria proxy-stack-web nginx
  progress_step 6 6 "验证服务" bash "$SCRIPT_DIR/proxy-stack.sh" verify
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
  read_menu_input _ "回车继续..."
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

========== SeronCheng ==========
用户：${WEB_DOMAIN}
管理：${MANAGEMENT_DOMAIN}
IP：${PUBLIC_IP}
版本：$(local_project_version)
入口：seroncheng
================================
EOF
}

show_service_status() {
  local unit active enabled
  printf '\n%-28s %-10s %-10s\n' "服务" "状态" "自启"
  for unit in proxy-stack-xray proxy-stack-hysteria proxy-stack-web nginx certbot.timer; do
    active="$(systemctl is-active "$unit" 2>/dev/null || true)"
    enabled="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
    printf '%-28s %-10s %-10s\n' "$unit" "${active:-unknown}" "${enabled:-unknown}"
  done
}

show_cert_status() {
  load_env
  local subject expires timer_active timer_enabled
  printf '\n证书：%s\n' "$TLS_CERT_FILE"
  if [[ -f "$TLS_CERT_FILE" ]] && command -v openssl >/dev/null 2>&1; then
    subject="$(openssl x509 -in "$TLS_CERT_FILE" -noout -subject 2>/dev/null | sed 's/^subject=//')"
    expires="$(openssl x509 -in "$TLS_CERT_FILE" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"
    printf '域名：%s\n' "${subject:-未知}"
    printf '到期：%s\n' "${expires:-未知}"
  else
    printf '状态：未找到证书文件或 openssl\n'
  fi
  timer_active="$(systemctl is-active certbot.timer 2>/dev/null || true)"
  timer_enabled="$(systemctl is-enabled certbot.timer 2>/dev/null || true)"
  printf '续签：certbot.timer %s / %s\n' "${timer_active:-unknown}" "${timer_enabled:-unknown}"
  if [[ -x /etc/letsencrypt/renewal-hooks/deploy/proxy-stack-reload.sh ]]; then
    printf 'Hook：已安装\n'
  else
    printf 'Hook：未安装，正在补写\n'
    write_certbot_hook
  fi
}

run_certbot_dry_run() {
  progress_step 1 2 "续签配置" ensure_certbot_auto_renewal
  progress_step 2 2 "续签测试" certbot renew --dry-run
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
1) 验证
2) 状态
3) 加用户
4) 批量加
5) 用户
6) 链接
7) 禁用
8) 启用
9) 删除
10) 导出
11) 重载
12) 证书
13) 续签测试
14) 查更新
15) 更新
0) 退出
EOF
    read_menu_input choice "选择："
    case "$choice" in
      1)
        run_menu_command bash "$SCRIPT_DIR/proxy-stack.sh" verify
        pause_menu
        ;;
      2)
        run_menu_command show_service_status
        pause_menu
        ;;
      3)
        read_menu_input name "用户名："
        [[ -n "$name" ]] && run_menu_command bash "$SCRIPT_DIR/proxy-stack.sh" user add "$name"
        pause_menu
        ;;
      4)
        read_menu_input prefix "前缀："
        read_menu_input count "数量："
        read_menu_input start "起始（默认 1）："
        start="${start:-1}"
        [[ -n "$prefix" && -n "$count" ]] && run_menu_command bash "$SCRIPT_DIR/proxy-stack.sh" user batch-add "$prefix" "$count" "$start"
        pause_menu
        ;;
      5)
        run_menu_command bash "$SCRIPT_DIR/proxy-stack.sh" user list
        pause_menu
        ;;
      6)
        read_menu_input key "用户/slug："
        [[ -n "$key" ]] && run_menu_command bash "$SCRIPT_DIR/proxy-stack.sh" user share "$key"
        pause_menu
        ;;
      7)
        read_menu_input key "用户/slug："
        [[ -n "$key" ]] && run_menu_command bash "$SCRIPT_DIR/proxy-stack.sh" user disable "$key"
        pause_menu
        ;;
      8)
        read_menu_input key "用户/slug："
        [[ -n "$key" ]] && run_menu_command bash "$SCRIPT_DIR/proxy-stack.sh" user enable "$key"
        pause_menu
        ;;
      9)
        read_menu_input key "用户/slug："
        if [[ -n "$key" ]]; then
          read_menu_input confirm "删除 ${key}？输入 yes："
          [[ "$confirm" == "yes" ]] && run_menu_command bash "$SCRIPT_DIR/proxy-stack.sh" user del "$key"
        fi
        pause_menu
        ;;
      10)
        read_menu_input format "格式 csv/json/text（默认 csv）："
        format="${format:-csv}"
        read_menu_input out_path "路径（留空默认）："
        run_menu_command bash "$SCRIPT_DIR/proxy-stack.sh" user export "$format" "$out_path"
        pause_menu
        ;;
      11)
        run_menu_command progress_step 1 3 "生成配置" bash "$SCRIPT_DIR/proxy-stack.sh" render
        run_menu_command progress_step 2 3 "重启服务" systemctl restart proxy-stack-xray proxy-stack-hysteria proxy-stack-web nginx
        run_menu_command progress_step 3 3 "验证服务" bash "$SCRIPT_DIR/proxy-stack.sh" verify
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

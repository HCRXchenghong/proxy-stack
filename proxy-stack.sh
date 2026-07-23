#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/render.sh"

PROJECT_REPO_URL="${PROXY_STACK_REPO_URL:-https://github.com/HCRXchenghong/proxy-stack}"
PROJECT_VERSION_FILE="$SCRIPT_DIR/VERSION"
XRAY_VERSION="v26.3.27"
XRAY_SHA256="23cd9af937744d97776ee35ecad4972cf4b2109d1e0fe6be9930467608f7c8ae"
HYSTERIA_VERSION="app/v2.10.0"
HYSTERIA_SHA256="04f7804159ef1d798de12a817d73aab4b9040ebe45fc62e223000c5c59e987fe"
SING_BOX_VERSION="v1.13.14"
SING_BOX_SHA256="f48703461a15476951ac4967cdad339d986f4b8096b4eb3ff0829a500502d697"

verify_sha256() {
  local file="$1"
  local expected="$2"
  local actual
  actual="$(sha256sum "$file" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || die "下载文件 SHA-256 校验失败：$file"
}

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
  ./proxy-stack.sh user client-add <用户名或slug> <设备名> [IP/CIDR]
  ./proxy-stack.sh user client-del <用户名或slug> <设备名>
  ./proxy-stack.sh user client-allow-ip <用户名或slug> <设备名> <IP/CIDR>
  ./proxy-stack.sh user client-deny-ip <用户名或slug> <设备名> <IP/CIDR>
  ./proxy-stack.sh user allow-ip <用户名或slug> <IP/CIDR>
  ./proxy-stack.sh user deny-ip <用户名或slug> <IP/CIDR>
  ./proxy-stack.sh user access <用户名或slug>
  ./proxy-stack.sh user export [csv|json|text] [路径]
  ./proxy-stack.sh security status
  ./proxy-stack.sh security ban <IP>
  ./proxy-stack.sh security unban <IP>
  ./proxy-stack.sh security apply
  ./proxy-stack.sh menu
  ./proxy-stack.sh uninstall-3xui
  ./proxy-stack.sh package

安装选项：
  --web-domain <域名>            用户交付页/订阅使用的公网域名。
  --management-domain <域名>     已弃用兼容参数，不签证书、不开放公网管理入口。
  --cert-email <邮箱>            Let's Encrypt 注册邮箱；交互式终端中省略时会提示输入。
  --tls-cert-file <路径>         已有 TLS fullchain 证书路径。
  --tls-key-file <路径>          已有 TLS 私钥路径。
  --public-ip <ip>               服务器公网 IP；省略时自动探测。
  --reality-target <host:port>   REALITY 伪装目标。
  --reality-sni <host>           REALITY SNI。
EOF
}

download_xray() {
  require_cmd curl sha256sum python3
  local url zip tmp
  url="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-64.zip"
  tmp="$(mktemp -d)"
  zip="$tmp/xray.zip"
  curl_https_download "$url" "$zip"
  verify_sha256 "$zip" "$XRAY_SHA256"
  safe_extract_zip "$zip" "$tmp/unpack"
  install -m 0755 "$tmp/unpack/xray" "${BIN_DIR}/xray"
  rm -rf "$tmp"
  log "已安装并校验 Xray ${XRAY_VERSION}"
}

download_hysteria() {
  require_cmd curl sha256sum
  local url tmp
  url="https://github.com/apernet/hysteria/releases/download/${HYSTERIA_VERSION}/hysteria-linux-amd64"
  tmp="$(mktemp)"
  curl_https_download "$url" "$tmp"
  verify_sha256 "$tmp" "$HYSTERIA_SHA256"
  install -m 0755 "$tmp" "${BIN_DIR}/hysteria"
  rm -f "$tmp"
  log "已安装并校验 Hysteria ${HYSTERIA_VERSION}"
}

download_sing_box() {
  require_cmd curl sha256sum tar
  local version url archive tmp binary
  version="${SING_BOX_VERSION#v}"
  url="https://github.com/SagerNet/sing-box/releases/download/${SING_BOX_VERSION}/sing-box-${version}-linux-amd64.tar.gz"
  tmp="$(mktemp -d)"
  archive="$tmp/sing-box.tar.gz"
  curl_https_download "$url" "$archive"
  verify_sha256 "$archive" "$SING_BOX_SHA256"
  safe_extract_tar "$archive" "$tmp/unpack"
  binary="$(find "$tmp/unpack" -type f -name sing-box -perm -0100 -print -quit)"
  [[ -n "$binary" ]] || die "sing-box 安装包中未找到可执行文件"
  install -m 0755 "$binary" "${BIN_DIR}/sing-box"
  rm -rf "$tmp"
  log "已安装并校验 sing-box ${SING_BOX_VERSION}"
}

ensure_proxy_binaries() {
  [[ -x "$BIN_DIR/xray" ]] || download_xray
  [[ -x "$BIN_DIR/hysteria" ]] || download_hysteria
  [[ -x "$BIN_DIR/sing-box" ]] || download_sing_box
}

install_pinned_proxy_binaries() {
  download_xray
  download_hysteria
  download_sing_box
}

install_system_packages() {
  quiet_cmd "更新系统软件源" apt-get update
  quiet_cmd "安装系统依赖" env DEBIAN_FRONTEND=noninteractive apt-get install -y jq nginx libnginx-mod-stream certbot python3-certbot-nginx python3 fail2ban
}

install_fail2ban_if_needed() {
  command -v fail2ban-client >/dev/null 2>&1 && return 0
  require_cmd apt-get
  quiet_cmd "更新 Fail2ban 软件源" apt-get update
  quiet_cmd "安装 Fail2ban" env DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban
}

validate_tls_material() {
  local cert="$1" key="$2" web_domain="$3"
  local cert_pub key_pub
  openssl x509 -in "$cert" -noout >/dev/null 2>&1 || die "TLS 证书无法解析：$cert"
  openssl pkey -in "$key" -noout >/dev/null 2>&1 || die "TLS 私钥无法解析：$key"
  openssl x509 -in "$cert" -noout -checkend 604800 >/dev/null 2>&1 \
    || die "TLS 证书将在 7 天内过期或已经过期：$cert"
  openssl x509 -in "$cert" -noout -checkhost "$web_domain" >/dev/null 2>&1 \
    || die "TLS 证书不覆盖用户域名：$web_domain"
  cert_pub="$(openssl x509 -in "$cert" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum | awk '{print $1}')"
  key_pub="$(openssl pkey -in "$key" -pubout -outform DER | sha256sum | awk '{print $1}')"
  [[ "$cert_pub" == "$key_pub" ]] || die "TLS 证书与私钥不匹配"
}

issue_cert_if_needed() {
  local cert="$1" key="$2" email="$3" web_domain="$4"
  if [[ -f "$cert" && -f "$key" ]]; then
    validate_tls_material "$cert" "$key" "$web_domain"
    log "复用已有 TLS 证书和私钥"
    return 0
  fi
  [[ -n "$email" ]] || die "未提供证书路径时必须提供证书邮箱"
  rm -f "$NGINX_HTTP_CONF"
  mkdir -p "$WEB_ROOT/.well-known/acme-challenge"
  write_nginx_acme_conf
  reload_nginx
  log "正在为 ${web_domain} 申请 Let's Encrypt 证书"
  if ! (umask 022; certbot certonly --webroot -w "$WEB_ROOT" \
    -d "$web_domain" \
    --cert-name "$web_domain" \
    --preferred-challenges http \
    --agree-tos --no-eff-email --non-interactive --expand -m "$email"); then
    die "Let's Encrypt 证书申请失败。请确认用户域名解析到本机、TCP 80 已放行、Cloudflare 代理云朵已关闭，并且 $email 是真实邮箱。详情见：/var/log/letsencrypt/letsencrypt.log"
  fi
  validate_tls_material "$cert" "$key" "$web_domain"
}

generate_env_file() {
  local web_domain="$1" mgmt_domain="$2" cert_email="$3" tls_cert="$4" tls_key="$5" public_ip="$6" reality_target="$7" reality_sni="$8"
  local private public short obfs out security_schema internal_proxy_token
  private=""
  public=""
  short=""
  obfs=""
  internal_proxy_token=""
  security_schema="2"
  if [[ -f "$STATE_DIR/stack.env" ]]; then
    # shellcheck disable=SC1090,SC1091
    source "$STATE_DIR/stack.env"
    private="${REALITY_PRIVATE_KEY:-}"
    public="${REALITY_PUBLIC_KEY:-}"
    short="${REALITY_SHORT_ID:-}"
    obfs="${HY2_OBFS_PASSWORD:-}"
    internal_proxy_token="${INTERNAL_PROXY_TOKEN:-}"
    security_schema="${SECURITY_SCHEMA_VERSION:-0}"
  fi
  if [[ -z "$private" || -z "$public" ]]; then
    out="$("${BIN_DIR}/xray" x25519)"
    private="$(printf '%s\n' "$out" | awk 'index($0,"PrivateKey:")==1 {print $2}')"
    public="$(printf '%s\n' "$out" | awk 'index($0,"Password (PublicKey):")==1 {print $3}')"
    [[ -n "$private" && -n "$public" ]] || die "生成 REALITY x25519 密钥对失败"
  fi
  [[ -n "$short" ]] || short="$(random_hex 8)"
  [[ -n "$obfs" ]] || obfs="$(random_token 24)"
  [[ "$internal_proxy_token" =~ ^[A-Za-z0-9_-]{40,}$ ]] || internal_proxy_token="$(random_token 32)"
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
ANYTLS_PORT=${ANYTLS_PORT}
TUIC_PORT=${TUIC_PORT}
NAIVE_PORT=${NAIVE_PORT}
INTERNAL_PROXY_TOKEN=${internal_proxy_token}
SECURITY_SCHEMA_VERSION=${security_schema}
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
  validate_domain "--web-domain" "$web_domain"
  if [[ -n "$mgmt_domain" ]]; then
    validate_domain "--management-domain" "$mgmt_domain"
    [[ "$web_domain" != "$mgmt_domain" ]] || die "用户域名和管理域名不能相同"
  fi
  if [[ -n "$tls_cert" || -n "$tls_key" ]]; then
    using_existing_tls=1
    [[ -n "$tls_cert" && -n "$tls_key" ]] || die "请同时提供 --tls-cert-file 和 --tls-key-file"
    [[ -f "$tls_cert" ]] || die "TLS 证书文件不存在：$tls_cert"
    [[ -f "$tls_key" ]] || die "TLS 私钥文件不存在：$tls_key"
    validate_safe_absolute_path "--tls-cert-file" "$tls_cert"
    validate_safe_absolute_path "--tls-key-file" "$tls_key"
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
  [[ -n "$reality_target" ]] || reality_target="www.amazon.com:443"
  [[ -n "$reality_sni" ]] || reality_sni="www.amazon.com"
  validate_reality_target "$reality_target"
  validate_domain "--reality-sni" "$reality_sni"
  [[ "${reality_target%:*}" == "$reality_sni" ]] \
    || die "--reality-target 主机名必须与 --reality-sni 一致"
  ensure_dirs
  if [[ -z "$public_ip" ]]; then
    public_ip="$(public_ipv4)" || die "自动探测公网 IPv4 失败，请传入 --public-ip <ip>"
  fi
  validate_ipv4 "--public-ip" "$public_ip"
  if [[ "$using_existing_tls" -eq 0 ]]; then
    preflight_acme_dns "$public_ip" "$web_domain"
  fi
  progress_step 1 11 "安装依赖" install_system_packages
  require_cmd jq nginx certbot fail2ban-client
  progress_step 2 11 "配置 nginx" ensure_nginx_stream_include
  progress_step 3 11 "启动 nginx" systemctl enable --now nginx
  progress_step 4 11 "安装 Xray" download_xray
  progress_step 5 11 "安装 Hysteria2" download_hysteria
  progress_step 6 11 "安装 sing-box" download_sing_box
  if [[ -z "$tls_cert" || -z "$tls_key" ]]; then
    tls_cert="/etc/letsencrypt/live/${web_domain}/fullchain.pem"
    tls_key="/etc/letsencrypt/live/${web_domain}/privkey.pem"
  fi
  generate_env_file "$web_domain" "$mgmt_domain" "$cert_email" "$tls_cert" "$tls_key" "$public_ip" "$reality_target" "$reality_sni"
  write_users_json
  disable_legacy_hcrx_conf
  load_env
  progress_step 7 11 "申请 SSL" issue_cert_if_needed "$tls_cert" "$tls_key" "$cert_email" "$web_domain"
  progress_step 8 11 "启用续签" ensure_certbot_auto_renewal
  progress_step 9 11 "生成配置" render_stack
  progress_step 10 11 "启动服务" systemctl enable --now proxy-stack-xray proxy-stack-hysteria proxy-stack-sing-box proxy-stack-web
  reload_nginx
  progress_step 11 11 "验证服务" verify_stack
  write_runtime_info
  install_launcher
  log "安装完成"
  start_menu_if_interactive
}

render_stack() {
  require_root
  install_fail2ban_if_needed
  ensure_dirs
  ensure_proxy_binaries
  ensure_env_defaults
  write_users_json
  ensure_user_protocol_credentials
  sync_service_tls_material
  write_xray_config
  write_hysteria_config
  write_sing_box_config
  write_public_env
  write_web_app
  write_nginx_http_conf
  write_nginx_stream_conf
  write_fail2ban_config
  write_systemd_units
  write_certbot_hook
  quiet_cmd "检查 Fail2ban 配置" fail2ban-client -t
  quiet_cmd "启用 SSH 防护" systemctl enable --now fail2ban
  quiet_cmd "重载 SSH 防护" systemctl restart fail2ban
  if systemctl is-active --quiet proxy-stack-xray 2>/dev/null; then
    quiet_cmd "启用 sing-box 服务" systemctl enable --now proxy-stack-sing-box
  fi
  log "配置渲染完成"
}

verify_stack() {
  require_root
  load_env
  quiet_cmd "检测 Xray 配置" "${BIN_DIR}/xray" run -test -c "${STATE_DIR}/xray.json"
  quiet_cmd "检测 sing-box 配置" "${BIN_DIR}/sing-box" check -c "${STATE_DIR}/sing-box.json"
  quiet_cmd "检测 Web 服务" curl -fsS "http://127.0.0.1:${APP_PORT}/healthz"
  quiet_cmd "检测 nginx 配置" nginx -t
  quiet_cmd "检测 HTTPS/SNI 分流" curl -fsS --noproxy '*' --connect-timeout 5 --resolve "${WEB_DOMAIN}:443:127.0.0.1" "https://${WEB_DOMAIN}/healthz"
  validate_tls_material "$TLS_CERT_FILE" "$TLS_KEY_FILE" "$WEB_DOMAIN"
  quiet_cmd "检查 Xray 服务" systemctl is-active --quiet proxy-stack-xray
  quiet_cmd "检查 Hysteria2 服务" systemctl is-active --quiet proxy-stack-hysteria
  quiet_cmd "检查 sing-box 服务" systemctl is-active --quiet proxy-stack-sing-box
  quiet_cmd "检查 Web 服务状态" systemctl is-active --quiet proxy-stack-web
  quiet_cmd "检查 nginx 服务" systemctl is-active --quiet nginx
  quiet_cmd "检查 Fail2ban 服务" systemctl is-active --quiet fail2ban
  log "验证通过"
}

wait_stack_ready() {
  local tries=30
  while (( tries > 0 )); do
    if systemctl is-active --quiet proxy-stack-xray \
      && systemctl is-active --quiet proxy-stack-hysteria \
      && systemctl is-active --quiet proxy-stack-sing-box \
      && systemctl is-active --quiet proxy-stack-web \
      && curl -fsS "http://127.0.0.1:${APP_PORT}/healthz" >/dev/null 2>&1; then
      return 0
    fi
    tries=$((tries - 1))
    sleep 1
  done
  die "Proxy Stack 服务未能在预期时间内就绪"
}

reload_stack_services() {
  quiet_cmd "重启代理服务" systemctl restart proxy-stack-xray proxy-stack-hysteria proxy-stack-sing-box proxy-stack-web
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
    printf '管理入口：仅 SSH\n'
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
  if [[ "$repo" =~ ^https://github.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)$ ]]; then
    owner="${BASH_REMATCH[1]}"
    name="${BASH_REMATCH[2]}"
    printf '%s %s\n' "$owner" "$name"
  else
    die "版本检测/更新仅支持 GitHub 仓库地址：$repo"
  fi
}

github_api_get() {
  local url="$1"
  [[ "$url" == https://api.github.com/* ]] || die "拒绝非 GitHub API 地址：$url"
  curl --fail --silent --show-error --location \
    --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --connect-timeout 10 --max-time 30 --retry 3 --retry-delay 2 --retry-all-errors \
    --max-filesize 4194304 \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    -- "$url"
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
  local expected_sha256="$3"
  local expected_version="$4"
  local tmp archive unpack src archive_sha version
  tmp="$(mktemp -d)"
  archive="$tmp/proxy-stack.tar.gz"
  unpack="$tmp/unpack"
  curl_https_download "$tarball_url" "$archive"
  archive_sha="$(sha256sum "$archive" | awk '{print $1}')"
  [[ "$archive_sha" == "$expected_sha256" ]] || die "更新包 SHA-256 校验失败，已拒绝覆盖当前版本"
  safe_extract_tar "$archive" "$unpack"
  mapfile -d '' -t roots < <(find "$unpack" -mindepth 1 -maxdepth 1 -print0)
  [[ "${#roots[@]}" -eq 1 && -d "${roots[0]}" ]] || die "更新包必须只包含一个顶层目录"
  src="${roots[0]}"
  [[ -f "$src/proxy-stack.sh" && -f "$src/deploy.sh" && -f "$src/app.py" \
      && -f "$src/lib/common.sh" && -f "$src/lib/render.sh" && -f "$src/VERSION" ]] \
    || die "更新包缺少必要文件"
  bash -n "$src/proxy-stack.sh" "$src/deploy.sh" "$src/lib/common.sh" "$src/lib/render.sh"
  python3 -c 'import ast,sys; ast.parse(open(sys.argv[1], encoding="utf-8").read())' "$src/app.py"
  version="$(head -n 1 "$src/VERSION" | tr -d '[:space:]')"
  [[ "$version" == "$expected_version" ]] || die "更新包版本与远程版本不一致：$version != $expected_version"
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
  local expected_sha256="${PROXY_STACK_UPDATE_SHA256:-}"
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

  [[ "$expected_sha256" =~ ^[0-9a-fA-F]{64}$ ]] \
    || die "安全更新需要先从可信渠道取得发布包 SHA-256，并设置 PROXY_STACK_UPDATE_SHA256"

  log "开始更新：${local_version} -> ${remote_version}（$(remote_source_label "$remote_source")：${remote_ref}）"
  progress_step 1 8 "下载并校验更新" download_project_payload "$SCRIPT_DIR" "$remote_tarball" "${expected_sha256,,}" "$remote_version"
  progress_step 2 8 "安装 SSH 防护" install_fail2ban_if_needed
  progress_step 3 8 "更新代理内核" bash "$SCRIPT_DIR/proxy-stack.sh" install-binaries
  progress_step 4 8 "更新入口" install_launcher
  progress_step 5 8 "续签配置" ensure_certbot_auto_renewal
  progress_step 6 8 "生成配置" bash "$SCRIPT_DIR/proxy-stack.sh" render
  progress_step 7 8 "重启服务" systemctl restart proxy-stack-xray proxy-stack-hysteria proxy-stack-sing-box proxy-stack-web nginx
  progress_step 8 8 "验证服务" bash "$SCRIPT_DIR/proxy-stack.sh" verify
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
  read_menu_input _ "按回车继续..."
}

confirm_menu_action() {
  local prompt="$1"
  local answer
  # shellcheck disable=SC1111
  read_menu_input answer "${prompt}（输入“确认”继续）："
  [[ "$answer" == "确认" ]]
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
管理：仅 SSH
IP：${PUBLIC_IP}
版本：$(local_project_version)
入口：seroncheng
================================
EOF
}

show_service_status() {
  local unit active enabled
  printf '\n%-28s %-10s %-10s\n' "服务" "状态" "自启"
  for unit in proxy-stack-xray proxy-stack-hysteria proxy-stack-sing-box proxy-stack-web nginx fail2ban certbot.timer; do
    active="$(systemctl is-active "$unit" 2>/dev/null || true)"
    enabled="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
    case "$active" in
      active) active="运行中" ;;
      inactive) active="未运行" ;;
      failed) active="故障" ;;
      activating) active="启动中" ;;
      deactivating) active="停止中" ;;
      *) active="${active:-未知}" ;;
    esac
    case "$enabled" in
      enabled) enabled="已启用" ;;
      disabled) enabled="未启用" ;;
      static) enabled="静态" ;;
      indirect) enabled="间接" ;;
      *) enabled="${enabled:-未知}" ;;
    esac
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

subscription_access_menu() {
  local choice key client_name network
  while true; do
    cat <<'EOF'

========== 订阅访问控制 ==========
通过条件：有效设备令牌 或 用户 IP/CIDR 白名单
最高安全：每台设备使用独立令牌，并绑定该设备出口 IP
-------------------------------------
1) 查看用户访问权限和订阅地址
2) 新增允许的设备
3) 撤销已允许的设备
4) 给设备令牌绑定 IP/CIDR
5) 解除设备令牌的 IP/CIDR
6) 添加用户 IP/CIDR 白名单
7) 删除用户 IP/CIDR 白名单
8) 显示用户全部分享信息
9) 查看可配置的用户列表
0) 返回主菜单
EOF
    read_menu_input choice "请选择："
    case "$choice" in
      1)
        read_menu_input key "用户名或 slug："
        [[ -n "$key" ]] && run_menu_command bash "$SCRIPT_DIR/proxy-stack.sh" user access "$key"
        pause_menu
        ;;
      2)
        read_menu_input key "用户名或 slug："
        read_menu_input client_name "设备名（例如 phone）："
        read_menu_input network "绑定 IP/CIDR（留空表示不绑定）："
        if [[ -n "$key" && -n "$client_name" ]]; then
          run_menu_command bash "$SCRIPT_DIR/proxy-stack.sh" user client-add "$key" "$client_name" "$network"
        else
          log "用户和设备名不能为空"
        fi
        pause_menu
        ;;
      3)
        read_menu_input key "用户名或 slug："
        read_menu_input client_name "要撤销的设备名："
        if [[ -n "$key" && -n "$client_name" ]] \
          && confirm_menu_action "确定撤销设备 ${client_name} 吗？"; then
          run_menu_command bash "$SCRIPT_DIR/proxy-stack.sh" user client-del "$key" "$client_name"
        else
          log "已取消撤销"
        fi
        pause_menu
        ;;
      4)
        read_menu_input key "用户名或 slug："
        read_menu_input client_name "设备名："
        read_menu_input network "要绑定的 IP/CIDR："
        if [[ -n "$key" && -n "$client_name" && -n "$network" ]]; then
          run_menu_command bash "$SCRIPT_DIR/proxy-stack.sh" user client-allow-ip "$key" "$client_name" "$network"
        else
          log "用户、设备名和 IP/CIDR 都不能为空"
        fi
        pause_menu
        ;;
      5)
        read_menu_input key "用户名或 slug："
        read_menu_input client_name "设备名："
        read_menu_input network "要解除的 IP/CIDR："
        if [[ -n "$key" && -n "$client_name" && -n "$network" ]]; then
          run_menu_command bash "$SCRIPT_DIR/proxy-stack.sh" user client-deny-ip "$key" "$client_name" "$network"
        else
          log "用户、设备名和 IP/CIDR 都不能为空"
        fi
        pause_menu
        ;;
      6)
        read_menu_input key "用户名或 slug："
        read_menu_input network "要允许的 IP/CIDR："
        if [[ -n "$key" && -n "$network" ]]; then
          run_menu_command bash "$SCRIPT_DIR/proxy-stack.sh" user allow-ip "$key" "$network"
        else
          log "用户和 IP/CIDR 不能为空"
        fi
        pause_menu
        ;;
      7)
        read_menu_input key "用户名或 slug："
        read_menu_input network "要删除的 IP/CIDR："
        if [[ -n "$key" && -n "$network" ]]; then
          run_menu_command bash "$SCRIPT_DIR/proxy-stack.sh" user deny-ip "$key" "$network"
        else
          log "用户和 IP/CIDR 不能为空"
        fi
        pause_menu
        ;;
      8)
        read_menu_input key "用户名或 slug："
        [[ -n "$key" ]] && run_menu_command bash "$SCRIPT_DIR/proxy-stack.sh" user share "$key"
        pause_menu
        ;;
      9)
        run_menu_command bash "$SCRIPT_DIR/proxy-stack.sh" user list
        pause_menu
        ;;
      0|q|Q) return 0 ;;
      *) log "未知选项：$choice"; pause_menu ;;
    esac
  done
}

ssh_security_menu() {
  local choice ip
  while true; do
    cat <<'EOF'

========== SSH 安全防护 ==========
临时规则：24 小时内失败 3 次，封禁 24 小时
永久规则：长期累计第 11 次失败，永久封禁
重犯兜底：累计 4 次临时封禁，永久封禁
----------------------------------
1) 查看 SSH 封禁状态和 IP 列表
2) 手动永久封禁 IP
3) 解除 IP 的全部封禁
4) 重新应用最高安全配置
0) 返回主菜单
EOF
    read_menu_input choice "请选择："
    case "$choice" in
      1)
        run_menu_command bash "$SCRIPT_DIR/proxy-stack.sh" security status
        pause_menu
        ;;
      2)
        read_menu_input ip "要永久封禁的 IPv4/IPv6："
        if [[ -n "$ip" ]] && confirm_menu_action "确定永久封禁 ${ip} 吗？"; then
          run_menu_command bash "$SCRIPT_DIR/proxy-stack.sh" security ban "$ip"
        else
          log "已取消封禁"
        fi
        pause_menu
        ;;
      3)
        read_menu_input ip "要解除封禁的 IPv4/IPv6："
        [[ -n "$ip" ]] && run_menu_command bash "$SCRIPT_DIR/proxy-stack.sh" security unban "$ip"
        pause_menu
        ;;
      4)
        if confirm_menu_action "确定重写并重启 SSH 安全防护吗？"; then
          run_menu_command bash "$SCRIPT_DIR/proxy-stack.sh" security apply
        else
          log "已取消重新应用"
        fi
        pause_menu
        ;;
      0|q|Q) return 0 ;;
      *) log "未知选项：$choice"; pause_menu ;;
    esac
  done
}

menu_loop() {
  require_root
  has_interactive_tty || {
    log "当前不是交互式终端，无法打开菜单；请在服务器命令行输入 seroncheng"
    return 0
  }

  local choice name prefix count start key format out_path update_sha
  while true; do
    menu_header
    cat <<'EOF'
1) 验证全部服务
2) 查看服务状态
3) 新增用户
4) 批量新增用户
5) 查看用户列表
6) 查看用户链接
7) 禁用用户
8) 启用用户
9) 删除用户
10) 导出用户数据
11) 重新生成并重载配置
12) 查看 TLS 证书状态
13) 测试 TLS 证书续签
14) 检查项目更新
15) 安全更新项目
16) 订阅访问控制
17) SSH 安全防护
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
          if confirm_menu_action "确定删除用户 ${key} 吗？"; then
            run_menu_command bash "$SCRIPT_DIR/proxy-stack.sh" user del "$key"
          else
            log "已取消删除"
          fi
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
        run_menu_command progress_step 2 3 "重启服务" systemctl restart proxy-stack-xray proxy-stack-hysteria proxy-stack-sing-box proxy-stack-web nginx
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
        read_menu_input update_sha "更新包 SHA-256："
        if [[ "$update_sha" =~ ^[0-9a-fA-F]{64}$ ]]; then
          PROXY_STACK_UPDATE_SHA256="$update_sha" run_menu_command update_project
        else
          log "SHA-256 格式无效，已取消更新"
        fi
        pause_menu
        ;;
      16)
        subscription_access_menu
        ;;
      17)
        ssh_security_menu
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
  validate_user_name "用户名" "$name"
  local slug uuid hy2
  slug="$(random_slug)"
  uuid="$(random_uuid)"
  hy2="$(random_token 18)"
  python3 - "$STATE_DIR/users.json" "$name" "$slug" "$uuid" "$hy2" <<'PY'
import json
import os
import sys
import tempfile
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
fd, tmp_name = tempfile.mkstemp(prefix=".users-", suffix=".json", dir=path.parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2, ensure_ascii=False)
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(tmp_name, 0o640)
    os.replace(tmp_name, path)
finally:
    if os.path.exists(tmp_name):
        os.unlink(tmp_name)
PY
  secure_state_file "$STATE_DIR/users.json" "$WEB_SERVICE_GROUP"
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
  validate_user_name "用户名前缀" "$prefix"
  (( ${#prefix} <= 60 )) || die "用户名前缀最多 60 位"
  python3 - "$STATE_DIR/users.json" "$prefix" "$count" "$start" <<'PY'
import json
import os
import secrets
import sys
import tempfile
import uuid
from pathlib import Path

path = Path(sys.argv[1])
prefix = sys.argv[2]
count = int(sys.argv[3])
start = int(sys.argv[4])
if not 1 <= count <= 1000:
    raise SystemExit("数量必须在 1 到 1000 之间")
if not 0 <= start <= 999_999_999:
    raise SystemExit("起始序号必须在 0 到 999999999 之间")
def rand_slug():
    return secrets.token_urlsafe(24)

def rand_token():
    return secrets.token_urlsafe(18)

data = json.loads(path.read_text())
users = data.setdefault("users", [])
existing = {u["name"] for u in users}
created = []
for idx in range(start, start + count):
    name = f"{prefix}{idx:03d}"
    if len(name) > 64:
        raise SystemExit(f"生成的用户名超过 64 位：{name}")
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
fd, tmp_name = tempfile.mkstemp(prefix=".users-", suffix=".json", dir=path.parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2, ensure_ascii=False)
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(tmp_name, 0o640)
    os.replace(tmp_name, path)
finally:
    if os.path.exists(tmp_name):
        os.unlink(tmp_name)
print("\n".join(created))
PY
  secure_state_file "$STATE_DIR/users.json" "$WEB_SERVICE_GROUP"
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
import os
import sys
import tempfile
from pathlib import Path

path = Path(sys.argv[1])
key = sys.argv[2]
want = sys.argv[3].lower() == "true"
data = json.loads(path.read_text())
users = data.setdefault("users", [])
matched = None
for user in users:
    if user.get("name") == key or user.get("slug") == key:
        user["enabled"] = want
        matched = user
        break
if matched is None:
    raise SystemExit("用户不存在")
fd, tmp_name = tempfile.mkstemp(prefix=".users-", suffix=".json", dir=path.parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2, ensure_ascii=False)
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(tmp_name, 0o640)
    os.replace(tmp_name, path)
finally:
    if os.path.exists(tmp_name):
        os.unlink(tmp_name)
print(f'{matched.get("name", key)}: {"enabled" if want else "disabled"}')
PY
  secure_state_file "$STATE_DIR/users.json" "$WEB_SERVICE_GROUP"
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
import os
import sys
import tempfile
from pathlib import Path

path = Path(sys.argv[1])
key = sys.argv[2]
data = json.loads(path.read_text())
users = data.setdefault("users", [])
filtered = [u for u in users if u.get("name") != key and u.get("slug") != key]
if len(filtered) == len(users):
    raise SystemExit("用户不存在")
data["users"] = filtered
fd, tmp_name = tempfile.mkstemp(prefix=".users-", suffix=".json", dir=path.parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2, ensure_ascii=False)
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(tmp_name, 0o640)
    os.replace(tmp_name, path)
finally:
    if os.path.exists(tmp_name):
        os.unlink(tmp_name)
PY
  secure_state_file "$STATE_DIR/users.json" "$WEB_SERVICE_GROUP"
  render_stack
  reload_stack_services
  write_runtime_info
  log "已删除用户：${key}"
}

normalize_ip_network() {
  local value="${1:?IP/CIDR 不能为空}"
  python3 - "$value" <<'PY'
import ipaddress
import sys

try:
    print(ipaddress.ip_network(sys.argv[1], strict=False))
except ValueError:
    raise SystemExit(f"IP/CIDR 无效：{sys.argv[1]}")
PY
}

validate_single_ip() {
  local value="${1:?IP 不能为空}"
  python3 - "$value" <<'PY'
import ipaddress
import sys

try:
    print(ipaddress.ip_address(sys.argv[1]))
except ValueError:
    raise SystemExit(f"IP 无效：{sys.argv[1]}")
PY
}

user_access_mutate() {
  require_root
  local operation="${1:?缺少操作}"
  local key="${2:?必须提供用户名称或 slug}"
  local client_name="${3:-}"
  local network="${4:-}"
  python3 - "$STATE_DIR/users.json" "$operation" "$key" "$client_name" "$network" <<'PY'
import json
import os
import secrets
import sys
import tempfile
from pathlib import Path

path = Path(sys.argv[1])
operation, key, client_name, network = sys.argv[2:6]
data = json.loads(path.read_text())
user = next(
    (item for item in data.setdefault("users", [])
     if item.get("name") == key or item.get("slug") == key),
    None,
)
if not user:
    raise SystemExit("用户不存在")

user.setdefault("allowed_ips", [])
clients = user.setdefault("subscription_clients", [])

if operation == "client-add":
    if any(item.get("name") == client_name for item in clients):
        raise SystemExit("设备名已存在")
    client = {
        "name": client_name,
        "token": secrets.token_urlsafe(32),
        "enabled": True,
        "allowed_ips": [network] if network else [],
    }
    clients.append(client)
    print(f'已允许设备：{client_name}')
elif operation == "client-del":
    remaining = [item for item in clients if item.get("name") != client_name]
    if len(remaining) == len(clients):
        raise SystemExit("设备不存在")
    user["subscription_clients"] = remaining
    print(f'已撤销设备：{client_name}')
elif operation in {"client-allow-ip", "client-deny-ip"}:
    client = next((item for item in clients if item.get("name") == client_name), None)
    if not client:
        raise SystemExit("设备不存在")
    values = client.setdefault("allowed_ips", [])
    if operation == "client-allow-ip":
        if network not in values:
            values.append(network)
        print(f'设备 {client_name} 已绑定：{network}')
    else:
        if network not in values:
            raise SystemExit("该设备未绑定此 IP/CIDR")
        values.remove(network)
        print(f'设备 {client_name} 已解除绑定：{network}')
elif operation == "allow-ip":
    if network not in user["allowed_ips"]:
        user["allowed_ips"].append(network)
    print(f'已允许来源：{network}')
elif operation == "deny-ip":
    if network not in user["allowed_ips"]:
        raise SystemExit("用户白名单中不存在此 IP/CIDR")
    user["allowed_ips"].remove(network)
    print(f'已移除来源：{network}')
else:
    raise SystemExit("未知的访问控制操作")

fd, tmp_name = tempfile.mkstemp(prefix=".users-", suffix=".json", dir=path.parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2, ensure_ascii=False)
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(tmp_name, 0o640)
    os.replace(tmp_name, path)
finally:
    if os.path.exists(tmp_name):
        os.unlink(tmp_name)
PY
  secure_state_file "$STATE_DIR/users.json" "$WEB_SERVICE_GROUP"
}

user_client_add() {
  local key="${1:?必须提供用户名称或 slug}"
  local client_name="${2:?必须提供设备名}"
  local network=""
  validate_user_name "设备名" "$client_name"
  [[ -z "${3:-}" ]] || network="$(normalize_ip_network "$3")"
  user_access_mutate client-add "$key" "$client_name" "$network"
  user_access "$key"
}

user_client_del() {
  local key="${1:?必须提供用户名称或 slug}"
  local client_name="${2:?必须提供设备名}"
  validate_user_name "设备名" "$client_name"
  user_access_mutate client-del "$key" "$client_name"
}

user_client_ip_change() {
  local operation="${1:?缺少操作}" key="${2:?必须提供用户名称或 slug}"
  local client_name="${3:?必须提供设备名}"
  local network
  validate_user_name "设备名" "$client_name"
  network="$(normalize_ip_network "${4:?必须提供 IP/CIDR}")"
  user_access_mutate "$operation" "$key" "$client_name" "$network"
}

user_ip_change() {
  local operation="${1:?缺少操作}" key="${2:?必须提供用户名称或 slug}"
  local network
  network="$(normalize_ip_network "${3:?必须提供 IP/CIDR}")"
  user_access_mutate "$operation" "$key" "" "$network"
}

user_access() {
  require_root
  local key="${1:?必须提供用户名称或 slug}"
  load_env
  python3 - "$STATE_DIR/users.json" "$key" "$WEB_DOMAIN" <<'PY'
import json
import sys
from pathlib import Path
from urllib.parse import quote

users = json.loads(Path(sys.argv[1]).read_text()).get("users", [])
key, domain = sys.argv[2:4]
user = next((item for item in users if item.get("name") == key or item.get("slug") == key), None)
if not user:
    raise SystemExit("用户不存在")

print(f'用户：{user["name"]}')
print('用户 IP/CIDR 白名单：' + (', '.join(user.get("allowed_ips", [])) or '无'))
clients = user.get("subscription_clients", [])
if not clients:
    print('允许的设备：无')
for client in clients:
    status = '启用' if client.get("enabled", True) else '禁用'
    bound = ', '.join(client.get("allowed_ips", [])) or '任意来源 IP'
    token = str(client.get("token", ""))
    print(f'\n设备：{client.get("name", "unnamed")} [{status}]')
    print(f'绑定：{bound}')
    print(f'令牌：{token}')
    if token and client.get("enabled", True):
        query = quote(token, safe="")
        print(f'交付页面：https://{domain}/web/{user["slug"]}?client={query}')
        print(f'通用订阅：https://{domain}/link/{user["slug"]}?client={query}')
        print(f'Mihomo配置：https://{domain}/mihomo/{user["slug"]}?client={query}')
PY
}

user_list() {
  require_root
  jq -r '.users[] | [.name, .slug, (if .enabled then "启用" else "禁用" end)] | @tsv' "$STATE_DIR/users.json"
}

user_show() {
  require_root
  local key="${1:?必须提供用户名称或 slug}"
  load_env
  python3 - "$STATE_DIR/users.json" "$key" "$WEB_DOMAIN" "$PUBLIC_IP" "$REALITY_PUBLIC_KEY" "$REALITY_SNI" "$REALITY_SHORT_ID" "$HY2_OBFS_PASSWORD" "$ANYTLS_PORT" "$TUIC_PORT" "$NAIVE_PORT" <<'PY'
import json
import sys
from pathlib import Path
from urllib.parse import quote

users = json.loads(Path(sys.argv[1]).read_text()).get("users", [])
key, domain, public_ip, pbk, sni, sid, obfs, anytls_port, tuic_port, naive_port = sys.argv[2:12]
u = None
for item in users:
    if item["name"] == key or item["slug"] == key:
        u = item
        break
if not u:
    raise SystemExit("用户不存在")
client_token = next(
    (str(item.get("token", "")) for item in u.get("subscription_clients", [])
     if item.get("enabled", True) and item.get("token")),
    "",
)
subscription_query = f'?client={quote(client_token, safe="")}' if client_token else ""
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
anytls = (
    f'anytls://{quote(u["anytls_password"], safe="")}@{public_ip}:{anytls_port}'
    f'?security=tls&sni={quote(domain)}&fp=chrome#{quote(u["name"] + "-anytls")}'
)
tuic = (
    f'tuic://{quote(u["tuic_uuid"], safe="")}:{quote(u["tuic_password"], safe="")}@{public_ip}:{tuic_port}'
    f'?sni={quote(domain)}&alpn=h3&congestion_control=bbr&udp_relay_mode=native'
    f'&zero_rtt_handshake=false#{quote(u["name"] + "-tuic")}'
)
naive = (
    f'naive+https://{quote(u["naive_username"], safe="")}:{quote(u["naive_password"], safe="")}'
    f'@{domain}:{naive_port}#{quote(u["name"] + "-naive")}'
)
print(f'用户名：{u["name"]}')
print(f'短码：{u["slug"]}')
print(f'交付页面：https://{domain}/web/{u["slug"]}{subscription_query}')
print(f'通用订阅：https://{domain}/link/{u["slug"]}{subscription_query}')
print(f'Mihomo配置：https://{domain}/mihomo/{u["slug"]}{subscription_query}')
print(f'原始节点：https://{domain}/node/{u["slug"]}{subscription_query}')
print(f'VLESS链接：{vless}')
print(f'Hysteria2链接：{hy2}')
print(f'AnyTLS链接：{anytls}')
print(f'TUIC链接：{tuic}')
print(f'NaiveProxy链接：{naive}')
PY
}

user_share() {
  require_root
  local key="${1:?必须提供用户名称或 slug}"
  load_env
  python3 - "$STATE_DIR/users.json" "$key" "$WEB_DOMAIN" "$PUBLIC_IP" "$REALITY_PUBLIC_KEY" "$REALITY_SNI" "$REALITY_SHORT_ID" "$HY2_OBFS_PASSWORD" "$ANYTLS_PORT" "$TUIC_PORT" "$NAIVE_PORT" <<'PY'
import json
import sys
from pathlib import Path
from urllib.parse import quote

users = json.loads(Path(sys.argv[1]).read_text()).get("users", [])
key, domain, public_ip, pbk, sni, sid, obfs, anytls_port, tuic_port, naive_port = sys.argv[2:12]
u = None
for item in users:
    if item["name"] == key or item["slug"] == key:
        u = item
        break
if not u:
    raise SystemExit("用户不存在")
client_token = next(
    (str(item.get("token", "")) for item in u.get("subscription_clients", [])
     if item.get("enabled", True) and item.get("token")),
    "",
)
subscription_query = f'?client={quote(client_token, safe="")}' if client_token else ""
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
anytls = (
    f'anytls://{quote(u["anytls_password"], safe="")}@{public_ip}:{anytls_port}'
    f'?security=tls&sni={quote(domain)}&fp=chrome#{quote(u["name"] + "-anytls")}'
)
tuic = (
    f'tuic://{quote(u["tuic_uuid"], safe="")}:{quote(u["tuic_password"], safe="")}@{public_ip}:{tuic_port}'
    f'?sni={quote(domain)}&alpn=h3&congestion_control=bbr&udp_relay_mode=native'
    f'&zero_rtt_handshake=false#{quote(u["name"] + "-tuic")}'
)
naive = (
    f'naive+https://{quote(u["naive_username"], safe="")}:{quote(u["naive_password"], safe="")}'
    f'@{domain}:{naive_port}#{quote(u["name"] + "-naive")}'
)
print(f"""[{u['name']}]
交付页面: https://{domain}/web/{u['slug']}{subscription_query}
通用订阅: https://{domain}/link/{u['slug']}{subscription_query}
Mihomo配置: https://{domain}/mihomo/{u['slug']}{subscription_query}
原始节点: https://{domain}/node/{u['slug']}{subscription_query}

VLESS:
{vless}

Hysteria2:
{hy2}

AnyTLS:
{anytls}

TUIC v5:
{tuic}

NaiveProxy:
{naive}
""")
PY
}

validate_export_path() {
  local format="$1" value="$2" canonical
  validate_safe_absolute_path "导出路径" "$value"
  [[ "$value" != *"/../"* && "$value" != */.. && "$value" != *"/./"* ]] \
    || die "导出路径不能包含 . 或 .. 路径段"
  canonical="$(realpath -m -- "$value")" || die "无法规范化导出路径"
  case "$canonical" in
    /root/*|/home/*/*|/var/backups/*) ;;
    *) die "导出文件只允许写入 /root、/home/<用户> 或 /var/backups 的子目录" ;;
  esac
  [[ ! -L "$value" ]] || die "导出目标不能是符号链接"
  [[ ! -e "$canonical" || -f "$canonical" ]] || die "导出目标已存在但不是普通文件"
  case "$format:$canonical" in
    csv:*.csv|json:*.json|text:*.txt) ;;
    *) die "导出文件扩展名必须与格式匹配（.csv/.json/.txt）" ;;
  esac
  printf '%s\n' "$canonical"
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
  out_path="$(validate_export_path "$format" "$out_path")"
  python3 - "$STATE_DIR/users.json" "$format" "$out_path" "$WEB_DOMAIN" "$PUBLIC_IP" "$REALITY_PUBLIC_KEY" "$REALITY_SNI" "$REALITY_SHORT_ID" "$HY2_OBFS_PASSWORD" "$ANYTLS_PORT" "$TUIC_PORT" "$NAIVE_PORT" <<'PY'
import csv
import json
import os
import sys
import tempfile
from pathlib import Path
from urllib.parse import quote

users_path = Path(sys.argv[1])
fmt = sys.argv[2]
out_path = Path(sys.argv[3])
domain, public_ip, pbk, sni, sid, obfs, anytls_port, tuic_port, naive_port = sys.argv[4:13]
users = json.loads(users_path.read_text()).get("users", [])

rows = []
for u in users:
    client_token = next(
        (str(item.get("token", "")) for item in u.get("subscription_clients", [])
         if item.get("enabled", True) and item.get("token")),
        "",
    )
    subscription_query = f'?client={quote(client_token, safe="")}' if client_token else ""
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
    anytls = (
        f'anytls://{quote(u["anytls_password"], safe="")}@{public_ip}:{anytls_port}'
        f'?security=tls&sni={quote(domain)}&fp=chrome#{quote(u["name"] + "-anytls")}'
    )
    tuic = (
        f'tuic://{quote(u["tuic_uuid"], safe="")}:{quote(u["tuic_password"], safe="")}@{public_ip}:{tuic_port}'
        f'?sni={quote(domain)}&alpn=h3&congestion_control=bbr&udp_relay_mode=native'
        f'&zero_rtt_handshake=false#{quote(u["name"] + "-tuic")}'
    )
    naive = (
        f'naive+https://{quote(u["naive_username"], safe="")}:{quote(u["naive_password"], safe="")}'
        f'@{domain}:{naive_port}#{quote(u["name"] + "-naive")}'
    )
    rows.append({
        "name": u["name"],
        "slug": u["slug"],
        "enabled": bool(u.get("enabled", True)),
        "web": f'https://{domain}/web/{u["slug"]}{subscription_query}',
        "link": f'https://{domain}/link/{u["slug"]}{subscription_query}',
        "mihomo": f'https://{domain}/mihomo/{u["slug"]}{subscription_query}',
        "node": f'https://{domain}/node/{u["slug"]}{subscription_query}',
        "vless": vless,
        "hy2": hy2,
        "anytls": anytls,
        "tuic": tuic,
        "naive": naive,
    })

out_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
fd, tmp_name = tempfile.mkstemp(prefix=".proxy-stack-export-", dir=out_path.parent)
try:
    with os.fdopen(fd, "w", newline="" if fmt == "csv" else None, encoding="utf-8") as f:
        if fmt == "json":
            json.dump(rows, f, indent=2, ensure_ascii=False)
        elif fmt == "csv":
            writer = csv.DictWriter(f, fieldnames=["name", "slug", "enabled", "web", "link", "mihomo", "node", "vless", "hy2", "anytls", "tuic", "naive"])
            writer.writeheader()
            writer.writerows(rows)
        else:
            for row in rows:
                f.write(
                    f"[{row['name']}]\n"
                    f"状态: {'启用' if row['enabled'] else '禁用'}\n"
                    f"交付页面: {row['web']}\n"
                    f"通用订阅: {row['link']}\n"
                    f"Mihomo配置: {row['mihomo']}\n"
                    f"原始节点: {row['node']}\n"
                    f"VLESS链接: {row['vless']}\n"
                    f"Hysteria2链接: {row['hy2']}\n\n"
                    f"AnyTLS链接: {row['anytls']}\n"
                    f"TUIC链接: {row['tuic']}\n"
                    f"NaiveProxy链接: {row['naive']}\n\n"
                )
        f.flush()
        os.fsync(f.fileno())
    os.chmod(tmp_name, 0o600)
    os.replace(tmp_name, out_path)
finally:
    if os.path.exists(tmp_name):
        os.unlink(tmp_name)
print(out_path)
PY
  chmod 0600 "$out_path"
}

fail2ban_status_value() {
  local output="$1" label="$2"
  awk -v label="$label" '
    index($0, label ":") {
      sub("^.*" label ":[[:space:]]*", "")
      print
      exit
    }
  ' <<<"$output"
}

security_status() {
  require_root
  require_cmd fail2ban-client
  systemctl is-active --quiet fail2ban || die "Fail2ban 未运行"
  local jail title output current_failed total_failed current_banned total_banned banned_ips
  printf '\n========== SSH 封禁状态 ==========\n'
  printf '服务状态：运行中\n'
  printf '临时规则：24 小时内失败 3 次，封禁 24 小时\n'
  printf '永久规则：长期累计第 11 次失败，永久封禁\n'
  printf '重犯兜底：累计 4 次临时封禁，永久封禁\n'
  for jail in proxy-stack-sshd-day proxy-stack-sshd-permanent proxy-stack-recidive; do
    case "$jail" in
      proxy-stack-sshd-day) title="24 小时临时封禁" ;;
      proxy-stack-sshd-permanent) title="SSH 失败累计永久封禁" ;;
      proxy-stack-recidive) title="重复违规永久封禁" ;;
    esac
    output="$(fail2ban-client status "$jail")" || die "读取 ${title} 状态失败"
    current_failed="$(fail2ban_status_value "$output" "Currently failed")"
    total_failed="$(fail2ban_status_value "$output" "Total failed")"
    current_banned="$(fail2ban_status_value "$output" "Currently banned")"
    total_banned="$(fail2ban_status_value "$output" "Total banned")"
    banned_ips="$(fail2ban_status_value "$output" "Banned IP list")"
    printf '\n[%s]\n' "$title"
    printf '当前失败记录：%s\n' "${current_failed:-0}"
    printf '累计失败记录：%s\n' "${total_failed:-0}"
    printf '当前封禁数量：%s\n' "${current_banned:-0}"
    printf '累计封禁数量：%s\n' "${total_banned:-0}"
    printf '已封禁 IP：%s\n' "${banned_ips:-无}"
  done
}

security_apply() {
  require_root
  install_fail2ban_if_needed
  write_fail2ban_config
  quiet_cmd "检查 Fail2ban 配置" fail2ban-client -t
  quiet_cmd "启用 SSH 安全防护" systemctl enable --now fail2ban
  quiet_cmd "重启 SSH 安全防护" systemctl restart fail2ban
  log "已重新应用 SSH 最高安全配置"
  security_status
}

security_ban() {
  require_root
  require_cmd fail2ban-client python3
  local ip
  ip="$(validate_single_ip "${1:?必须提供 IP}")"
  systemctl is-active --quiet fail2ban || die "Fail2ban 未运行"
  fail2ban-client set proxy-stack-sshd-permanent banip "$ip" >/dev/null
  log "已永久封禁：${ip}"
}

security_unban() {
  require_root
  require_cmd fail2ban-client python3
  local ip jail
  ip="$(validate_single_ip "${1:?必须提供 IP}")"
  systemctl is-active --quiet fail2ban || die "Fail2ban 未运行"
  for jail in proxy-stack-sshd-day proxy-stack-sshd-permanent proxy-stack-recidive; do
    fail2ban-client set "$jail" unbanip "$ip" >/dev/null 2>&1 || true
  done
  log "已从全部 SSH 封禁列表解除：${ip}"
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
  install-binaries) require_root; ensure_dirs; install_pinned_proxy_binaries ;;
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
      client-add) user_client_add "${3:-}" "${4:-}" "${5:-}" ;;
      client-del) user_client_del "${3:-}" "${4:-}" ;;
      client-allow-ip) user_client_ip_change client-allow-ip "${3:-}" "${4:-}" "${5:-}" ;;
      client-deny-ip) user_client_ip_change client-deny-ip "${3:-}" "${4:-}" "${5:-}" ;;
      allow-ip) user_ip_change allow-ip "${3:-}" "${4:-}" ;;
      deny-ip) user_ip_change deny-ip "${3:-}" "${4:-}" ;;
      access) user_access "${3:-}" ;;
      *) usage; exit 1 ;;
    esac
    ;;
  security)
    sub="${2:-}"
    case "$sub" in
      status) security_status ;;
      ban) security_ban "${3:-}" ;;
      unban) security_unban "${3:-}" ;;
      apply) security_apply ;;
      *) usage; exit 1 ;;
    esac
    ;;
  uninstall-3xui) uninstall_3xui ;;
  package) package_project ;;
  *) usage; exit 1 ;;
esac

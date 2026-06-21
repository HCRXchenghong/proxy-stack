#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="/etc/proxy-stack"
RUNTIME_DIR="/opt/proxy-stack"
WEB_ROOT="/var/www/proxy-stack"
ACME_HOME="$RUNTIME_DIR/acme.sh"
XRAY_HOME="$RUNTIME_DIR/xray"
BIN_DIR="$RUNTIME_DIR/bin"
NGINX_HTTP_CONF="/etc/nginx/conf.d/proxy-stack-http.conf"
NGINX_STREAM_CONF="/etc/nginx/stream-conf.d/proxy-stack-stream.conf"
NGINX_ACME_CONF="/etc/nginx/conf.d/proxy-stack-acme.conf"
SYSTEMD_DIR="/etc/systemd/system"
APP_PORT="9080"
WEB_TLS_PORT="9443"
MGMT_TLS_PORT="9444"
VLESS_INTERNAL_PORT="10443"

log() {
  printf '[proxy-stack] %s\n' "$*"
}

die() {
  printf '[proxy-stack] 错误：%s\n' "$*" >&2
  exit 1
}

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "请使用 root 运行"
}

require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "缺少命令：$cmd"
  done
}

is_placeholder_domain() {
  local domain
  domain="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$domain" in
    example.com|*.example.com|example.net|*.example.net|example.org|*.example.org|localhost|*.localhost|invalid|*.invalid|test|*.test)
      return 0
      ;;
  esac
  return 1
}

is_valid_domain() {
  local domain
  domain="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  [[ "$domain" != *"://"* ]] || return 1
  [[ "$domain" != */* ]] || return 1
  [[ "$domain" != .* && "$domain" != *. ]] || return 1
  [[ "$domain" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
}

validate_domain() {
  local label="$1"
  local domain="$2"
  is_valid_domain "$domain" || die "$label 必须是真实域名，不能包含 http:// 或路径：$domain"
  ! is_placeholder_domain "$domain" || die "$label 仍然是示例/保留域名：$domain"
}

validate_email() {
  local label="$1"
  local email="$2"
  is_valid_email "$email" || die "$label 必须是有效的真实邮箱地址：$email"
}

is_valid_email() {
  local email="$1"
  local email_domain="${email##*@}"
  [[ "$email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || return 1
  ! is_placeholder_domain "$email_domain"
}

prompt_value_if_tty() {
  local var_name="$1"
  local prompt="$2"
  local current_value="${!var_name:-}"
  if [[ -n "$current_value" ]]; then
    return 0
  fi
  if [[ -r /dev/tty && -w /dev/tty ]]; then
    printf '%s: ' "$prompt" >/dev/tty
    IFS= read -r current_value </dev/tty
  elif [[ -t 0 ]]; then
    read -r -p "$prompt: " current_value
  else
    return 0
  fi
  printf -v "$var_name" '%s' "$current_value"
}

validate_ipv4() {
  local label="$1"
  local ip="$2"
  local IFS=.
  local -a parts
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "$label 必须是 IPv4 地址：$ip"
  read -r -a parts <<<"$ip"
  local part
  for part in "${parts[@]}"; do
    (( 10#$part >= 0 && 10#$part <= 255 )) || die "$label 包含无效的 IPv4 数字段：$ip"
  done
}

ensure_dirs() {
  mkdir -p "$STATE_DIR" "$RUNTIME_DIR" "$WEB_ROOT" "$BIN_DIR" /etc/nginx/stream-conf.d
}

load_env() {
  local env_file="$STATE_DIR/stack.env"
  [[ -f "$env_file" ]] || die "缺少配置文件：$env_file"
  # shellcheck disable=SC1090
  source "$env_file"
}

save_env() {
  local env_file="$STATE_DIR/stack.env"
  cat >"$env_file"
  chmod 600 "$env_file"
}

json_get() {
  local file="$1"
  local filter="$2"
  jq -r "$filter" "$file"
}

random_slug() {
  python3 - <<'PY'
import secrets
import string

alphabet = string.ascii_letters + string.digits
print("".join(secrets.choice(alphabet) for _ in range(10)))
PY
}

random_hex() {
  local n="${1:-8}"
  openssl rand -hex "$n"
}

random_token() {
  local n="${1:-24}"
  openssl rand -base64 "$n" | tr -d '\n' | tr '/+' '_-'
}

random_uuid() {
  python3 - <<'PY'
import uuid
print(uuid.uuid4())
PY
}

public_ipv4() {
  if [[ -n "${PUBLIC_IP_OVERRIDE:-}" ]]; then
    printf '%s\n' "$PUBLIC_IP_OVERRIDE"
    return
  fi
  curl -fsSL --max-time 10 https://api.ipify.org
}

resolve_domain_ipv4s() {
  local domain="$1"
  getent ahostsv4 "$domain" | awk '{print $1}' | sort -u
}

preflight_acme_dns() {
  local public_ip="$1"
  shift
  local domain ips bad_ips flat_ips
  for domain in "$@"; do
    ips="$(resolve_domain_ipv4s "$domain" || true)"
    if [[ -z "$ips" ]]; then
      die "$domain 没有 IPv4 A 记录。申请 Let's Encrypt 证书前，请先把它解析到 $public_ip。"
    fi
    bad_ips="$(printf '%s\n' "$ips" | grep -Fxv "$public_ip" || true)"
    if [[ -n "$bad_ips" ]]; then
      flat_ips="$(printf '%s' "$ips" | paste -sd ',' -)"
      die "$domain 当前解析到 $flat_ips。申请 Let's Encrypt 证书前，所有 IPv4 A 记录都必须指向本机公网 IP $public_ip。"
    fi
  done
}

ensure_nginx_stream_include() {
  grep -q 'include /etc/nginx/stream-conf.d/\*.conf;' /etc/nginx/nginx.conf && return 0
  python3 - <<'PY'
import re
from pathlib import Path

path = Path("/etc/nginx/nginx.conf")
text = path.read_text()
include = "    include /etc/nginx/stream-conf.d/*.conf;"
if "include /etc/nginx/stream-conf.d/*.conf;" in text:
    raise SystemExit(0)

if re.search(r"(?m)^stream\s*\{", text):
    text = re.sub(r"(?m)^(stream\s*\{\s*)$", rf"\1\n{include}", text, count=1)
else:
    text = text.rstrip() + "\n\nstream {\n" + include + "\n}\n"

path.write_text(text)
PY
}

reload_nginx() {
  nginx -t
  if systemctl is-active --quiet nginx; then
    systemctl reload nginx
  else
    systemctl restart nginx
  fi
}

systemd_reload() {
  systemctl daemon-reload
}

disable_legacy_hcrx_conf() {
  local legacy="/etc/nginx/conf.d/hcrx-ltd.conf"
  local backup="/etc/nginx/conf.d/hcrx-ltd.conf.proxy-stack.bak"
  if [[ -f "$legacy" ]]; then
    mv "$legacy" "$backup"
    log "已禁用旧 nginx 站点配置：$legacy -> $backup"
  fi
}

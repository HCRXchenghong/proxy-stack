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
  printf '[proxy-stack] ERROR: %s\n' "$*" >&2
  exit 1
}

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "run as root"
}

require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "missing command: $cmd"
  done
}

ensure_dirs() {
  mkdir -p "$STATE_DIR" "$RUNTIME_DIR" "$WEB_ROOT" "$BIN_DIR" /etc/nginx/stream-conf.d
}

load_env() {
  local env_file="$STATE_DIR/stack.env"
  [[ -f "$env_file" ]] || die "missing $env_file"
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
  openssl rand -base64 9 | tr -dc 'a-zA-Z0-9' | head -c 10
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
  systemctl reload nginx
}

systemd_reload() {
  systemctl daemon-reload
}

disable_legacy_hcrx_conf() {
  local legacy="/etc/nginx/conf.d/hcrx-ltd.conf"
  local backup="/etc/nginx/conf.d/hcrx-ltd.conf.proxy-stack.bak"
  if [[ -f "$legacy" ]]; then
    mv "$legacy" "$backup"
    log "disabled legacy nginx vhost: $legacy -> $backup"
  fi
}

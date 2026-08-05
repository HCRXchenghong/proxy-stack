#!/usr/bin/env bash
set -euo pipefail
umask 077

# This file is sourced by multiple scripts; many globals are consumed by the caller.
# shellcheck disable=SC2034
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="/etc/proxy-stack"
RUNTIME_DIR="/opt/proxy-stack"
WEB_ROOT="/var/www/proxy-stack"
BIN_DIR="$RUNTIME_DIR/bin"
WEB_SERVICE_USER="proxy-stack-web"
WEB_SERVICE_GROUP="proxy-stack-web"
XRAY_SERVICE_USER="proxy-stack-xray"
XRAY_SERVICE_GROUP="proxy-stack-xray"
HYSTERIA_SERVICE_USER="proxy-stack-hysteria"
HYSTERIA_SERVICE_GROUP="proxy-stack-hysteria"
SING_BOX_SERVICE_USER="proxy-stack-sing-box"
SING_BOX_SERVICE_GROUP="proxy-stack-sing-box"
TLS_SERVICE_GROUP="proxy-stack-tls"
SERVICE_TLS_DIR="$STATE_DIR/tls"
NGINX_HTTP_CONF="/etc/nginx/conf.d/proxy-stack-http.conf"
NGINX_STREAM_CONF="/etc/nginx/stream-conf.d/proxy-stack-stream.conf"
NGINX_ACME_CONF="/etc/nginx/conf.d/proxy-stack-acme.conf"
FAIL2BAN_MAIN_CONF="/etc/fail2ban/fail2ban.d/proxy-stack.local"
FAIL2BAN_JAIL_CONF="/etc/fail2ban/jail.d/proxy-stack-sshd.local"
SYSTEMD_DIR="/etc/systemd/system"
APP_PORT="9080"
WEB_TLS_PORT="9443"
VLESS_INTERNAL_PORT="10443"
ANYTLS_PORT="8443"
TUIC_PORT="8443"
NAIVE_PORT="8444"
HTTPS_PORT="8445"
PROXY_STACK_LOG_FILE="${PROXY_STACK_LOG_FILE:-/var/log/proxy-stack.log}"

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

curl_https_download() {
  local url="$1"
  local output="$2"
  local max_time="${3:-300}"
  [[ "$url" == https://* ]] || die "拒绝非 HTTPS 下载地址：$url"
  [[ "$max_time" =~ ^[0-9]+$ ]] || die "下载超时参数无效"
  curl --fail --silent --show-error --location \
    --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --connect-timeout 10 --max-time "$max_time" \
    --retry 3 --retry-delay 2 --retry-all-errors \
    --max-filesize 536870912 \
    --output "$output" -- "$url"
}

safe_extract_archive() {
  local archive_type="$1"
  local archive="$2"
  local destination="$3"
  require_cmd python3
  [[ -f "$archive" ]] || die "归档文件不存在：$archive"
  [[ "$archive_type" == "tar" || "$archive_type" == "zip" ]] \
    || die "不支持的归档类型：$archive_type"
  install -d -m 0700 "$destination"
  python3 - "$archive_type" "$archive" "$destination" <<'PY'
import os
import shutil
import stat
import sys
import tarfile
import zipfile
from pathlib import Path

archive_type, archive_name, destination_name = sys.argv[1:4]
archive = Path(archive_name)
destination = Path(destination_name)
MAX_MEMBERS = 10_000
MAX_MEMBER_SIZE = 256 * 1024 * 1024
MAX_TOTAL_SIZE = 512 * 1024 * 1024


def clean_parts(name):
    if not isinstance(name, str) or not name or len(name) > 1024:
        raise ValueError("归档成员名称无效")
    if name.startswith("/") or "\\" in name or "\x00" in name:
        raise ValueError(f"归档包含危险路径：{name!r}")
    stripped = name[:-1] if name.endswith("/") else name
    parts = stripped.split("/")
    if not stripped or any(part in {"", ".", ".."} for part in parts):
        raise ValueError(f"归档包含危险路径：{name!r}")
    return tuple(parts)


def validate_entries(entries):
    if len(entries) > MAX_MEMBERS:
        raise ValueError("归档成员数量超过安全上限")
    seen = set()
    files = set()
    total_size = 0
    for entry in entries:
        parts = entry["parts"]
        if parts in seen:
            raise ValueError("归档包含重复路径")
        seen.add(parts)
        if entry["kind"] == "file":
            size = entry["size"]
            if size < 0 or size > MAX_MEMBER_SIZE:
                raise ValueError("归档单个文件超过安全上限")
            total_size += size
            files.add(parts)
        if entry["mode"] & 0o7000:
            raise ValueError("归档包含 setuid/setgid/sticky 权限")
    if total_size > MAX_TOTAL_SIZE:
        raise ValueError("归档解压总大小超过安全上限")
    for entry in entries:
        parts = entry["parts"]
        for index in range(1, len(parts)):
            if parts[:index] in files:
                raise ValueError("归档中文件与目录路径发生冲突")


def write_entries(entries, opener):
    directories = []
    for entry in entries:
        target = destination.joinpath(*entry["parts"])
        if entry["kind"] == "dir":
            target.mkdir(parents=True, exist_ok=True)
            directories.append((target, entry["mode"]))
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        source = opener(entry["source"])
        if source is None:
            raise ValueError("归档普通文件无法读取")
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        fd = os.open(target, flags, 0o600)
        try:
            with source, os.fdopen(fd, "wb") as output:
                shutil.copyfileobj(source, output, length=1024 * 1024)
        except Exception:
            try:
                os.close(fd)
            except OSError:
                pass
            raise
        os.chmod(target, entry["mode"] & 0o777)
    for target, mode in sorted(directories, key=lambda item: len(item[0].parts), reverse=True):
        os.chmod(target, mode & 0o777)


try:
    if archive_type == "tar":
        with tarfile.open(archive, mode="r:*") as handle:
            entries = []
            for member in handle.getmembers():
                if member.isfile():
                    kind = "file"
                elif member.isdir():
                    kind = "dir"
                else:
                    raise ValueError(f"归档包含链接或特殊文件：{member.name!r}")
                entries.append({
                    "parts": clean_parts(member.name),
                    "kind": kind,
                    "size": member.size,
                    "mode": member.mode,
                    "source": member,
                })
            validate_entries(entries)
            write_entries(entries, handle.extractfile)
    else:
        with zipfile.ZipFile(archive) as handle:
            entries = []
            for info in handle.infolist():
                mode = (info.external_attr >> 16) & 0xFFFF
                file_type = stat.S_IFMT(mode)
                if info.flag_bits & 0x1:
                    raise ValueError("归档包含加密成员")
                if info.is_dir():
                    kind = "dir"
                elif file_type not in {0, stat.S_IFREG}:
                    raise ValueError(f"归档包含链接或特殊文件：{info.filename!r}")
                else:
                    kind = "file"
                entries.append({
                    "parts": clean_parts(info.filename),
                    "kind": kind,
                    "size": info.file_size,
                    "mode": mode or (0o755 if kind == "dir" else 0o644),
                    "source": info,
                })
            validate_entries(entries)
            write_entries(entries, handle.open)
except (OSError, tarfile.TarError, zipfile.BadZipFile, ValueError) as exc:
    raise SystemExit(f"安全解压失败：{exc}")
PY
}

safe_extract_tar() {
  safe_extract_archive tar "$1" "$2"
}

safe_extract_zip() {
  safe_extract_archive zip "$1" "$2"
}

ensure_log_file() {
  local dir
  dir="$(dirname "$PROXY_STACK_LOG_FILE")"
  mkdir -p "$dir"
  touch "$PROXY_STACK_LOG_FILE"
  chmod 600 "$PROXY_STACK_LOG_FILE" 2>/dev/null || true
}

quiet_cmd() {
  local label="$1"
  shift
  ensure_log_file
  if ! "$@" >>"$PROXY_STACK_LOG_FILE" 2>&1; then
    die "${label}失败，详细日志：$PROXY_STACK_LOG_FILE"
  fi
}

progress_bar() {
  local current="$1"
  local total="$2"
  local width=24
  local filled empty percent
  (( total > 0 )) || total=1
  (( current < 0 )) && current=0
  (( current > total )) && current="$total"
  filled=$((current * width / total))
  empty=$((width - filled))
  percent=$((current * 100 / total))
  printf '['
  printf '%*s' "$filled" '' | tr ' ' '#'
  printf '%*s' "$empty" '' | tr ' ' '-'
  printf '] %3d%%' "$percent"
}

progress_step() {
  local current="$1"
  local total="$2"
  local label="$3"
  local bar
  shift 3
  ensure_log_file
  bar="$(progress_bar "$current" "$total")"
  printf '%s %s ... ' "$bar" "$label"
  if ( "$@" ) >>"$PROXY_STACK_LOG_FILE" 2>&1; then
    printf '完成\n'
  else
    printf '失败\n' >&2
    die "${label}失败，详细日志：$PROXY_STACK_LOG_FILE"
  fi
}

is_placeholder_domain() {
  local domain
  domain="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$domain" in
    example.com|*.example.com|example.net|*.example.net|example.org|*.example.org|your-domain.com|*.your-domain.com|your-real-domain.com|*.your-real-domain.com|localhost|*.localhost|invalid|*.invalid|test|*.test)
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
  [[ "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,63}$ ]] || return 1
  ! is_placeholder_domain "$email_domain"
}

validate_safe_absolute_path() {
  local label="$1"
  local path="$2"
  [[ "$path" =~ ^/[A-Za-z0-9._/+:@-]+$ ]] || die "$label 必须是仅含安全字符的绝对路径：$path"
}

validate_reality_target() {
  local target="$1"
  local host="${target%:*}"
  local port="${target##*:}"
  is_valid_domain "$host" || die "--reality-target 主机名无效：$target"
  if [[ ! "$port" =~ ^[0-9]+$ ]] || (( 10#$port < 1 || 10#$port > 65535 )); then
    die "--reality-target 端口无效：$target"
  fi
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
  ensure_service_account
  install -d -m 0751 -o root -g root "$STATE_DIR"
  install -d -m 0750 -o root -g "$TLS_SERVICE_GROUP" "$SERVICE_TLS_DIR"
  install -d -m 0755 -o root -g root "$RUNTIME_DIR" "$BIN_DIR" "$WEB_ROOT" /etc/nginx/stream-conf.d
}

ensure_service_account() {
  local pair user group
  for pair in \
    "$WEB_SERVICE_USER:$WEB_SERVICE_GROUP" \
    "$XRAY_SERVICE_USER:$XRAY_SERVICE_GROUP" \
    "$HYSTERIA_SERVICE_USER:$HYSTERIA_SERVICE_GROUP" \
    "$SING_BOX_SERVICE_USER:$SING_BOX_SERVICE_GROUP"; do
    user="${pair%%:*}"
    group="${pair##*:}"
    getent group "$group" >/dev/null 2>&1 || groupadd --system "$group"
    if ! id -u "$user" >/dev/null 2>&1; then
      useradd --system --gid "$group" --home-dir /nonexistent --shell /usr/sbin/nologin "$user"
    fi
  done
  getent group "$TLS_SERVICE_GROUP" >/dev/null 2>&1 || groupadd --system "$TLS_SERVICE_GROUP"
}

secure_state_file() {
  local path="$1"
  local group="${2:-$WEB_SERVICE_GROUP}"
  chown root:"$group" "$path"
  chmod 0640 "$path"
}

secure_root_file() {
  local path="$1"
  chown root:root "$path"
  chmod 0600 "$path"
}

sync_service_tls_material() {
  load_env
  ensure_service_account
  install -d -m 0750 -o root -g "$TLS_SERVICE_GROUP" "$SERVICE_TLS_DIR"
  install -m 0640 -o root -g "$TLS_SERVICE_GROUP" "$TLS_CERT_FILE" "$SERVICE_TLS_DIR/fullchain.pem"
  install -m 0640 -o root -g "$TLS_SERVICE_GROUP" "$TLS_KEY_FILE" "$SERVICE_TLS_DIR/privkey.pem"
}

load_env() {
  local env_file="$STATE_DIR/stack.env"
  [[ -f "$env_file" ]] || die "缺少配置文件：$env_file"
  # shellcheck disable=SC1090
  source "$env_file"
}

save_env() {
  local env_file="$STATE_DIR/stack.env"
  local tmp_file
  tmp_file="$(mktemp "$STATE_DIR/.stack.env.XXXXXX")"
  cat >"$tmp_file"
  secure_root_file "$tmp_file"
  mv -f "$tmp_file" "$env_file"
}

ensure_env_defaults() {
  local env_file="$STATE_DIR/stack.env"
  local rotated_obfs rotated_short_id rotated_private rotated_public xray_out tmp_file internal_proxy_token
  [[ -f "$env_file" ]] || die "缺少配置文件：$env_file"
  if ! grep -q '^SECURITY_SCHEMA_VERSION=2$' "$env_file"; then
    rotated_obfs="$(random_token 24)"
    rotated_short_id="$(random_hex 8)"
    rotated_private=""
    rotated_public=""
    if [[ -x "$BIN_DIR/xray" ]]; then
      xray_out="$("$BIN_DIR/xray" x25519)"
      rotated_private="$(printf '%s\n' "$xray_out" | awk 'index($0,"PrivateKey:")==1 {print $2}')"
      rotated_public="$(printf '%s\n' "$xray_out" | awk 'index($0,"Password (PublicKey):")==1 {print $3}')"
      [[ -n "$rotated_private" && -n "$rotated_public" ]] \
        || die "安全迁移时生成 REALITY 密钥失败"
    fi
    tmp_file="$(mktemp "$STATE_DIR/.stack.env.XXXXXX")"
    awk -v obfs="$rotated_obfs" -v short_id="$rotated_short_id" \
      -v private_key="$rotated_private" -v public_key="$rotated_public" '
      BEGIN { replaced_obfs = 0; replaced_short_id = 0 }
      /^HY2_OBFS_PASSWORD=/ { print "HY2_OBFS_PASSWORD=" obfs; replaced_obfs = 1; next }
      /^REALITY_SHORT_ID=/ { print "REALITY_SHORT_ID=" short_id; replaced_short_id = 1; next }
      /^REALITY_PRIVATE_KEY=/ && private_key != "" { print "REALITY_PRIVATE_KEY=" private_key; next }
      /^REALITY_PUBLIC_KEY=/ && public_key != "" { print "REALITY_PUBLIC_KEY=" public_key; next }
      /^SECURITY_SCHEMA_VERSION=/ { next }
      { print }
      END {
        if (!replaced_obfs) print "HY2_OBFS_PASSWORD=" obfs
        if (!replaced_short_id) print "REALITY_SHORT_ID=" short_id
        print "SECURITY_SCHEMA_VERSION=2"
      }
    ' "$env_file" >"$tmp_file"
    mv "$tmp_file" "$env_file"
    log "已执行安全迁移：轮换共享 Hysteria2 混淆密钥与 REALITY 密钥标识"
  fi
  grep -q '^ANYTLS_PORT=' "$env_file" || printf 'ANYTLS_PORT=%s\n' "$ANYTLS_PORT" >>"$env_file"
  grep -q '^TUIC_PORT=' "$env_file" || printf 'TUIC_PORT=%s\n' "$TUIC_PORT" >>"$env_file"
  grep -q '^NAIVE_PORT=' "$env_file" || printf 'NAIVE_PORT=%s\n' "$NAIVE_PORT" >>"$env_file"
  grep -q '^HTTPS_PORT=' "$env_file" || printf 'HTTPS_PORT=%s\n' "$HTTPS_PORT" >>"$env_file"
  if ! grep -Eq '^INTERNAL_PROXY_TOKEN=[A-Za-z0-9_-]{40,}$' "$env_file"; then
    internal_proxy_token="$(random_token 32)"
    printf 'INTERNAL_PROXY_TOKEN=%s\n' "$internal_proxy_token" >>"$env_file"
  fi
  secure_root_file "$env_file"
  load_env
}

json_get() {
  local file="$1"
  local filter="$2"
  jq -r "$filter" "$file"
}

random_slug() {
  python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(24))
PY
}

validate_user_name() {
  local label="$1"
  local name="$2"
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] \
    || die "$label 仅允许 1-64 位英文字母、数字、点、下划线和连字符，且必须以字母或数字开头"
}

random_hex() {
  local n="${1:-8}"
  openssl rand -hex "$n"
}

random_token() {
  local n="${1:-24}"
  openssl rand -base64 "$n" | tr -d '\n=' | tr '/+' '_-'
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
  curl --fail --silent --show-error --location \
    --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --connect-timeout 5 --max-time 10 --retry 2 --retry-delay 1 \
    --max-filesize 1024 -- https://api.ipify.org
}

resolve_domain_ipv4s() {
  local domain="$1"
  getent ahostsv4 "$domain" | awk '{print $1}' | sort -u
}

resolve_domain_ipv6s() {
  local domain="$1"
  getent ahostsv6 "$domain" | awk '{print $1}' | grep -F ':' | sort -u
}

preflight_acme_dns() {
  local public_ip="$1"
  shift
  local domain ips bad_ips flat_ips ipv6s
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
    ipv6s="$(resolve_domain_ipv6s "$domain" || true)"
    [[ -z "$ipv6s" ]] \
      || die "$domain 存在 IPv6 AAAA 记录，但当前栈只交付 IPv4 地址。请先删除 AAAA 记录，避免证书验证和客户端连接到错误主机。"
  done
}

ensure_nginx_stream_include() {
  grep -q 'include /etc/nginx/stream-conf.d/\*.conf;' /etc/nginx/nginx.conf && return 0
  python3 - <<'PY'
import os
import re
import tempfile
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

metadata = path.stat()
fd, tmp_name = tempfile.mkstemp(prefix=".nginx-", suffix=".conf", dir=path.parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        os.fchown(handle.fileno(), metadata.st_uid, metadata.st_gid)
        os.fchmod(handle.fileno(), metadata.st_mode & 0o777)
        handle.write(text)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(tmp_name, path)
finally:
    if os.path.exists(tmp_name):
        os.unlink(tmp_name)
PY
}

reload_nginx() {
  quiet_cmd "检测 nginx 配置" nginx -t
  if systemctl is-active --quiet nginx; then
    quiet_cmd "重载 nginx" systemctl reload nginx
  else
    quiet_cmd "启动 nginx" systemctl restart nginx
  fi
}

systemd_reload() {
  quiet_cmd "重载 systemd" systemctl daemon-reload
}

disable_legacy_hcrx_conf() {
  local legacy="/etc/nginx/conf.d/hcrx-ltd.conf"
  local backup="/etc/nginx/conf.d/hcrx-ltd.conf.proxy-stack.bak"
  if [[ -f "$legacy" ]]; then
    mv "$legacy" "$backup"
    log "已禁用旧 nginx 站点配置：$legacy -> $backup"
  fi
}

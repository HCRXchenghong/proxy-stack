#!/usr/bin/env bash
set -euo pipefail
umask 077

REPO_URL="${PROXY_STACK_REPO_URL:-https://github.com/HCRXchenghong/proxy-stack}"
BRANCH="${PROXY_STACK_BRANCH:-main}"
INSTALL_DIR="${PROXY_STACK_INSTALL_DIR:-/root/proxy-stack}"
TARBALL_URL="${PROXY_STACK_TARBALL_URL:-}"
TARBALL_SHA256="${PROXY_STACK_TARBALL_SHA256:-}"

WEB_DOMAIN="${WEB_DOMAIN:-}"
MANAGEMENT_DOMAIN="${MANAGEMENT_DOMAIN:-${MGMT_DOMAIN:-}}"
CERT_EMAIL="${CERT_EMAIL:-}"
TLS_CERT_FILE="${TLS_CERT_FILE:-}"
TLS_KEY_FILE="${TLS_KEY_FILE:-}"
PUBLIC_IP="${PUBLIC_IP:-}"
REALITY_TARGET="${REALITY_TARGET:-}"
REALITY_SNI="${REALITY_SNI:-}"
ASSUME_YES=0

log() {
  printf '[deploy] %s\n' "$*"
}

die() {
  printf '[deploy] 错误：%s\n' "$*" >&2
  exit 1
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

validate_domain_arg() {
  local label="$1"
  local domain="$2"
  is_valid_domain "$domain" || die "$label 必须是真实域名，不能包含 http:// 或路径：$domain"
  ! is_placeholder_domain "$domain" || die "$label 仍然是示例/保留域名：$domain"
}

validate_email_arg() {
  local email="$1"
  local email_domain="${email##*@}"
  [[ "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,63}$ ]] || die "--cert-email 必须是有效邮箱地址"
  ! is_placeholder_domain "$email_domain" || die "--cert-email 不能使用示例/保留域名邮箱：$email"
}

is_valid_cert_email() {
  local email="$1"
  local email_domain="${email##*@}"
  [[ "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,63}$ ]] || return 1
  ! is_placeholder_domain "$email_domain"
}

usage() {
  cat <<'EOF'
用法：
  sudo bash deploy.sh [--web-domain <域名>] [--cert-email <邮箱>]

选项：
  --web-domain <域名>            用户交付页/订阅使用的公网域名。
  --management-domain <域名>     已弃用兼容参数，不签证书、不开放公网管理入口。
  --cert-email <邮箱>            Let's Encrypt 注册邮箱；交互式终端中省略时会提示输入。
  --tls-cert-file <路径>         已有 TLS fullchain 证书路径。
  --tls-key-file <路径>          已有 TLS 私钥路径。
  --public-ip <ip>               服务器公网 IP；省略时自动探测。
  --reality-target <host:port>   REALITY 伪装目标；默认 www.amazon.com:443。
  --reality-sni <host>           REALITY SNI；默认 www.amazon.com。
  --install-dir <路径>           本地安装目录；默认 /root/proxy-stack。
  --repo-url <url>               curl 管道部署时下载项目的仓库地址。
  --branch <分支名>              curl 管道部署时下载项目的分支；默认 main。
  --tarball-url <https-url>      远程项目归档地址；设置后不再拼接仓库分支地址。
  --tarball-sha256 <sha256>      远程项目归档的可信 SHA-256；远程部署时强制要求。
  -y, --yes                      跳过最终确认。
  -h, --help                     显示帮助。

也支持同名环境变量：
  WEB_DOMAIN, MANAGEMENT_DOMAIN, CERT_EMAIL, TLS_CERT_FILE, TLS_KEY_FILE,
  PUBLIC_IP, REALITY_TARGET, REALITY_SNI, PROXY_STACK_INSTALL_DIR,
  PROXY_STACK_REPO_URL, PROXY_STACK_BRANCH, PROXY_STACK_TARBALL_URL,
  PROXY_STACK_TARBALL_SHA256.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --web-domain) WEB_DOMAIN="${2:-}"; shift 2 ;;
    --management-domain|--mgmt-domain) MANAGEMENT_DOMAIN="${2:-}"; shift 2 ;;
    --cert-email) CERT_EMAIL="${2:-}"; shift 2 ;;
    --tls-cert-file) TLS_CERT_FILE="${2:-}"; shift 2 ;;
    --tls-key-file) TLS_KEY_FILE="${2:-}"; shift 2 ;;
    --public-ip) PUBLIC_IP="${2:-}"; shift 2 ;;
    --reality-target) REALITY_TARGET="${2:-}"; shift 2 ;;
    --reality-sni) REALITY_SNI="${2:-}"; shift 2 ;;
    --install-dir) INSTALL_DIR="${2:-}"; shift 2 ;;
    --repo-url) REPO_URL="${2:-}"; shift 2 ;;
    --branch) BRANCH="${2:-}"; shift 2 ;;
    --tarball-url) TARBALL_URL="${2:-}"; shift 2 ;;
    --tarball-sha256) TARBALL_SHA256="${2:-}"; shift 2 ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知选项：$1" ;;
  esac
done

prompt_if_tty() {
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

prompt_cert_email_if_needed() {
  [[ -z "$TLS_CERT_FILE" && -z "$TLS_KEY_FILE" ]] || return 0
  while ! is_valid_cert_email "$CERT_EMAIL"; do
    if [[ -n "$CERT_EMAIL" ]]; then
      log "证书邮箱 '$CERT_EMAIL' 无效或属于保留域名，请输入真实邮箱"
      CERT_EMAIL=""
    fi
    prompt_if_tty CERT_EMAIL "请输入 Let's Encrypt 邮箱"
    if [[ -z "$CERT_EMAIL" ]]; then
      return 0
    fi
  done
}

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "请使用 sudo 或 root 运行"
}

require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "缺少命令：$cmd"
  done
}

normalize_repo_url() {
  local url="$1"
  url="${url%.git}"
  printf '%s\n' "$url"
}

validate_remote_source() {
  local repo
  repo="$(normalize_repo_url "$REPO_URL")"
  [[ "$repo" =~ ^https://github.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
    || die "--repo-url 只允许不含凭据、查询参数和片段的 GitHub HTTPS 仓库地址"
  [[ "$BRANCH" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$ ]] \
    || die "--branch 包含不安全字符"
  [[ "$BRANCH" != *".."* && "$BRANCH" != *"//"* && "$BRANCH" != */ ]] \
    || die "--branch 格式无效"
  if [[ -n "$TARBALL_URL" ]]; then
    [[ "$TARBALL_URL" =~ ^https://[^[:space:]#]+$ ]] \
      || die "--tarball-url 必须是不含片段的 HTTPS 地址"
  fi
}

validate_install_dir() {
  local canonical owner permissions
  [[ "$INSTALL_DIR" =~ ^/[A-Za-z0-9._/+-]+$ ]] \
    || die "--install-dir 必须是仅含安全字符的绝对路径"
  [[ "$INSTALL_DIR" != *"/../"* && "$INSTALL_DIR" != */.. && "$INSTALL_DIR" != *"/./"* ]] \
    || die "--install-dir 不能包含 . 或 .. 路径段"
  canonical="$(realpath -m -- "$INSTALL_DIR")" || die "无法规范化 --install-dir"
  case "$canonical" in
    /root/*|/opt/*|/srv/*|/usr/local/src/*|/home/*/*) ;;
    *) die "--install-dir 必须位于专用子目录中（/root、/opt、/srv、/usr/local/src 或 /home/<用户> 下）" ;;
  esac
  [[ ! -L "$INSTALL_DIR" ]] || die "--install-dir 不能是符号链接"
  if [[ -e "$canonical" ]]; then
    [[ -d "$canonical" ]] || die "--install-dir 已存在但不是目录"
    owner="$(stat -c '%u' "$canonical")"
    permissions="$(stat -c '%a' "$canonical")"
    [[ "$owner" == "0" ]] || die "已有安装目录必须由 root 拥有：$canonical"
    (( (8#$permissions & 8#022) == 0 )) || die "已有安装目录不能允许组或其他用户写入：$canonical"
  fi
  INSTALL_DIR="$canonical"
}

curl_https_download() {
  local url="$1" output="$2"
  [[ "$url" == https://* ]] || die "拒绝非 HTTPS 下载地址：$url"
  curl --fail --silent --show-error --location \
    --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --connect-timeout 10 --max-time 300 \
    --retry 3 --retry-delay 2 --retry-all-errors \
    --max-filesize 536870912 \
    --output "$output" -- "$url"
}

safe_extract_tar() {
  local archive="$1" destination="$2"
  require_cmd python3
  install -d -m 0700 "$destination"
  python3 - "$archive" "$destination" <<'PY'
import os
import shutil
import sys
import tarfile
from pathlib import Path

archive, destination = map(Path, sys.argv[1:3])
MAX_MEMBERS = 10_000
MAX_MEMBER_SIZE = 256 * 1024 * 1024
MAX_TOTAL_SIZE = 512 * 1024 * 1024


def clean_parts(name):
    if not name or len(name) > 1024 or name.startswith("/") or "\\" in name or "\x00" in name:
        raise ValueError(f"归档包含危险路径：{name!r}")
    stripped = name[:-1] if name.endswith("/") else name
    parts = stripped.split("/")
    if not stripped or any(part in {"", ".", ".."} for part in parts):
        raise ValueError(f"归档包含危险路径：{name!r}")
    return tuple(parts)


try:
    with tarfile.open(archive, mode="r:*") as handle:
        members = handle.getmembers()
        if len(members) > MAX_MEMBERS:
            raise ValueError("归档成员数量超过安全上限")
        entries = []
        seen = set()
        files = set()
        total_size = 0
        for member in members:
            if member.isfile():
                kind = "file"
            elif member.isdir():
                kind = "dir"
            else:
                raise ValueError(f"归档包含链接或特殊文件：{member.name!r}")
            parts = clean_parts(member.name)
            if parts in seen:
                raise ValueError("归档包含重复路径")
            seen.add(parts)
            if member.mode & 0o7000:
                raise ValueError("归档包含 setuid/setgid/sticky 权限")
            if kind == "file":
                if member.size < 0 or member.size > MAX_MEMBER_SIZE:
                    raise ValueError("归档单个文件超过安全上限")
                total_size += member.size
                files.add(parts)
            entries.append((member, parts, kind))
        if total_size > MAX_TOTAL_SIZE:
            raise ValueError("归档解压总大小超过安全上限")
        for _, parts, _ in entries:
            if any(parts[:index] in files for index in range(1, len(parts))):
                raise ValueError("归档中文件与目录路径发生冲突")

        directories = []
        for member, parts, kind in entries:
            target = destination.joinpath(*parts)
            if kind == "dir":
                target.mkdir(parents=True, exist_ok=True)
                directories.append((target, member.mode))
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            source = handle.extractfile(member)
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
            os.chmod(target, member.mode & 0o777)
        for target, mode in sorted(directories, key=lambda item: len(item[0].parts), reverse=True):
            os.chmod(target, mode & 0o777)
except (OSError, tarfile.TarError, ValueError) as exc:
    raise SystemExit(f"安全解压失败：{exc}")
PY
}

script_dir() {
  local src="${BASH_SOURCE[0]:-$0}"
  local dir
  dir="$(cd "$(dirname "$src")" >/dev/null 2>&1 && pwd -P)" || dir="$(pwd -P)"
  printf '%s\n' "$dir"
}

has_local_payload() {
  local dir="$1"
  [[ -f "$dir/proxy-stack.sh" && -f "$dir/app.py" && -d "$dir/lib" ]]
}

copy_local_payload() {
  local src="$1"
  local dst="$2"
  mkdir -p "$dst"
  if [[ "$(cd "$src" && pwd -P)" != "$(cd "$dst" && pwd -P 2>/dev/null || printf '%s' "$dst")" ]]; then
    cp -a "$src/proxy-stack.sh" "$src/app.py" "$src/lib" "$dst/"
    [[ -f "$src/README.md" ]] && cp -a "$src/README.md" "$dst/"
    [[ -f "$src/deploy.sh" ]] && cp -a "$src/deploy.sh" "$dst/"
    [[ -f "$src/VERSION" ]] && cp -a "$src/VERSION" "$dst/"
  fi
  chmod 0755 "$dst/proxy-stack.sh"
  [[ -f "$dst/deploy.sh" ]] && chmod 0755 "$dst/deploy.sh"
  chown -R root:root "$dst"
  chmod 0755 "$dst"
}

download_payload() {
  local dst="$1"
  local tmp archive unpack src repo archive_sha
  local -a roots
  require_cmd curl python3 sha256sum
  [[ "$TARBALL_SHA256" =~ ^[0-9a-fA-F]{64}$ ]] \
    || die "远程部署必须提供可信的 --tarball-sha256（64 位 SHA-256）"
  tmp="$(mktemp -d)"
  archive="$tmp/proxy-stack.tar.gz"
  unpack="$tmp/unpack"
  if [[ -n "$TARBALL_URL" ]]; then
    curl_https_download "$TARBALL_URL" "$archive"
  else
    repo="$(normalize_repo_url "$REPO_URL")"
    curl_https_download "${repo}/archive/refs/heads/${BRANCH}.tar.gz" "$archive"
  fi
  archive_sha="$(sha256sum "$archive" | awk '{print $1}')"
  [[ "$archive_sha" == "${TARBALL_SHA256,,}" ]] \
    || die "远程项目归档 SHA-256 校验失败，已拒绝执行"
  safe_extract_tar "$archive" "$unpack"
  mapfile -d '' -t roots < <(find "$unpack" -mindepth 1 -maxdepth 1 -print0)
  [[ "${#roots[@]}" -eq 1 && -d "${roots[0]}" ]] \
    || die "项目归档必须只包含一个顶层目录"
  src="${roots[0]}"
  [[ -f "$src/proxy-stack.sh" && -f "$src/app.py" && -f "$src/lib/common.sh" && -f "$src/lib/render.sh" ]] \
    || die "项目下载包缺少必要文件"
  bash -n "$src/proxy-stack.sh" "$src/lib/common.sh" "$src/lib/render.sh"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import ast,sys; ast.parse(open(sys.argv[1], encoding="utf-8").read())' "$src/app.py"
  fi
  mkdir -p "$dst"
  cp -a "$src/." "$dst/"
  chmod 0755 "$dst/proxy-stack.sh"
  [[ -f "$dst/deploy.sh" ]] && chmod 0755 "$dst/deploy.sh"
  chown -R root:root "$dst"
  chmod 0755 "$dst"
  rm -rf "$tmp"
}

prepare_payload() {
  local local_dir="$1"
  if has_local_payload "$local_dir"; then
    log "使用本地项目文件：$local_dir"
    copy_local_payload "$local_dir" "$INSTALL_DIR"
  else
    log "正在从 $REPO_URL 下载项目文件（分支：$BRANCH）"
    download_payload "$INSTALL_DIR"
  fi
}

validate_inputs() {
  prompt_if_tty WEB_DOMAIN "请输入用户交付页/订阅域名"
  prompt_cert_email_if_needed

  [[ -n "$WEB_DOMAIN" ]] || die "必须提供 --web-domain"
  validate_domain_arg "--web-domain" "$WEB_DOMAIN"
  if [[ -n "$MANAGEMENT_DOMAIN" ]]; then
    validate_domain_arg "--management-domain" "$MANAGEMENT_DOMAIN"
    [[ "$WEB_DOMAIN" != "$MANAGEMENT_DOMAIN" ]] || die "用户域名和管理域名不能相同"
  fi
  validate_install_dir
  validate_remote_source
  if [[ -n "$TARBALL_SHA256" ]]; then
    [[ "$TARBALL_SHA256" =~ ^[0-9a-fA-F]{64}$ ]] \
      || die "--tarball-sha256 必须是 64 位十六进制 SHA-256"
  fi
  if [[ -n "$TLS_CERT_FILE" || -n "$TLS_KEY_FILE" ]]; then
    [[ -n "$TLS_CERT_FILE" && -n "$TLS_KEY_FILE" ]] || die "请同时提供 --tls-cert-file 和 --tls-key-file"
    [[ -f "$TLS_CERT_FILE" ]] || die "TLS 证书文件不存在：$TLS_CERT_FILE"
    [[ -f "$TLS_KEY_FILE" ]] || die "TLS 私钥文件不存在：$TLS_KEY_FILE"
  else
    [[ -n "$CERT_EMAIL" ]] || die "未提供 TLS 证书/私钥时必须提供 --cert-email"
    validate_email_arg "$CERT_EMAIL"
  fi
}

confirm() {
  [[ "$ASSUME_YES" -eq 1 || ! -t 0 ]] && return 0
  printf '\n'
  log "即将使用以下配置部署："
  printf '  用户域名：  %s\n' "$WEB_DOMAIN"
  printf '  管理入口：  仅 SSH（不开放公网面板）\n'
  printf '  证书邮箱：  %s\n' "${CERT_EMAIL:-使用已有证书/私钥}"
  printf '  安装目录：  %s\n' "$INSTALL_DIR"
  printf '\n'
  read -r -p "是否继续？[y/N] " answer
  [[ "$answer" == "y" || "$answer" == "Y" || "$answer" == "yes" || "$answer" == "YES" ]] || die "已取消"
}

run_install() {
  local args
  args=(
    "$INSTALL_DIR/proxy-stack.sh" install
    --web-domain "$WEB_DOMAIN"
  )
  [[ -n "$MANAGEMENT_DOMAIN" ]] && args+=(--management-domain "$MANAGEMENT_DOMAIN")
  [[ -n "$CERT_EMAIL" ]] && args+=(--cert-email "$CERT_EMAIL")
  [[ -n "$TLS_CERT_FILE" ]] && args+=(--tls-cert-file "$TLS_CERT_FILE")
  [[ -n "$TLS_KEY_FILE" ]] && args+=(--tls-key-file "$TLS_KEY_FILE")
  [[ -n "$PUBLIC_IP" ]] && args+=(--public-ip "$PUBLIC_IP")
  [[ -n "$REALITY_TARGET" ]] && args+=(--reality-target "$REALITY_TARGET")
  [[ -n "$REALITY_SNI" ]] && args+=(--reality-sni "$REALITY_SNI")

  bash "${args[@]}"
}

main() {
  require_root
  validate_inputs
  confirm
  prepare_payload "$(script_dir)"
  run_install

  log "部署完成"
  log "已自动执行验证；后续管理请输入：seroncheng"
}

main "$@"

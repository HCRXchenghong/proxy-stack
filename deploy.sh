#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${PROXY_STACK_REPO_URL:-https://github.com/HCRXchenghong/proxy-stack}"
BRANCH="${PROXY_STACK_BRANCH:-main}"
INSTALL_DIR="${PROXY_STACK_INSTALL_DIR:-/root/proxy-stack}"
TARBALL_URL="${PROXY_STACK_TARBALL_URL:-}"

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
  [[ "$email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || die "--cert-email 必须是有效邮箱地址"
  ! is_placeholder_domain "$email_domain" || die "--cert-email 不能使用示例/保留域名邮箱：$email"
}

is_valid_cert_email() {
  local email="$1"
  local email_domain="${email##*@}"
  [[ "$email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || return 1
  ! is_placeholder_domain "$email_domain"
}

usage() {
  cat <<'EOF'
用法：
  sudo bash deploy.sh [--web-domain <域名>] [--management-domain <域名>] [--cert-email <邮箱>]

选项：
  --web-domain <域名>            用户交付页/订阅使用的公网域名。
  --management-domain <域名>     管理域名，会转发到 127.0.0.1:8317。
  --cert-email <邮箱>            Let's Encrypt 注册邮箱；交互式终端中省略时会提示输入。
  --tls-cert-file <路径>         已有 TLS fullchain 证书路径。
  --tls-key-file <路径>          已有 TLS 私钥路径。
  --public-ip <ip>               服务器公网 IP；省略时自动探测。
  --reality-target <host:port>   REALITY 伪装目标；默认 www.amazon.com:443。
  --reality-sni <host>           REALITY SNI；默认 www.amazon.com。
  --install-dir <路径>           本地安装目录；默认 /root/proxy-stack。
  --repo-url <url>               curl 管道部署时下载项目的仓库地址。
  --branch <分支名>              curl 管道部署时下载项目的分支；默认 main。
  -y, --yes                      跳过最终确认。
  -h, --help                     显示帮助。

也支持同名环境变量：
  WEB_DOMAIN, MANAGEMENT_DOMAIN, CERT_EMAIL, TLS_CERT_FILE, TLS_KEY_FILE,
  PUBLIC_IP, REALITY_TARGET, REALITY_SNI, PROXY_STACK_INSTALL_DIR,
  PROXY_STACK_REPO_URL, PROXY_STACK_BRANCH.
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
  fi
  chmod 0755 "$dst/proxy-stack.sh"
  [[ -f "$dst/deploy.sh" ]] && chmod 0755 "$dst/deploy.sh"
}

download_payload() {
  local dst="$1"
  local tmp archive src repo
  require_cmd curl tar
  tmp="$(mktemp -d)"
  archive="$tmp/proxy-stack.tar.gz"
  if [[ -n "$TARBALL_URL" ]]; then
    curl -fsSL "$TARBALL_URL" -o "$archive"
  else
    repo="$(normalize_repo_url "$REPO_URL")"
    curl -fsSL "${repo}/archive/refs/heads/${BRANCH}.tar.gz" -o "$archive"
  fi
  tar -xzf "$archive" -C "$tmp"
  src="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  [[ -n "$src" ]] || die "解压仓库压缩包失败"
  mkdir -p "$dst"
  cp -a "$src/." "$dst/"
  chmod 0755 "$dst/proxy-stack.sh"
  [[ -f "$dst/deploy.sh" ]] && chmod 0755 "$dst/deploy.sh"
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
  prompt_if_tty MANAGEMENT_DOMAIN "请输入管理域名"
  prompt_cert_email_if_needed

  [[ -n "$WEB_DOMAIN" ]] || die "必须提供 --web-domain"
  [[ -n "$MANAGEMENT_DOMAIN" ]] || die "必须提供 --management-domain"
  validate_domain_arg "--web-domain" "$WEB_DOMAIN"
  validate_domain_arg "--management-domain" "$MANAGEMENT_DOMAIN"
  [[ "$WEB_DOMAIN" != "$MANAGEMENT_DOMAIN" ]] || die "用户域名和管理域名不能相同"
  [[ "$INSTALL_DIR" == /* ]] || die "--install-dir 必须是绝对路径"
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
  printf '  管理域名：  %s\n' "$MANAGEMENT_DOMAIN"
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
    --management-domain "$MANAGEMENT_DOMAIN"
  )
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
  log "添加用户：bash $INSTALL_DIR/proxy-stack.sh user add <name>"
  log "验证服务：bash $INSTALL_DIR/proxy-stack.sh verify"
}

main "$@"

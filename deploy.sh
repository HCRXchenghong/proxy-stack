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
  printf '[deploy] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  sudo bash deploy.sh --web-domain <domain> --management-domain <domain> --cert-email <email>

Options:
  --web-domain <domain>          Public delivery/subscription domain.
  --management-domain <domain>   Management domain routed to 127.0.0.1:8317.
  --cert-email <email>           Let's Encrypt registration email.
  --tls-cert-file <path>         Existing TLS certificate fullchain path.
  --tls-key-file <path>          Existing TLS private key path.
  --public-ip <ip>               Public server IP. Auto-detected when omitted.
  --reality-target <host:port>   REALITY camouflage target. Default: www.amazon.com:443.
  --reality-sni <host>           REALITY SNI. Default: www.amazon.com.
  --install-dir <path>           Local project path. Default: /root/proxy-stack.
  --repo-url <url>               Repository URL used when running from curl pipe.
  --branch <name>                Repository branch used when running from curl pipe.
  -y, --yes                      Skip final confirmation.
  -h, --help                     Show this help.

Environment variables with the same names are also supported:
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
    *) die "unknown option: $1" ;;
  esac
done

prompt_if_tty() {
  local var_name="$1"
  local prompt="$2"
  local current_value="${!var_name:-}"
  if [[ -n "$current_value" || ! -t 0 ]]; then
    return 0
  fi
  read -r -p "$prompt: " current_value
  printf -v "$var_name" '%s' "$current_value"
}

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "run with sudo or as root"
}

require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "missing command: $cmd"
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
  [[ -n "$src" ]] || die "failed to unpack repository archive"
  mkdir -p "$dst"
  cp -a "$src/." "$dst/"
  chmod 0755 "$dst/proxy-stack.sh"
  [[ -f "$dst/deploy.sh" ]] && chmod 0755 "$dst/deploy.sh"
  rm -rf "$tmp"
}

prepare_payload() {
  local local_dir="$1"
  if has_local_payload "$local_dir"; then
    log "using local project files from $local_dir"
    copy_local_payload "$local_dir" "$INSTALL_DIR"
  else
    log "downloading project files from $REPO_URL ($BRANCH)"
    download_payload "$INSTALL_DIR"
  fi
}

validate_inputs() {
  prompt_if_tty WEB_DOMAIN "Web/subscription domain"
  prompt_if_tty MANAGEMENT_DOMAIN "Management domain"
  if [[ -z "$CERT_EMAIL" && ( -z "$TLS_CERT_FILE" || -z "$TLS_KEY_FILE" ) ]]; then
    prompt_if_tty CERT_EMAIL "Let's Encrypt email"
  fi

  [[ -n "$WEB_DOMAIN" ]] || die "--web-domain is required"
  [[ -n "$MANAGEMENT_DOMAIN" ]] || die "--management-domain is required"
  [[ "$WEB_DOMAIN" != "$MANAGEMENT_DOMAIN" ]] || die "web domain and management domain must be different"
  if [[ -n "$TLS_CERT_FILE" || -n "$TLS_KEY_FILE" ]]; then
    [[ -n "$TLS_CERT_FILE" && -n "$TLS_KEY_FILE" ]] || die "provide both --tls-cert-file and --tls-key-file"
  else
    [[ -n "$CERT_EMAIL" ]] || die "--cert-email is required when no TLS cert/key is provided"
  fi
}

confirm() {
  [[ "$ASSUME_YES" -eq 1 || ! -t 0 ]] && return 0
  printf '\n'
  log "about to deploy with:"
  printf '  Web domain:        %s\n' "$WEB_DOMAIN"
  printf '  Management domain: %s\n' "$MANAGEMENT_DOMAIN"
  printf '  Cert email:        %s\n' "${CERT_EMAIL:-existing cert/key}"
  printf '  Install dir:       %s\n' "$INSTALL_DIR"
  printf '\n'
  read -r -p "Continue? [y/N] " answer
  [[ "$answer" == "y" || "$answer" == "Y" || "$answer" == "yes" || "$answer" == "YES" ]] || die "cancelled"
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

  log "deployment finished"
  log "add a user: bash $INSTALL_DIR/proxy-stack.sh user add <name>"
  log "verify:     bash $INSTALL_DIR/proxy-stack.sh verify"
}

main "$@"

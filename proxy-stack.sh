#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/render.sh"

usage() {
  cat <<'EOF'
Usage:
  ./proxy-stack.sh install [options]
  ./proxy-stack.sh render
  ./proxy-stack.sh verify
  ./proxy-stack.sh user add <name>
  ./proxy-stack.sh user batch-add <prefix> <count> [start]
  ./proxy-stack.sh user del <name-or-slug>
  ./proxy-stack.sh user disable <name-or-slug>
  ./proxy-stack.sh user enable <name-or-slug>
  ./proxy-stack.sh user list
  ./proxy-stack.sh user show <name-or-slug>
  ./proxy-stack.sh user share <name-or-slug>
  ./proxy-stack.sh user export [csv|json|text] [path]
  ./proxy-stack.sh uninstall-3xui
  ./proxy-stack.sh package

Install options:
  --web-domain <domain>
  --management-domain <domain>
  --cert-email <email>
  --tls-cert-file <path>
  --tls-key-file <path>
  --public-ip <ip>
  --reality-target <host:port>
  --reality-sni <host>
EOF
}

download_xray() {
  require_cmd curl jq unzip
  local api tag url zip tmp
  api='https://api.github.com/repos/XTLS/Xray-core/releases/latest'
  tag="$(curl -fsSL "$api" | jq -r '.tag_name')"
  url="$(curl -fsSL "$api" | jq -r '.assets[] | select(.name=="Xray-linux-64.zip") | .browser_download_url')"
  [[ -n "$tag" && -n "$url" ]] || die "unable to resolve latest xray release"
  tmp="$(mktemp -d)"
  zip="$tmp/xray.zip"
  curl -fsSL "$url" -o "$zip"
  unzip -qo "$zip" -d "$tmp/unpack"
  install -m 0755 "$tmp/unpack/xray" "${BIN_DIR}/xray"
  rm -rf "$tmp"
  log "installed xray ${tag}"
}

download_hysteria() {
  require_cmd curl jq
  local api tag url tmp
  api='https://api.github.com/repos/apernet/hysteria/releases/latest'
  tag="$(curl -fsSL "$api" | jq -r '.tag_name')"
  url="$(curl -fsSL "$api" | jq -r '.assets[] | select(.name=="hysteria-linux-amd64") | .browser_download_url')"
  [[ -n "$tag" && -n "$url" ]] || die "unable to resolve latest hysteria release"
  tmp="$(mktemp)"
  curl -fsSL "$url" -o "$tmp"
  install -m 0755 "$tmp" "${BIN_DIR}/hysteria"
  rm -f "$tmp"
  log "installed hysteria ${tag}"
}

issue_cert_if_needed() {
  local cert="$1" key="$2" email="$3" web_domain="$4" mgmt_domain="$5"
  if [[ -f "$cert" && -f "$key" ]]; then
    log "reusing existing TLS cert/key"
    return 0
  fi
  [[ -n "$email" ]] || die "cert email required when cert paths are absent"
  mkdir -p "$WEB_ROOT/.well-known/acme-challenge"
  write_nginx_acme_conf
  reload_nginx
  certbot certonly --webroot -w "$WEB_ROOT" \
    -d "$web_domain" -d "$mgmt_domain" \
    --cert-name "$web_domain" \
    --agree-tos --non-interactive -m "$email"
}

generate_env_file() {
  local web_domain="$1" mgmt_domain="$2" cert_email="$3" tls_cert="$4" tls_key="$5" public_ip="$6" reality_target="$7" reality_sni="$8"
  local private public short obfs out
  out="$("${BIN_DIR}/xray" x25519)"
  private="$(printf '%s\n' "$out" | awk 'index($0,"PrivateKey:")==1 {print $2}')"
  public="$(printf '%s\n' "$out" | awk 'index($0,"Password (PublicKey):")==1 {print $3}')"
  [[ -n "$private" && -n "$public" ]] || die "failed to generate reality x25519 keypair"
  short="$(random_hex 4)"
  obfs="$(random_token 12)"
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
      *) die "unknown install option: $1" ;;
    esac
  done
  [[ -n "$web_domain" ]] || die "--web-domain required"
  [[ -n "$mgmt_domain" ]] || die "--management-domain required"
  ensure_dirs
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y jq unzip nginx libnginx-mod-stream certbot python3-certbot-nginx python3
  require_cmd jq unzip nginx certbot
  ensure_nginx_stream_include
  systemctl enable --now nginx
  download_xray
  download_hysteria
  [[ -n "$public_ip" ]] || public_ip="$(public_ipv4)"
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
  write_certbot_hook
  render_stack
  systemctl enable --now proxy-stack-xray proxy-stack-hysteria proxy-stack-web
  reload_nginx
  log "install complete"
}

render_stack() {
  require_root
  write_xray_config
  write_hysteria_config
  write_web_app
  write_nginx_http_conf
  write_nginx_stream_conf
  write_systemd_units
  log "render complete"
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
  log "verify passed"
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
  die "proxy stack services failed to become ready"
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
    printf 'Generated: %s UTC\n' "$(date -u '+%Y-%m-%d %H:%M:%S')"
    printf 'Project: /root/proxy-stack\n'
    printf 'Package: /root/proxy-stack-project.tar.gz\n'
    printf 'Web domain: %s\n' "$WEB_DOMAIN"
    printf 'Management domain: %s\n' "$MANAGEMENT_DOMAIN"
    printf 'Public IP: %s\n' "$PUBLIC_IP"
    printf 'User list command: bash /root/proxy-stack/proxy-stack.sh user list\n'
  } >"$info_file"
  chmod 600 "$info_file"
}

user_add() {
  require_root
  local name="${1:?name required}"
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
        raise SystemExit("user already exists")
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
  local prefix="${1:?prefix required}"
  local count="${2:?count required}"
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
    raise SystemExit("count must be > 0")
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
      raise SystemExit(f"user already exists: {name}")
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
  log "batch users created with prefix ${prefix}"
}

user_set_enabled() {
  require_root
  local key="${1:?user key required}"
  local want="${2:?enabled flag required}"
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
raise SystemExit("user not found")
PY
  render_stack
  reload_stack_services
  write_runtime_info
  user_show "$key"
}

user_del() {
  require_root
  local key="${1:?user key required}"
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
    raise SystemExit("user not found")
data["users"] = filtered
path.write_text(json.dumps(data, indent=2))
PY
  render_stack
  reload_stack_services
  write_runtime_info
  log "user removed: ${key}"
}

user_list() {
  require_root
  jq -r '.users[] | [.name, .slug, .enabled] | @tsv' "$STATE_DIR/users.json"
}

user_show() {
  require_root
  local key="${1:?user key required}"
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
    raise SystemExit("user not found")
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
  local key="${1:?user key required}"
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
    raise SystemExit("user not found")
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
      die "unsupported export format: $format"
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
                f"状态: {'enabled' if row['enabled'] else 'disabled'}\n"
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
  log "3x-ui removed"
}

package_project() {
  require_root
  tar -C /root -czf /root/proxy-stack-project.tar.gz proxy-stack
  log "package written to /root/proxy-stack-project.tar.gz"
}

cmd="${1:-}"
case "$cmd" in
  install) shift; install_stack "$@" ;;
  render) render_stack ;;
  verify) verify_stack ;;
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

#!/usr/bin/env bash
set -euo pipefail

RENDER_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$RENDER_SCRIPT_DIR/common.sh"

write_xray_config() {
  load_env

  local users_json="$STATE_DIR/users.json"
  [[ -f "$users_json" ]] || die "缺少用户文件：$users_json"

  python3 - "$users_json" "$STATE_DIR/xray.json" "$STATE_DIR/stack.env" <<'PY'
import json
import sys
from pathlib import Path

users_path = Path(sys.argv[1])
out_path = Path(sys.argv[2])
env = {}
for line in Path(sys.argv[3]).read_text().splitlines():
    if not line or line.startswith("#") or "=" not in line:
        continue
    k, v = line.split("=", 1)
    env[k] = v

data = json.loads(users_path.read_text())
enabled = [u for u in data.get("users", []) if u.get("enabled", True)]

vless_users = []
for u in enabled:
    vless_users.append({
        "id": u["vless_uuid"],
        "email": f'{u["name"]}@proxy-stack',
        "flow": "xtls-rprx-vision",
    })

cfg = {
    "log": {
        "loglevel": "warning",
    },
    "inbounds": [
        {
            "tag": "vless-reality",
            "listen": "127.0.0.1",
            "port": int(env["VLESS_INTERNAL_PORT"]),
            "protocol": "vless",
            "settings": {
                "clients": vless_users,
                "decryption": "none",
            },
            "sniffing": {
                "enabled": True,
                "destOverride": ["http", "tls", "quic"],
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "sockopt": {
                    "acceptProxyProtocol": True,
                },
                "realitySettings": {
                    "show": False,
                    "target": env["REALITY_TARGET"],
                    "serverNames": [env["REALITY_SNI"]],
                    "privateKey": env["REALITY_PRIVATE_KEY"],
                    "shortIds": [env["REALITY_SHORT_ID"]],
                    "xver": 0,
                    "maxTimeDiff": 60000,
                },
            },
        },
    ],
    "outbounds": [
        {"protocol": "freedom", "tag": "direct"},
        {"protocol": "blackhole", "tag": "block"},
    ],
    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": [
            {
                "type": "field",
                "ip": [
                    "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8",
                    "169.254.0.0/16", "172.16.0.0/12", "192.0.0.0/24", "192.0.2.0/24",
                    "192.168.0.0/16", "198.18.0.0/15", "198.51.100.0/24",
                    "203.0.113.0/24", "224.0.0.0/4", "240.0.0.0/4",
                    "::/128", "::1/128", "::ffff:0:0/96", "64:ff9b::/96",
                    "64:ff9b:1::/48", "100::/64", "2001:db8::/32",
                    "2001:10::/28", "2001:20::/28", "fc00::/7", "fe80::/10", "ff00::/8"
                ],
                "outboundTag": "block",
            }
        ],
    },
}

out_path.write_text(json.dumps(cfg, indent=2))
PY
  secure_state_file "$STATE_DIR/xray.json" "$XRAY_SERVICE_GROUP"
}

write_hysteria_config() {
  load_env
  cat >"${STATE_DIR}/hysteria-server.yaml" <<EOF
listen: :443

tls:
  cert: ${SERVICE_TLS_DIR}/fullchain.pem
  key: ${SERVICE_TLS_DIR}/privkey.pem
  sniGuard: strict

auth:
  type: http
  http:
    url: http://127.0.0.1:${APP_PORT}/hy2-auth

obfs:
  type: salamander
  salamander:
    password: ${HY2_OBFS_PASSWORD}

udpIdleTimeout: 60s

acl:
  inline:
    - reject(0.0.0.0/8)
    - reject(10.0.0.0/8)
    - reject(100.64.0.0/10)
    - reject(127.0.0.0/8)
    - reject(169.254.0.0/16)
    - reject(172.16.0.0/12)
    - reject(192.0.0.0/24)
    - reject(192.0.2.0/24)
    - reject(192.168.0.0/16)
    - reject(198.18.0.0/15)
    - reject(198.51.100.0/24)
    - reject(203.0.113.0/24)
    - reject(224.0.0.0/4)
    - reject(240.0.0.0/4)
    - reject(::/128)
    - reject(::1/128)
    - reject(::ffff:0:0/96)
    - reject(64:ff9b::/96)
    - reject(64:ff9b:1::/48)
    - reject(100::/64)
    - reject(2001:db8::/32)
    - reject(2001:10::/28)
    - reject(2001:20::/28)
    - reject(fc00::/7)
    - reject(fe80::/10)
    - reject(ff00::/8)

masquerade:
  type: string
  string:
    content: nothing here
    statusCode: 404
EOF
  secure_state_file "$STATE_DIR/hysteria-server.yaml" "$HYSTERIA_SERVICE_GROUP"
}

ensure_user_protocol_credentials() {
  local users_json="$STATE_DIR/users.json"
  python3 - "$users_json" <<'PY'
import json
import os
import secrets
import tempfile
import uuid
from pathlib import Path

path = Path(__import__('sys').argv[1])
data = json.loads(path.read_text())
changed = False
rotate_legacy = int(data.get("schema_version", 0)) < 2
seen_slugs = set()
seen_client_tokens = set()
for user in data.setdefault("users", []):
    slug = str(user.get("slug", ""))
    if rotate_legacy or len(slug) < 24 or slug in seen_slugs:
        user["slug"] = secrets.token_urlsafe(24)
        changed = True
    if rotate_legacy:
        user["vless_uuid"] = str(uuid.uuid4())
        user["hy2_auth"] = secrets.token_urlsafe(24)
        changed = True
    seen_slugs.add(user["slug"])
    defaults = {
        "anytls_password": secrets.token_urlsafe(24),
        "tuic_uuid": str(uuid.uuid4()),
        "tuic_password": secrets.token_urlsafe(24),
        "naive_username": "u_" + user["slug"],
        "naive_password": secrets.token_urlsafe(24),
    }
    for key, value in defaults.items():
        if not user.get(key):
            user[key] = value
            changed = True
    if not isinstance(user.get("allowed_ips"), list):
        user["allowed_ips"] = []
        changed = True
    if not isinstance(user.get("subscription_clients"), list):
        user["subscription_clients"] = []
        changed = True
    normalized_clients = []
    seen_client_names = set()
    for index, client in enumerate(user["subscription_clients"], start=1):
        if not isinstance(client, dict):
            changed = True
            continue
        name = str(client.get("name", "")).strip() or f"device-{index}"
        if name in seen_client_names:
            name = f"{name}-{index}"
            changed = True
        seen_client_names.add(name)
        token = str(client.get("token", ""))
        if len(token) < 40 or token in seen_client_tokens:
            token = secrets.token_urlsafe(32)
            changed = True
        seen_client_tokens.add(token)
        allowed_ips = client.get("allowed_ips", [])
        if not isinstance(allowed_ips, list):
            allowed_ips = []
            changed = True
        normalized = {
            "name": name,
            "token": token,
            "enabled": bool(client.get("enabled", True)),
            "allowed_ips": allowed_ips,
        }
        if normalized != client:
            changed = True
        normalized_clients.append(normalized)
    user["subscription_clients"] = normalized_clients
    if not user["subscription_clients"]:
        user["subscription_clients"].append({
            "name": "default",
            "token": secrets.token_urlsafe(32),
            "enabled": True,
            "allowed_ips": [],
        })
        changed = True

if int(data.get("schema_version", 0)) < 3:
    data["schema_version"] = 3
    changed = True

if changed:
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
  secure_state_file "$users_json"
}

write_sing_box_config() {
  load_env
  python3 - "$STATE_DIR/users.json" "$STATE_DIR/sing-box.json" \
    "$ANYTLS_PORT" "$TUIC_PORT" "$NAIVE_PORT" "$SERVICE_TLS_DIR" <<'PY'
import json
import sys
from pathlib import Path

users_path, out_path = map(Path, sys.argv[1:3])
anytls_port, tuic_port, naive_port = map(int, sys.argv[3:6])
tls_dir = sys.argv[6]
users = [u for u in json.loads(users_path.read_text()).get("users", []) if u.get("enabled", True)]

def tls(alpn):
    return {
        "enabled": True,
        "alpn": alpn,
        "min_version": "1.3",
        "certificate_path": f"{tls_dir}/fullchain.pem",
        "key_path": f"{tls_dir}/privkey.pem",
    }

cfg = {
    "log": {"level": "warn", "timestamp": True},
    "dns": {
        "servers": [{"type": "local", "tag": "local"}],
        "strategy": "prefer_ipv4",
        "independent_cache": True,
    },
    "inbounds": [
        {
            "type": "anytls", "tag": "anytls-in", "listen": "::", "listen_port": anytls_port,
            "users": [{"name": u["name"], "password": u["anytls_password"]} for u in users],
            "tls": tls(["h2", "http/1.1"]),
        },
        {
            "type": "tuic", "tag": "tuic-in", "listen": "::", "listen_port": tuic_port,
            "users": [{"name": u["name"], "uuid": u["tuic_uuid"], "password": u["tuic_password"]} for u in users],
            "congestion_control": "bbr", "auth_timeout": "3s", "zero_rtt_handshake": False,
            "heartbeat": "10s", "tls": tls(["h3"]),
        },
        {
            "type": "naive", "tag": "naive-in", "network": "tcp", "listen": "::", "listen_port": naive_port,
            "users": [{"username": u["naive_username"], "password": u["naive_password"]} for u in users],
            "tls": tls(["h2"]),
        },
    ],
    "outbounds": [{"type": "direct", "tag": "direct"}],
    "route": {
        "rules": [
            {"action": "resolve", "server": "local", "strategy": "prefer_ipv4"},
            {"ip_is_private": True, "action": "reject"},
            {
                "ip_cidr": [
                    "0.0.0.0/8", "100.64.0.0/10", "169.254.0.0/16",
                    "192.0.0.0/24", "192.0.2.0/24", "198.18.0.0/15",
                    "198.51.100.0/24", "203.0.113.0/24", "224.0.0.0/4", "240.0.0.0/4",
                    "::/128", "::ffff:0:0/96", "64:ff9b::/96", "64:ff9b:1::/48",
                    "100::/64", "2001:db8::/32", "2001:10::/28", "2001:20::/28", "ff00::/8",
                ],
                "action": "reject",
            },
        ],
        "default_domain_resolver": "local",
        "final": "direct",
    },
}
out_path.write_text(json.dumps(cfg, indent=2, ensure_ascii=False))
PY
  secure_state_file "$STATE_DIR/sing-box.json" "$SING_BOX_SERVICE_GROUP"
}

write_users_json() {
  local users_json="$STATE_DIR/users.json"
  [[ -f "$users_json" ]] && return 0
  cat >"$users_json" <<'JSON'
{
  "schema_version": 3,
  "users": []
}
JSON
  secure_state_file "$users_json" "$WEB_SERVICE_GROUP"
}

write_public_env() {
  load_env
  cat >"$STATE_DIR/public.env" <<EOF
WEB_DOMAIN=${WEB_DOMAIN}
PUBLIC_IP=${PUBLIC_IP}
REALITY_PUBLIC_KEY=${REALITY_PUBLIC_KEY}
REALITY_SNI=${REALITY_SNI}
REALITY_SHORT_ID=${REALITY_SHORT_ID}
HY2_OBFS_PASSWORD=${HY2_OBFS_PASSWORD}
ANYTLS_PORT=${ANYTLS_PORT}
TUIC_PORT=${TUIC_PORT}
NAIVE_PORT=${NAIVE_PORT}
INTERNAL_PROXY_TOKEN=${INTERNAL_PROXY_TOKEN}
EOF
  secure_state_file "$STATE_DIR/public.env" "$WEB_SERVICE_GROUP"
}

write_web_app() {
  install -m 0755 "$PROJECT_ROOT/app.py" "$RUNTIME_DIR/app.py"
}

write_nginx_acme_conf() {
  load_env
  cat >"$NGINX_ACME_CONF" <<EOF
log_format proxy_stack_acme_safe '\$remote_addr [\$time_local] \$status \$request_method';

server {
    listen 80;
    listen [::]:80;
    server_name ${WEB_DOMAIN};
    access_log /var/log/nginx/proxy-stack-access.log proxy_stack_acme_safe;
    error_log /var/log/nginx/proxy-stack-error.log crit;

    location ^~ /.well-known/acme-challenge/ {
        root ${WEB_ROOT};
        default_type "text/plain";
    }

    location / {
        return 301 https://${WEB_DOMAIN}\$request_uri;
    }
}
EOF
}

write_nginx_http_conf() {
  load_env
  write_nginx_acme_conf

  cat >"$NGINX_HTTP_CONF" <<EOF
limit_req_zone \$binary_remote_addr zone=proxy_stack_web_rate:10m rate=5r/s;
limit_conn_zone \$binary_remote_addr zone=proxy_stack_web_conn:10m;
log_format proxy_stack_safe '\$remote_addr [\$time_local] \$status \$request_method';
server_tokens off;

server {
    listen 127.0.0.1:${WEB_TLS_PORT} ssl http2 proxy_protocol;
    server_name ${WEB_DOMAIN};

    set_real_ip_from 127.0.0.1;
    real_ip_header proxy_protocol;

    limit_req zone=proxy_stack_web_rate burst=10 nodelay;
    limit_req_status 429;
    limit_conn proxy_stack_web_conn 10;
    limit_conn_status 429;

    ssl_certificate ${TLS_CERT_FILE};
    ssl_certificate_key ${TLS_KEY_FILE};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_tickets off;

    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options DENY always;
    add_header Referrer-Policy no-referrer always;
    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header Permissions-Policy "camera=(), microphone=(), geolocation=()" always;
    add_header Cross-Origin-Opener-Policy same-origin always;
    add_header Cross-Origin-Resource-Policy same-origin always;
    access_log /var/log/nginx/proxy-stack-access.log proxy_stack_safe;
    error_log /var/log/nginx/proxy-stack-error.log crit;

    client_max_body_size 4k;
    client_header_buffer_size 1k;
    large_client_header_buffers 2 4k;
    client_header_timeout 10s;
    client_body_timeout 10s;
    keepalive_timeout 15s;
    send_timeout 15s;

    location = /hy2-auth {
        return 404;
    }

    location = / {
        default_type text/html;
        return 200 '<!doctype html><html><head><title>Welcome</title></head><body><h1>Welcome</h1></body></html>';
    }

    location = /healthz {
        default_type text/plain;
        return 200 'ok';
    }

    location ~ "^/(web|link|mihomo|node)/[A-Za-z0-9_-]{24,64}\$" {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_http_version 1.1;
        proxy_connect_timeout 5s;
        proxy_read_timeout 30s;
        proxy_send_timeout 30s;
        proxy_hide_header Server;
        proxy_set_header Host \$host;
        proxy_set_header X-Proxy-Stack-Internal ${INTERNAL_PROXY_TOKEN};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location / {
        return 404;
    }
}
EOF
  secure_root_file "$NGINX_HTTP_CONF"
}

write_fail2ban_config() {
  install -d -m 0755 -o root -g root /etc/fail2ban/fail2ban.d /etc/fail2ban/jail.d
  cat >"$FAIL2BAN_MAIN_CONF" <<'EOF'
[Definition]
logtarget = /var/log/fail2ban.log
dbfile = /var/lib/fail2ban/fail2ban.sqlite3
dbpurgeage = 315360000
EOF

  cat >"$FAIL2BAN_JAIL_CONF" <<'EOF'
[proxy-stack-sshd-day]
enabled = true
filter = sshd
backend = systemd
banaction = %(banaction_allports)s
maxretry = 3
findtime = 86400
bantime = 86400
ignoreip = 127.0.0.0/8 ::1

[proxy-stack-sshd-permanent]
enabled = true
filter = sshd
backend = systemd
banaction = %(banaction_allports)s
maxretry = 11
findtime = 315360000
bantime = -1
ignoreip = 127.0.0.0/8 ::1

[proxy-stack-recidive]
enabled = true
filter = recidive
backend = auto
logpath = /var/log/fail2ban.log
banaction = %(banaction_allports)s
maxretry = 4
findtime = 315360000
bantime = -1
ignoreip = 127.0.0.0/8 ::1
EOF
  secure_root_file "$FAIL2BAN_MAIN_CONF"
  secure_root_file "$FAIL2BAN_JAIL_CONF"
}

write_nginx_stream_conf() {
  load_env
  cat >"$NGINX_STREAM_CONF" <<EOF
map \$ssl_preread_server_name \$proxy_stack_tcp_backend {
    ${WEB_DOMAIN} web_tls_backend;
    default reality_backend;
}

upstream web_tls_backend {
    server 127.0.0.1:${WEB_TLS_PORT};
}

upstream reality_backend {
    server 127.0.0.1:${VLESS_INTERNAL_PORT};
}

server {
    listen 443 reuseport;
    listen [::]:443 reuseport;
    proxy_pass \$proxy_stack_tcp_backend;
    proxy_protocol on;
    ssl_preread on;
}
EOF
}

write_systemd_units() {
  ensure_service_account
  cat >"$SYSTEMD_DIR/proxy-stack-xray.service" <<EOF
[Unit]
Description=Proxy Stack Xray
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${XRAY_SERVICE_USER}
Group=${XRAY_SERVICE_GROUP}
UMask=0077
ExecStart=${BIN_DIR}/xray run -c ${STATE_DIR}/xray.json
Restart=on-failure
RestartSec=2
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
ProtectKernelLogs=true
ProtectClock=true
ProtectHostname=true
ProtectProc=invisible
RestrictNamespaces=true
SystemCallArchitectures=native
MemoryDenyWriteExecute=true
RestrictRealtime=true
RemoveIPC=true
KeyringMode=private
RestrictSUIDSGID=true
LockPersonality=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
TasksMax=512

[Install]
WantedBy=multi-user.target
EOF

  cat >"$SYSTEMD_DIR/proxy-stack-web.service" <<EOF
[Unit]
Description=Proxy Stack Delivery App
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${WEB_SERVICE_USER}
Group=${WEB_SERVICE_GROUP}
UMask=0077
Environment=PROXY_STACK_STATE=${STATE_DIR}
Environment=PROXY_STACK_DOMAIN=
Environment=PYTHONDONTWRITEBYTECODE=1
ExecStart=/usr/bin/python3 ${RUNTIME_DIR}/app.py --state-dir ${STATE_DIR} --env-file ${STATE_DIR}/public.env --host 127.0.0.1 --port ${APP_PORT}
Restart=on-failure
RestartSec=2
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
ProtectKernelLogs=true
ProtectClock=true
ProtectHostname=true
ProtectProc=invisible
RestrictNamespaces=true
SystemCallArchitectures=native
MemoryDenyWriteExecute=true
RestrictRealtime=true
RemoveIPC=true
KeyringMode=private
RestrictSUIDSGID=true
LockPersonality=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
TasksMax=128

[Install]
WantedBy=multi-user.target
EOF

  cat >"$SYSTEMD_DIR/proxy-stack-hysteria.service" <<EOF
[Unit]
Description=Proxy Stack Hysteria2
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${HYSTERIA_SERVICE_USER}
Group=${HYSTERIA_SERVICE_GROUP}
SupplementaryGroups=${TLS_SERVICE_GROUP}
UMask=0077
ExecStart=${BIN_DIR}/hysteria server -c ${STATE_DIR}/hysteria-server.yaml
Restart=on-failure
RestartSec=2
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
ProtectKernelLogs=true
ProtectClock=true
ProtectHostname=true
ProtectProc=invisible
RestrictNamespaces=true
SystemCallArchitectures=native
MemoryDenyWriteExecute=true
RestrictRealtime=true
RemoveIPC=true
KeyringMode=private
RestrictSUIDSGID=true
LockPersonality=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
TasksMax=512

[Install]
WantedBy=multi-user.target
EOF

  cat >"$SYSTEMD_DIR/proxy-stack-sing-box.service" <<EOF
[Unit]
Description=Proxy Stack AnyTLS, TUIC and NaiveProxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SING_BOX_SERVICE_USER}
Group=${SING_BOX_SERVICE_GROUP}
SupplementaryGroups=${TLS_SERVICE_GROUP}
UMask=0077
ExecStart=${BIN_DIR}/sing-box run -c ${STATE_DIR}/sing-box.json
Restart=on-failure
RestartSec=2
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
ProtectKernelLogs=true
ProtectClock=true
ProtectHostname=true
ProtectProc=invisible
RestrictNamespaces=true
SystemCallArchitectures=native
MemoryDenyWriteExecute=true
RestrictRealtime=true
RemoveIPC=true
KeyringMode=private
RestrictSUIDSGID=true
LockPersonality=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
TasksMax=512

[Install]
WantedBy=multi-user.target
EOF

  systemd_reload
}

write_certbot_hook() {
  mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat >/etc/letsencrypt/renewal-hooks/deploy/proxy-stack-reload.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
umask 077
# shellcheck disable=SC1091
source /etc/proxy-stack/stack.env
install -d -m 0750 -o root -g proxy-stack-tls /etc/proxy-stack/tls
install -m 0640 -o root -g proxy-stack-tls "$TLS_CERT_FILE" /etc/proxy-stack/tls/fullchain.pem
install -m 0640 -o root -g proxy-stack-tls "$TLS_KEY_FILE" /etc/proxy-stack/tls/privkey.pem
systemctl reload nginx
systemctl restart proxy-stack-hysteria proxy-stack-sing-box
EOF
  chmod 750 /etc/letsencrypt/renewal-hooks/deploy/proxy-stack-reload.sh
}

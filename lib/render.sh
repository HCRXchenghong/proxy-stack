#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

write_xray_config() {
  load_env

  local users_json="$STATE_DIR/users.json"
  [[ -f "$users_json" ]] || die "missing $users_json"

  python3 - "$users_json" "$STATE_DIR/xray.json" <<'PY'
import json
import sys
from pathlib import Path

users_path = Path(sys.argv[1])
out_path = Path(sys.argv[2])
env = {}
for line in Path("/etc/proxy-stack/stack.env").read_text().splitlines():
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
                "realitySettings": {
                    "show": False,
                    "target": env["REALITY_TARGET"],
                    "serverNames": [env["REALITY_SNI"]],
                    "privateKey": env["REALITY_PRIVATE_KEY"],
                    "shortIds": [env["REALITY_SHORT_ID"]],
                    "xver": 0,
                    "maxTimeDiff": 0,
                },
            },
        },
    ],
    "outbounds": [
        {"protocol": "freedom", "tag": "direct"},
        {"protocol": "blackhole", "tag": "block"},
    ],
}

out_path.write_text(json.dumps(cfg, indent=2))
PY
}

write_hysteria_config() {
  load_env
  cat >"${STATE_DIR}/hysteria-server.yaml" <<EOF
listen: :443

tls:
  cert: ${TLS_CERT_FILE}
  key: ${TLS_KEY_FILE}
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

masquerade:
  type: string
  string:
    content: nothing here
    statusCode: 404
EOF
}

write_users_json() {
  local users_json="$STATE_DIR/users.json"
  [[ -f "$users_json" ]] && return 0
  cat >"$users_json" <<'JSON'
{
  "users": []
}
JSON
  chmod 600 "$users_json"
}

write_web_app() {
  install -m 0755 "$PROJECT_ROOT/app.py" "$RUNTIME_DIR/app.py"
}

write_nginx_acme_conf() {
  load_env
  cat >"$NGINX_ACME_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${WEB_DOMAIN} ${MANAGEMENT_DOMAIN};

    location ^~ /.well-known/acme-challenge/ {
        root ${WEB_ROOT};
        default_type "text/plain";
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF
}

write_nginx_http_conf() {
  load_env
  write_nginx_acme_conf

  cat >"$NGINX_HTTP_CONF" <<EOF
server {
    listen 127.0.0.1:${WEB_TLS_PORT} ssl http2;
    server_name ${WEB_DOMAIN};

    ssl_certificate ${TLS_CERT_FILE};
    ssl_certificate_key ${TLS_KEY_FILE};

    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options DENY always;
    add_header Referrer-Policy no-referrer always;
    add_header Content-Security-Policy "default-src 'self' 'unsafe-inline' data:;" always;

    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}

server {
    listen 127.0.0.1:${MGMT_TLS_PORT} ssl http2;
    server_name ${MANAGEMENT_DOMAIN};

    ssl_certificate ${TLS_CERT_FILE};
    ssl_certificate_key ${TLS_KEY_FILE};

    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options DENY always;
    add_header Referrer-Policy no-referrer always;

    location / {
        proxy_pass http://127.0.0.1:8317;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
}

write_nginx_stream_conf() {
  load_env
  cat >"$NGINX_STREAM_CONF" <<EOF
map \$ssl_preread_server_name \$proxy_stack_tcp_backend {
    ${WEB_DOMAIN} web_tls_backend;
    ${MANAGEMENT_DOMAIN} mgmt_tls_backend;
    default reality_backend;
}

upstream web_tls_backend {
    server 127.0.0.1:${WEB_TLS_PORT};
}

upstream mgmt_tls_backend {
    server 127.0.0.1:${MGMT_TLS_PORT};
}

upstream reality_backend {
    server 127.0.0.1:${VLESS_INTERNAL_PORT};
}

server {
    listen 443 reuseport;
    listen [::]:443 reuseport;
    proxy_pass \$proxy_stack_tcp_backend;
    ssl_preread on;
}
EOF
}

write_systemd_units() {
  cat >"$SYSTEMD_DIR/proxy-stack-xray.service" <<EOF
[Unit]
Description=Proxy Stack Xray
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN_DIR}/xray run -c ${STATE_DIR}/xray.json
Restart=on-failure
RestartSec=2
LimitNOFILE=1048576

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
Environment=PROXY_STACK_STATE=${STATE_DIR}
Environment=PROXY_STACK_DOMAIN=
ExecStart=/usr/bin/python3 ${RUNTIME_DIR}/app.py --state-dir ${STATE_DIR} --host 127.0.0.1 --port ${APP_PORT}
Restart=on-failure
RestartSec=2

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
ExecStart=${BIN_DIR}/hysteria server -c ${STATE_DIR}/hysteria-server.yaml
Restart=on-failure
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemd_reload
}

write_certbot_hook() {
  cat >/etc/letsencrypt/renewal-hooks/deploy/proxy-stack-reload.sh <<'EOF'
#!/usr/bin/env bash
set -e
systemctl reload nginx
systemctl restart proxy-stack-xray proxy-stack-hysteria proxy-stack-web
EOF
  chmod 755 /etc/letsencrypt/renewal-hooks/deploy/proxy-stack-reload.sh
}

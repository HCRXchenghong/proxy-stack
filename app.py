#!/usr/bin/env python3
import argparse
import base64
import html
import json
import os
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import quote


def load_env(path: Path) -> dict:
    env = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        env[k] = v
    return env


def find_user(state_dir: Path, key: str):
    data = json.loads((state_dir / "users.json").read_text())
    for user in data.get("users", []):
        if user.get("slug") == key or user.get("name") == key:
            return user
    return None


def find_user_by_hy2_auth(state_dir: Path, auth: str):
    data = json.loads((state_dir / "users.json").read_text())
    for user in data.get("users", []):
        if user.get("enabled", True) and user.get("hy2_auth") == auth:
            return user
    return None


def raw_links(env: dict, user: dict):
    name = user["name"]
    vless = (
        f'vless://{user["vless_uuid"]}@{env["PUBLIC_IP"]}:443'
        f'?type=tcp&security=reality&pbk={quote(env["REALITY_PUBLIC_KEY"])}'
        f'&fp=chrome&sni={quote(env["REALITY_SNI"])}&sid={env["REALITY_SHORT_ID"]}'
        f'&flow=xtls-rprx-vision#{quote(name + "-vless")}'
    )
    hy2 = (
        f'hysteria2://{quote(user["hy2_auth"])}@{env["PUBLIC_IP"]}:443'
        f'?sni={quote(env["WEB_DOMAIN"])}&alpn=h3&security=tls'
    )
    obfs = env.get("HY2_OBFS_PASSWORD", "").strip()
    if obfs:
        hy2 += f'&obfs=salamander&obfs-password={quote(obfs)}'
    hy2 += f'#{quote(name + "-hy2")}'
    return vless, hy2


def render_clash(env: dict, user: dict):
    vless, hy2 = raw_links(env, user)
    # Conservative Mihomo YAML that keeps separate nodes.
    base = f"""mixed-port: 7890
allow-lan: true
mode: rule
log-level: info
proxies:
  - name: "{user['name']}-vless"
    type: vless
    server: {env['PUBLIC_IP']}
    port: 443
    uuid: {user['vless_uuid']}
    network: tcp
    tls: true
    udp: true
    servername: {env['REALITY_SNI']}
    reality-opts:
      public-key: {env['REALITY_PUBLIC_KEY']}
      short-id: {env['REALITY_SHORT_ID']}
    client-fingerprint: chrome
    flow: xtls-rprx-vision
  - name: "{user['name']}-hy2"
    type: hysteria2
    server: {env['PUBLIC_IP']}
    port: 443
    password: "{user['hy2_auth']}"
    sni: {env['WEB_DOMAIN']}
    alpn:
      - h3
"""
    obfs = env.get("HY2_OBFS_PASSWORD", "").strip()
    if obfs:
        return base + f"""    obfs: salamander
    obfs-password: "{obfs}"
proxy-groups:
  - name: "AUTO"
    type: select
    proxies:
      - "{user['name']}-vless"
      - "{user['name']}-hy2"
rules:
  - MATCH,AUTO
"""
    return base + """proxy-groups:
  - name: "AUTO"
    type: select
    proxies:
      - "{name}-vless"
      - "{name}-hy2"
rules:
  - MATCH,AUTO
""".format(name=user["name"])


def render_html(env: dict, user: dict):
    vless, hy2 = raw_links(env, user)
    slug = user["slug"]
    sub_url = f"https://{env['WEB_DOMAIN']}/sub/{slug}"
    clash_url = f"https://{env['WEB_DOMAIN']}/clash/{slug}"
    raw_url = f"https://{env['WEB_DOMAIN']}/raw/{slug}"
    return f"""<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{html.escape(user['name'])} - Proxy Stack</title>
  <style>
    body {{ font-family: -apple-system,BlinkMacSystemFont,Segoe UI,sans-serif; margin: 0; background: #0b1220; color: #e5eefc; }}
    main {{ max-width: 880px; margin: 0 auto; padding: 32px 20px 48px; }}
    h1 {{ margin: 0 0 8px; font-size: 28px; }}
    p {{ color: #a9bddf; line-height: 1.6; }}
    .grid {{ display: grid; gap: 16px; margin-top: 24px; }}
    .card {{ background: #131d31; border: 1px solid #20304d; border-radius: 10px; padding: 18px; }}
    .label {{ font-size: 13px; color: #8ba5d3; margin-bottom: 8px; }}
    code {{ display: block; white-space: pre-wrap; word-break: break-all; background: #0a1324; border-radius: 8px; padding: 12px; color: #d8e6ff; }}
    a {{ color: #7cc5ff; }}
  </style>
</head>
<body>
  <main>
    <h1>{html.escape(user['name'])}</h1>
    <p>给 URI 客户端使用通用订阅；给 Mihomo/Clash Meta 使用 Clash 订阅。原始链接也保留在下面，方便手动导入。</p>
    <div class="grid">
      <div class="card">
        <div class="label">通用短订阅（v2rayN / v2rayNG / V2Box / Shadowrocket 可直接复制）</div>
        <code>{html.escape(sub_url)}</code>
      </div>
      <div class="card">
        <div class="label">Mihomo / Clash Meta 订阅</div>
        <code>{html.escape(clash_url)}</code>
      </div>
      <div class="card">
        <div class="label">原始 URI 订阅</div>
        <code>{html.escape(raw_url)}</code>
      </div>
      <div class="card">
        <div class="label">VLESS + REALITY + Vision</div>
        <code>{html.escape(vless)}</code>
      </div>
      <div class="card">
        <div class="label">Hysteria2</div>
        <code>{html.escape(hy2)}</code>
      </div>
    </div>
  </main>
</body>
</html>"""


class App(BaseHTTPRequestHandler):
    state_dir = Path("/etc/proxy-stack")
    env = {}

    def do_GET(self):
        parts = [p for p in self.path.split("?")[0].split("/") if p]
        if not parts:
            self.send_error(HTTPStatus.NOT_FOUND)
            return

        route = parts[0]
        key = parts[1] if len(parts) > 1 else ""
        user = find_user(self.state_dir, key) if key else None

        if route == "healthz":
            self._send(HTTPStatus.OK, "text/plain; charset=utf-8", b"ok")
            return
        if not user:
            self.send_error(HTTPStatus.NOT_FOUND)
            return

        if route == "sub":
            body = "\n".join(raw_links(self.env, user)).encode()
            payload = base64.b64encode(body)
            self._send(HTTPStatus.OK, "text/plain; charset=utf-8", payload)
            return
        if route == "raw":
            body = ("\n".join(raw_links(self.env, user)) + "\n").encode()
            self._send(HTTPStatus.OK, "text/plain; charset=utf-8", body)
            return
        if route == "clash":
            self._send(HTTPStatus.OK, "application/yaml; charset=utf-8", render_clash(self.env, user).encode())
            return
        if route in {"u", "s"}:
            self._send(HTTPStatus.OK, "text/html; charset=utf-8", render_html(self.env, user).encode())
            return

        self.send_error(HTTPStatus.NOT_FOUND)

    def do_POST(self):
        parts = [p for p in self.path.split("?")[0].split("/") if p]
        if parts == ["hy2-auth"]:
            length = int(self.headers.get("Content-Length", "0") or "0")
            body = self.rfile.read(length) if length > 0 else b"{}"
            try:
                payload = json.loads(body.decode("utf-8"))
            except Exception:
                self._send(HTTPStatus.OK, "application/json; charset=utf-8", b'{"ok":false}')
                return
            auth = str(payload.get("auth", ""))
            user = find_user_by_hy2_auth(self.state_dir, auth)
            if user:
                body = json.dumps({"ok": True, "id": user["name"]}).encode("utf-8")
                self._send(HTTPStatus.OK, "application/json; charset=utf-8", body)
                return
            self._send(HTTPStatus.OK, "application/json; charset=utf-8", b'{"ok":false}')
            return
        self.send_error(HTTPStatus.NOT_FOUND)

    def log_message(self, fmt, *args):
        return

    def _send(self, status, content_type, body: bytes):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--state-dir", required=True)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=9080)
    args = parser.parse_args()

    App.state_dir = Path(args.state_dir)
    App.env = load_env(App.state_dir / "stack.env")

    httpd = ThreadingHTTPServer((args.host, args.port), App)
    httpd.serve_forever()


if __name__ == "__main__":
    main()

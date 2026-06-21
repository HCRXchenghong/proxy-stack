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
    page_url = f"https://{env['WEB_DOMAIN']}/web/{slug}"
    link_url = f"https://{env['WEB_DOMAIN']}/link/{slug}"
    mihomo_url = f"https://{env['WEB_DOMAIN']}/mihomo/{slug}"
    node_url = f"https://{env['WEB_DOMAIN']}/node/{slug}"
    safe_name = html.escape(user["name"])
    return f"""<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{safe_name} - 节点交付</title>
  <style>
    :root {{
      color-scheme: light;
      --bg: #f6f8fb;
      --panel: #ffffff;
      --ink: #172033;
      --muted: #657085;
      --line: #dbe2ec;
      --soft: #eef3f7;
      --accent: #0f766e;
      --accent-2: #334155;
      --code: #111827;
    }}
    * {{ box-sizing: border-box; }}
    body {{
      margin: 0;
      min-height: 100vh;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      background: var(--bg);
      color: var(--ink);
    }}
    main {{ max-width: 980px; margin: 0 auto; padding: 28px 18px 42px; }}
    header {{
      display: flex;
      justify-content: space-between;
      align-items: flex-start;
      gap: 16px;
      padding: 22px 0 18px;
      border-bottom: 1px solid var(--line);
    }}
    h1 {{ margin: 0; font-size: 30px; line-height: 1.18; letter-spacing: 0; }}
    h2 {{ margin: 28px 0 12px; font-size: 18px; letter-spacing: 0; }}
    .meta {{ margin-top: 8px; color: var(--muted); font-size: 14px; word-break: break-all; }}
    .badge {{
      flex: 0 0 auto;
      border: 1px solid #b7d7d2;
      background: #e7f5f2;
      color: #0f5f59;
      border-radius: 999px;
      padding: 7px 11px;
      font-size: 13px;
      font-weight: 700;
    }}
    .grid {{ display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 12px; margin-top: 16px; }}
    .stack {{ display: grid; gap: 12px; }}
    .card {{
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 8px;
      padding: 16px;
      box-shadow: 0 10px 28px rgba(23, 32, 51, 0.06);
    }}
    .card-title {{ margin: 0 0 10px; font-size: 15px; font-weight: 800; }}
    .url {{
      display: block;
      min-height: 46px;
      white-space: pre-wrap;
      word-break: break-all;
      background: var(--soft);
      border: 1px solid #e3e9f2;
      border-radius: 8px;
      padding: 11px;
      color: var(--code);
      font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      font-size: 13px;
      line-height: 1.45;
    }}
    .actions {{ display: flex; gap: 8px; margin-top: 12px; }}
    button, a.button {{
      appearance: none;
      border: 1px solid var(--line);
      background: #ffffff;
      color: var(--accent-2);
      border-radius: 8px;
      padding: 9px 12px;
      font-size: 14px;
      font-weight: 700;
      text-decoration: none;
      cursor: pointer;
    }}
    button.primary, a.primary {{ background: var(--accent); border-color: var(--accent); color: #ffffff; }}
    .wide {{ grid-column: 1 / -1; }}
    .toast {{
      position: fixed;
      left: 50%;
      bottom: 22px;
      transform: translateX(-50%);
      background: #172033;
      color: #ffffff;
      border-radius: 8px;
      padding: 10px 14px;
      opacity: 0;
      pointer-events: none;
      transition: opacity .18s ease;
      font-size: 14px;
    }}
    .toast.show {{ opacity: 1; }}
    @media (max-width: 760px) {{
      main {{ padding: 18px 14px 32px; }}
      header {{ display: block; }}
      h1 {{ font-size: 26px; }}
      .badge {{ display: inline-block; margin-top: 14px; }}
      .grid {{ grid-template-columns: 1fr; }}
      .actions {{ flex-wrap: wrap; }}
      button, a.button {{ flex: 1 1 auto; text-align: center; }}
    }}
  </style>
</head>
<body>
  <main>
    <header>
      <div>
        <h1>{safe_name}</h1>
        <div class="meta">交付页面：{html.escape(page_url)}</div>
      </div>
      <div class="badge">已启用</div>
    </header>

    <h2>订阅入口</h2>
    <div class="grid">
      <div class="card">
        <div class="card-title">通用订阅</div>
        <code class="url" id="link">{html.escape(link_url)}</code>
        <div class="actions">
          <button class="primary" data-copy="link">复制</button>
          <a class="button" href="{html.escape(link_url)}">打开</a>
        </div>
      </div>
      <div class="card">
        <div class="card-title">Mihomo 配置</div>
        <code class="url" id="mihomo">{html.escape(mihomo_url)}</code>
        <div class="actions">
          <button class="primary" data-copy="mihomo">复制</button>
          <a class="button" href="{html.escape(mihomo_url)}">打开</a>
        </div>
      </div>
      <div class="card">
        <div class="card-title">原始节点</div>
        <code class="url" id="node">{html.escape(node_url)}</code>
        <div class="actions">
          <button class="primary" data-copy="node">复制</button>
          <a class="button" href="{html.escape(node_url)}">打开</a>
        </div>
      </div>

      <div class="card wide">
        <div class="card-title">VLESS + REALITY + Vision</div>
        <code class="url" id="vless">{html.escape(vless)}</code>
        <div class="actions">
          <button class="primary" data-copy="vless">复制</button>
        </div>
      </div>
      <div class="card wide">
        <div class="card-title">Hysteria2</div>
        <code class="url" id="hy2">{html.escape(hy2)}</code>
        <div class="actions">
          <button class="primary" data-copy="hy2">复制</button>
        </div>
      </div>
    </div>
  </main>
  <div class="toast" id="toast">已复制</div>
  <script>
    const toast = document.getElementById('toast');
    function showToast(text) {{
      toast.textContent = text;
      toast.classList.add('show');
      setTimeout(() => toast.classList.remove('show'), 1300);
    }}
    document.querySelectorAll('[data-copy]').forEach((button) => {{
      button.addEventListener('click', async () => {{
        const target = document.getElementById(button.dataset.copy);
        const text = target ? target.textContent.trim() : '';
        try {{
          await navigator.clipboard.writeText(text);
          showToast('已复制');
        }} catch (err) {{
          showToast('复制失败，请手动选择');
        }}
      }});
    }});
  </script>
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

        if route == "link":
            body = "\n".join(raw_links(self.env, user)).encode()
            payload = base64.b64encode(body)
            self._send(HTTPStatus.OK, "text/plain; charset=utf-8", payload)
            return
        if route == "node":
            body = ("\n".join(raw_links(self.env, user)) + "\n").encode()
            self._send(HTTPStatus.OK, "text/plain; charset=utf-8", body)
            return
        if route == "mihomo":
            self._send(HTTPStatus.OK, "application/yaml; charset=utf-8", render_clash(self.env, user).encode())
            return
        if route == "web":
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

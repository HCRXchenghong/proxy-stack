#!/usr/bin/env python3
import argparse
import base64
import hmac
import html
import ipaddress
import json
import threading
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, quote, urlsplit


def load_env(path: Path) -> dict:
    env = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        env[k] = v
    return env


def secure_compare(left, right) -> bool:
    try:
        return hmac.compare_digest(str(left), str(right))
    except (TypeError, UnicodeError):
        return False


def find_user(state_dir: Path, slug: str):
    """Return an enabled user by the unguessable public slug only."""
    data = json.loads((state_dir / "users.json").read_text())
    for user in data.get("users", []):
        if user.get("enabled", True) and secure_compare(user.get("slug", ""), slug):
            return user
    return None


def find_user_by_hy2_auth(state_dir: Path, auth: str):
    data = json.loads((state_dir / "users.json").read_text())
    for user in data.get("users", []):
        if user.get("enabled", True) and secure_compare(user.get("hy2_auth", ""), auth):
            return user
    return None


def ip_is_allowed(address: str, networks) -> bool:
    try:
        candidate = ipaddress.ip_address(address)
        if isinstance(candidate, ipaddress.IPv6Address) and candidate.ipv4_mapped:
            candidate = candidate.ipv4_mapped
    except ValueError:
        return False

    for value in networks if isinstance(networks, list) else []:
        try:
            network = ipaddress.ip_network(str(value), strict=False)
        except ValueError:
            continue
        if candidate.version == network.version and candidate in network:
            return True
    return False


def authorize_subscription(user: dict, client_ip: str, supplied_tokens) -> tuple[bool, str]:
    """Authorize by a revocable client token or the user's source-IP allowlist."""
    tokens = [str(token) for token in supplied_tokens if token]
    clients = user.get("subscription_clients", [])
    if isinstance(clients, list):
        for client in clients:
            if not isinstance(client, dict) or not client.get("enabled", True):
                continue
            expected = str(client.get("token", ""))
            if not expected:
                continue
            for supplied in tokens:
                if secure_compare(expected, supplied):
                    allowed_ips = client.get("allowed_ips", [])
                    if not allowed_ips or ip_is_allowed(client_ip, allowed_ips):
                        return True, supplied

    if ip_is_allowed(client_ip, user.get("allowed_ips", [])):
        return True, ""
    return False, ""


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
    anytls = (
        f'anytls://{quote(user["anytls_password"], safe="")}@{env["PUBLIC_IP"]}:{env["ANYTLS_PORT"]}'
        f'?security=tls&sni={quote(env["WEB_DOMAIN"])}&fp=chrome'
        f'#{quote(name + "-anytls")}'
    )
    tuic = (
        f'tuic://{quote(user["tuic_uuid"], safe="")}:{quote(user["tuic_password"], safe="")}'
        f'@{env["PUBLIC_IP"]}:{env["TUIC_PORT"]}'
        f'?sni={quote(env["WEB_DOMAIN"])}&alpn=h3&congestion_control=bbr'
        f'&udp_relay_mode=native&zero_rtt_handshake=false#{quote(name + "-tuic")}'
    )
    naive = (
        f'naive+https://{quote(user["naive_username"], safe="")}:'
        f'{quote(user["naive_password"], safe="")}@{env["WEB_DOMAIN"]}:{env["NAIVE_PORT"]}'
        f'#{quote(name + "-naive")}'
    )
    return vless, hy2, anytls, tuic, naive


def render_clash(env: dict, user: dict):
    # JSON strings are valid YAML scalars and prevent user-controlled YAML injection.
    yaml_string = lambda value: json.dumps(str(value), ensure_ascii=False)
    names = {
        "vless": f'{user["name"]}-vless',
        "hy2": f'{user["name"]}-hy2',
        "anytls": f'{user["name"]}-anytls',
        "tuic": f'{user["name"]}-tuic',
    }
    base = f"""mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
proxies:
  - name: {yaml_string(names['vless'])}
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
  - name: {yaml_string(names['hy2'])}
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
        base += f"""    obfs: salamander
    obfs-password: {yaml_string(obfs)}
"""
    return base + f"""  - name: {yaml_string(names['anytls'])}
    type: anytls
    server: {env['PUBLIC_IP']}
    port: {env['ANYTLS_PORT']}
    password: {yaml_string(user['anytls_password'])}
    client-fingerprint: chrome
    udp: true
    sni: {env['WEB_DOMAIN']}
    alpn:
      - h2
      - http/1.1
    skip-cert-verify: false
  - name: {yaml_string(names['tuic'])}
    type: tuic
    server: {env['PUBLIC_IP']}
    port: {env['TUIC_PORT']}
    uuid: {user['tuic_uuid']}
    password: {yaml_string(user['tuic_password'])}
    sni: {env['WEB_DOMAIN']}
    alpn:
      - h3
    disable-sni: false
    reduce-rtt: false
    udp-relay-mode: native
    congestion-controller: bbr
proxy-groups:
  - name: "AUTO"
    type: select
    proxies:
      - {yaml_string(names['vless'])}
      - {yaml_string(names['hy2'])}
      - {yaml_string(names['anytls'])}
      - {yaml_string(names['tuic'])}
rules:
  - MATCH,AUTO
"""


def render_html(env: dict, user: dict, client_token: str = ""):
    vless, hy2, anytls, tuic, naive = raw_links(env, user)
    slug = user["slug"]
    query = f"?client={quote(client_token, safe='')}" if client_token else ""
    page_url = f"https://{env['WEB_DOMAIN']}/web/{slug}{query}"
    link_url = f"https://{env['WEB_DOMAIN']}/link/{slug}{query}"
    mihomo_url = f"https://{env['WEB_DOMAIN']}/mihomo/{slug}{query}"
    node_url = f"https://{env['WEB_DOMAIN']}/node/{slug}{query}"
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
      <div class="card wide">
        <div class="card-title">AnyTLS</div>
        <code class="url" id="anytls">{html.escape(anytls)}</code>
        <div class="actions"><button class="primary" data-copy="anytls">复制</button></div>
      </div>
      <div class="card wide">
        <div class="card-title">TUIC v5（0-RTT 已关闭）</div>
        <code class="url" id="tuic">{html.escape(tuic)}</code>
        <div class="actions"><button class="primary" data-copy="tuic">复制</button></div>
      </div>
      <div class="card wide">
        <div class="card-title">NaiveProxy（独立客户端）</div>
        <code class="url" id="naive">{html.escape(naive)}</code>
        <div class="actions"><button class="primary" data-copy="naive">复制</button></div>
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

    def _client_ip(self) -> str:
        peer_ip = str(self.client_address[0])
        expected = self.env.get("INTERNAL_PROXY_TOKEN", "")
        supplied = self.headers.get("X-Proxy-Stack-Internal", "")
        if expected and supplied and secure_compare(expected, supplied):
            forwarded = self.headers.get("X-Real-IP", "").strip()
            try:
                ipaddress.ip_address(forwarded)
                return forwarded
            except ValueError:
                pass
        return peer_ip

    def _supplied_client_tokens(self, query: dict) -> list[str]:
        tokens = query.get("client", [])
        if len(tokens) > 1:
            return []
        result = [tokens[0]] if tokens else []
        authorization = self.headers.get("Authorization", "")
        if authorization.startswith("Bearer "):
            result.append(authorization[7:].strip())
        return [token for token in result if token]

    def do_GET(self):
        parsed = urlsplit(self.path)
        parts = [p for p in parsed.path.split("/") if p]
        if not parts:
            self.send_error(HTTPStatus.NOT_FOUND)
            return

        route = parts[0]
        if parts == ["healthz"]:
            self._send(HTTPStatus.OK, "text/plain; charset=utf-8", b"ok")
            return
        if len(parts) != 2 or route not in {"web", "link", "mihomo", "node"}:
            self.send_error(HTTPStatus.NOT_FOUND)
            return

        key = parts[1]
        user = find_user(self.state_dir, key)
        if not user:
            self.send_error(HTTPStatus.NOT_FOUND)
            return

        query = parse_qs(parsed.query, keep_blank_values=True)
        supplied_tokens = self._supplied_client_tokens(query)
        authorized, matched_token = authorize_subscription(user, self._client_ip(), supplied_tokens)
        if not authorized:
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
            self._send(
                HTTPStatus.OK,
                "text/html; charset=utf-8",
                render_html(self.env, user, matched_token).encode(),
            )
            return

        self.send_error(HTTPStatus.NOT_FOUND)

    def do_POST(self):
        parts = [p for p in self.path.split("?")[0].split("/") if p]
        if parts == ["hy2-auth"]:
            try:
                length = int(self.headers.get("Content-Length", "0") or "0")
            except ValueError:
                self._send(HTTPStatus.BAD_REQUEST, "application/json; charset=utf-8", b'{"ok":false}')
                return
            if length < 0 or length > 4096:
                self._send(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, "application/json; charset=utf-8", b'{"ok":false}')
                return
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
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
        self.send_header("Pragma", "no-cache")
        self.end_headers()
        self.wfile.write(body)


class BoundedThreadingHTTPServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, *args, max_workers=64, **kwargs):
        self._worker_slots = threading.BoundedSemaphore(max_workers)
        super().__init__(*args, **kwargs)

    def get_request(self):
        request, client_address = super().get_request()
        request.settimeout(15)
        return request, client_address

    def process_request(self, request, client_address):
        if not self._worker_slots.acquire(blocking=False):
            request.close()
            return
        try:
            super().process_request(request, client_address)
        except Exception:
            self._worker_slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self._worker_slots.release()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--state-dir", required=True)
    parser.add_argument("--env-file", default="")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=9080)
    args = parser.parse_args()

    App.state_dir = Path(args.state_dir)
    env_file = Path(args.env_file) if args.env_file else App.state_dir / "stack.env"
    App.env = load_env(env_file)

    httpd = BoundedThreadingHTTPServer((args.host, args.port), App)
    httpd.serve_forever()


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
import argparse
import base64
import hmac
import html
import ipaddress
import json
import re
import secrets
import threading
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, quote, urlsplit


MAX_USERS_FILE_BYTES = 16 * 1024 * 1024
MAX_REQUEST_TARGET_LENGTH = 4096
MAX_QUERY_LENGTH = 1024
MAX_CLIENT_TOKEN_LENGTH = 256
PUBLIC_SLUG_RE = re.compile(r"^[A-Za-z0-9_-]{24,64}$")
DOMAIN_RE = re.compile(r"^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$", re.IGNORECASE)
SAFE_TOKEN_RE = re.compile(r"^[A-Za-z0-9_-]+$")


def load_env(path: Path) -> dict:
    env = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        env[k] = v
    return env


def validate_runtime_env(env: dict) -> bool:
    """Reject malformed root-managed configuration before serving requests."""
    required = (
        "PUBLIC_IP",
        "WEB_DOMAIN",
        "REALITY_PUBLIC_KEY",
        "REALITY_SNI",
        "REALITY_SHORT_ID",
        "ANYTLS_PORT",
        "TUIC_PORT",
        "NAIVE_PORT",
        "HTTPS_PORT",
        "INTERNAL_PROXY_TOKEN",
    )
    if not isinstance(env, dict) or any(not isinstance(env.get(key), str) for key in required):
        return False
    if any(not value or len(value) > 512 or any(char in value for char in "\r\n\x00") for value in env.values()):
        return False
    try:
        if not isinstance(ipaddress.ip_address(env["PUBLIC_IP"]), ipaddress.IPv4Address):
            return False
        ports = {key: int(env[key]) for key in ("ANYTLS_PORT", "TUIC_PORT", "NAIVE_PORT", "HTTPS_PORT")}
        if any(not 1 <= value <= 65535 for value in ports.values()):
            return False
        if len({443, ports["ANYTLS_PORT"], ports["NAIVE_PORT"], ports["HTTPS_PORT"]}) != 4:
            return False
    except ValueError:
        return False
    if not DOMAIN_RE.fullmatch(env["WEB_DOMAIN"]) or not DOMAIN_RE.fullmatch(env["REALITY_SNI"]):
        return False
    if not SAFE_TOKEN_RE.fullmatch(env["REALITY_PUBLIC_KEY"]):
        return False
    if not re.fullmatch(r"[0-9a-fA-F]{2,32}", env["REALITY_SHORT_ID"]):
        return False
    if not re.fullmatch(r"[A-Za-z0-9_-]{40,256}", env["INTERNAL_PROXY_TOKEN"]):
        return False
    obfs = env.get("HY2_OBFS_PASSWORD", "")
    return not obfs or bool(re.fullmatch(r"[A-Za-z0-9_-]{16,256}", obfs))


def secure_compare(left, right) -> bool:
    try:
        return hmac.compare_digest(str(left), str(right))
    except (TypeError, UnicodeError):
        return False


def load_users(state_dir: Path) -> list[dict]:
    """Load a bounded, minimally validated user list and fail closed."""
    try:
        path = state_dir / "users.json"
        if path.stat().st_size > MAX_USERS_FILE_BYTES:
            return []
        data = json.loads(path.read_text(encoding="utf-8"))
        users = data.get("users", []) if isinstance(data, dict) else []
        return [user for user in users if isinstance(user, dict)] if isinstance(users, list) else []
    except (OSError, UnicodeError, json.JSONDecodeError, TypeError, ValueError):
        return []


def find_user(state_dir: Path, slug: str):
    """Return an enabled user by the unguessable public slug only."""
    if not isinstance(slug, str) or not PUBLIC_SLUG_RE.fullmatch(slug):
        return None
    for user in load_users(state_dir):
        if user.get("enabled", True) and secure_compare(user.get("slug", ""), slug):
            return user
    return None


def find_user_by_hy2_auth(state_dir: Path, auth: str):
    if not isinstance(auth, str) or not 1 <= len(auth) <= MAX_CLIENT_TOKEN_LENGTH:
        return None
    for user in load_users(state_dir):
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
    if not isinstance(user, dict) or not isinstance(supplied_tokens, list):
        return False, ""
    tokens = [str(token) for token in supplied_tokens if token and len(str(token)) <= MAX_CLIENT_TOKEN_LENGTH]
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
    https_proxy = (
        f'https://{quote(user["https_username"], safe="")}:'
        f'{quote(user["https_password"], safe="")}@{env["WEB_DOMAIN"]}:{env["HTTPS_PORT"]}'
        f'#{quote(name + "-https")}'
    )
    return vless, hy2, anytls, tuic, naive, https_proxy


def render_clash(env: dict, user: dict):
    # JSON strings are valid YAML scalars and prevent user-controlled YAML injection.
    yaml_string = lambda value: json.dumps(str(value), ensure_ascii=False)
    names = {
        "vless": f'{user["name"]}-vless',
        "hy2": f'{user["name"]}-hy2',
        "anytls": f'{user["name"]}-anytls',
        "tuic": f'{user["name"]}-tuic',
        "https": f'{user["name"]}-https',
    }
    base = f"""mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
proxies:
  - name: {yaml_string(names['vless'])}
    type: vless
    server: {yaml_string(env['PUBLIC_IP'])}
    port: 443
    uuid: {yaml_string(user['vless_uuid'])}
    network: tcp
    tls: true
    udp: true
    servername: {yaml_string(env['REALITY_SNI'])}
    reality-opts:
      public-key: {yaml_string(env['REALITY_PUBLIC_KEY'])}
      short-id: {yaml_string(env['REALITY_SHORT_ID'])}
    client-fingerprint: chrome
    flow: xtls-rprx-vision
  - name: {yaml_string(names['hy2'])}
    type: hysteria2
    server: {yaml_string(env['PUBLIC_IP'])}
    port: 443
    password: {yaml_string(user['hy2_auth'])}
    sni: {yaml_string(env['WEB_DOMAIN'])}
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
    server: {yaml_string(env['PUBLIC_IP'])}
    port: {env['ANYTLS_PORT']}
    password: {yaml_string(user['anytls_password'])}
    client-fingerprint: chrome
    udp: true
    sni: {yaml_string(env['WEB_DOMAIN'])}
    alpn:
      - h2
      - http/1.1
    skip-cert-verify: false
  - name: {yaml_string(names['tuic'])}
    type: tuic
    server: {yaml_string(env['PUBLIC_IP'])}
    port: {env['TUIC_PORT']}
    uuid: {yaml_string(user['tuic_uuid'])}
    password: {yaml_string(user['tuic_password'])}
    sni: {yaml_string(env['WEB_DOMAIN'])}
    alpn:
      - h3
    disable-sni: false
    reduce-rtt: false
    udp-relay-mode: native
    congestion-controller: bbr
  - name: {yaml_string(names['https'])}
    type: http
    server: {yaml_string(env['WEB_DOMAIN'])}
    port: {env['HTTPS_PORT']}
    username: {yaml_string(user['https_username'])}
    password: {yaml_string(user['https_password'])}
    tls: true
    sni: {yaml_string(env['WEB_DOMAIN'])}
    skip-cert-verify: false
proxy-groups:
  - name: "AUTO"
    type: select
    proxies:
      - {yaml_string(names['vless'])}
      - {yaml_string(names['hy2'])}
      - {yaml_string(names['anytls'])}
      - {yaml_string(names['tuic'])}
      - {yaml_string(names['https'])}
rules:
  - MATCH,AUTO
"""


def render_html(env: dict, user: dict, client_token: str = "", csp_nonce: str = ""):
    vless, hy2, anytls, tuic, naive, https_proxy = raw_links(env, user)
    slug = user["slug"]
    query = f"?client={quote(client_token, safe='')}" if client_token else ""
    page_url = f"https://{env['WEB_DOMAIN']}/web/{slug}{query}"
    link_url = f"https://{env['WEB_DOMAIN']}/link/{slug}{query}"
    mihomo_url = f"https://{env['WEB_DOMAIN']}/mihomo/{slug}{query}"
    node_url = f"https://{env['WEB_DOMAIN']}/node/{slug}{query}"
    safe_name = html.escape(user["name"])
    safe_nonce = html.escape(csp_nonce, quote=True)
    return f"""<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{safe_name} - 节点交付</title>
  <style nonce="{safe_nonce}">
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
      <div class="card wide">
        <div class="card-title">HTTPS Proxy（TLS 1.3）</div>
        <code class="url" id="https-proxy">{html.escape(https_proxy)}</code>
        <div class="actions"><button class="primary" data-copy="https-proxy">复制</button></div>
      </div>
    </div>
  </main>
  <div class="toast" id="toast">已复制</div>
  <script nonce="{safe_nonce}">
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
        query_token = tokens[0] if tokens else ""
        authorization = self.headers.get("Authorization", "")
        header_token = ""
        if authorization.startswith("Bearer "):
            header_token = authorization[7:].strip()
        if query_token and header_token and not secure_compare(query_token, header_token):
            return []
        token = query_token or header_token
        if not token or len(token) > MAX_CLIENT_TOKEN_LENGTH:
            return []
        return [token]

    def do_GET(self):
        if len(self.path) > MAX_REQUEST_TARGET_LENGTH:
            self.send_error(HTTPStatus.REQUEST_URI_TOO_LONG)
            return
        try:
            parsed = urlsplit(self.path)
        except ValueError:
            self.send_error(HTTPStatus.BAD_REQUEST)
            return
        if len(parsed.query) > MAX_QUERY_LENGTH:
            self.send_error(HTTPStatus.REQUEST_URI_TOO_LONG)
            return
        parts = [p for p in parsed.path.split("/") if p]
        if not parts:
            self.send_error(HTTPStatus.NOT_FOUND)
            return

        route = parts[0]
        if parts == ["healthz"] and parsed.path == "/healthz" and not parsed.query:
            self._send(HTTPStatus.OK, "text/plain; charset=utf-8", b"ok")
            return
        if len(parts) != 2 or route not in {"web", "link", "mihomo", "node"}:
            self.send_error(HTTPStatus.NOT_FOUND)
            return

        key = parts[1]
        if parsed.path != f"/{route}/{key}" or not PUBLIC_SLUG_RE.fullmatch(key):
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        user = find_user(self.state_dir, key)
        if not user:
            self.send_error(HTTPStatus.NOT_FOUND)
            return

        try:
            query = parse_qs(parsed.query, keep_blank_values=True, max_num_fields=4)
        except ValueError:
            self.send_error(HTTPStatus.BAD_REQUEST)
            return
        if any(name != "client" for name in query):
            self.send_error(HTTPStatus.NOT_FOUND)
            return
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
            nonce = secrets.token_urlsafe(24)
            content_security_policy = (
                "default-src 'none'; "
                f"style-src 'nonce-{nonce}'; script-src 'nonce-{nonce}'; "
                "connect-src 'none'; img-src 'none'; font-src 'none'; object-src 'none'; "
                "base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
            )
            self._send(
                HTTPStatus.OK,
                "text/html; charset=utf-8",
                render_html(self.env, user, matched_token, nonce).encode(),
                {"Content-Security-Policy": content_security_policy},
            )
            return

        self.send_error(HTTPStatus.NOT_FOUND)

    def do_POST(self):
        if len(self.path) > MAX_REQUEST_TARGET_LENGTH:
            self.send_error(HTTPStatus.REQUEST_URI_TOO_LONG)
            return
        if self.path == "/hy2-auth":
            if self.headers.get("Transfer-Encoding"):
                self._send(HTTPStatus.BAD_REQUEST, "application/json; charset=utf-8", b'{"ok":false}')
                return
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
            except (UnicodeError, json.JSONDecodeError, TypeError, ValueError):
                self._send(HTTPStatus.OK, "application/json; charset=utf-8", b'{"ok":false}')
                return
            auth = payload.get("auth", "") if isinstance(payload, dict) else ""
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

    def send_response(self, code, message=None):
        """Send status and date without disclosing the Python server banner."""
        self.log_request(code)
        self.send_response_only(code, message)
        self.send_header("Date", self.date_time_string())

    def send_error(self, code, message=None, explain=None):
        body = b"not found" if int(code) == int(HTTPStatus.NOT_FOUND) else b"request rejected"
        self._send(code, "text/plain; charset=utf-8", body)

    def _send(self, status, content_type, body: bytes, extra_headers=None):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
        self.send_header("Pragma", "no-cache")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
        for name, value in (extra_headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            return


class BoundedThreadingHTTPServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, *args, max_workers=32, **kwargs):
        self._worker_slots = threading.BoundedSemaphore(max_workers)
        super().__init__(*args, **kwargs)

    def get_request(self):
        request, client_address = super().get_request()
        request.settimeout(10)
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
    if not validate_runtime_env(App.env):
        parser.error("运行配置无效或包含不安全值")

    httpd = BoundedThreadingHTTPServer((args.host, args.port), App)
    httpd.serve_forever()


if __name__ == "__main__":
    main()

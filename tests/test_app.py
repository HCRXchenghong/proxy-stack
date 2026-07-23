import base64
import json
import subprocess
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path

import app


ENV = {
    "PUBLIC_IP": "203.0.113.10",
    "WEB_DOMAIN": "node.example.net",
    "REALITY_PUBLIC_KEY": "public-key",
    "REALITY_SNI": "www.amazon.com",
    "REALITY_SHORT_ID": "01234567",
    "HY2_OBFS_PASSWORD": "obfs-secret",
    "ANYTLS_PORT": "8443",
    "TUIC_PORT": "8443",
    "NAIVE_PORT": "8444",
    "INTERNAL_PROXY_TOKEN": "nginx-to-app-secret",
}

USER = {
    "name": "alice",
    "slug": "abcdefghijklmnopqrstuvwxyz012345",
    "vless_uuid": "11111111-1111-4111-8111-111111111111",
    "hy2_auth": "hy2-secret",
    "anytls_password": "anytls-secret",
    "tuic_uuid": "22222222-2222-4222-8222-222222222222",
    "tuic_password": "tuic-secret",
    "naive_username": "u_abcdefghijklmnopqrstuvwxyz012345",
    "naive_password": "naive-secret",
    "allowed_ips": [],
    "subscription_clients": [
        {
            "name": "default",
            "token": "client-token-secret",
            "enabled": True,
            "allowed_ips": [],
        }
    ],
    "enabled": True,
}


class DeliverySecurityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.state = Path(self.temp.name)
        (self.state / "users.json").write_text(json.dumps({"users": [USER]}))

    def tearDown(self):
        self.temp.cleanup()

    def test_public_lookup_accepts_only_enabled_slug(self):
        self.assertEqual(app.find_user(self.state, USER["slug"])["name"], "alice")
        self.assertIsNone(app.find_user(self.state, "alice"))

        disabled = dict(USER, enabled=False)
        (self.state / "users.json").write_text(json.dumps({"users": [disabled]}))
        self.assertIsNone(app.find_user(self.state, USER["slug"]))

    def test_raw_subscription_contains_five_distinct_protocols(self):
        links = app.raw_links(ENV, USER)
        self.assertEqual(len(links), 5)
        self.assertEqual(
            [link.split(":", 1)[0] for link in links],
            ["vless", "hysteria2", "anytls", "tuic", "naive+https"],
        )

    def test_mihomo_is_not_a_lan_open_proxy(self):
        config = app.render_clash(ENV, USER)
        self.assertIn("allow-lan: false", config)
        self.assertNotIn("allow-lan: true", config)
        for proxy_type in ("vless", "hysteria2", "anytls", "tuic"):
            self.assertIn(f"type: {proxy_type}", config)
        self.assertIn("reduce-rtt: false", config)

    def test_base64_subscription_round_trip(self):
        payload = base64.b64encode("\n".join(app.raw_links(ENV, USER)).encode())
        self.assertEqual(len(base64.b64decode(payload).decode().splitlines()), 5)

    def test_non_ascii_or_wrong_client_tokens_are_rejected_safely(self):
        self.assertEqual(app.authorize_subscription(USER, "192.0.2.1", ["错误令牌"]), (False, ""))
        self.assertEqual(app.authorize_subscription(USER, "192.0.2.1", ["wrong"]), (False, ""))

    def test_http_routes_do_not_accept_username(self):
        app.App.state_dir = self.state
        app.App.env = ENV
        server = app.BoundedThreadingHTTPServer(("127.0.0.1", 0), app.App)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            base = f"http://127.0.0.1:{server.server_port}"
            with self.assertRaises(urllib.error.HTTPError) as error:
                urllib.request.urlopen(f"{base}/node/alice?client=client-token-secret", timeout=2)
            self.assertEqual(error.exception.code, 404)
            with self.assertRaises(urllib.error.HTTPError) as error:
                urllib.request.urlopen(f"{base}/node/{USER['slug']}", timeout=2)
            self.assertEqual(error.exception.code, 404)
            body = urllib.request.urlopen(
                f"{base}/node/{USER['slug']}?client=client-token-secret", timeout=2
            ).read().decode()
            self.assertEqual(len(body.splitlines()), 5)
        finally:
            server.shutdown()
            server.server_close()

    def test_ip_allowlist_uses_only_authenticated_nginx_source_ip(self):
        allowed = dict(USER, allowed_ips=["198.51.100.0/24"], subscription_clients=[])
        (self.state / "users.json").write_text(json.dumps({"users": [allowed]}))
        app.App.state_dir = self.state
        app.App.env = ENV
        server = app.BoundedThreadingHTTPServer(("127.0.0.1", 0), app.App)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            url = f"http://127.0.0.1:{server.server_port}/node/{USER['slug']}"
            spoofed = urllib.request.Request(url, headers={"X-Real-IP": "198.51.100.8"})
            with self.assertRaises(urllib.error.HTTPError) as error:
                urllib.request.urlopen(spoofed, timeout=2)
            self.assertEqual(error.exception.code, 404)

            trusted = urllib.request.Request(
                url,
                headers={
                    "X-Real-IP": "198.51.100.8",
                    "X-Proxy-Stack-Internal": ENV["INTERNAL_PROXY_TOKEN"],
                },
            )
            body = urllib.request.urlopen(trusted, timeout=2).read().decode()
            self.assertEqual(len(body.splitlines()), 5)
        finally:
            server.shutdown()
            server.server_close()

    def test_client_token_can_be_bound_to_ip_and_html_preserves_token(self):
        client = dict(USER["subscription_clients"][0], allowed_ips=["203.0.113.0/24"])
        bound = dict(USER, subscription_clients=[client])
        (self.state / "users.json").write_text(json.dumps({"users": [bound]}))
        app.App.state_dir = self.state
        app.App.env = ENV
        server = app.BoundedThreadingHTTPServer(("127.0.0.1", 0), app.App)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            url = (
                f"http://127.0.0.1:{server.server_port}/web/{USER['slug']}"
                "?client=client-token-secret"
            )
            wrong_ip = urllib.request.Request(
                url,
                headers={
                    "X-Real-IP": "198.51.100.8",
                    "X-Proxy-Stack-Internal": ENV["INTERNAL_PROXY_TOKEN"],
                },
            )
            with self.assertRaises(urllib.error.HTTPError) as error:
                urllib.request.urlopen(wrong_ip, timeout=2)
            self.assertEqual(error.exception.code, 404)

            right_ip = urllib.request.Request(
                url,
                headers={
                    "X-Real-IP": "203.0.113.8",
                    "X-Proxy-Stack-Internal": ENV["INTERNAL_PROXY_TOKEN"],
                },
            )
            body = urllib.request.urlopen(right_ip, timeout=2).read().decode()
            self.assertIn(
                f"/mihomo/{USER['slug']}?client=client-token-secret",
                body,
            )
        finally:
            server.shutdown()
            server.server_close()

    def test_hysteria_http_auth_rejects_wrong_password(self):
        app.App.state_dir = self.state
        app.App.env = ENV
        server = app.BoundedThreadingHTTPServer(("127.0.0.1", 0), app.App)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            request = urllib.request.Request(
                f"http://127.0.0.1:{server.server_port}/hy2-auth",
                data=b'{"auth":"wrong"}',
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            payload = json.loads(urllib.request.urlopen(request, timeout=2).read())
            self.assertEqual(payload, {"ok": False})
        finally:
            server.shutdown()
            server.server_close()


class RenderTests(unittest.TestCase):
    def test_systemd_units_use_separate_non_root_accounts(self):
        template = (Path(__file__).parents[1] / "lib" / "render.sh").read_text()
        for variable in (
            "XRAY_SERVICE_USER",
            "WEB_SERVICE_USER",
            "HYSTERIA_SERVICE_USER",
            "SING_BOX_SERVICE_USER",
        ):
            self.assertIn(f"User=${{{variable}}}", template)
        self.assertNotIn("User=root", template)
        self.assertGreaterEqual(template.count("NoNewPrivileges=true"), 4)
        self.assertIn("--env-file ${STATE_DIR}/public.env", template)

    def test_legacy_security_migration_rotates_exposed_credentials(self):
        with tempfile.TemporaryDirectory() as temp_name:
            state = Path(temp_name)
            old_user = dict(USER, slug="AbCd123456", vless_uuid="old-vless", hy2_auth="old-hy2")
            for key in ("anytls_password", "tuic_uuid", "tuic_password", "naive_username", "naive_password"):
                old_user.pop(key)
            (state / "stack.env").write_text("HY2_OBFS_PASSWORD=old-obfs\n")
            (state / "users.json").write_text(json.dumps({"users": [old_user]}))
            command = r'''
source "$1/lib/render.sh"
STATE_DIR="$2"
SERVICE_TLS_DIR="$2/tls"
secure_state_file() { chmod 0600 "$1"; }
secure_root_file() { chmod 0600 "$1"; }
ensure_env_defaults
ensure_user_protocol_credentials
'''
            subprocess.run(
                ["bash", "-c", command, "bash", str(Path(__file__).parents[1]), str(state)],
                check=True,
                stdout=subprocess.DEVNULL,
            )
            migrated = json.loads((state / "users.json").read_text())
            user = migrated["users"][0]
            self.assertEqual(migrated["schema_version"], 3)
            self.assertGreaterEqual(len(user["slug"]), 24)
            self.assertNotEqual(user["vless_uuid"], "old-vless")
            self.assertNotEqual(user["hy2_auth"], "old-hy2")
            self.assertTrue(user["anytls_password"])
            self.assertEqual(user["allowed_ips"], [])
            self.assertEqual(user["subscription_clients"][0]["name"], "default")
            self.assertGreaterEqual(len(user["subscription_clients"][0]["token"]), 40)
            env_text = (state / "stack.env").read_text()
            self.assertIn("SECURITY_SCHEMA_VERSION=2", env_text)
            self.assertIn("INTERNAL_PROXY_TOKEN=", env_text)
            self.assertNotIn("HY2_OBFS_PASSWORD=old-obfs", env_text)

    def test_sing_box_server_has_three_hardened_inbounds(self):
        with tempfile.TemporaryDirectory() as temp_name:
            state = Path(temp_name)
            (state / "stack.env").write_text(
                "WEB_DOMAIN=node.example.net\nANYTLS_PORT=8443\nTUIC_PORT=8443\nNAIVE_PORT=8444\n"
            )
            (state / "users.json").write_text(json.dumps({"users": [USER]}))
            command = r'''
source "$1/lib/render.sh"
STATE_DIR="$2"
SERVICE_TLS_DIR="$2/tls"
ANYTLS_PORT=8443
TUIC_PORT=8443
NAIVE_PORT=8444
secure_state_file() { chmod 0600 "$1"; }
write_sing_box_config
'''
            subprocess.run(
                ["bash", "-c", command, "bash", str(Path(__file__).parents[1]), str(state)],
                check=True,
            )
            config = json.loads((state / "sing-box.json").read_text())
            self.assertEqual([item["type"] for item in config["inbounds"]], ["anytls", "tuic", "naive"])
            self.assertFalse(config["inbounds"][1]["zero_rtt_handshake"])
            self.assertEqual(config["route"]["rules"], [{"ip_is_private": True, "action": "reject"}])

    def test_fail2ban_has_temporary_and_permanent_ssh_thresholds(self):
        template = (Path(__file__).parents[1] / "lib" / "render.sh").read_text()
        self.assertIn("[proxy-stack-sshd-day]", template)
        self.assertIn("maxretry = 3", template)
        self.assertIn("bantime = 86400", template)
        self.assertIn("[proxy-stack-sshd-permanent]", template)
        self.assertIn("maxretry = 11", template)
        self.assertIn("bantime = -1", template)
        self.assertIn("dbpurgeage = 315360000", template)
        self.assertIn("[proxy-stack-recidive]", template)

    def test_chinese_menu_exposes_all_access_and_ssh_controls(self):
        script = (Path(__file__).parents[1] / "proxy-stack.sh").read_text()
        for label in (
            "16) 订阅访问控制",
            "17) SSH 安全防护",
            "新增允许的设备",
            "撤销已允许的设备",
            "给设备令牌绑定 IP/CIDR",
            "添加用户 IP/CIDR 白名单",
            "手动永久封禁 IP",
            "解除 IP 的全部封禁",
            "重新应用最高安全配置",
        ):
            self.assertIn(label, script)
        for command in (
            'user client-add',
            'user client-del',
            'user client-allow-ip',
            'user client-deny-ip',
            'user allow-ip',
            'user deny-ip',
            'security ban',
            'security unban',
            'security apply',
        ):
            self.assertIn(command, script)


if __name__ == "__main__":
    unittest.main()

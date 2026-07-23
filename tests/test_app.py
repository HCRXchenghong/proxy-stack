import base64
import io
import json
import re
import stat
import subprocess
import tarfile
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

import app


ENV = {
    "PUBLIC_IP": "203.0.113.10",
    "WEB_DOMAIN": "node.example.net",
    "REALITY_PUBLIC_KEY": "public-key",
    "REALITY_SNI": "www.amazon.com",
    "REALITY_SHORT_ID": "01234567",
    "HY2_OBFS_PASSWORD": "O" * 32,
    "ANYTLS_PORT": "8443",
    "TUIC_PORT": "8443",
    "NAIVE_PORT": "8444",
    "INTERNAL_PROXY_TOKEN": "N" * 43,
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

    def test_malformed_or_oversized_user_database_fails_closed(self):
        (self.state / "users.json").write_text("not-json")
        self.assertIsNone(app.find_user(self.state, USER["slug"]))
        (self.state / "users.json").write_bytes(b" " * (app.MAX_USERS_FILE_BYTES + 1))
        self.assertIsNone(app.find_user(self.state, USER["slug"]))

    def test_runtime_environment_validation_rejects_injection(self):
        self.assertTrue(app.validate_runtime_env(ENV))
        poisoned = dict(ENV, WEB_DOMAIN="node.example.net\nrules: injected")
        self.assertFalse(app.validate_runtime_env(poisoned))
        weak_internal_token = dict(ENV, INTERNAL_PROXY_TOKEN="short")
        self.assertFalse(app.validate_runtime_env(weak_internal_token))

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
            response = urllib.request.urlopen(
                f"{base}/node/{USER['slug']}?client=client-token-secret", timeout=2
            )
            self.assertIsNone(response.headers.get("Server"))
            body = response.read().decode()
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
            response = urllib.request.urlopen(right_ip, timeout=2)
            csp = response.headers.get("Content-Security-Policy", "")
            self.assertIn("default-src 'none'", csp)
            self.assertIn("style-src 'nonce-", csp)
            self.assertNotIn("unsafe-inline", csp)
            body = response.read().decode()
            nonce = re.search(r'<style nonce="([A-Za-z0-9_-]+)">', body).group(1)
            self.assertIn(f'<script nonce="{nonce}">', body)
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

    def test_request_limits_and_ambiguous_tokens_fail_closed(self):
        app.App.state_dir = self.state
        app.App.env = ENV
        server = app.BoundedThreadingHTTPServer(("127.0.0.1", 0), app.App)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            base = f"http://127.0.0.1:{server.server_port}"
            oversized = f"{base}/node/{USER['slug']}?client=" + ("x" * (app.MAX_QUERY_LENGTH + 1))
            with self.assertRaises(urllib.error.HTTPError) as error:
                urllib.request.urlopen(oversized, timeout=2)
            self.assertEqual(error.exception.code, 414)

            url = f"{base}/node/{USER['slug']}?client=client-token-secret"
            ambiguous = urllib.request.Request(url, headers={"Authorization": "Bearer different"})
            with self.assertRaises(urllib.error.HTTPError) as error:
                urllib.request.urlopen(ambiguous, timeout=2)
            self.assertEqual(error.exception.code, 404)
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
        for setting in (
            "ProtectKernelLogs=true",
            "ProtectClock=true",
            "ProtectHostname=true",
            "ProtectProc=invisible",
            "RestrictNamespaces=true",
            "SystemCallArchitectures=native",
            "MemoryDenyWriteExecute=true",
            "KeyringMode=private",
        ):
            self.assertGreaterEqual(template.count(setting), 4)

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

    def test_shell_generated_internal_token_is_urlsafe_without_padding(self):
        common = Path(__file__).parents[1] / "lib" / "common.sh"
        result = subprocess.run(
            ["bash", "-c", 'source "$1"; random_token 32', "bash", str(common)],
            check=True,
            stdout=subprocess.PIPE,
            text=True,
        )
        self.assertRegex(result.stdout.strip(), r"^[A-Za-z0-9_-]{40,}$")
        self.assertNotIn("=", result.stdout)

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
            self.assertEqual(config["dns"]["servers"], [{"type": "local", "tag": "local"}])
            self.assertEqual(
                config["route"]["rules"][0],
                {"action": "resolve", "server": "local", "strategy": "prefer_ipv4"},
            )
            self.assertEqual(config["route"]["rules"][1], {"ip_is_private": True, "action": "reject"})
            special_ranges = config["route"]["rules"][2]["ip_cidr"]
            for network in ("169.254.0.0/16", "64:ff9b::/96", "2001:db8::/32", "ff00::/8"):
                self.assertIn(network, special_ranges)

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

    def test_nginx_template_has_strict_limits_without_unsafe_inline_csp(self):
        template = (Path(__file__).parents[1] / "lib" / "render.sh").read_text()
        self.assertNotIn("unsafe-inline", template)
        self.assertIn("client_header_timeout 10s", template)
        self.assertIn("large_client_header_buffers 2 4k", template)
        self.assertIn("limit_conn proxy_stack_web_conn 10", template)
        self.assertIn("log_format proxy_stack_acme_safe", template)
        self.assertIn("proxy-stack-access.log proxy_stack_acme_safe", template)
        self.assertGreaterEqual(template.count("proxy-stack-error.log crit"), 2)
        self.assertIn("listen 127.0.0.1:${WEB_TLS_PORT} ssl http2 proxy_protocol", template)
        self.assertIn("real_ip_header proxy_protocol", template)
        self.assertIn("proxy_protocol on", template)
        self.assertIn('"acceptProxyProtocol": True', template)

    def test_remote_bootstrap_requires_hash_and_safe_extraction(self):
        deploy = (Path(__file__).parents[1] / "deploy.sh").read_text()
        self.assertIn("PROXY_STACK_TARBALL_SHA256", deploy)
        self.assertIn("远程部署必须提供可信的 --tarball-sha256", deploy)
        self.assertIn("safe_extract_tar", deploy)
        self.assertNotIn('tar -xzf "$archive"', deploy)
        self.assertIn("--proto '=https'", deploy)
        self.assertIn("--proto-redir '=https'", deploy)
        self.assertIn("已有安装目录不能允许组或其他用户写入", deploy)

    def test_sensitive_exports_are_path_limited_and_atomic(self):
        script = (Path(__file__).parents[1] / "proxy-stack.sh").read_text()
        self.assertIn("validate_export_path", script)
        self.assertIn("导出目标不能是符号链接", script)
        self.assertIn("导出文件只允许写入 /root、/home/<用户> 或 /var/backups", script)
        self.assertIn("os.replace(tmp_name, out_path)", script)


class ArchiveExtractionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.common = Path(__file__).parents[1] / "lib" / "common.sh"

    def tearDown(self):
        self.temp.cleanup()

    def run_extract(self, kind, archive, destination):
        command = 'source "$1"; safe_extract_archive "$2" "$3" "$4"'
        return subprocess.run(
            ["bash", "-c", command, "bash", str(self.common), kind, str(archive), str(destination)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

    def test_tar_extractor_accepts_regular_files_and_rejects_traversal_and_links(self):
        normal = self.root / "normal.tar.gz"
        with tarfile.open(normal, "w:gz") as handle:
            payload = b"safe"
            info = tarfile.TarInfo("project/file.txt")
            info.size = len(payload)
            info.mode = 0o644
            handle.addfile(info, io.BytesIO(payload))
        destination = self.root / "normal-out"
        result = self.run_extract("tar", normal, destination)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((destination / "project" / "file.txt").read_bytes(), b"safe")

        for name, member in (
            ("traversal", tarfile.TarInfo("../escaped.txt")),
            ("symlink", tarfile.TarInfo("project/link")),
        ):
            archive = self.root / f"{name}.tar.gz"
            if name == "symlink":
                member.type = tarfile.SYMTYPE
                member.linkname = "/etc/passwd"
            else:
                member.size = 1
            with tarfile.open(archive, "w:gz") as handle:
                handle.addfile(member, io.BytesIO(b"x") if member.isfile() else None)
            result = self.run_extract("tar", archive, self.root / f"{name}-out")
            self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "escaped.txt").exists())

    def test_zip_extractor_rejects_symbolic_links(self):
        archive = self.root / "link.zip"
        with zipfile.ZipFile(archive, "w") as handle:
            info = zipfile.ZipInfo("project/link")
            info.create_system = 3
            info.external_attr = (stat.S_IFLNK | 0o777) << 16
            handle.writestr(info, "/etc/passwd")
        result = self.run_extract("zip", archive, self.root / "zip-out")
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()

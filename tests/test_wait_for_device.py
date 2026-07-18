from __future__ import annotations

from contextlib import contextmanager
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest


PROJECT_ROOT = Path(__file__).resolve().parents[1]
VALID_TOKEN = "a" * 40
DEPLOYMENT_NONCE = "deployment-0123456789abcdef0123456789abcdef"


class _HealthHandler(BaseHTTPRequestHandler):
    payload_factory = staticmethod(dict)
    received_tokens: list[str] = []

    def do_GET(self) -> None:
        self.__class__.received_tokens.append(
            self.headers.get("X-Vibe-Stick-Token", "")
        )
        if self.path != "/device/health":
            self.send_response(404)
            self.end_headers()
            return
        data = json.dumps(self.__class__.payload_factory()).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, _format: str, *_args: object) -> None:
        return


@contextmanager
def _health_server(payload_factory):
    handler = type("HealthHandler", (_HealthHandler,), {})
    handler.payload_factory = staticmethod(payload_factory)
    handler.received_tokens = []
    try:
        server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    except PermissionError as exc:
        raise unittest.SkipTest("local sockets are unavailable in this sandbox") from exc
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server.server_address[1], handler
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


def _health_payload(*, fresh: bool) -> dict[str, object]:
    if fresh:
        seen_at = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        age = 0.0
    else:
        seen_at = "2020-01-01T00:00:00.000Z"
        age = 1000.0
    return {
        "ok": True,
        "bridge_name": "vibestick-bridge",
        "bridge_version": "0.1.5",
        "device_last_seen_at": seen_at,
        "device_last_seen_age_seconds": age,
        "device_firmware_name": "vibestick",
        "device_firmware_version": "0.1.5",
        "device_firmware_transport": "wifi",
        "device_firmware_build_date": "Jul 17 2026 10:20:30",
        "device_deployment_nonce": DEPLOYMENT_NONCE,
    }


class WaitForDeviceScriptTests(unittest.TestCase):
    def _project(self, temporary: str, token: str = VALID_TOKEN) -> Path:
        root = Path(temporary) / "project"
        (root / "scripts").mkdir(parents=True)
        shutil.copy2(
            PROJECT_ROOT / "scripts/wait-for-device.sh",
            root / "scripts/wait-for-device.sh",
        )
        (root / ".env").write_text(
            f"VIBE_STICK_BRIDGE_TOKEN='{token}'\n",
            encoding="utf-8",
        )
        return root

    def _run(
        self,
        root: Path,
        *,
        port: int,
        timeout: str = "1",
    ) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment.pop("VIBE_STICK_BRIDGE_TOKEN", None)
        environment["VIBE_STICK_PYTHON"] = sys.executable
        return subprocess.run(
            [
                "/bin/sh",
                str(root / "scripts/wait-for-device.sh"),
                "--deployment-nonce",
                DEPLOYMENT_NONCE,
                "--timeout",
                timeout,
                "--interval",
                "0.05",
                "--port",
                str(port),
            ],
            cwd=root,
            env=environment,
            text=True,
            capture_output=True,
            check=False,
            timeout=5,
        )

    def test_succeeds_for_a_fresh_authenticated_vibestick_poll(self) -> None:
        with tempfile.TemporaryDirectory() as temporary, _health_server(
            lambda: _health_payload(fresh=True)
        ) as (port, handler):
            root = self._project(temporary)
            result = self._run(root, port=port)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("VibeStick device is online", result.stdout)
        self.assertEqual(handler.received_tokens, [VALID_TOKEN])
        self.assertNotIn(VALID_TOKEN, result.stdout + result.stderr)

    def test_rejects_a_stale_device_presence_record(self) -> None:
        with tempfile.TemporaryDirectory() as temporary, _health_server(
            lambda: _health_payload(fresh=False)
        ) as (port, handler):
            root = self._project(temporary)
            result = self._run(root, port=port, timeout="0.2")

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.returncode, 75)
        self.assertIn("before this verification", result.stderr)
        self.assertGreaterEqual(len(handler.received_tokens), 1)
        self.assertNotIn(VALID_TOKEN, result.stdout + result.stderr)

    def test_rejects_a_fresh_device_from_another_deployment(self) -> None:
        def wrong_deployment() -> dict[str, object]:
            payload = _health_payload(fresh=True)
            payload["device_deployment_nonce"] = "different-0123456789abcdef0123456789abcdef"
            return payload

        with tempfile.TemporaryDirectory() as temporary, _health_server(
            wrong_deployment
        ) as (port, handler):
            root = self._project(temporary)
            result = self._run(root, port=port, timeout="0.2")

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.returncode, 75)
        self.assertIn("does not match this deployment", result.stderr)
        self.assertGreaterEqual(len(handler.received_tokens), 1)
        self.assertNotIn(VALID_TOKEN, result.stdout + result.stderr)

    def test_requires_a_valid_token_before_polling(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = self._project(temporary, token="too-short")
            result = self._run(root, port=8765)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("valid VIBE_STICK_BRIDGE_TOKEN", result.stderr)
        self.assertNotIn("too-short", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()

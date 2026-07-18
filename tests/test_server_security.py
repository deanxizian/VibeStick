import http.client
import json
import os
import threading
import unittest
from contextlib import contextmanager
from unittest import mock

from vibe_stick.protocol.state import default_state
from vibe_stick.server import app


class _TestStore:
    def __init__(self) -> None:
        self.events: list[dict[str, object]] = []

    def get_state(self):
        return default_state()

    def update_from_event(self, body):
        self.events.append(body)
        return default_state()

    def refresh_quota(self):
        return default_state()


@contextmanager
def _running_server(store: _TestStore):
    try:
        server = app.VibeStickHTTPServer(("127.0.0.1", 0), app.make_handler(store))
    except PermissionError as exc:
        raise unittest.SkipTest("local sockets are unavailable in this sandbox") from exc
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server.server_address[1]
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


class ServerSecurityTests(unittest.TestCase):
    def test_loopback_host_does_not_require_token(self) -> None:
        self.assertFalse(app._host_requires_token("127.0.0.1"))
        self.assertFalse(app._host_requires_token("localhost"))
        self.assertFalse(app._host_requires_token("::1"))

    def test_non_loopback_host_requires_token(self) -> None:
        self.assertTrue(app._host_requires_token("0.0.0.0"))
        self.assertTrue(app._host_requires_token(""))
        self.assertTrue(app._host_requires_token("192.168.1.10"))

    def test_placeholder_token_is_treated_as_missing(self) -> None:
        with mock.patch.dict(os.environ, {"VIBE_STICK_BRIDGE_TOKEN": "change-this-shared-token"}):
            self.assertEqual(app._bridge_token(), "")

    def test_real_token_is_used(self) -> None:
        with mock.patch.dict(os.environ, {"VIBE_STICK_BRIDGE_TOKEN": "abc123-secret"}):
            self.assertEqual(app._bridge_token(), "abc123-secret")

    def test_non_loopback_rejects_short_token(self) -> None:
        with mock.patch.dict(os.environ, {"VIBE_STICK_BRIDGE_TOKEN": "too-short"}):
            with self.assertRaises(SystemExit):
                app._enforce_bind_security("0.0.0.0")

    def test_non_loopback_rejects_non_url_safe_token(self) -> None:
        with mock.patch.dict(
            os.environ,
            {"VIBE_STICK_BRIDGE_TOKEN": "x" * 31 + "!"},
        ):
            with self.assertRaises(SystemExit):
                app._enforce_bind_security("0.0.0.0")

    def test_health_is_public_but_state_requires_token(self) -> None:
        store = _TestStore()
        with mock.patch.dict(
            os.environ,
            {"VIBE_STICK_BRIDGE_TOKEN": "0123456789abcdef"},
        ), _running_server(store) as port:
            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
            connection.request("GET", "/health")
            health = connection.getresponse()
            self.assertEqual(health.status, 200)
            health.read()

            connection.request("GET", "/device/health")
            protected_health = connection.getresponse()
            self.assertEqual(protected_health.status, 401)
            protected_health.read()

            connection.request("GET", "/state")
            unauthorized = connection.getresponse()
            self.assertEqual(unauthorized.status, 401)
            unauthorized.read()

            connection.request(
                "GET",
                "/state",
                headers={"X-Vibe-Stick-Token": "0123456789abcdef"},
            )
            authorized = connection.getresponse()
            payload = json.loads(authorized.read())
            self.assertEqual(authorized.status, 200)
            self.assertEqual(payload["bridge_name"], app.BRIDGE_NAME)
            connection.close()

    def test_health_reports_only_authenticated_vibestick_firmware_polls(self) -> None:
        store = _TestStore()
        token = "a" * 40
        firmware_headers = {
            "X-Vibe-Stick-Token": token,
            "X-Vibe-Stick-Firmware-Name": "vibestick",
            "X-Vibe-Stick-Firmware-Version": "0.1.5",
            "X-Vibe-Stick-Firmware-Transport": "wifi",
            "X-Vibe-Stick-Firmware-Build-Date": "Jul 17 2026 10:20:30",
            "X-Vibe-Stick-Deployment-Nonce": "deployment-0123456789abcdef0123456789abcdef",
        }
        with mock.patch.dict(
            os.environ,
            {"VIBE_STICK_BRIDGE_TOKEN": token},
            clear=True,
        ), _running_server(store) as port:
            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=2)

            connection.request("GET", "/device/health", headers={"X-Vibe-Stick-Token": token})
            initial = connection.getresponse()
            initial_payload = json.loads(initial.read())
            self.assertIsNone(initial_payload["device_last_seen_at"])
            self.assertIsNone(initial_payload["device_last_seen_age_seconds"])
            self.assertIsNone(initial_payload["device_firmware_name"])

            connection.request(
                "GET",
                "/state",
                headers={
                    **firmware_headers,
                    "X-Vibe-Stick-Token": "wrong-token",
                },
            )
            unauthorized = connection.getresponse()
            self.assertEqual(unauthorized.status, 401)
            unauthorized.read()

            connection.request(
                "GET",
                "/state",
                headers={
                    **firmware_headers,
                    "X-Vibe-Stick-Firmware-Name": "not-vibestick",
                },
            )
            wrong_firmware = connection.getresponse()
            self.assertEqual(wrong_firmware.status, 200)
            wrong_firmware.read()

            connection.request("GET", "/device/health", headers={"X-Vibe-Stick-Token": token})
            unchanged = connection.getresponse()
            unchanged_payload = json.loads(unchanged.read())
            self.assertIsNone(unchanged_payload["device_last_seen_at"])

            connection.request("GET", "/state", headers=firmware_headers)
            state = connection.getresponse()
            self.assertEqual(state.status, 200)
            state.read()

            connection.request("GET", "/device/health", headers={"X-Vibe-Stick-Token": token})
            health = connection.getresponse()
            payload = json.loads(health.read())
            connection.close()

        self.assertEqual(health.status, 200)
        self.assertTrue(payload["device_last_seen_at"].endswith("Z"))
        self.assertGreaterEqual(payload["device_last_seen_age_seconds"], 0)
        self.assertLess(payload["device_last_seen_age_seconds"], 1)
        self.assertEqual(payload["device_firmware_name"], "vibestick")
        self.assertEqual(payload["device_firmware_version"], "0.1.5")
        self.assertEqual(payload["device_firmware_transport"], "wifi")
        self.assertEqual(payload["device_firmware_build_date"], "Jul 17 2026 10:20:30")
        self.assertEqual(
            payload["device_deployment_nonce"],
            "deployment-0123456789abcdef0123456789abcdef",
        )
        self.assertNotIn(token, json.dumps(payload))

    def test_firmware_headers_without_a_configured_token_do_not_mark_device_online(self) -> None:
        store = _TestStore()
        with mock.patch.dict(os.environ, {}, clear=True), _running_server(store) as port:
            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
            connection.request(
                "GET",
                "/state",
                headers={
                    "X-Vibe-Stick-Firmware-Name": "vibestick",
                    "X-Vibe-Stick-Firmware-Version": "0.1.5",
                },
            )
            state = connection.getresponse()
            self.assertEqual(state.status, 200)
            state.read()

            connection.request("GET", "/device/health")
            health = connection.getresponse()
            payload = json.loads(health.read())
            connection.close()

        self.assertIsNone(payload["device_last_seen_at"])
        self.assertIsNone(payload["device_firmware_name"])

    def test_device_presence_tracker_uses_monotonic_age_and_bounded_metadata(self) -> None:
        wall_values = iter((1_721_188_800.125,))
        monotonic_values = iter((10.0, 12.345))
        tracker = app.DevicePresenceTracker(
            wall_clock=lambda: next(wall_values),
            monotonic_clock=lambda: next(monotonic_values),
        )
        tracker.record(
            {
                "name": "vibestick",
                "version": "0.1.5",
                "transport": "wifi",
                "build_date": "Jul 17 2026 10:20:30",
            }
        )

        payload = tracker.health_metadata()

        self.assertEqual(payload["device_last_seen_at"], "2024-07-17T04:00:00.125Z")
        self.assertEqual(payload["device_last_seen_age_seconds"], 2.345)
        self.assertEqual(
            app._firmware_metadata_from_headers(
                {
                    "X-Vibe-Stick-Firmware-Name": "vibestick",
                    "X-Vibe-Stick-Firmware-Version": "x" * 129,
                }
            )["version"],
            "",
        )

    def test_malformed_or_non_object_json_is_rejected(self) -> None:
        store = _TestStore()
        with mock.patch.dict(os.environ, {}, clear=True), _running_server(store) as port:
            for body in (b"{bad", b"[]", b"\xff"):
                with self.subTest(body=body):
                    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
                    connection.request(
                        "POST",
                        "/event",
                        body=body,
                        headers={"Content-Type": "application/json"},
                    )
                    response = connection.getresponse()
                    self.assertEqual(response.status, 400)
                    response.read()
                    connection.close()
        self.assertEqual(store.events, [])

    def test_oversized_json_is_rejected_without_reading_body(self) -> None:
        store = _TestStore()
        with mock.patch.dict(os.environ, {}, clear=True), _running_server(store) as port:
            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
            connection.putrequest("POST", "/event")
            connection.putheader("Content-Length", str(app.MAX_JSON_BODY_BYTES + 1))
            connection.endheaders()
            response = connection.getresponse()
            self.assertEqual(response.status, 413)
            response.read()
            connection.close()

    def test_browser_simple_content_type_cannot_trigger_event(self) -> None:
        store = _TestStore()
        with mock.patch.dict(os.environ, {}, clear=True), _running_server(store) as port:
            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
            connection.request(
                "POST",
                "/event",
                body=b'{"event":"button_double"}',
                headers={"Content-Type": "text/plain"},
            )
            response = connection.getresponse()
            self.assertEqual(response.status, 415)
            response.read()
            connection.close()

        self.assertEqual(store.events, [])

    def test_empty_browser_post_cannot_start_microphone(self) -> None:
        store = _TestStore()
        with mock.patch.dict(os.environ, {}, clear=True), _running_server(store) as port:
            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
            connection.request("POST", "/recording/start", body=b"")
            response = connection.getresponse()
            self.assertEqual(response.status, 415)
            response.read()
            connection.close()


if __name__ == "__main__":
    unittest.main()

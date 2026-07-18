from __future__ import annotations

import argparse
from collections import deque
import hmac
import ipaddress
import json
import os
import threading
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Mapping
from urllib.parse import parse_qs, urlparse

from vibe_stick import __version__ as BRIDGE_VERSION
from vibe_stick.audio.recorder import (
    RecordingConflictError,
    RecordingController,
    RecordingRequestError,
)
from vibe_stick.claude.usage import fetch_usage as fetch_claude_usage
from vibe_stick.claude.usage import to_quota_snapshot as claude_usage_to_quota
from vibe_stick.codex.quota import QuotaSnapshot, load_quota, save_quota
from vibe_stick.config.paths import CLAUDE_QUOTA_PATH, QUOTA_PATH, RECORDING_PATH, STATE_PATH, ensure_app_support
from vibe_stick.config.storage import atomic_write_text
from vibe_stick.desktop.hud import hide_hud
from vibe_stick.paste.input_injector import MacPasteInjector, PasteResult
from vibe_stick.protocol.state import (
    AlertState,
    AlertType,
    VibeStickState,
    AgentStatus,
    CodexState,
    ProviderState,
    default_state,
    event_id,
    now_time_text,
    state_from_dict,
)
from vibe_stick.providers.base import ProviderAlert, ProviderObservation
from vibe_stick.providers.claude import observe_claude
from vibe_stick.providers.codex import observe_codex

MANUAL_STATUS_SECONDS = 60
BRIDGE_NAME = "vibestick-bridge"
DEFAULT_MAX_RECORDING_AUDIO_BYTES = 2_000_000
DEFAULT_CLAUDE_USAGE_INTERVAL_SECONDS = 300
MIN_CLAUDE_USAGE_INTERVAL_SECONDS = 30
ALERT_PRESENTATION_SECONDS = 6.0
MAX_JSON_BODY_BYTES = 64 * 1024
REQUEST_SOCKET_TIMEOUT_SECONDS = 10
MAX_CONCURRENT_REQUESTS = 16
MAX_SEEN_ALERT_EVENT_IDS = 2048
MIN_BRIDGE_TOKEN_LENGTH = 32
PLACEHOLDER_BRIDGE_TOKENS = {
    "change-this-shared-token",
    "paste-generated-token-here",
    "changeme",
    "change-me",
    "your-token",
}
VIBESTICK_FIRMWARE_NAME = "vibestick"
MAX_FIRMWARE_METADATA_LENGTH = 128


class DevicePresenceTracker:
    """Tracks the latest authenticated VibeStick firmware state poll in memory."""

    def __init__(
        self,
        *,
        wall_clock: Callable[[], float] = time.time,
        monotonic_clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._lock = threading.Lock()
        self._wall_clock = wall_clock
        self._monotonic_clock = monotonic_clock
        self._last_seen_wall: float | None = None
        self._last_seen_monotonic: float | None = None
        self._firmware: dict[str, str] = {}

    def record(self, firmware: Mapping[str, str]) -> None:
        with self._lock:
            self._last_seen_wall = self._wall_clock()
            self._last_seen_monotonic = self._monotonic_clock()
            self._firmware = dict(firmware)

    def health_metadata(self) -> dict[str, Any]:
        with self._lock:
            last_seen_wall = self._last_seen_wall
            last_seen_monotonic = self._last_seen_monotonic
            firmware = dict(self._firmware)

        if last_seen_wall is None or last_seen_monotonic is None:
            return {
                "device_last_seen_at": None,
                "device_last_seen_age_seconds": None,
                "device_firmware_name": None,
                "device_firmware_version": None,
                "device_firmware_transport": None,
                "device_firmware_build_date": None,
                "device_deployment_nonce": None,
            }

        age_seconds = max(0.0, self._monotonic_clock() - last_seen_monotonic)
        seen_at = datetime.fromtimestamp(last_seen_wall, timezone.utc).isoformat(
            timespec="milliseconds"
        ).replace("+00:00", "Z")
        return {
            "device_last_seen_at": seen_at,
            "device_last_seen_age_seconds": round(age_seconds, 3),
            "device_firmware_name": firmware.get("name") or None,
            "device_firmware_version": firmware.get("version") or None,
            "device_firmware_transport": firmware.get("transport") or None,
            "device_firmware_build_date": firmware.get("build_date") or None,
            "device_deployment_nonce": firmware.get("deployment_nonce") or None,
        }


class RequestBodyError(ValueError):
    def __init__(self, status: HTTPStatus, message: str) -> None:
        super().__init__(message)
        self.status = status
        self.message = message


class VibeStickHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    block_on_close = False
    request_queue_size = 16

    def __init__(self, *args: object, **kwargs: object) -> None:
        self._request_slots = threading.BoundedSemaphore(MAX_CONCURRENT_REQUESTS)
        super().__init__(*args, **kwargs)

    def process_request(self, request: object, client_address: object) -> None:
        if not self._request_slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except Exception:
            self._request_slots.release()
            raise

    def process_request_thread(self, request: object, client_address: object) -> None:
        try:
            super().process_request_thread(request, client_address)
        finally:
            self._request_slots.release()


class BridgeStateStore:
    def __init__(self) -> None:
        ensure_app_support()
        self._lock = threading.RLock()
        self._project_root = _resolve_project_root()
        self._manual_status_until = 0.0
        self._state = self._load_state()
        self._last_active_provider = self._state.active_provider or "codex"
        self._claude_quota = load_quota(CLAUDE_QUOTA_PATH)
        if not _has_quota(self._claude_quota):
            self._claude_quota = _claude_quota_from_state(self._state)
        self._claude_usage_last_attempt = 0.0
        self._claude_usage_last_success = 0.0
        self._claude_usage_generation = 0
        self._claude_usage_thread: threading.Thread | None = None
        self._alert_tracking_initialized = False
        self._seen_alert_event_ids: set[str] = set()
        self._seen_alert_event_order: deque[str] = deque()
        self._pending_alerts: deque[ProviderAlert] = deque()
        self._published_alert_since = 0.0
        quota = load_quota(QUOTA_PATH)
        self._state.codex.quota_5h_remaining = quota.quota_5h_remaining
        self._state.codex.quota_7d_remaining = quota.quota_7d_remaining
        self._state.codex.quota_updated_at = quota.quota_updated_at
        self._state.codex.quota_stale = quota.quota_stale
        self.recording = RecordingController(RECORDING_PATH)
        self.input_injector = MacPasteInjector()
        hide_hud()

    def get_state(self) -> VibeStickState:
        with self._lock:
            self._refresh_providers_locked()
            self._state.time = now_time_text()
            self._save_state_locked()
            return self._state_snapshot_locked()

    def update_from_event(self, event: dict[str, Any]) -> VibeStickState:
        with self._lock:
            event_name = str(event.get("event") or "")
            requested_status = event.get("codex_status") or event.get("status")
            if requested_status:
                self._set_codex_status(str(requested_status), str(event.get("message") or ""))
                self._manual_status_until = time.monotonic() + MANUAL_STATUS_SECONDS
            elif event_name == "button_short":
                self._state.alert = AlertState(event_id="", type=AlertType.NONE, message="")
                self._log_button_action("send", self.input_injector.press_enter())
            elif event_name == "button_double":
                self._log_button_action("pause", self.input_injector.pause_current_codex_task())
            self._save_state_locked()
            return self._state_snapshot_locked()

    @staticmethod
    def _log_button_action(action: str, result: PasteResult) -> None:
        print(
            f"button action={action} success={str(result.success).lower()} message={result.message}",
            flush=True,
        )

    def refresh_quota(self) -> VibeStickState:
        with self._lock:
            self.refresh_quota_locked()
            self._save_state_locked()
            return self._state_snapshot_locked()

    def refresh_quota_locked(self) -> None:
        if self._state.active_provider == "claude":
            self._refresh_claude_usage_locked(force=True)
            self._state.provider = _provider_state_from_observation(
                self._apply_claude_quota(observe_claude(self._project_root))
            )
            return

        codex_observation = observe_codex(self._project_root)
        self._apply_codex_quota(codex_observation, force_stale=True)
        self._state.codex = _codex_state_from_observation(codex_observation)
        if self._state.active_provider == "codex":
            self._state.provider = _provider_state_from_observation(codex_observation)

    def start_recording(self, request: dict[str, Any] | None = None) -> dict[str, Any]:
        session = self.recording.start(request)
        return {"recording": session.to_public_jsonable(), "state": self.get_state().to_jsonable()}

    def stop_recording(self, request: dict[str, Any] | None = None) -> dict[str, Any]:
        session = self.recording.stop(request)
        return {"recording": session.to_public_jsonable(), "state": self.get_state().to_jsonable()}

    def upload_recording_audio(
        self,
        pcm: bytes,
        *,
        session_id: str = "",
        sample_rate: int = 16000,
        channels: int = 1,
        bits_per_sample: int = 16,
    ) -> dict[str, Any]:
        session = self.recording.attach_pcm(
            pcm,
            session_id=session_id,
            sample_rate=sample_rate,
            channels=channels,
            bits_per_sample=bits_per_sample,
        )
        return {"recording": session.to_public_jsonable(), "state": self.get_state().to_jsonable()}

    def _refresh_providers_locked(self) -> None:
        codex_observation = observe_codex(self._project_root)
        claude_observation = observe_claude(self._project_root)
        self._apply_codex_quota(codex_observation)

        if time.monotonic() < self._manual_status_until:
            _apply_manual_codex_state(codex_observation, self._state)

        active_provider = _select_active_provider(
            _configured_provider(),
            self._last_active_provider,
            codex_observation,
            claude_observation,
        )
        self._last_active_provider = active_provider
        self._state.active_provider = active_provider

        if active_provider == "claude":
            self._refresh_claude_usage_locked(force=False)
            active_observation = self._apply_claude_quota(claude_observation)
        else:
            active_observation = codex_observation

        self._state.codex = _codex_state_from_observation(codex_observation)
        self._state.provider = _provider_state_from_observation(active_observation)
        self._apply_alerts_from_observations(
            active_observation,
            codex_observation,
            claude_observation,
        )

    def _apply_alerts_from_observations(
        self,
        active_observation: ProviderObservation,
        *observations: ProviderObservation,
    ) -> None:
        preferred = _select_alert_observation(active_observation, *observations)
        alert_events = _collect_alert_events(preferred, *observations)
        now = time.monotonic()

        if not self._alert_tracking_initialized:
            for alert in alert_events:
                self._remember_alert_event_id(alert.event_id)
            self._alert_tracking_initialized = True
            # Establish a baseline after a Bridge restart without replaying a
            # terminal event that the device may already have announced.
            self._state.alert = AlertState(event_id="", type=AlertType.NONE, message="")
            self._published_alert_since = now
            return

        for alert in alert_events:
            if alert.event_id in self._seen_alert_event_ids:
                continue
            self._remember_alert_event_id(alert.event_id)
            self._pending_alerts.append(alert)

        current_is_alert = self._state.alert.type in {
            AlertType.DONE,
            AlertType.APPROVAL,
            AlertType.ERROR,
        }
        presentation_complete = (
            not current_is_alert
            or now - self._published_alert_since >= ALERT_PRESENTATION_SECONDS
        )
        if self._pending_alerts and presentation_complete:
            alert = self._pending_alerts.popleft()
            self._state.alert = AlertState(
                event_id=alert.event_id,
                type=AlertType(alert.alert_type),
                message=alert.message,
            )
            self._published_alert_since = now
            return

        if not self._pending_alerts:
            visible_event_ids = {alert.event_id for alert in alert_events}
            if self._state.alert.event_id in visible_event_ids:
                return
            # Never switch back to an older, already-consumed event merely
            # because its provider is active. That A→B→A transition makes the
            # device ring twice for A because it only remembers the last id.
            self._state.alert = AlertState(event_id="", type=AlertType.NONE, message="")

    def _remember_alert_event_id(self, event_id_value: str) -> None:
        if not event_id_value or event_id_value in self._seen_alert_event_ids:
            return
        self._seen_alert_event_ids.add(event_id_value)
        order = getattr(self, "_seen_alert_event_order", None)
        if order is None:
            order = deque()
            self._seen_alert_event_order = order
        order.append(event_id_value)
        while len(order) > MAX_SEEN_ALERT_EVENT_IDS:
            self._seen_alert_event_ids.discard(order.popleft())

    def _apply_codex_quota(self, observation: ProviderObservation, *, force_stale: bool = False) -> None:
        if observation.quota_5h_remaining is not None or observation.quota_7d_remaining is not None:
            refreshed = QuotaSnapshot(
                quota_5h_remaining=observation.quota_5h_remaining,
                quota_7d_remaining=observation.quota_7d_remaining,
                quota_updated_at=observation.quota_updated_at,
                quota_stale=observation.quota_stale,
            )
            save_quota(QUOTA_PATH, refreshed)
        else:
            existing = QuotaSnapshot(
                quota_5h_remaining=self._state.codex.quota_5h_remaining,
                quota_7d_remaining=self._state.codex.quota_7d_remaining,
                quota_updated_at=self._state.codex.quota_updated_at,
                quota_stale=self._state.codex.quota_stale,
            )
            if existing.quota_5h_remaining is None and existing.quota_7d_remaining is None:
                refreshed = existing
            else:
                refreshed = _stale_quota(existing)
            if force_stale:
                save_quota(QUOTA_PATH, refreshed)

        observation.quota_5h_remaining = refreshed.quota_5h_remaining
        observation.quota_7d_remaining = refreshed.quota_7d_remaining
        observation.quota_updated_at = refreshed.quota_updated_at
        observation.quota_stale = refreshed.quota_stale

    def _refresh_claude_usage_locked(self, *, force: bool) -> None:
        now = time.monotonic()
        interval = _claude_usage_interval_seconds()
        if not force and now - self._claude_usage_last_attempt < interval:
            return
        if not force:
            running = self._claude_usage_thread
            if running is not None and running.is_alive():
                return
            self._claude_usage_last_attempt = now
            generation = self._next_claude_usage_generation_locked()
            self._claude_usage_thread = threading.Thread(
                target=self._refresh_claude_usage_background,
                args=(generation,),
                name="vibestick-claude-quota",
                daemon=True,
            )
            self._claude_usage_thread.start()
            return

        self._claude_usage_last_attempt = now
        generation = self._next_claude_usage_generation_locked()
        usage = fetch_claude_usage()
        if generation == self._claude_usage_generation:
            self._apply_claude_usage_result_locked(usage, now)

    def _next_claude_usage_generation_locked(self) -> int:
        self._claude_usage_generation = getattr(
            self,
            "_claude_usage_generation",
            0,
        ) + 1
        return self._claude_usage_generation

    def _refresh_claude_usage_background(self, generation: int) -> None:
        try:
            usage = fetch_claude_usage()
        except Exception as exc:  # Provider failures must never take down state serving.
            print(f"claude quota refresh failed: {type(exc).__name__}", flush=True)
            usage = None
        now = time.monotonic()
        with self._lock:
            if generation != self._claude_usage_generation:
                return
            self._apply_claude_usage_result_locked(usage, now)

    def _apply_claude_usage_result_locked(self, usage: object | None, now: float) -> None:
        if usage is None:
            if _has_quota(self._claude_quota):
                self._claude_quota = _stale_quota(self._claude_quota)
                save_quota(CLAUDE_QUOTA_PATH, self._claude_quota)
            else:
                self._claude_quota = QuotaSnapshot()
            return

        self._claude_quota = claude_usage_to_quota(usage)
        save_quota(CLAUDE_QUOTA_PATH, self._claude_quota)
        self._claude_usage_last_success = now

    def _apply_claude_quota(self, observation: ProviderObservation) -> ProviderObservation:
        quota = self._current_claude_quota()
        observation.quota_5h_remaining = quota.quota_5h_remaining
        observation.quota_7d_remaining = quota.quota_7d_remaining
        observation.quota_updated_at = quota.quota_updated_at
        observation.quota_stale = quota.quota_stale
        return observation

    def _current_claude_quota(self) -> QuotaSnapshot:
        if (
            self._claude_quota.quota_5h_remaining is None
            and self._claude_quota.quota_7d_remaining is None
        ):
            return self._claude_quota
        if self._claude_usage_last_success and time.monotonic() - self._claude_usage_last_success > 30 * 60:
            return _stale_quota(self._claude_quota)
        return self._claude_quota

    def _set_codex_status(self, raw_status: str, message: str) -> None:
        try:
            status = AgentStatus(raw_status.upper())
        except ValueError:
            status = AgentStatus.UNKNOWN
        self._state.codex.status = status
        if self._state.active_provider == "codex":
            self._state.provider.status = status
        if status == AgentStatus.DONE:
            self._state.alert = AlertState(event_id("done"), AlertType.DONE, message or "Codex task completed")
        elif status == AgentStatus.APPROVAL:
            self._state.alert = AlertState(
                event_id("approval"),
                AlertType.APPROVAL,
                message or "Codex is waiting for approval",
            )
        elif status == AgentStatus.ERROR:
            self._state.alert = AlertState(event_id("error"), AlertType.ERROR, message or "Codex needs attention")
        else:
            self._state.alert = AlertState(event_id="", type=AlertType.NONE, message="")

    def _load_state(self) -> VibeStickState:
        try:
            return state_from_dict(json.loads(STATE_PATH.read_text()))
        except (FileNotFoundError, json.JSONDecodeError, OSError, ValueError):
            return default_state()

    def _save_state_locked(self) -> None:
        atomic_write_text(
            STATE_PATH,
            json.dumps(self._state.to_jsonable(), indent=2) + "\n",
            skip_if_unchanged=True,
        )

    def _state_snapshot_locked(self) -> VibeStickState:
        return state_from_dict(self._state.to_jsonable())


def make_handler(
    store: BridgeStateStore,
    device_presence: DevicePresenceTracker | None = None,
) -> type[BaseHTTPRequestHandler]:
    presence = device_presence or DevicePresenceTracker()

    class VibeStickHandler(BaseHTTPRequestHandler):
        server_version = "VibeStick/0.1"

        def setup(self) -> None:
            super().setup()
            self.connection.settimeout(REQUEST_SOCKET_TIMEOUT_SECONDS)

        def do_GET(self) -> None:
            parsed = urlparse(self.path)
            if parsed.path in _protected_paths() and not self._is_authorized():
                self._send_error(HTTPStatus.UNAUTHORIZED, "Unauthorized")
                return
            try:
                if parsed.path == "/state":
                    payload = _with_bridge_metadata(store.get_state().to_jsonable())
                    firmware = self._authenticated_firmware_metadata()
                    if firmware is not None:
                        presence.record(firmware)
                    self._send_json(payload)
                elif parsed.path == "/health":
                    self._send_json(
                        {
                            "ok": True,
                            "bridge_name": BRIDGE_NAME,
                            "bridge_version": BRIDGE_VERSION,
                            "bridge_instance": os.environ.get(
                                "VIBE_STICK_INSTALL_NONCE",
                                "",
                            ),
                        }
                    )
                elif parsed.path == "/device/health":
                    health = {
                        "ok": True,
                        "bridge_name": BRIDGE_NAME,
                        "bridge_version": BRIDGE_VERSION,
                        "bridge_instance": os.environ.get(
                            "VIBE_STICK_INSTALL_NONCE",
                            "",
                        ),
                    }
                    health.update(presence.health_metadata())
                    self._send_json(health)
                else:
                    self._send_error(HTTPStatus.NOT_FOUND, "Unknown endpoint")
            except Exception as exc:
                self._send_internal_error(exc)

        def do_POST(self) -> None:
            parsed = urlparse(self.path)
            if parsed.path in _protected_paths() and not self._is_authorized():
                self._send_error(HTTPStatus.UNAUTHORIZED, "Unauthorized")
                return
            try:
                if parsed.path == "/event":
                    body = self._read_json_body()
                    self._send_json(store.update_from_event(body).to_jsonable())
                elif parsed.path == "/quota/refresh":
                    self._require_content_type("application/json")
                    state = store.refresh_quota()
                    self._send_json({"refreshed": True, "state": state.to_jsonable()})
                elif parsed.path == "/recording/start":
                    body = self._read_json_body()
                    self._send_json(store.start_recording(body))
                elif parsed.path == "/recording/audio":
                    self._require_content_type("application/octet-stream")
                    query = parse_qs(parsed.query)
                    content_length = self._content_length()
                    max_audio_bytes = _max_recording_audio_bytes()
                    if content_length > max_audio_bytes:
                        raise RequestBodyError(
                            HTTPStatus.REQUEST_ENTITY_TOO_LARGE,
                            f"Recording audio exceeds {max_audio_bytes} bytes",
                        )
                    pcm = self._read_raw_body(content_length)
                    self._send_json(
                        store.upload_recording_audio(
                            pcm,
                            session_id=_first(query, "session_id"),
                            sample_rate=_int_header(self.headers.get("X-Vibe-Stick-Sample-Rate"), 16000),
                            channels=_int_header(self.headers.get("X-Vibe-Stick-Channels"), 1),
                            bits_per_sample=_int_header(self.headers.get("X-Vibe-Stick-Bits-Per-Sample"), 16),
                        )
                    )
                elif parsed.path == "/recording/stop":
                    body = self._read_json_body()
                    self._send_json(store.stop_recording(body))
                else:
                    self._send_error(HTTPStatus.NOT_FOUND, "Unknown endpoint")
            except RequestBodyError as exc:
                self._send_error(exc.status, exc.message)
            except RecordingConflictError as exc:
                self._send_error(HTTPStatus.CONFLICT, str(exc))
            except RecordingRequestError as exc:
                self._send_error(HTTPStatus.UNPROCESSABLE_ENTITY, str(exc))
            except ValueError as exc:
                self._send_error(HTTPStatus.BAD_REQUEST, str(exc) or "Invalid request")
            except Exception as exc:
                self._send_internal_error(exc)

        def log_message(self, fmt: str, *args: object) -> None:
            if (
                self.command == "GET"
                and urlparse(self.path).path == "/state"
                and len(args) > 1
                and str(args[1]) == "200"
            ):
                return
            firmware_name = self.headers.get("X-Vibe-Stick-Firmware-Name", "-")
            firmware_version = self.headers.get("X-Vibe-Stick-Firmware-Version", "-")
            firmware_transport = self.headers.get("X-Vibe-Stick-Firmware-Transport", "-")
            print(
                f"{self.address_string()} - {fmt % args} "
                f"firmware={firmware_name}/{firmware_version} transport={firmware_transport}",
                flush=True,
            )

        def _read_json_body(self) -> dict[str, Any]:
            length = self._content_length()
            if length > MAX_JSON_BODY_BYTES:
                raise RequestBodyError(
                    HTTPStatus.REQUEST_ENTITY_TOO_LARGE,
                    f"JSON body exceeds {MAX_JSON_BODY_BYTES} bytes",
                )
            self._require_content_type("application/json")
            if length == 0:
                return {}
            raw = self._read_raw_body(length)
            try:
                data = json.loads(raw.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                raise RequestBodyError(HTTPStatus.BAD_REQUEST, "Malformed JSON body") from exc
            if not isinstance(data, dict):
                raise RequestBodyError(HTTPStatus.BAD_REQUEST, "JSON body must be an object")
            return data

        def _require_content_type(self, expected: str) -> None:
            content_type = self.headers.get("Content-Type", "")
            media_type = content_type.partition(";")[0].strip().lower()
            if media_type != expected:
                raise RequestBodyError(
                    HTTPStatus.UNSUPPORTED_MEDIA_TYPE,
                    f"Content-Type must be {expected}",
                )

        def _read_raw_body(self, length: int) -> bytes:
            if length <= 0:
                return b""
            data = self.rfile.read(length)
            if len(data) != length:
                raise RequestBodyError(HTTPStatus.BAD_REQUEST, "Incomplete request body")
            return data

        def _content_length(self) -> int:
            raw = self.headers.get("Content-Length")
            if raw is None:
                return 0
            try:
                length = int(raw)
            except ValueError as exc:
                raise RequestBodyError(HTTPStatus.BAD_REQUEST, "Invalid Content-Length") from exc
            if length < 0:
                raise RequestBodyError(HTTPStatus.BAD_REQUEST, "Invalid Content-Length")
            return length

        def _is_authorized(self) -> bool:
            expected = _bridge_token()
            if not expected:
                return True
            supplied = self.headers.get("X-Vibe-Stick-Token", "")
            return hmac.compare_digest(supplied, expected)

        def _authenticated_firmware_metadata(self) -> dict[str, str] | None:
            expected = _bridge_token()
            if not expected:
                return None
            supplied = self.headers.get("X-Vibe-Stick-Token", "")
            if not hmac.compare_digest(supplied, expected):
                return None
            return _firmware_metadata_from_headers(self.headers)

        def _send_json(self, payload: dict[str, Any], status: HTTPStatus = HTTPStatus.OK) -> None:
            data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Access-Control-Allow-Origin", "http://127.0.0.1")
            self.end_headers()
            self.wfile.write(data)

        def _send_error(self, status: HTTPStatus, message: str) -> None:
            self._send_json({"error": message}, status=status)

        def _send_internal_error(self, exc: Exception) -> None:
            print(
                f"request failed method={self.command} path={urlparse(self.path).path} "
                f"error={type(exc).__name__}",
                flush=True,
            )
            try:
                self._send_error(HTTPStatus.INTERNAL_SERVER_ERROR, "Internal server error")
            except OSError:
                pass

    return VibeStickHandler


def run_server(host: str, port: int) -> None:
    _enforce_bind_security(host)
    store = BridgeStateStore()
    server = VibeStickHTTPServer((host, port), make_handler(store))
    if not _bridge_token():
        print(
            "WARNING: VIBE_STICK_BRIDGE_TOKEN is not set; protected endpoints are unauthenticated on loopback only.",
            flush=True,
        )
    print(f"VibeStick Bridge listening on http://{host}:{port}", flush=True)
    server.serve_forever()


def _protected_paths() -> set[str]:
    return {
        "/state",
        "/device/health",
        "/event",
        "/quota/refresh",
        "/recording/start",
        "/recording/audio",
        "/recording/stop",
    }


def _bridge_token() -> str:
    token = os.environ.get("VIBE_STICK_BRIDGE_TOKEN", "").strip()
    if token.lower() in PLACEHOLDER_BRIDGE_TOKENS:
        return ""
    return token


def _firmware_metadata_from_headers(headers: Mapping[str, str]) -> dict[str, str] | None:
    name = _safe_firmware_metadata_value(
        headers.get("X-Vibe-Stick-Firmware-Name", "")
    )
    if name.lower() != VIBESTICK_FIRMWARE_NAME:
        return None
    return {
        "name": VIBESTICK_FIRMWARE_NAME,
        "version": _safe_firmware_metadata_value(
            headers.get("X-Vibe-Stick-Firmware-Version", "")
        ),
        "transport": _safe_firmware_metadata_value(
            headers.get("X-Vibe-Stick-Firmware-Transport", "")
        ),
        "build_date": _safe_firmware_metadata_value(
            headers.get("X-Vibe-Stick-Firmware-Build-Date", "")
        ),
        "deployment_nonce": _safe_firmware_metadata_value(
            headers.get("X-Vibe-Stick-Deployment-Nonce", "")
        ),
    }


def _safe_firmware_metadata_value(value: str) -> str:
    normalized = " ".join(str(value).split())
    if not normalized or len(normalized) > MAX_FIRMWARE_METADATA_LENGTH:
        return ""
    if any(ord(character) < 0x20 or ord(character) == 0x7F for character in normalized):
        return ""
    return normalized


def _enforce_bind_security(host: str) -> None:
    if _host_requires_token(host) and not _bridge_token():
        raise SystemExit(
            "Refusing to bind VibeStick Bridge outside loopback without "
            "VIBE_STICK_BRIDGE_TOKEN. Set a strong shared token or use --host 127.0.0.1."
        )
    if _host_requires_token(host) and not _bridge_token_is_valid(_bridge_token()):
        raise SystemExit(
            f"VIBE_STICK_BRIDGE_TOKEN must contain {MIN_BRIDGE_TOKEN_LENGTH}-256 "
            "URL-safe characters when binding outside loopback."
        )


def _bridge_token_is_valid(token: str) -> bool:
    allowed_punctuation = "._~-"
    return (
        MIN_BRIDGE_TOKEN_LENGTH <= len(token) <= 256
        and token.isascii()
        and all(character.isalnum() or character in allowed_punctuation for character in token)
    )


def _host_requires_token(host: str) -> bool:
    normalized = host.strip().strip("[]").lower()
    if normalized == "localhost":
        return False
    if not normalized:
        return True
    try:
        address = ipaddress.ip_address(normalized)
    except ValueError:
        return True
    return not address.is_loopback


def _max_recording_audio_bytes() -> int:
    raw = os.environ.get("VIBE_STICK_MAX_RECORDING_AUDIO_BYTES", "").strip()
    if not raw:
        return DEFAULT_MAX_RECORDING_AUDIO_BYTES
    try:
        value = int(raw)
    except ValueError:
        return DEFAULT_MAX_RECORDING_AUDIO_BYTES
    return max(256_000, min(8_000_000, value))


def _resolve_project_root() -> Path:
    configured = os.environ.get("VIBE_STICK_PROJECT_ROOT", "").strip()
    root = Path(configured).expanduser() if configured else Path.cwd()
    if root.name in {"bridge", "firmware", "app", "scripts"} and (root.parent / "README.md").exists():
        root = root.parent
    return root.resolve()


def _stale_quota(existing: QuotaSnapshot) -> QuotaSnapshot:
    return QuotaSnapshot(
        quota_5h_remaining=existing.quota_5h_remaining,
        quota_7d_remaining=existing.quota_7d_remaining,
        quota_updated_at=existing.quota_updated_at,
        quota_stale=True,
    )


def _has_quota(snapshot: QuotaSnapshot) -> bool:
    return snapshot.quota_5h_remaining is not None or snapshot.quota_7d_remaining is not None


def _claude_quota_from_state(state: VibeStickState) -> QuotaSnapshot:
    provider = state.provider
    if provider.id != "claude":
        return QuotaSnapshot()
    snapshot = QuotaSnapshot(
        quota_5h_remaining=provider.quota_5h_remaining,
        quota_7d_remaining=provider.quota_7d_remaining,
        quota_updated_at=provider.quota_updated_at,
        quota_stale=True,
    )
    return snapshot if _has_quota(snapshot) else QuotaSnapshot()


def _first(query: dict[str, list[str]], key: str) -> str:
    values = query.get(key) or []
    return values[0] if values else ""


def _with_bridge_metadata(payload: dict[str, Any]) -> dict[str, Any]:
    payload["bridge_name"] = BRIDGE_NAME
    payload["bridge_version"] = BRIDGE_VERSION
    return payload


def _configured_provider() -> str:
    value = os.environ.get("VIBE_STICK_PROVIDER", "auto").strip().lower()
    return value if value in {"codex", "claude", "auto"} else "auto"


def _select_active_provider(
    configured: str,
    last_active: str,
    codex_observation: ProviderObservation,
    claude_observation: ProviderObservation,
) -> str:
    if configured in {"codex", "claude"}:
        return configured

    if codex_observation.online and not claude_observation.online:
        return "codex"
    if claude_observation.online and not codex_observation.online:
        return "claude"
    if codex_observation.online and claude_observation.online:
        codex_time = codex_observation.latest_event_timestamp
        claude_time = claude_observation.latest_event_timestamp
        if codex_time is not None and claude_time is not None:
            return "claude" if claude_time > codex_time else "codex"
        if claude_time is not None:
            return "claude"
        if codex_time is not None:
            return "codex"
        return last_active if last_active in {"codex", "claude"} else "codex"

    return last_active if last_active in {"codex", "claude"} else "codex"


def _select_alert_observation(
    active_observation: ProviderObservation,
    *observations: ProviderObservation,
) -> ProviderObservation:
    if _observation_has_alert(active_observation):
        return active_observation
    for observation in observations:
        if observation is active_observation:
            continue
        if _observation_has_alert(observation):
            return observation
    return active_observation


def _collect_alert_events(
    preferred: ProviderObservation,
    *observations: ProviderObservation,
) -> tuple[ProviderAlert, ...]:
    events: list[ProviderAlert] = []
    seen_event_ids: set[str] = set()
    for observation in (preferred, *observations):
        candidates = observation.alert_events
        if not candidates and _observation_has_alert(observation):
            candidates = (
                ProviderAlert(
                    event_id=observation.alert_event_id,
                    alert_type=observation.alert_type,
                    message=observation.alert_message,
                    timestamp=observation.latest_event_timestamp,
                ),
            )
        for alert in candidates:
            if not alert.event_id or alert.event_id in seen_event_ids:
                continue
            try:
                alert_type = AlertType(alert.alert_type)
            except ValueError:
                continue
            if alert_type not in {AlertType.DONE, AlertType.APPROVAL, AlertType.ERROR}:
                continue
            seen_event_ids.add(alert.event_id)
            events.append(alert)
    events.sort(
        key=lambda alert: alert.timestamp.timestamp()
        if alert.timestamp is not None
        else 0.0
    )
    return tuple(events)


def _observation_has_alert(observation: ProviderObservation) -> bool:
    try:
        alert_type = AlertType(observation.alert_type)
    except ValueError:
        return False
    return alert_type in {AlertType.DONE, AlertType.APPROVAL, AlertType.ERROR} and bool(observation.alert_event_id)


def _claude_usage_interval_seconds() -> int:
    try:
        value = int(os.environ.get("VIBE_STICK_CLAUDE_USAGE_INTERVAL_SECONDS", ""))
    except ValueError:
        value = DEFAULT_CLAUDE_USAGE_INTERVAL_SECONDS
    if value <= 0:
        value = DEFAULT_CLAUDE_USAGE_INTERVAL_SECONDS
    return max(MIN_CLAUDE_USAGE_INTERVAL_SECONDS, value)


def _codex_state_from_observation(observation: ProviderObservation) -> CodexState:
    return CodexState(
        status=observation.status,
        project=observation.project,
        quota_5h_remaining=observation.quota_5h_remaining,
        quota_7d_remaining=observation.quota_7d_remaining,
        quota_updated_at=observation.quota_updated_at,
        quota_stale=observation.quota_stale,
        active_conversations=observation.active_conversations,
    )


def _provider_state_from_observation(observation: ProviderObservation) -> ProviderState:
    return ProviderState(
        id=observation.provider_id,
        display_name=observation.display_name,
        implemented=True,
        status=observation.status,
        project=observation.project,
        quota_5h_remaining=observation.quota_5h_remaining,
        quota_7d_remaining=observation.quota_7d_remaining,
        quota_updated_at=observation.quota_updated_at,
        quota_stale=observation.quota_stale,
        active_conversations=observation.active_conversations,
    )


def _apply_manual_codex_state(observation: ProviderObservation, state: VibeStickState) -> None:
    observation.status = state.codex.status
    observation.alert_type = state.alert.type.value
    observation.alert_message = state.alert.message
    observation.alert_event_id = state.alert.event_id
    if _observation_has_alert(observation):
        manual_alert = ProviderAlert(
            event_id=observation.alert_event_id,
            alert_type=observation.alert_type,
            message=observation.alert_message,
            timestamp=datetime.now(timezone.utc),
        )
        observation.alert_events = (manual_alert,)
        observation.latest_event_timestamp = manual_alert.timestamp
    else:
        observation.alert_events = ()


def _int_header(raw: str | None, default: int) -> int:
    try:
        value = int(raw or "")
    except ValueError:
        return default
    return value if value > 0 else default


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run VibeStick Bridge.")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    return parser


def main(argv: list[str] | None = None) -> None:
    args = build_parser().parse_args(argv)
    run_server(args.host, args.port)

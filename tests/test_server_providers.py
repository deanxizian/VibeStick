import os
import threading
import unittest
from collections import deque
from datetime import datetime, timezone
from unittest import mock

from vibe_stick.protocol.state import AgentStatus, ProviderState, default_state
from vibe_stick.codex.quota import QuotaSnapshot
from vibe_stick.providers.base import ProviderAlert, ProviderObservation
from vibe_stick.server import app


class ServerProviderTests(unittest.TestCase):
    def test_configured_provider_accepts_known_values_only(self) -> None:
        with mock.patch.dict(os.environ, {"VIBE_STICK_PROVIDER": "claude"}):
            self.assertEqual(app._configured_provider(), "claude")
        with mock.patch.dict(os.environ, {"VIBE_STICK_PROVIDER": "bogus"}):
            self.assertEqual(app._configured_provider(), "auto")

    def test_select_active_provider_respects_pinned_config(self) -> None:
        self.assertEqual(app._select_active_provider("claude", "codex", self._obs("codex"), self._obs("claude")), "claude")

    def test_select_active_provider_auto_uses_online_provider(self) -> None:
        selected = app._select_active_provider(
            "auto",
            "codex",
            self._obs("codex", online=False),
            self._obs("claude", online=True),
        )

        self.assertEqual(selected, "claude")

    def test_select_active_provider_auto_uses_recent_activity_when_both_online(self) -> None:
        selected = app._select_active_provider(
            "auto",
            "codex",
            self._obs("codex", latest=datetime(2026, 6, 28, 9, 0, tzinfo=timezone.utc)),
            self._obs("claude", latest=datetime(2026, 6, 28, 9, 1, tzinfo=timezone.utc)),
        )

        self.assertEqual(selected, "claude")

    def test_select_active_provider_auto_keeps_last_when_none_online(self) -> None:
        selected = app._select_active_provider(
            "auto",
            "claude",
            self._obs("codex", online=False),
            self._obs("claude", online=False),
        )

        self.assertEqual(selected, "claude")

    def test_select_alert_observation_uses_non_active_provider_alert(self) -> None:
        active = self._obs("claude")
        codex = self._obs(
            "codex",
            status=AgentStatus.DONE,
            alert_type="DONE",
            alert_event_id="evt_codex_done",
            alert_message="Codex task completed",
        )

        selected = app._select_alert_observation(active, codex, active)

        self.assertIs(selected, codex)

    def test_select_alert_observation_prefers_active_provider_alert(self) -> None:
        active = self._obs(
            "claude",
            status=AgentStatus.APPROVAL,
            alert_type="APPROVAL",
            alert_event_id="evt_claude_approval",
            alert_message="Claude is waiting for approval",
        )
        codex = self._obs(
            "codex",
            status=AgentStatus.DONE,
            alert_type="DONE",
            alert_event_id="evt_codex_done",
            alert_message="Codex task completed",
        )

        selected = app._select_alert_observation(active, codex, active)

        self.assertIs(selected, active)

    def test_multiple_codex_completion_alerts_are_presented_in_order(self) -> None:
        store = app.BridgeStateStore.__new__(app.BridgeStateStore)
        store._state = default_state()
        store._alert_tracking_initialized = True
        store._seen_alert_event_ids = set()
        store._pending_alerts = deque()
        store._published_alert_since = 0.0
        first = ProviderAlert("evt_first", "DONE", "First completed")
        second = ProviderAlert("evt_second", "DONE", "Second completed")
        codex = self._obs("codex", status=AgentStatus.RUNNING)
        codex.alert_events = (first, second)

        with mock.patch.object(app.time, "monotonic", return_value=10.0):
            store._apply_alerts_from_observations(codex, codex)
        self.assertEqual(store._state.alert.event_id, "evt_first")

        with mock.patch.object(app.time, "monotonic", return_value=11.0):
            store._apply_alerts_from_observations(codex, codex)
        self.assertEqual(store._state.alert.event_id, "evt_first")

        with mock.patch.object(
            app.time,
            "monotonic",
            return_value=10.0 + app.ALERT_PRESENTATION_SECONDS + 0.1,
        ):
            store._apply_alerts_from_observations(codex, codex)
        self.assertEqual(store._state.alert.event_id, "evt_second")

        with mock.patch.object(
            app.time,
            "monotonic",
            return_value=10.0 + app.ALERT_PRESENTATION_SECONDS + 1.0,
        ):
            store._apply_alerts_from_observations(codex, codex)
        self.assertEqual(store._state.alert.event_id, "evt_second")

    def test_cross_provider_alert_does_not_fall_back_and_ring_twice(self) -> None:
        store = app.BridgeStateStore.__new__(app.BridgeStateStore)
        store._state = default_state()
        store._alert_tracking_initialized = True
        store._seen_alert_event_ids = set()
        store._seen_alert_event_order = deque()
        store._pending_alerts = deque()
        store._published_alert_since = 0.0
        first_at = datetime(2026, 7, 17, 10, 0, tzinfo=timezone.utc)
        second_at = datetime(2026, 7, 17, 10, 1, tzinfo=timezone.utc)
        codex = self._obs("codex", status=AgentStatus.DONE)
        codex.alert_events = (
            ProviderAlert("evt_codex", "DONE", "Codex done", first_at),
        )
        claude = self._obs("claude", status=AgentStatus.DONE)
        claude.alert_events = (
            ProviderAlert("evt_claude", "DONE", "Claude done", second_at),
        )

        with mock.patch.object(app.time, "monotonic", return_value=10.0):
            store._apply_alerts_from_observations(codex, codex, claude)
        self.assertEqual(store._state.alert.event_id, "evt_codex")

        with mock.patch.object(
            app.time,
            "monotonic",
            return_value=10.0 + app.ALERT_PRESENTATION_SECONDS + 0.1,
        ):
            store._apply_alerts_from_observations(codex, codex, claude)
        self.assertEqual(store._state.alert.event_id, "evt_claude")

        with mock.patch.object(
            app.time,
            "monotonic",
            return_value=10.0 + 2 * app.ALERT_PRESENTATION_SECONDS + 0.2,
        ):
            store._apply_alerts_from_observations(codex, codex, claude)
        self.assertEqual(store._state.alert.event_id, "evt_claude")

    def test_claude_usage_interval_has_minimum(self) -> None:
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertEqual(app._claude_usage_interval_seconds(), 300)
        with mock.patch.dict(os.environ, {"VIBE_STICK_CLAUDE_USAGE_INTERVAL_SECONDS": "5"}):
            self.assertEqual(app._claude_usage_interval_seconds(), 30)
        with mock.patch.dict(os.environ, {"VIBE_STICK_CLAUDE_USAGE_INTERVAL_SECONDS": "90"}):
            self.assertEqual(app._claude_usage_interval_seconds(), 90)

    def test_failed_claude_usage_refresh_keeps_cached_quota_stale(self) -> None:
        store = app.BridgeStateStore.__new__(app.BridgeStateStore)
        store._claude_quota = QuotaSnapshot(66, 96, "09:40", False)
        store._claude_usage_last_attempt = 0.0
        store._claude_usage_last_success = 1.0

        with mock.patch.object(app, "fetch_claude_usage", return_value=None):
            with mock.patch.object(app, "save_quota") as save_quota:
                store._refresh_claude_usage_locked(force=True)

        self.assertEqual(store._claude_quota.quota_5h_remaining, 66)
        self.assertEqual(store._claude_quota.quota_7d_remaining, 96)
        self.assertTrue(store._claude_quota.quota_stale)
        save_quota.assert_called_once_with(app.CLAUDE_QUOTA_PATH, store._claude_quota)

    def test_failed_claude_usage_without_cache_remains_unknown(self) -> None:
        store = app.BridgeStateStore.__new__(app.BridgeStateStore)
        store._claude_quota = QuotaSnapshot()
        store._claude_usage_last_attempt = 0.0
        store._claude_usage_last_success = 0.0

        with mock.patch.object(app, "fetch_claude_usage", return_value=None):
            with mock.patch.object(app, "save_quota") as save_quota:
                store._refresh_claude_usage_locked(force=True)

        self.assertIsNone(store._claude_quota.quota_5h_remaining)
        self.assertIsNone(store._claude_quota.quota_7d_remaining)
        save_quota.assert_not_called()

    def test_successful_claude_usage_refresh_saves_quota(self) -> None:
        store = app.BridgeStateStore.__new__(app.BridgeStateStore)
        store._claude_quota = QuotaSnapshot()
        store._claude_usage_last_attempt = 0.0
        store._claude_usage_last_success = 0.0
        refreshed = QuotaSnapshot(65, 95, "09:41", False)

        with mock.patch.object(app, "fetch_claude_usage", return_value=object()):
            with mock.patch.object(app, "claude_usage_to_quota", return_value=refreshed):
                with mock.patch.object(app, "save_quota") as save_quota:
                    store._refresh_claude_usage_locked(force=True)

        self.assertEqual(store._claude_quota, refreshed)
        save_quota.assert_called_once_with(app.CLAUDE_QUOTA_PATH, refreshed)

    def test_periodic_claude_usage_refresh_runs_outside_state_request(self) -> None:
        store = app.BridgeStateStore.__new__(app.BridgeStateStore)
        store._lock = threading.RLock()
        store._claude_quota = QuotaSnapshot()
        store._claude_usage_last_attempt = 0.0
        store._claude_usage_last_success = 0.0
        store._claude_usage_thread = None
        started = threading.Event()
        release = threading.Event()

        def fetch_usage():
            started.set()
            release.wait(timeout=2)
            return None

        with mock.patch.object(app, "fetch_claude_usage", side_effect=fetch_usage):
            with mock.patch.object(app.time, "monotonic", return_value=400.0):
                store._refresh_claude_usage_locked(force=False)
                self.assertTrue(started.wait(timeout=1))
                self.assertTrue(store._claude_usage_thread.is_alive())
                release.set()
                store._claude_usage_thread.join(timeout=2)

        self.assertFalse(store._claude_usage_thread.is_alive())

    def test_stale_background_usage_cannot_overwrite_forced_refresh(self) -> None:
        store = app.BridgeStateStore.__new__(app.BridgeStateStore)
        store._lock = threading.RLock()
        store._claude_quota = QuotaSnapshot()
        store._claude_usage_last_attempt = 0.0
        store._claude_usage_last_success = 0.0
        store._claude_usage_generation = 0
        store._claude_usage_thread = None
        background_started = threading.Event()
        release_background = threading.Event()
        old_usage = object()
        fresh_usage = object()
        old_quota = QuotaSnapshot(10, 20, "old", False)
        fresh_quota = QuotaSnapshot(80, 90, "fresh", False)

        def fetch_usage():
            if not background_started.is_set():
                background_started.set()
                release_background.wait(timeout=2)
                return old_usage
            return fresh_usage

        def to_quota(usage):
            return old_quota if usage is old_usage else fresh_quota

        with mock.patch.object(app, "fetch_claude_usage", side_effect=fetch_usage):
            with mock.patch.object(app, "claude_usage_to_quota", side_effect=to_quota):
                with mock.patch.object(app, "save_quota"):
                    with mock.patch.object(app.time, "monotonic", return_value=400.0):
                        with store._lock:
                            store._refresh_claude_usage_locked(force=False)
                        self.assertTrue(background_started.wait(timeout=1))
                        with store._lock:
                            store._refresh_claude_usage_locked(force=True)
                        release_background.set()
                        store._claude_usage_thread.join(timeout=2)

        self.assertFalse(store._claude_usage_thread.is_alive())
        self.assertEqual(store._claude_quota, fresh_quota)

    def test_first_observation_baselines_alerts_without_restart_replay(self) -> None:
        store = app.BridgeStateStore.__new__(app.BridgeStateStore)
        store._state = default_state()
        store._alert_tracking_initialized = False
        store._seen_alert_event_ids = set()
        store._seen_alert_event_order = deque()
        store._pending_alerts = deque()
        store._published_alert_since = 0.0
        codex = self._obs("codex", status=AgentStatus.DONE)
        codex.alert_events = (
            ProviderAlert("evt_before_restart", "DONE", "Already completed"),
        )

        with mock.patch.object(app.time, "monotonic", return_value=10.0):
            store._apply_alerts_from_observations(codex, codex)

        self.assertEqual(store._state.alert.type.value, "NONE")
        self.assertIn("evt_before_restart", store._seen_alert_event_ids)

    def test_manual_alert_replaces_real_history_during_override(self) -> None:
        observation = self._obs("codex", status=AgentStatus.RUNNING)
        observation.alert_events = (
            ProviderAlert("evt_real", "DONE", "Real completion"),
        )
        state = default_state()
        state.codex.status = AgentStatus.DONE
        state.alert.event_id = "evt_manual"
        state.alert.type = app.AlertType.DONE
        state.alert.message = "Manual test"

        app._apply_manual_codex_state(observation, state)
        events = app._collect_alert_events(observation, observation)

        self.assertEqual([event.event_id for event in events], ["evt_manual"])

    def test_claude_quota_can_seed_from_saved_provider_state(self) -> None:
        state = default_state()
        state.provider = ProviderState(
            id="claude",
            display_name="Claude",
            implemented=True,
            status=AgentStatus.IDLE,
            project="VibeStick",
            quota_5h_remaining=26,
            quota_7d_remaining=92,
            quota_updated_at="22:44",
            quota_stale=False,
        )

        snapshot = app._claude_quota_from_state(state)

        self.assertEqual(snapshot.quota_5h_remaining, 26)
        self.assertEqual(snapshot.quota_7d_remaining, 92)
        self.assertEqual(snapshot.quota_updated_at, "22:44")
        self.assertTrue(snapshot.quota_stale)

    def test_claude_quota_does_not_seed_from_other_provider_state(self) -> None:
        state = default_state()
        state.provider = ProviderState(
            id="codex",
            display_name="Codex",
            implemented=True,
            status=AgentStatus.IDLE,
            project="VibeStick",
            quota_5h_remaining=26,
            quota_7d_remaining=92,
            quota_updated_at="22:44",
            quota_stale=False,
        )

        snapshot = app._claude_quota_from_state(state)

        self.assertIsNone(snapshot.quota_5h_remaining)
        self.assertIsNone(snapshot.quota_7d_remaining)

    def _obs(
        self,
        provider_id: str,
        *,
        online: bool = True,
        latest: datetime | None = None,
        status: AgentStatus = AgentStatus.IDLE,
        alert_type: str = "NONE",
        alert_message: str = "",
        alert_event_id: str = "",
    ) -> ProviderObservation:
        return ProviderObservation(
            provider_id=provider_id,
            display_name=provider_id.title(),
            online=online,
            status=status,
            project="VibeStick",
            quota_5h_remaining=None,
            quota_7d_remaining=None,
            quota_updated_at="",
            quota_stale=False,
            alert_type=alert_type,
            alert_message=alert_message,
            alert_event_id=alert_event_id,
            latest_event_timestamp=latest,
        )


if __name__ == "__main__":
    unittest.main()

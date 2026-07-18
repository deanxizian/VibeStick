import unittest
from collections import deque
from datetime import datetime, timezone
from unittest import mock

from vibe_stick.protocol.state import AgentStatus, default_state
from vibe_stick.providers.base import ProviderAlert, ProviderObservation
from vibe_stick.server import app


class ServerCodexTests(unittest.TestCase):
    def test_running_conversation_count_reaches_both_state_blocks(self) -> None:
        observation = self._observation(
            status=AgentStatus.RUNNING,
            active_conversations=3,
        )

        self.assertEqual(
            app._codex_state_from_observation(observation).active_conversations,
            3,
        )
        self.assertEqual(
            app._provider_state_from_observation(observation).active_conversations,
            3,
        )

    def test_refresh_always_publishes_codex_as_active(self) -> None:
        store = app.BridgeStateStore.__new__(app.BridgeStateStore)
        store._project_root = mock.Mock()
        store._manual_status_until = 0.0
        store._state = default_state()
        store._alert_tracking_initialized = False
        store._seen_alert_event_ids = set()
        store._seen_alert_event_order = deque()
        store._pending_alerts = deque()
        store._published_alert_since = 0.0
        observation = self._observation(
            status=AgentStatus.RUNNING,
            active_conversations=2,
        )

        with mock.patch.object(app, "observe_codex", return_value=observation):
            with mock.patch.object(store, "_apply_codex_quota"):
                store._refresh_providers_locked()

        self.assertEqual(store._state.active_provider, "codex")
        self.assertEqual(store._state.provider.id, "codex")
        self.assertEqual(store._state.provider.status, AgentStatus.RUNNING)
        self.assertEqual(store._state.provider.active_conversations, 2)

    def test_multiple_completion_alerts_are_presented_in_order(self) -> None:
        store = self._alert_store()
        first = ProviderAlert("evt_first", "DONE", "First completed")
        second = ProviderAlert("evt_second", "DONE", "Second completed")
        observation = self._observation(status=AgentStatus.RUNNING)
        observation.alert_events = (first, second)

        with mock.patch.object(app.time, "monotonic", return_value=10.0):
            store._apply_alerts_from_observation(observation)
        self.assertEqual(store._state.alert.event_id, "evt_first")

        with mock.patch.object(app.time, "monotonic", return_value=11.0):
            store._apply_alerts_from_observation(observation)
        self.assertEqual(store._state.alert.event_id, "evt_first")

        with mock.patch.object(
            app.time,
            "monotonic",
            return_value=10.0 + app.ALERT_PRESENTATION_SECONDS + 0.1,
        ):
            store._apply_alerts_from_observation(observation)
        self.assertEqual(store._state.alert.event_id, "evt_second")

    def test_first_observation_baselines_alerts_without_restart_replay(self) -> None:
        store = self._alert_store()
        store._alert_tracking_initialized = False
        observation = self._observation(status=AgentStatus.DONE)
        observation.alert_events = (
            ProviderAlert("evt_before_restart", "DONE", "Already completed"),
        )

        with mock.patch.object(app.time, "monotonic", return_value=10.0):
            store._apply_alerts_from_observation(observation)

        self.assertEqual(store._state.alert.type.value, "NONE")
        self.assertIn("evt_before_restart", store._seen_alert_event_ids)

    def test_manual_alert_replaces_observed_history_during_override(self) -> None:
        observation = self._observation(status=AgentStatus.RUNNING)
        observation.alert_events = (
            ProviderAlert("evt_real", "DONE", "Real completion"),
        )
        state = default_state()
        state.codex.status = AgentStatus.DONE
        state.alert.event_id = "evt_manual"
        state.alert.type = app.AlertType.DONE
        state.alert.message = "Manual test"

        app._apply_manual_codex_state(observation, state)
        events = app._collect_alert_events(observation)

        self.assertEqual([event.event_id for event in events], ["evt_manual"])

    def test_alert_events_are_sorted_and_invalid_types_are_ignored(self) -> None:
        early = datetime(2026, 7, 17, 10, 0, tzinfo=timezone.utc)
        late = datetime(2026, 7, 17, 10, 1, tzinfo=timezone.utc)
        observation = self._observation()
        observation.alert_events = (
            ProviderAlert("evt_late", "ERROR", "Needs attention", late),
            ProviderAlert("evt_invalid", "UNKNOWN", "Ignore", early),
            ProviderAlert("evt_early", "DONE", "Completed", early),
        )

        events = app._collect_alert_events(observation)

        self.assertEqual([event.event_id for event in events], ["evt_early", "evt_late"])

    @staticmethod
    def _alert_store() -> app.BridgeStateStore:
        store = app.BridgeStateStore.__new__(app.BridgeStateStore)
        store._state = default_state()
        store._alert_tracking_initialized = True
        store._seen_alert_event_ids = set()
        store._seen_alert_event_order = deque()
        store._pending_alerts = deque()
        store._published_alert_since = 0.0
        return store

    @staticmethod
    def _observation(
        *,
        status: AgentStatus = AgentStatus.IDLE,
        active_conversations: int = 0,
    ) -> ProviderObservation:
        return ProviderObservation(
            provider_id="codex",
            display_name="Codex",
            online=True,
            status=status,
            project="VibeStick",
            quota_5h_remaining=None,
            quota_7d_remaining=None,
            quota_updated_at="",
            quota_stale=False,
            alert_type="NONE",
            alert_message="",
            alert_event_id="",
            latest_event_timestamp=None,
            active_conversations=active_conversations,
        )


if __name__ == "__main__":
    unittest.main()

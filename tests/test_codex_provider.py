import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch

from vibe_stick.codex import local_observer
from vibe_stick.codex.local_observer import LocalCodexObservation
from vibe_stick.codex.quota import QuotaSnapshot
from vibe_stick.protocol.state import AgentStatus
from vibe_stick.providers.codex import observation_from_local_codex


class CodexProviderTests(unittest.TestCase):
    def _observe_events(self, events: list[dict[str, object]]) -> LocalCodexObservation:
        return self._observe_sessions({"codex-session": events})

    def _observe_sessions(
        self,
        sessions: dict[str, list[dict[str, object]]],
    ) -> LocalCodexObservation:
        paths = [Path(f"/tmp/{name}.jsonl") for name in sessions]
        events_by_path = dict(zip(paths, sessions.values(), strict=True))
        with (
            patch.object(local_observer, "_codex_process_running", return_value=True),
            patch.object(local_observer, "_session_files", return_value=paths),
            patch.object(
                local_observer,
                "_tail_json_events",
                side_effect=events_by_path.__getitem__,
            ),
        ):
            return local_observer.observe_codex(Path("/tmp/VibeStick"))

    @staticmethod
    def _event(
        timestamp: datetime,
        payload_type: str,
        *,
        turn_id: str = "",
    ) -> dict[str, object]:
        payload = {"type": payload_type}
        if turn_id:
            payload["turn_id"] = turn_id
        return {
            "timestamp": timestamp.isoformat(),
            "type": "event_msg",
            "payload": payload,
        }

    @staticmethod
    def _session_meta(
        timestamp: datetime,
        *,
        thread_source: str,
        source: object,
        cwd: str = "",
        session_id: str = "",
    ) -> dict[str, object]:
        payload = {
            "thread_source": thread_source,
            "source": source,
        }
        if cwd:
            payload["cwd"] = cwd
        if session_id:
            payload["id"] = session_id
        return {
            "timestamp": timestamp.isoformat(),
            "type": "session_meta",
            "payload": payload,
        }

    def test_chatgpt_bundled_codex_process_is_detected(self) -> None:
        command = (
            "/Applications/ChatGPT.app/Contents/Resources/codex "
            "-c features.code_mode_host=true app-server --analytics-default-enabled"
        )

        self.assertTrue(local_observer._is_codex_process_command(command))

    def test_chatgpt_codex_helper_without_app_server_is_ignored(self) -> None:
        command = (
            "/Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/"
            "Helpers/Codex (Renderer).app/Contents/MacOS/Codex (Renderer) --type=renderer"
        )

        self.assertFalse(local_observer._is_codex_process_command(command))

    def test_codex_local_observation_maps_to_provider_observation(self) -> None:
        timestamp = datetime(2026, 6, 28, 9, 41, tzinfo=timezone.utc)
        observation = observation_from_local_codex(
            LocalCodexObservation(
                status=AgentStatus.DONE,
                project="VibeStick",
                quota=QuotaSnapshot(66, 96, "09:40", False),
                quota_found=True,
                alert_type="DONE",
                alert_message="Codex task completed",
                alert_timestamp=timestamp,
                latest_event_timestamp=timestamp,
                codex_online=True,
            )
        )

        self.assertEqual(observation.provider_id, "codex")
        self.assertEqual(observation.display_name, "Codex")
        self.assertEqual(observation.status, AgentStatus.DONE)
        self.assertEqual(observation.quota_5h_remaining, 66)
        self.assertEqual(observation.quota_7d_remaining, 96)
        self.assertEqual(observation.alert_type, "DONE")
        self.assertEqual(observation.alert_event_id, f"evt_{timestamp.astimezone().strftime('%Y%m%d_%H%M%S')}_done")
        self.assertEqual(observation.latest_event_timestamp, timestamp)

    def test_missing_codex_quota_maps_to_unknown_bars(self) -> None:
        observation = observation_from_local_codex(
            LocalCodexObservation(
                status=AgentStatus.IDLE,
                project="VibeStick",
                quota=None,
                quota_found=False,
                codex_online=True,
            )
        )

        self.assertIsNone(observation.quota_5h_remaining)
        self.assertIsNone(observation.quota_7d_remaining)
        self.assertEqual(observation.alert_type, "NONE")

    def test_task_complete_reports_done_immediately(self) -> None:
        now = datetime.now(timezone.utc)

        observation = self._observe_events(
            [
                self._event(
                    now - timedelta(seconds=2),
                    "task_started",
                    turn_id="turn-1",
                ),
                self._event(
                    now - timedelta(seconds=1),
                    "task_complete",
                    turn_id="turn-1",
                ),
            ]
        )

        self.assertEqual(observation.status, AgentStatus.DONE)
        self.assertEqual(observation.alert_type, "DONE")
        self.assertIsNotNone(observation.alert_timestamp)
        self.assertTrue(observation.alert_event_id.startswith("evt_codex_"))

    def test_completion_alert_survives_while_another_conversation_runs(self) -> None:
        now = datetime.now(timezone.utc)

        observation = self._observe_sessions(
            {
                "still-running": [
                    self._event(
                        now - timedelta(seconds=3),
                        "task_started",
                        turn_id="turn-running",
                    )
                ],
                "just-completed": [
                    self._event(
                        now - timedelta(seconds=2),
                        "task_started",
                        turn_id="turn-done",
                    ),
                    self._event(
                        now - timedelta(seconds=1),
                        "task_complete",
                        turn_id="turn-done",
                    ),
                ],
            }
        )

        self.assertEqual(observation.status, AgentStatus.RUNNING)
        self.assertEqual(observation.alert_type, "DONE")
        self.assertTrue(observation.latest_session_path.endswith("just-completed.jsonl"))

        provider_observation = observation_from_local_codex(observation)
        self.assertEqual(provider_observation.status, AgentStatus.RUNNING)
        self.assertEqual(provider_observation.alert_type, "DONE")
        self.assertEqual(
            provider_observation.alert_event_id,
            observation.alert_event_id,
        )

    def test_completions_in_different_conversations_have_unique_event_ids(self) -> None:
        now = datetime.now(timezone.utc)

        observation = self._observe_sessions(
            {
                "first": [
                    self._session_meta(
                        now - timedelta(seconds=2),
                        thread_source="user",
                        source="vscode",
                        session_id="thread-first",
                    ),
                    self._event(now, "task_complete", turn_id="turn-1"),
                ],
                "second": [
                    self._session_meta(
                        now - timedelta(seconds=2),
                        thread_source="user",
                        source="vscode",
                        session_id="thread-second",
                    ),
                    self._event(now, "task_complete", turn_id="turn-2"),
                ],
            }
        )

        self.assertEqual(len(observation.alert_events), 2)
        self.assertEqual(len({alert.event_id for alert in observation.alert_events}), 2)

    def test_all_user_conversations_are_observed(self) -> None:
        now = datetime.now(timezone.utc)

        observation = self._observe_sessions(
            {
                "older-with-newer-output": [
                    self._event(
                        now - timedelta(seconds=4),
                        "task_started",
                        turn_id="older-turn",
                    ),
                    self._event(
                        now - timedelta(seconds=1),
                        "task_complete",
                        turn_id="older-turn",
                    ),
                ],
                "current-running": [
                    self._event(
                        now - timedelta(seconds=2),
                        "task_started",
                        turn_id="current-turn",
                    )
                ],
            }
        )

        self.assertEqual(observation.status, AgentStatus.RUNNING)
        self.assertEqual(observation.alert_type, "DONE")
        self.assertTrue(observation.latest_session_path.endswith("older-with-newer-output.jsonl"))

    def test_completion_of_last_active_turn_reports_done_immediately(self) -> None:
        now = datetime.now(timezone.utc)

        observation = self._observe_sessions(
            {
                "first": [
                    self._event(
                        now - timedelta(seconds=4),
                        "task_started",
                        turn_id="turn-1",
                    ),
                    self._event(
                        now - timedelta(seconds=2),
                        "task_complete",
                        turn_id="turn-1",
                    ),
                ],
                "last": [
                    self._event(
                        now - timedelta(seconds=3),
                        "task_started",
                        turn_id="turn-2",
                    ),
                    self._event(
                        now - timedelta(seconds=1),
                        "task_complete",
                        turn_id="turn-2",
                    ),
                ],
            }
        )

        self.assertEqual(observation.status, AgentStatus.DONE)
        self.assertEqual(observation.alert_type, "DONE")

    def test_mismatched_completion_does_not_close_active_turn(self) -> None:
        now = datetime.now(timezone.utc)

        observation = self._observe_events(
            [
                self._event(
                    now - timedelta(seconds=2),
                    "task_started",
                    turn_id="turn-running",
                ),
                self._event(
                    now - timedelta(seconds=1),
                    "task_complete",
                    turn_id="different-turn",
                ),
            ]
        )

        self.assertEqual(observation.status, AgentStatus.RUNNING)
        self.assertEqual(observation.alert_type, "")

    def test_subagent_activity_does_not_suppress_user_completion(self) -> None:
        now = datetime.now(timezone.utc)

        observation = self._observe_sessions(
            {
                "user-task": [
                    self._session_meta(
                        now - timedelta(seconds=4),
                        thread_source="user",
                        source="vscode",
                    ),
                    self._event(
                        now - timedelta(seconds=3),
                        "task_started",
                        turn_id="user-turn",
                    ),
                    self._event(
                        now - timedelta(seconds=2),
                        "task_complete",
                        turn_id="user-turn",
                    ),
                ],
                "guardian": [
                    self._session_meta(
                        now - timedelta(seconds=3),
                        thread_source="subagent",
                        source={"subagent": {"other": "guardian"}},
                    ),
                    self._event(
                        now - timedelta(seconds=1),
                        "task_started",
                        turn_id="guardian-turn",
                    ),
                ],
            }
        )

        self.assertEqual(observation.status, AgentStatus.DONE)
        self.assertEqual(observation.alert_type, "DONE")

    def test_subagent_completion_never_publishes_an_alert(self) -> None:
        now = datetime.now(timezone.utc)

        observation = self._observe_sessions(
            {
                "guardian": [
                    self._session_meta(
                        now - timedelta(seconds=3),
                        thread_source="subagent",
                        source={"subagent": {"other": "guardian"}},
                    ),
                    self._event(
                        now - timedelta(seconds=2),
                        "task_started",
                        turn_id="guardian-turn",
                    ),
                    self._event(
                        now - timedelta(seconds=1),
                        "task_complete",
                        turn_id="guardian-turn",
                    ),
                ]
            }
        )

        self.assertEqual(observation.status, AgentStatus.IDLE)
        self.assertEqual(observation.alert_type, "")

    def test_user_conversations_from_other_projects_are_observed(self) -> None:
        now = datetime.now(timezone.utc)

        observation = self._observe_sessions(
            {
                "vibestick": [
                    self._session_meta(
                        now - timedelta(seconds=4),
                        thread_source="user",
                        source="vscode",
                        cwd="/tmp/VibeStick",
                    ),
                    self._event(
                        now - timedelta(seconds=3),
                        "task_started",
                        turn_id="vibestick-turn",
                    ),
                    self._event(
                        now - timedelta(seconds=2),
                        "task_complete",
                        turn_id="vibestick-turn",
                    ),
                ],
                "other-project": [
                    self._session_meta(
                        now - timedelta(seconds=3),
                        thread_source="user",
                        source="vscode",
                        cwd="/tmp/PACE",
                    ),
                    self._event(
                        now - timedelta(seconds=1),
                        "task_started",
                        turn_id="pace-turn",
                    ),
                ],
            }
        )

        self.assertEqual(observation.status, AgentStatus.RUNNING)
        self.assertEqual(observation.alert_type, "DONE")

    def test_newer_task_activity_clears_older_done_alert(self) -> None:
        now = datetime.now(timezone.utc)

        observation = self._observe_events(
            [
                self._event(now - timedelta(seconds=40), "task_complete"),
                self._event(
                    now - timedelta(seconds=5),
                    "task_started",
                    turn_id="turn-new",
                ),
            ]
        )

        self.assertEqual(observation.status, AgentStatus.RUNNING)
        self.assertEqual(observation.alert_type, "")

    def test_newer_task_activity_clears_old_error_alert(self) -> None:
        now = datetime.now(timezone.utc)

        observation = self._observe_events(
            [
                self._event(now - timedelta(seconds=40), "agent_error"),
                self._event(now - timedelta(seconds=5), "task_started"),
            ]
        )

        self.assertEqual(observation.status, AgentStatus.RUNNING)
        self.assertEqual(observation.alert_type, "")

    def test_current_approval_and_error_alerts_remain_immediate(self) -> None:
        now = datetime.now(timezone.utc)
        cases = (
            ("approval_requested", AgentStatus.APPROVAL, "APPROVAL"),
            ("agent_error", AgentStatus.ERROR, "ERROR"),
        )

        for payload_type, expected_status, expected_alert_type in cases:
            with self.subTest(payload_type=payload_type):
                observation = self._observe_events(
                    [self._event(now - timedelta(seconds=1), payload_type)]
                )

                self.assertEqual(observation.status, expected_status)
                self.assertEqual(observation.alert_type, expected_alert_type)

    def test_model_specific_rate_limit_does_not_replace_main_codex_quota(self) -> None:
        now = datetime.now(timezone.utc)
        payload = {
            "type": "token_count",
            "rate_limits": {
                "limit_id": "codex_bengalfox",
                "primary": {"used_percent": 0, "window_minutes": 10080},
            },
        }

        self.assertIsNone(local_observer._quota_from_payload(payload, now, now))

    def test_main_codex_rate_limit_reports_remaining_percentage(self) -> None:
        now = datetime.now(timezone.utc)
        payload = {
            "type": "token_count",
            "rate_limits": {
                "limit_id": "codex",
                "primary": {"used_percent": 97, "window_minutes": 10080},
            },
        }

        quota = local_observer._quota_from_payload(payload, now, now)

        self.assertIsNotNone(quota)
        self.assertEqual(quota.quota_7d_remaining, 3)


if __name__ == "__main__":
    unittest.main()

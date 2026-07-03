import json
import os
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

from vibe_stick.protocol.state import AgentStatus
from vibe_stick.providers import claude


class ClaudeProviderTests(unittest.TestCase):
    def test_no_process_reports_offline(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            with mock.patch.object(claude, "PROJECTS_DIR", Path(tmp)), mock.patch.object(
                claude, "_claude_process_running", return_value=False
            ):
                observation = claude.observe_claude(Path(tmp))

        self.assertEqual(observation.status, AgentStatus.OFFLINE)
        self.assertFalse(observation.online)

    def test_recent_api_error_reports_error_with_message(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            projects = Path(tmp) / "projects"
            self._write_event(
                projects,
                {
                    "type": "assistant",
                    "timestamp": self._timestamp(minutes_ago=1),
                    "sessionId": "s1",
                    "isApiErrorMessage": True,
                    "apiErrorStatus": 429,
                    "message": "You've hit your limit",
                },
            )
            with mock.patch.object(claude, "PROJECTS_DIR", projects), mock.patch.object(
                claude, "_claude_process_running", return_value=True
            ):
                observation = claude.observe_claude(Path(tmp))

        self.assertEqual(observation.status, AgentStatus.ERROR)
        self.assertEqual(observation.alert_type, "ERROR")
        self.assertIn("limit", observation.alert_message)

    def test_recent_plain_assistant_event_reports_running(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            projects = Path(tmp) / "projects"
            self._write_event(
                projects,
                {
                    "type": "assistant",
                    "timestamp": self._timestamp(minutes_ago=1),
                    "sessionId": "s1",
                    "message": {"id": "msg_1", "content": [{"type": "text", "text": "working"}]},
                },
            )
            with mock.patch.object(claude, "PROJECTS_DIR", projects), mock.patch.object(
                claude, "_claude_process_running", return_value=True
            ):
                observation = claude.observe_claude(Path(tmp))

        self.assertEqual(observation.status, AgentStatus.RUNNING)
        self.assertEqual(observation.alert_type, "NONE")

    def test_completed_assistant_turn_reports_done_once_per_message(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            projects = Path(tmp) / "projects"
            self._write_event(
                projects,
                {
                    "type": "assistant",
                    "timestamp": self._timestamp(minutes_ago=1),
                    "sessionId": "s1",
                    "message": {"id": "msg_done", "stop_reason": "end_turn", "content": []},
                },
            )
            with mock.patch.object(claude, "PROJECTS_DIR", projects), mock.patch.object(
                claude, "_claude_process_running", return_value=True
            ):
                observation = claude.observe_claude(Path(tmp))

        self.assertEqual(observation.status, AgentStatus.DONE)
        self.assertEqual(observation.alert_type, "DONE")
        self.assertEqual(observation.alert_event_id, "evt_claude_done_msg_done")

    def test_tool_use_assistant_reports_running_not_done(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            projects = Path(tmp) / "projects"
            self._write_event(
                projects,
                {
                    "type": "assistant",
                    "timestamp": self._timestamp(minutes_ago=1),
                    "sessionId": "s1",
                    "message": {"id": "msg_tool", "stop_reason": "tool_use", "content": []},
                },
            )
            with mock.patch.object(claude, "PROJECTS_DIR", projects), mock.patch.object(
                claude, "_claude_process_running", return_value=True
            ):
                observation = claude.observe_claude(Path(tmp))

        self.assertEqual(observation.status, AgentStatus.RUNNING)
        self.assertEqual(observation.alert_type, "NONE")

    def test_pending_tool_use_in_default_mode_reports_approval(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            projects = Path(tmp) / "projects"
            self._write_events(
                projects,
                [
                    {
                        "type": "user",
                        "timestamp": self._timestamp(minutes_ago=2),
                        "sessionId": "s1",
                        "permissionMode": "default",
                        "message": "do it",
                    },
                    {
                        "type": "assistant",
                        "timestamp": self._timestamp(minutes_ago=1),
                        "sessionId": "s1",
                        "message": {"id": "msg_tool", "stop_reason": "tool_use", "content": []},
                    },
                ],
            )
            with mock.patch.object(claude, "PROJECTS_DIR", projects), mock.patch.object(
                claude, "_claude_process_running", return_value=True
            ):
                observation = claude.observe_claude(Path(tmp))

        self.assertEqual(observation.status, AgentStatus.APPROVAL)
        self.assertEqual(observation.alert_type, "APPROVAL")
        self.assertEqual(observation.alert_event_id, "evt_claude_approval_msg_tool")

    def test_pending_tool_use_in_accept_edits_mode_is_running(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            projects = Path(tmp) / "projects"
            self._write_events(
                projects,
                [
                    {
                        "type": "user",
                        "timestamp": self._timestamp(minutes_ago=2),
                        "sessionId": "s1",
                        "permissionMode": "acceptEdits",
                        "message": "do it",
                    },
                    {
                        "type": "assistant",
                        "timestamp": self._timestamp(minutes_ago=1),
                        "sessionId": "s1",
                        "message": {"id": "msg_tool", "stop_reason": "tool_use", "content": []},
                    },
                ],
            )
            with mock.patch.object(claude, "PROJECTS_DIR", projects), mock.patch.object(
                claude, "_claude_process_running", return_value=True
            ):
                observation = claude.observe_claude(Path(tmp))

        self.assertEqual(observation.status, AgentStatus.RUNNING)
        self.assertEqual(observation.alert_type, "NONE")

    def test_end_turn_then_newer_activity_reports_running(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            projects = Path(tmp) / "projects"
            self._write_events(
                projects,
                [
                    {
                        "type": "assistant",
                        "timestamp": self._timestamp(minutes_ago=3),
                        "sessionId": "s1",
                        "message": {"id": "msg_done", "stop_reason": "end_turn", "content": []},
                    },
                    {
                        "type": "user",
                        "timestamp": self._timestamp(minutes_ago=1),
                        "sessionId": "s1",
                        "message": "another request",
                    },
                ],
            )
            with mock.patch.object(claude, "PROJECTS_DIR", projects), mock.patch.object(
                claude, "_claude_process_running", return_value=True
            ):
                observation = claude.observe_claude(Path(tmp))

        self.assertEqual(observation.status, AgentStatus.RUNNING)
        self.assertEqual(observation.alert_type, "NONE")

    def test_default_mode_in_other_session_does_not_trigger_approval(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            projects = Path(tmp) / "projects"
            self._write_events(
                projects,
                [
                    {
                        "type": "user",
                        "timestamp": self._timestamp(minutes_ago=3),
                        "sessionId": "sA",
                        "permissionMode": "acceptEdits",
                        "message": "go",
                    },
                    {
                        "type": "user",
                        "timestamp": self._timestamp(minutes_ago=2),
                        "sessionId": "sB",
                        "permissionMode": "default",
                        "message": "other session",
                    },
                    {
                        "type": "assistant",
                        "timestamp": self._timestamp(minutes_ago=1),
                        "sessionId": "sA",
                        "message": {"id": "msg_tool", "stop_reason": "tool_use", "content": []},
                    },
                ],
            )
            with mock.patch.object(claude, "PROJECTS_DIR", projects), mock.patch.object(
                claude, "_claude_process_running", return_value=True
            ):
                observation = claude.observe_claude(Path(tmp))

        self.assertEqual(observation.status, AgentStatus.RUNNING)
        self.assertEqual(observation.alert_type, "NONE")

    def test_stale_activity_reports_idle(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            projects = Path(tmp) / "projects"
            self._write_event(
                projects,
                {
                    "type": "user",
                    "timestamp": self._timestamp(minutes_ago=20),
                    "sessionId": "s1",
                    "message": "hello",
                },
            )
            with mock.patch.object(claude, "PROJECTS_DIR", projects), mock.patch.object(
                claude, "_claude_process_running", return_value=True
            ):
                observation = claude.observe_claude(Path(tmp))

        self.assertEqual(observation.status, AgentStatus.IDLE)

    def _write_event(self, projects: Path, event: dict[str, object]) -> None:
        self._write_events(projects, [event])

    def _write_events(self, projects: Path, events: list[dict[str, object]]) -> None:
        session = projects / "sample.jsonl"
        session.parent.mkdir(parents=True, exist_ok=True)
        session.write_text("".join(json.dumps(event) + "\n" for event in events))
        os.utime(session, None)

    def _timestamp(self, *, minutes_ago: int) -> str:
        return (datetime.now(timezone.utc) - timedelta(minutes=minutes_ago)).isoformat()


if __name__ == "__main__":
    unittest.main()

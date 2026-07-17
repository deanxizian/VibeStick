import json
import os
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

from vibe_stick.protocol.state import AgentStatus
from vibe_stick.providers import _jsonl, claude


class ClaudeProcessDetectionTests(unittest.TestCase):
    def _run_with_ps_output(self, output: str) -> bool:
        completed = mock.Mock(returncode=0, stdout=output)
        _jsonl.clear_process_command_cache()
        with mock.patch.object(_jsonl.subprocess, "run", return_value=completed):
            result = claude._claude_process_running()
        _jsonl.clear_process_command_cache()
        return result

    def test_detects_cli_process_by_bare_executable_name(self) -> None:
        self.assertTrue(self._run_with_ps_output("claude\n"))

    def test_detects_cli_process_by_full_path(self) -> None:
        self.assertTrue(self._run_with_ps_output("/usr/local/bin/claude\n"))

    def test_detects_desktop_app_process(self) -> None:
        self.assertTrue(
            self._run_with_ps_output("/Applications/Claude.app/Contents/MacOS/Claude\n")
        )

    def test_does_not_match_unrelated_claude_named_tools(self) -> None:
        output = (
            "/Users/x/.nvm/versions/node/v24.12.0/bin/node "
            "/Users/x/.claude/plugins/cache/claude-hud/claude-hud/0.0.11/dist/index.js\n"
        )
        self.assertFalse(self._run_with_ps_output(output))

    def test_no_matching_process_returns_false(self) -> None:
        self.assertFalse(self._run_with_ps_output("bash\nzsh\n"))


class ClaudeProviderTests(unittest.TestCase):
    def test_no_process_reports_offline(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            with mock.patch.object(claude, "PROJECTS_DIR", Path(tmp)), mock.patch.object(
                claude, "_claude_process_running", return_value=False
            ):
                observation = claude.observe_claude(Path(tmp))

        self.assertEqual(observation.status, AgentStatus.OFFLINE)

    def test_one_shot_cli_completion_alert_survives_process_exit(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            projects = Path(tmp) / "projects"
            self._write_event(
                projects,
                {
                    "type": "assistant",
                    "timestamp": self._timestamp(minutes_ago=1),
                    "sessionId": "s1",
                    "message": {
                        "id": "msg_done_offline",
                        "stop_reason": "end_turn",
                        "content": [],
                    },
                },
            )
            with mock.patch.object(claude, "PROJECTS_DIR", projects), mock.patch.object(
                claude, "_claude_process_running", return_value=False
            ):
                observation = claude.observe_claude(Path(tmp))

        self.assertEqual(observation.status, AgentStatus.OFFLINE)
        self.assertEqual(observation.alert_type, "DONE")
        self.assertEqual(observation.alert_event_id, "evt_claude_done_msg_done_offline")
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
                    "message": {
                        "id": "msg_tool",
                        "stop_reason": "tool_use",
                        "isFinal": True,
                        "content": [],
                    },
                },
            )
            with mock.patch.object(claude, "PROJECTS_DIR", projects), mock.patch.object(
                claude, "_claude_process_running", return_value=True
            ):
                observation = claude.observe_claude(Path(tmp))

        self.assertEqual(observation.status, AgentStatus.RUNNING)
        self.assertEqual(observation.alert_type, "NONE")

    def test_explicit_approval_request_reports_approval(self) -> None:
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
                        "message": {
                            "id": "msg_tool",
                            "stop_reason": "tool_use",
                            "requiresApproval": True,
                            "content": [],
                        },
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

    def test_default_mode_tool_use_without_explicit_request_is_running(self) -> None:
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
                        "message": {
                            "id": "msg_tool",
                            "stop_reason": "tool_use",
                            "content": [],
                        },
                    },
                ],
            )
            with mock.patch.object(claude, "PROJECTS_DIR", projects), mock.patch.object(
                claude, "_claude_process_running", return_value=True
            ):
                observation = claude.observe_claude(Path(tmp))

        self.assertEqual(observation.status, AgentStatus.RUNNING)
        self.assertEqual(observation.alert_type, "NONE")

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

    def test_completion_alert_survives_while_other_session_runs(self) -> None:
        now = datetime.now(timezone.utc)
        with tempfile.TemporaryDirectory() as tmp:
            projects = Path(tmp) / "projects"
            self._write_session(
                projects,
                "completed.jsonl",
                [
                    {
                        "type": "assistant",
                        "timestamp": (now - timedelta(seconds=2)).isoformat(),
                        "sessionId": "completed",
                        "message": {
                            "id": "msg_completed",
                            "stop_reason": "end_turn",
                            "content": [],
                        },
                    }
                ],
            )
            self._write_session(
                projects,
                "running.jsonl",
                [
                    {
                        "type": "assistant",
                        "timestamp": (now - timedelta(seconds=1)).isoformat(),
                        "sessionId": "running",
                        "message": {"id": "msg_running", "content": []},
                    }
                ],
            )
            with mock.patch.object(claude, "PROJECTS_DIR", projects), mock.patch.object(
                claude, "_claude_process_running", return_value=True
            ):
                observation = claude.observe_claude(Path(tmp))

        self.assertEqual(observation.status, AgentStatus.RUNNING)
        self.assertEqual(observation.alert_type, "DONE")
        self.assertEqual(observation.alert_event_id, "evt_claude_done_msg_completed")
        self.assertEqual(len(observation.alert_events), 1)

    def test_multiple_root_session_completions_emit_distinct_alert_events(self) -> None:
        now = datetime.now(timezone.utc)
        with tempfile.TemporaryDirectory() as tmp:
            projects = Path(tmp) / "projects"
            for index in range(2):
                self._write_session(
                    projects,
                    f"completed-{index}.jsonl",
                    [
                        {
                            "type": "assistant",
                            "timestamp": (now - timedelta(seconds=2 - index)).isoformat(),
                            "sessionId": f"session-{index}",
                            "message": {
                                "id": f"msg_done_{index}",
                                "stop_reason": "end_turn",
                                "content": [],
                            },
                        }
                    ],
                )
            with mock.patch.object(claude, "PROJECTS_DIR", projects), mock.patch.object(
                claude, "_claude_process_running", return_value=True
            ):
                observation = claude.observe_claude(Path(tmp))

        self.assertEqual(observation.status, AgentStatus.DONE)
        self.assertEqual(len(observation.alert_events), 2)
        self.assertEqual(
            {alert.event_id for alert in observation.alert_events},
            {"evt_claude_done_msg_done_0", "evt_claude_done_msg_done_1"},
        )

    def test_subagent_directory_completion_is_ignored(self) -> None:
        now = datetime.now(timezone.utc)
        with tempfile.TemporaryDirectory() as tmp:
            projects = Path(tmp) / "projects"
            self._write_session(
                projects / "root" / "subagents",
                "agent-child.jsonl",
                [
                    {
                        "type": "assistant",
                        "timestamp": now.isoformat(),
                        "sessionId": "child",
                        "message": {
                            "id": "msg_child",
                            "stop_reason": "end_turn",
                            "content": [],
                        },
                    }
                ],
            )
            with mock.patch.object(claude, "PROJECTS_DIR", projects), mock.patch.object(
                claude, "_claude_process_running", return_value=True
            ):
                observation = claude.observe_claude(Path(tmp))

        self.assertEqual(observation.status, AgentStatus.IDLE)
        self.assertEqual(observation.alert_type, "NONE")
        self.assertEqual(observation.alert_events, ())

    def test_sidechain_session_completion_is_ignored(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            projects = Path(tmp) / "projects"
            self._write_event(
                projects,
                {
                    "type": "assistant",
                    "timestamp": self._timestamp(minutes_ago=1),
                    "sessionId": "sidechain",
                    "isSidechain": True,
                    "message": {
                        "id": "msg_sidechain",
                        "stop_reason": "end_turn",
                        "content": [],
                    },
                },
            )
            with mock.patch.object(claude, "PROJECTS_DIR", projects), mock.patch.object(
                claude, "_claude_process_running", return_value=True
            ):
                observation = claude.observe_claude(Path(tmp))

        self.assertEqual(observation.status, AgentStatus.IDLE)
        self.assertEqual(observation.alert_type, "NONE")
        self.assertEqual(observation.alert_events, ())

    def test_unchanged_real_session_uses_cached_summary(self) -> None:
        now = datetime.now(timezone.utc)
        with tempfile.TemporaryDirectory() as tmp:
            projects = Path(tmp) / "projects"
            path = projects / "cached.jsonl"
            events = [
                {
                    "type": "assistant",
                    "timestamp": (now - timedelta(seconds=1)).isoformat(),
                    "sessionId": "cached",
                    "message": {"id": "msg_working", "content": []},
                }
            ]
            self._write_session(projects, path.name, events)
            claude._SESSION_SUMMARY_CACHE.clear()

            with (
                mock.patch.object(claude, "PROJECTS_DIR", projects),
                mock.patch.object(claude, "_claude_process_running", return_value=True),
                mock.patch.object(
                    claude,
                    "tail_json_events",
                    wraps=claude.tail_json_events,
                ) as tail,
            ):
                claude.observe_claude(Path(tmp))
                claude.observe_claude(Path(tmp))
                self.assertEqual(tail.call_count, 1)

                events.append(
                    {
                        "type": "assistant",
                        "timestamp": now.isoformat(),
                        "sessionId": "cached",
                        "message": {
                            "id": "msg_cached_done",
                            "stop_reason": "end_turn",
                            "content": [],
                        },
                    }
                )
                self._write_session(projects, path.name, events)
                observation = claude.observe_claude(Path(tmp))

            claude._SESSION_SUMMARY_CACHE.clear()

        self.assertEqual(tail.call_count, 2)
        self.assertEqual(observation.status, AgentStatus.DONE)

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
        self._write_session(projects, "sample.jsonl", events)

    def _write_session(
        self,
        projects: Path,
        filename: str,
        events: list[dict[str, object]],
    ) -> None:
        session = projects / filename
        session.parent.mkdir(parents=True, exist_ok=True)
        session.write_text("".join(json.dumps(event) + "\n" for event in events))
        os.utime(session, None)

    def _timestamp(self, *, minutes_ago: int) -> str:
        return (datetime.now(timezone.utc) - timedelta(minutes=minutes_ago)).isoformat()


if __name__ == "__main__":
    unittest.main()

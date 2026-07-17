from __future__ import annotations

import os
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

from vibe_stick.protocol.state import AgentStatus
from vibe_stick.providers._jsonl import (
    FileFingerprint,
    FileSummaryCache,
    process_commands,
    session_files,
    tail_json_events,
)
from vibe_stick.providers.base import ProviderAlert, ProviderObservation

CLAUDE_HOME = Path.home() / ".claude"
PROJECTS_DIR = CLAUDE_HOME / "projects"
TAIL_BYTES = 1_500_000
MAX_SESSION_FILES = 40
RUNNING_ACTIVITY_WINDOW = timedelta(minutes=4)
ALERT_ACTIVITY_WINDOW = timedelta(minutes=5)


@dataclass(frozen=True)
class _ClaudeSessionSummary:
    identity: str
    latest_event: tuple[datetime, str, str] | None
    latest_error: tuple[datetime, str, str] | None
    latest_done: tuple[datetime, str, str] | None
    latest_approval: tuple[datetime, str, str] | None


@dataclass(frozen=True)
class _ClaudeFileSummary:
    sessions: tuple[_ClaudeSessionSummary, ...]


@dataclass
class _ClaudeSessionAccumulator:
    identity: str
    latest_event: tuple[datetime, str, str] | None = None
    latest_error: tuple[datetime, str, str] | None = None
    latest_done: tuple[datetime, str, str] | None = None
    latest_approval: tuple[datetime, str, str] | None = None

    def freeze(self) -> _ClaudeSessionSummary:
        return _ClaudeSessionSummary(
            identity=self.identity,
            latest_event=self.latest_event,
            latest_error=self.latest_error,
            latest_done=self.latest_done,
            latest_approval=self.latest_approval,
        )


_SESSION_SUMMARY_CACHE: FileSummaryCache[_ClaudeFileSummary] = FileSummaryCache()


def observe_claude(project_root: Path) -> ProviderObservation:
    now = datetime.now(timezone.utc)
    online = _claude_process_running()
    project = _project_name_from_env_or_root(project_root)
    paths = session_files(
        PROJECTS_DIR,
        max_files=MAX_SESSION_FILES,
        accept=_claude_path_is_root,
    )
    summaries: list[_ClaudeSessionSummary] = []
    for path in paths:
        file_summary = _SESSION_SUMMARY_CACHE.get_or_load(
            path,
            lambda session_path=path: _summarize_file(session_path),
        )
        summaries.extend(file_summary.sessions)
    _SESSION_SUMMARY_CACHE.retain(paths)

    latest_event = _latest_session_value(summaries, "latest_event")
    session_alerts = [
        (summary.identity, alert)
        for summary in summaries
        if (alert := _current_session_alert(summary, now)) is not None
        and (online or alert.alert_type in {"DONE", "ERROR"})
    ]
    session_alerts.sort(
        key=lambda item: item[1].timestamp or datetime.min.replace(tzinfo=timezone.utc)
    )
    alert_session_ids = {identity for identity, _ in session_alerts}
    alert_events = tuple(alert for _, alert in session_alerts)
    latest_alert = alert_events[-1] if alert_events else None
    active_session_exists = any(
        summary.latest_event is not None
        and summary.identity not in alert_session_ids
        and now - summary.latest_event[0] <= RUNNING_ACTIVITY_WINDOW
        for summary in summaries
    )

    status = AgentStatus.IDLE
    alert_type = "NONE"
    alert_message = ""
    alert_event_id = ""
    if not online:
        status = AgentStatus.OFFLINE
    elif latest_alert is not None and latest_alert.alert_type in {"ERROR", "APPROVAL"}:
        status = AgentStatus(latest_alert.alert_type)
    elif active_session_exists:
        status = AgentStatus.RUNNING
    elif latest_alert is not None:
        status = AgentStatus(latest_alert.alert_type)
    elif latest_event and now - latest_event[0] <= RUNNING_ACTIVITY_WINDOW:
        status = AgentStatus.RUNNING

    if latest_alert is not None:
        alert_type = latest_alert.alert_type
        alert_event_id = latest_alert.event_id
        alert_message = latest_alert.message

    return ProviderObservation(
        provider_id="claude",
        display_name="Claude",
        online=online,
        status=status,
        project=project,
        quota_5h_remaining=None,
        quota_7d_remaining=None,
        quota_updated_at="",
        quota_stale=False,
        alert_type=alert_type,
        alert_message=alert_message,
        alert_event_id=alert_event_id,
        latest_event_timestamp=latest_event[0] if latest_event else None,
        alert_events=alert_events,
    )


def _summarize_file(path: Path) -> _ClaudeFileSummary:
    events = list(tail_json_events(path, tail_bytes=TAIL_BYTES))
    sidechain_identities = {
        _event_session_identity(event, path)
        for event in events
        if _event_is_sidechain(event)
    }
    sessions: dict[str, _ClaudeSessionAccumulator] = {}

    for event in events:
        identity = _event_session_identity(event, path)
        if identity in sidechain_identities:
            continue
        timestamp = _parse_timestamp(event.get("timestamp"))
        if timestamp is None:
            continue

        session = sessions.setdefault(identity, _ClaudeSessionAccumulator(identity))
        session_id = str(event.get("sessionId") or identity)
        event_type = str(event.get("type") or "")
        if event_type and (
            session.latest_event is None or timestamp > session.latest_event[0]
        ):
            session.latest_event = (timestamp, event_type, session_id)

        error_message = _error_message(event)
        if error_message is not None and (
            session.latest_error is None or timestamp > session.latest_error[0]
        ):
            session.latest_error = (
                timestamp,
                _stable_event_id(
                    "claude_error", event, timestamp, session_identity=identity
                ),
                error_message,
            )

        if _event_requests_approval(event) and (
            session.latest_approval is None or timestamp > session.latest_approval[0]
        ):
            session.latest_approval = (
                timestamp,
                _stable_event_id(
                    "claude_approval", event, timestamp, session_identity=identity
                ),
                session_id,
            )

        if event_type == "assistant" and _assistant_turn_complete(event) and (
            session.latest_done is None or timestamp > session.latest_done[0]
        ):
            session.latest_done = (
                timestamp,
                _stable_event_id(
                    "claude_done", event, timestamp, session_identity=identity
                ),
                "Claude task completed",
            )

    return _ClaudeFileSummary(
        sessions=tuple(session.freeze() for session in sessions.values())
    )


def _current_session_alert(
    summary: _ClaudeSessionSummary,
    now: datetime,
) -> ProviderAlert | None:
    if summary.latest_event is None:
        return None
    latest_event_at = summary.latest_event[0]
    if (
        summary.latest_error is not None
        and summary.latest_error[0] >= latest_event_at
        and now - summary.latest_error[0] <= ALERT_ACTIVITY_WINDOW
    ):
        timestamp, event_id, message = summary.latest_error
        return ProviderAlert(event_id, "ERROR", message, timestamp)

    if (
        summary.latest_approval is not None
        and summary.latest_approval[0] >= latest_event_at
        and now - summary.latest_approval[0] <= RUNNING_ACTIVITY_WINDOW
    ):
        timestamp, event_id, _ = summary.latest_approval
        return ProviderAlert(
            event_id,
            "APPROVAL",
            "Claude is waiting for approval",
            timestamp,
        )

    if (
        summary.latest_done is not None
        and summary.latest_done[0] >= latest_event_at
        and now - summary.latest_done[0] <= ALERT_ACTIVITY_WINDOW
    ):
        timestamp, event_id, message = summary.latest_done
        return ProviderAlert(event_id, "DONE", message, timestamp)
    return None


def _latest_session_value(
    summaries: list[_ClaudeSessionSummary],
    attribute: str,
) -> tuple[datetime, str, str] | None:
    values = [getattr(summary, attribute) for summary in summaries]
    candidates = [value for value in values if value is not None]
    return max(candidates, key=lambda value: value[0]) if candidates else None


def _claude_path_is_root(path: Path, _fingerprint: FileFingerprint) -> bool:
    return "subagents" not in {part.lower() for part in path.parts}


def _event_session_identity(event: dict[str, Any], path: Path) -> str:
    session_id = event.get("sessionId")
    return session_id if isinstance(session_id, str) and session_id else str(path)


def _event_is_sidechain(event: dict[str, Any]) -> bool:
    if _truthy(event.get("isSidechain")):
        return True
    message = event.get("message")
    return isinstance(message, dict) and _truthy(message.get("isSidechain"))


def _claude_process_running() -> bool:
    for line in process_commands():
        lower = line.strip().lower()
        if not lower:
            continue
        if "claude.app/contents/macos/claude" in lower:
            return True
        executable = lower.split()[0].rsplit("/", 1)[-1]
        if executable == "claude":
            return True
    return False


def _error_message(event: dict[str, Any]) -> str | None:
    if _truthy(event.get("isApiErrorMessage")) or event.get("apiErrorStatus") is not None or event.get("error"):
        return _message_text(event) or "Claude task failed or needs attention"
    message = event.get("message")
    if isinstance(message, dict):
        if _truthy(message.get("isApiErrorMessage")) or message.get("apiErrorStatus") is not None or message.get("error"):
            return _message_text(event) or "Claude task failed or needs attention"
    return None


def _stop_reason(event: dict[str, Any]) -> str:
    message = event.get("message")
    if isinstance(message, dict):
        for key in ("stop_reason", "stopReason"):
            value = message.get(key)
            if isinstance(value, str) and value:
                return value
    return ""


def _assistant_turn_complete(event: dict[str, Any]) -> bool:
    # "Done" means the model ended its turn and is handing control back to the
    # user (stop_reason == "end_turn"). A "tool_use" stop reason means it paused
    # to call a tool mid-task and is NOT done.
    stop_reason = _stop_reason(event)
    if stop_reason:
        return stop_reason == "end_turn"
    message = event.get("message")
    if isinstance(message, dict):
        for key in ("turnComplete", "isComplete", "isFinal"):
            if _truthy(message.get(key)):
                return True
    return _truthy(event.get("turnComplete")) or _truthy(event.get("isComplete")) or _truthy(event.get("isFinal"))


def _event_requests_approval(event: dict[str, Any]) -> bool:
    containers = [event]
    message = event.get("message")
    if isinstance(message, dict):
        containers.append(message)

    for container in containers:
        for key in (
            "requiresApproval",
            "approvalRequired",
            "requiresPermission",
            "permissionRequired",
            "needsApproval",
        ):
            if _truthy(container.get(key)):
                return True
        for key in ("type", "subtype", "event", "status"):
            value = container.get(key)
            if not isinstance(value, str):
                continue
            normalized = value.lower().replace("-", "_")
            if (
                ("approval" in normalized or "permission" in normalized)
                and any(
                    marker in normalized
                    for marker in ("request", "required", "pending", "prompt", "needed")
                )
            ):
                return True
    return False


def _message_text(event: dict[str, Any]) -> str:
    direct = event.get("message")
    if isinstance(direct, str):
        return direct
    if isinstance(direct, dict):
        for key in ("text", "message", "error", "content"):
            value = direct.get(key)
            if isinstance(value, str) and value:
                return value
        content = direct.get("content")
        if isinstance(content, list):
            parts: list[str] = []
            for item in content:
                if isinstance(item, dict) and isinstance(item.get("text"), str):
                    parts.append(item["text"])
            return " ".join(parts)
    for key in ("error", "text"):
        value = event.get(key)
        if isinstance(value, str):
            return value
    return ""


def _stable_event_id(
    prefix: str,
    event: dict[str, Any],
    timestamp: datetime,
    *,
    session_identity: str = "",
) -> str:
    for value in (
        event.get("uuid"),
        event.get("messageUuid"),
        event.get("message_id"),
        _message_dict_value(event, "uuid"),
        _message_dict_value(event, "id"),
    ):
        if isinstance(value, str) and value:
            return f"evt_{prefix}_{value}"
    session_id = event.get("sessionId") or session_identity
    if isinstance(session_id, str) and session_id:
        return f"evt_{prefix}_{session_id}_{int(timestamp.timestamp())}"
    return f"evt_{prefix}_{int(timestamp.timestamp())}"


def _message_dict_value(event: dict[str, Any], key: str) -> object:
    message = event.get("message")
    if isinstance(message, dict):
        return message.get(key)
    return None


def _parse_timestamp(value: object) -> datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def _truthy(value: object) -> bool:
    return value is True or (isinstance(value, str) and value.lower() == "true")


def _project_name_from_env_or_root(project_root: Path) -> str:
    configured = os.environ.get("VIBE_STICK_PROJECT_NAME", "").strip()
    if configured:
        return configured
    return _project_name_from_path(project_root)


def _project_name_from_path(path: Path) -> str:
    root = path.expanduser().resolve()
    if root.name in {"bridge", "firmware", "app", "scripts"} and (root.parent / "README.md").exists():
        root = root.parent
    return root.name or "vibestick"

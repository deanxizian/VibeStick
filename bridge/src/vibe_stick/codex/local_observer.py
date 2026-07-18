from __future__ import annotations

import hashlib
import json
import math
import os
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

from vibe_stick.codex.quota import QuotaSnapshot
from vibe_stick.protocol.state import AgentStatus
from vibe_stick.providers._jsonl import (
    FileFingerprint,
    FileSummaryCache,
    process_commands,
    session_files,
    tail_json_events,
)


CODEX_HOME = Path.home() / ".codex"
SESSIONS_DIR = CODEX_HOME / "sessions"
TAIL_BYTES = 1_500_000
MAX_SESSION_FILES = 40
RUNNING_ACTIVITY_WINDOW = timedelta(minutes=4)
ALERT_ACTIVITY_WINDOW = timedelta(minutes=5)
QUOTA_STALE_AFTER = timedelta(minutes=30)
TURN_TERMINAL_TYPES = {
    "task_complete",
    "turn_aborted",
    "turn_cancelled",
    "task_aborted",
    "task_cancelled",
}


@dataclass
class LocalCodexAlert:
    event_id: str
    alert_type: str
    message: str
    timestamp: datetime


@dataclass
class LocalCodexObservation:
    status: AgentStatus
    project: str
    quota: QuotaSnapshot | None
    quota_found: bool
    alert_type: str = ""
    alert_message: str = ""
    alert_timestamp: datetime | None = None
    alert_event_id: str = ""
    latest_event_type: str = ""
    latest_event_timestamp: datetime | None = None
    latest_session_path: str = ""
    codex_online: bool = False
    alert_events: tuple[LocalCodexAlert, ...] = ()
    active_conversations: int = 0


@dataclass(frozen=True)
class _CodexSessionSummary:
    path: str
    latest_event: tuple[datetime, str, str] | None
    latest_cwd: tuple[datetime, Path] | None
    turn_lifecycle: tuple[datetime, str, str] | None
    latest_task_started: datetime | None
    latest_alert: tuple[datetime, AgentStatus, str, str, str] | None
    latest_quota: tuple[datetime, QuotaSnapshot] | None


_SESSION_SUMMARY_CACHE: FileSummaryCache[_CodexSessionSummary | None] = FileSummaryCache()
_SESSION_CLASSIFICATION_CACHE: FileSummaryCache[bool] = FileSummaryCache(max_entries=4096)


def observe_codex(project_root: Path) -> LocalCodexObservation:
    now = datetime.now(timezone.utc)
    codex_online = _codex_process_running()
    project = _project_name_from_env_or_root(project_root)
    session_paths = _session_files()
    summaries: list[_CodexSessionSummary] = []
    for session_path in session_paths:
        summary = _SESSION_SUMMARY_CACHE.get_or_load(
            session_path,
            lambda path=session_path: _summarize_session(path),
        )
        if summary is not None:
            summaries.append(summary)
    _SESSION_SUMMARY_CACHE.retain(session_paths)

    latest_event_summary = _latest_summary(summaries, "latest_event")
    latest_event = latest_event_summary.latest_event if latest_event_summary else None
    latest_session_path = latest_event_summary.path if latest_event_summary else ""
    latest_cwd_summary = _latest_summary(summaries, "latest_cwd")
    latest_cwd = latest_cwd_summary.latest_cwd if latest_cwd_summary else None
    latest_quota_summary = _latest_summary(summaries, "latest_quota")
    latest_quota = latest_quota_summary.latest_quota if latest_quota_summary else None

    current_alerts = [
        summary.latest_alert
        for summary in summaries
        if summary.latest_alert is not None
        and now - summary.latest_alert[0] <= ALERT_ACTIVITY_WINDOW
        and (
            summary.latest_task_started is None
            or summary.latest_task_started <= summary.latest_alert[0]
        )
    ]
    latest_alert: tuple[datetime, AgentStatus, str, str, str] | None = None
    if current_alerts:
        latest_alert = max(current_alerts, key=lambda alert: alert[0])

    if latest_cwd is not None and not os.environ.get("VIBE_STICK_PROJECT_NAME", "").strip():
        project = _project_name_from_path(latest_cwd[1])

    quota_snapshot = _quota_at_time(latest_quota, now)
    active_conversations = sum(
        summary.turn_lifecycle is not None
        and summary.turn_lifecycle[1] == "task_started"
        and summary.latest_event is not None
        and now - summary.latest_event[0] <= RUNNING_ACTIVITY_WINDOW
        for summary in summaries
    )
    if (
        active_conversations == 0
        and latest_event is not None
        and latest_event[1] not in TURN_TERMINAL_TYPES
        and now - latest_event[0] <= RUNNING_ACTIVITY_WINDOW
    ):
        # Older Codex logs do not always include task lifecycle events. Keep
        # the existing recent-activity fallback, but make it explicit in the
        # count so RUNNING and the number shown on the device cannot disagree.
        active_conversations = 1
    if not codex_online:
        status = AgentStatus.OFFLINE
        active_conversations = 0
    elif (
        latest_alert
        and latest_alert[1] in {AgentStatus.APPROVAL, AgentStatus.ERROR}
    ):
        status = latest_alert[1]
    elif active_conversations > 0:
        status = AgentStatus.RUNNING
    elif latest_alert:
        status = latest_alert[1]
    elif latest_event and latest_event[1] in TURN_TERMINAL_TYPES:
        status = AgentStatus.IDLE
    else:
        status = AgentStatus.IDLE

    observation = LocalCodexObservation(
        status=status,
        project=project,
        quota=quota_snapshot,
        quota_found=quota_snapshot is not None,
        latest_session_path=latest_session_path,
        codex_online=codex_online,
        active_conversations=active_conversations,
        alert_events=tuple(
            LocalCodexAlert(
                event_id=alert[4],
                alert_type=alert[2],
                message=alert[3],
                timestamp=alert[0],
            )
            for alert in sorted(current_alerts, key=lambda item: item[0])
        ),
    )
    if latest_alert:
        observation.alert_timestamp = latest_alert[0]
        observation.alert_type = latest_alert[2]
        observation.alert_message = latest_alert[3]
        observation.alert_event_id = latest_alert[4]
    if latest_event:
        observation.latest_event_timestamp = latest_event[0]
        observation.latest_event_type = latest_event[1]
    return observation


def _summarize_session(path: Path) -> _CodexSessionSummary | None:
    events = _tail_json_events(path)
    if _session_is_subagent(path, events):
        return None

    latest_event: tuple[datetime, str, str] | None = None
    latest_cwd: tuple[datetime, Path] | None = None
    turn_lifecycle: tuple[datetime, str, str] | None = None
    latest_task_started: datetime | None = None
    latest_alert: tuple[datetime, AgentStatus, str, str, str] | None = None
    latest_quota: tuple[datetime, QuotaSnapshot] | None = None

    for event in events:
        timestamp = _parse_timestamp(event.get("timestamp"))
        if timestamp is None:
            continue

        top_type = str(event.get("type") or "")
        payload = event.get("payload")
        payload = payload if isinstance(payload, dict) else {}
        payload_type = str(payload.get("type") or top_type)
        candidate_type = payload_type or top_type

        if top_type == "turn_context":
            cwd = payload.get("cwd")
            if isinstance(cwd, str) and cwd and (
                latest_cwd is None or timestamp > latest_cwd[0]
            ):
                latest_cwd = (timestamp, Path(cwd))

        if candidate_type and (latest_event is None or timestamp > latest_event[0]):
            latest_event = (timestamp, candidate_type, str(payload.get("message") or ""))

        if candidate_type == "task_started" or candidate_type in TURN_TERMINAL_TYPES:
            turn_id = str(payload.get("turn_id") or "")
            completion_matches_active_turn = not (
                candidate_type in TURN_TERMINAL_TYPES
                and turn_lifecycle is not None
                and turn_lifecycle[1] == "task_started"
                and turn_id
                and turn_lifecycle[2]
                and turn_id != turn_lifecycle[2]
            )
            if completion_matches_active_turn and (
                turn_lifecycle is None or timestamp > turn_lifecycle[0]
            ):
                turn_lifecycle = (timestamp, candidate_type, turn_id)
            if candidate_type == "task_started" and (
                latest_task_started is None or timestamp > latest_task_started
            ):
                latest_task_started = timestamp
        else:
            completion_matches_active_turn = True

        quota = _quota_from_payload(payload, timestamp, timestamp)
        if quota is not None and (latest_quota is None or timestamp > latest_quota[0]):
            latest_quota = (timestamp, quota)

        alert = _alert_from_payload(candidate_type, payload)
        if alert is not None and completion_matches_active_turn:
            alert_status, alert_kind, message = alert
            candidate_alert = (
                timestamp,
                alert_status,
                alert_kind,
                message,
                _alert_event_id(
                    path,
                    events,
                    alert_kind=alert_kind,
                    turn_id=str(payload.get("turn_id") or ""),
                    timestamp=timestamp,
                ),
            )
            if latest_alert is None or timestamp > latest_alert[0]:
                latest_alert = candidate_alert

    return _CodexSessionSummary(
        path=str(path),
        latest_event=latest_event,
        latest_cwd=latest_cwd,
        turn_lifecycle=turn_lifecycle,
        latest_task_started=latest_task_started,
        latest_alert=latest_alert,
        latest_quota=latest_quota,
    )


def _latest_summary(
    summaries: list[_CodexSessionSummary],
    attribute: str,
) -> _CodexSessionSummary | None:
    candidates = [summary for summary in summaries if getattr(summary, attribute) is not None]
    if not candidates:
        return None
    return max(candidates, key=lambda summary: getattr(summary, attribute)[0])


def _quota_at_time(
    latest_quota: tuple[datetime, QuotaSnapshot] | None,
    now: datetime,
) -> QuotaSnapshot | None:
    if latest_quota is None:
        return None
    timestamp, quota = latest_quota
    return QuotaSnapshot(
        quota_5h_remaining=quota.quota_5h_remaining,
        quota_7d_remaining=quota.quota_7d_remaining,
        quota_updated_at=quota.quota_updated_at,
        quota_stale=now - timestamp > QUOTA_STALE_AFTER,
    )


def _session_files() -> list[Path]:
    return session_files(
        SESSIONS_DIR,
        max_files=MAX_SESSION_FILES,
        accept=_session_path_is_root,
    )


def _tail_json_events(path: Path) -> list[dict[str, Any]]:
    return list(tail_json_events(path, tail_bytes=TAIL_BYTES))


def _session_path_is_root(path: Path, fingerprint: FileFingerprint) -> bool:
    return _SESSION_CLASSIFICATION_CACHE.get_or_load_with_fingerprint(
        path,
        fingerprint,
        lambda: _subagent_classification(_first_json_event(path)) is not True,
    )


def _session_is_subagent(path: Path, events: list[dict[str, Any]]) -> bool:
    for event in events:
        classification = _subagent_classification(event)
        if classification is not None:
            return classification

    first_event = _first_json_event(path)
    classification = _subagent_classification(first_event)
    return classification is True


def _session_id(path: Path, events: list[dict[str, Any]]) -> str:
    metadata_events = [*events, _first_json_event(path)]
    for event in reversed(metadata_events):
        if not isinstance(event, dict) or event.get("type") != "session_meta":
            continue
        payload = event.get("payload")
        if not isinstance(payload, dict):
            continue
        session_id = payload.get("id") or payload.get("session_id")
        if isinstance(session_id, str) and session_id:
            return session_id
    return ""


def _alert_event_id(
    path: Path,
    events: list[dict[str, Any]],
    *,
    alert_kind: str,
    turn_id: str,
    timestamp: datetime,
) -> str:
    session_identity = _session_id(path, events) or str(path)
    raw_identity = "\x1f".join(
        (session_identity, turn_id, timestamp.isoformat(), alert_kind)
    )
    digest = hashlib.sha256(raw_identity.encode("utf-8")).hexdigest()[:20]
    return f"evt_codex_{digest}_{alert_kind.lower()}"


def _subagent_classification(event: dict[str, Any] | None) -> bool | None:
    if not isinstance(event, dict) or event.get("type") != "session_meta":
        return None
    payload = event.get("payload")
    if not isinstance(payload, dict):
        return None

    thread_source = str(payload.get("thread_source") or "").lower()
    source = payload.get("source")
    return (
        thread_source == "subagent"
        or (isinstance(source, str) and source.lower() == "subagent")
        or (isinstance(source, dict) and "subagent" in source)
    )


def _first_json_event(path: Path) -> dict[str, Any] | None:
    try:
        with path.open("r", encoding="utf-8", errors="ignore") as handle:
            line = handle.readline()
    except OSError:
        return None
    try:
        event = json.loads(line)
    except json.JSONDecodeError:
        return None
    return event if isinstance(event, dict) else None


def _quota_from_payload(
    payload: dict[str, Any],
    timestamp: datetime,
    now: datetime,
) -> QuotaSnapshot | None:
    if payload.get("type") != "token_count":
        return None
    rate_limits = payload.get("rate_limits")
    if not isinstance(rate_limits, dict):
        return None
    limit_id = str(rate_limits.get("limit_id") or "")
    if limit_id and limit_id != "codex":
        return None

    five_hour = None
    seven_day = None
    for window in ("primary", "secondary"):
        data = rate_limits.get(window)
        if not isinstance(data, dict):
            continue
        remaining = _remaining_percent(data.get("used_percent"))
        minutes = data.get("window_minutes")
        if minutes == 300:
            five_hour = remaining
        elif minutes == 10080:
            seven_day = remaining

    if five_hour is None and seven_day is None:
        return None

    return QuotaSnapshot(
        quota_5h_remaining=five_hour,
        quota_7d_remaining=seven_day,
        quota_updated_at=timestamp.astimezone().strftime("%H:%M"),
        quota_stale=now - timestamp > QUOTA_STALE_AFTER,
    )


def _remaining_percent(used_percent: object) -> int | None:
    try:
        used = float(used_percent)
    except (TypeError, ValueError):
        return None
    if not math.isfinite(used):
        return None
    return max(0, min(100, int(round(100.0 - used))))


def _alert_from_payload(
    payload_type: str,
    payload: dict[str, Any],
) -> tuple[AgentStatus, str, str] | None:
    normalized = payload_type.lower()
    if normalized == "task_complete":
        return (AgentStatus.DONE, "DONE", "Codex task completed")
    if "approval" in normalized or "permission" in normalized:
        return (AgentStatus.APPROVAL, "APPROVAL", "Codex is waiting for approval")
    if normalized in {"error", "agent_error"} or normalized.endswith("_error"):
        message = str(payload.get("message") or payload.get("error") or "Codex task failed or needs attention")
        return (AgentStatus.ERROR, "ERROR", message)
    rate_limit_reached = payload.get("rate_limit_reached_type")
    if rate_limit_reached:
        return (AgentStatus.ERROR, "ERROR", "Codex quota limit reached")
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


def _is_newer(value: datetime, other: datetime | None) -> bool:
    return other is None or value > other


def _codex_process_running() -> bool:
    for line in process_commands():
        if _is_codex_process_command(line):
            return True
    return False


def _is_codex_process_command(command: str) -> bool:
    lower = command.lower()
    if "/applications/codex.app/" in lower:
        return True
    if "codex app-server" in lower:
        return True
    return (
        "/applications/chatgpt.app/contents/resources/codex" in lower
        and " app-server" in lower
    )


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

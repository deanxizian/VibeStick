from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Protocol

from vibe_stick.protocol.state import AgentStatus


@dataclass(frozen=True)
class ProviderAlert:
    event_id: str
    alert_type: str
    message: str
    timestamp: datetime | None = None


@dataclass
class ProviderObservation:
    provider_id: str
    display_name: str
    online: bool
    status: AgentStatus
    project: str
    quota_5h_remaining: int | None
    quota_7d_remaining: int | None
    quota_updated_at: str
    quota_stale: bool
    alert_type: str
    alert_message: str
    alert_event_id: str
    latest_event_timestamp: datetime | None = None
    alert_events: tuple[ProviderAlert, ...] = ()
    active_conversations: int = 0


class Provider(Protocol):
    provider_id: str
    display_name: str

    def observe(self) -> ProviderObservation:
        ...

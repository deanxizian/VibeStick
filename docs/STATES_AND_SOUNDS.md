# States And Sounds

VibeStick v0.1.6 plays sounds only for key agent status changes on the home screen. Recording states do not play sounds.

| State | Trigger | Sound |
| --- | --- | --- |
| Completed / 完成 | Any user-started root Codex conversation finishes | 880 Hz 80 ms, 40 ms gap, 1320 Hz 120 ms |
| Error / 报错 | Codex reports `ERROR`, `FAILED`, or `FAILURE` | 240 Hz 100 ms, 60 ms gap, repeated 3 times |
| Waiting for approval / 等待审批 | Codex reports `APPROVAL`, `WAITING_APPROVAL`, `PENDING_APPROVAL`, or `NEEDS_APPROVAL` | 600 Hz 100 ms, 60 ms gap, 800 Hz 100 ms |

## No Sound

These states and events do not play sounds:

- Recording start.
- Recording stop.
- Recording in progress.
- Idle.
- Ready.
- Running.
- Thinking.
- Polling.
- Quota refresh.
- Quota stale.
- Screen refresh.
- `/state` polling.

## Implementation

Sound generation lives in `firmware/sticks3/src/vibe_audio.c`.

The firmware generates 16 kHz mono 16-bit PCM in memory and plays it through the ES8311 / I2S speaker path. No WAV, MP3, TTS, or network service is used for agent alert sounds.

Recording has priority. If recording is active, up to 32 alert sounds are queued and played after the recording overlay closes.

Duplicate prevention lives in `firmware/sticks3/src/main.c`. A sound is played only once for a new `alert.event_id`; if no event id exists, the firmware falls back to status-edge detection.

Codex includes the same `turn_id` in `task_started` and `task_complete`. The Bridge
observes every user-started root conversation on the Mac and publishes a uniquely
identified completion alert as soon as a matching turn finishes. If another
conversation is still active, the home-screen status stays `RUNNING` while the
completion alert still plays once. Background subagent sessions (including approval
guardians) are excluded. A newer turn in the same conversation clears that
conversation's older stale alert.

While Codex is `RUNNING`, a small numeric badge replaces the status dot immediately
before the running label. It counts running user root conversations only; the badge
is hidden for all other states and never includes background subagents.

When several conversations complete between two device polls, the Bridge presents
their unique alerts in order for at least 6 seconds each. The firmware's event-id
deduplication therefore plays one sound per completion instead of collapsing them
into one. Codex quota display accepts the main `limit_id=codex` account bucket and
ignores model-specific buckets, which may independently report 100% remaining.

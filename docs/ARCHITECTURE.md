# VibeStick Architecture

VibeStick has two active runtime parts:

1. StickS3 firmware.
2. Local Mac bridge service.

The StickS3 does not call cloud AI services directly. It polls and posts to the Mac bridge over HTTP on the local network.

```mermaid
flowchart LR
  Codex["Local Codex sessions"] --> Bridge["VibeStick Bridge"]
  Bridge --> HUD["macOS HUD"]
  Stick["StickS3 firmware"] <--> Bridge
  Stick --> Screen["StickS3 screen"]
  Stick --> Speaker["StickS3 speaker"]
  Stick --> Mic["StickS3 microphone"]
  Bridge --> Paste["macOS paste injection"]
  Bridge --> ASR["Optional ASR provider or local command"]
```

## StickS3 Firmware

Firmware lives in `firmware/sticks3/`.

It owns:

- Screen rendering with LVGL.
- Wi-Fi connection.
- Polling `GET /state`.
- Posting button events to `/event`.
- Blue front-button controls: single click sends Return, double click stops the current Codex turn, and long press records push-to-talk audio.
- 16 kHz / 16-bit / mono PCM recording from the StickS3 microphone.
- Uploading PCM to `/recording/audio`.
- Agent status sounds generated as PCM and played through ES8311/I2S speaker output.
- Local battery and USB power display from the StickS3 PMIC.

It does not read account cookies, browser state, API keys, or quota dashboards.

## Mac Bridge

Bridge code lives in `bridge/src/vibe_stick/`.

It owns:

- HTTP API for the StickS3.
- Local Codex status and quota observation from `~/.codex/sessions/**/*.jsonl`.
- Recording session state.
- Optional ASR via local command or Groq API.
- Transcript paste injection into the active macOS app.
- Return-key injection for sending a draft and Codex-targeted Escape injection for stopping the current turn.
- HUD state file updates for recording status.

Bridge state is stored under:

```text
~/Library/Application Support/VibeStick/
```

## Transport

v0.1.5 uses HTTP over Wi-Fi.

BLE is not part of the current mainline transport. USB is used for flashing and serial logs, not for runtime state transport.

HTTP traffic is not encrypted. The shared token authorizes protected requests but can be captured and replayed by an observer on the same network. The supported deployment boundary is a private, trusted LAN with port `8765` blocked from the internet.

## State Flow

1. The StickS3 polls `GET /state` every 2 seconds.
2. The Bridge builds a local `VibeStickState`.
3. The StickS3 parses Codex status, quota fields, and alert fields.
4. The StickS3 renders the home screen.
5. Alert sounds are triggered only on relevant alert state changes, not on every poll.

## Recording Flow

1. User long-presses the blue front button.
2. Firmware starts StickS3 microphone recording and posts `/recording/start`.
3. Firmware shows a full-screen listening overlay.
4. User releases the button.
5. Firmware stops recording, uploads PCM to `/recording/audio`, then posts `/recording/stop`.
6. Bridge writes a local WAV file, runs ASR, and pastes the transcript when successful.
7. Recording start and stop do not play agent alert sounds.

## Status And Quota

Codex status is inferred from local Codex process/session activity and recent session event payloads. Quota is inferred from `token_count` events containing `rate_limits`. This is a local observation strategy, not an official quota API.

Codex observation covers all user-started root conversations visible in local session data. Background subagents are excluded. A completion in any root conversation can publish an alert even while another conversation keeps the aggregate screen status at `RUNNING`.

The StickS3 provider surface is limited to the providers explicitly compiled into the firmware.

## v0.1.5 Limits

- No packaged Mac App.
- No signed firmware release artifact.
- No general device abstraction beyond StickS3.
- No official provider API for quota.
- No BLE runtime transport.

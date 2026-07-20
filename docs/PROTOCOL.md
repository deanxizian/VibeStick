# Protocol

VibeStick v0.1.7 uses HTTP over Wi-Fi between the StickS3 firmware and the local Mac bridge.

Default bridge URL:

```text
http://<mac-ip>:8765
```

## Firmware Headers

Firmware requests include:

```text
X-Vibe-Stick-Firmware-Name: vibestick
X-Vibe-Stick-Firmware-Version: 0.1.7
X-Vibe-Stick-Firmware-Transport: HTTP
X-Vibe-Stick-Firmware-Build-Date: <compile date>
```

Audio upload requests additionally include:

```text
X-Vibe-Stick-Sample-Rate: 16000
X-Vibe-Stick-Channels: 1
X-Vibe-Stick-Bits-Per-Sample: 16
```

When `VIBE_STICK_BRIDGE_TOKEN` is configured on the bridge and firmware, protected requests also include:

```text
X-Vibe-Stick-Token: <shared-token>
```

Protected endpoints are `GET /state`, `/event`, `/quota/refresh`, `/recording/start`, `/recording/audio`, and `/recording/stop`. If the bridge binds outside loopback, such as `0.0.0.0`, `VIBE_STICK_BRIDGE_TOKEN` is required and placeholder tokens are rejected. If the bridge binds to loopback only, missing tokens are allowed for local development. `GET /health` remains public for installation and diagnostics.

This transport is plain HTTP. The token is sent over the LAN and therefore does not protect against passive capture or replay. Run the bridge only on a private, trusted network, keep port `8765` behind the macOS firewall, and never forward it to the internet. A future authenticated-encryption or nonce/HMAC transport is needed before treating hostile networks as supported.

## GET /state

Returns the current bridge state:

```json
{
  "time": "13:01",
  "wifi": true,
  "ble": false,
  "battery": null,
  "active_provider": "codex",
  "provider": {
    "id": "codex",
    "display_name": "Codex",
    "implemented": true,
    "status": "RUNNING",
    "project": "vibestick",
    "active_conversations": 2,
    "quota_5h_remaining": 53,
    "quota_7d_remaining": 93,
    "quota_updated_at": "13:01",
    "quota_stale": false
  },
  "codex": {
    "status": "RUNNING",
    "project": "vibestick",
    "active_conversations": 2,
    "quota_5h_remaining": 53,
    "quota_7d_remaining": 93,
    "quota_updated_at": "13:01",
    "quota_stale": false
  },
  "alert": {
    "event_id": "",
    "type": "NONE",
    "message": ""
  },
  "bridge_name": "vibestick-bridge",
  "bridge_version": "0.1.7"
}
```

`battery` is intentionally `null` from the bridge. The StickS3 displays its local PMIC battery reading.

`active_provider` is fixed to `codex`, and the normalized `provider` block mirrors the `codex` block for older firmware. `active_conversations` is the number of running root conversations, clamped to `0` through `99`; Codex subagent sessions are excluded. The firmware shows this number only while Codex is `RUNNING`. `quota_5h_remaining` and `quota_7d_remaining` are remaining percentages from `0` to `100`; `null` means unknown and the firmware renders `--%`. Current firmware reads the `codex` block directly.

## GET /health

Returns bridge health metadata:

```json
{
  "ok": true,
  "bridge_name": "vibestick-bridge",
  "bridge_version": "0.1.7"
}
```

## POST /event

Receives generic firmware or debug events.

Examples:

```json
{"event":"button_short","source":"sticks3"}
```

After a recording finishes successfully, the Bridge accepts button actions for 30 seconds. During that window, `button_short` injects Return into the focused macOS app, while `button_double` activates the Codex desktop app and sends its stop-turn Escape sequence. Both events are acknowledged but ignored outside the window. Stopping interrupts only the current turn; the task history remains available for a follow-up.

```json
{"event":"button_double","source":"sticks3"}
```

```json
{"event":"test_agent_status","source":"manual_test","status":"DONE","message":"test done"}
```

Manual `DONE`, `ERROR`, and `APPROVAL` statuses produce alert fields for local testing.

## POST /quota/refresh

Requests a Codex quota refresh from local session events. If no valid local snapshot is available, quota fields remain `null` and the firmware shows `--%`.

```json
{
  "refreshed": true,
  "state": {
    "time": "13:01",
    "wifi": true,
    "battery": null
  }
}
```

## POST /recording/start

Starts a recording session:

```json
{
  "event": "button_long_start",
  "source": "sticks3",
  "audio_source": "sticks3_pcm",
  "session_id": "<firmware-generated-id>"
}
```

## POST /recording/audio

Uploads raw little-endian signed PCM for the active session:

```text
POST /recording/audio?session_id=<id>
Content-Type: application/octet-stream
```

The bridge writes a local WAV file under:

```text
~/Library/Application Support/VibeStick/Recordings/
```

The bridge rejects audio uploads larger than `VIBE_STICK_MAX_RECORDING_AUDIO_BYTES`. The default is `2000000` bytes.

## POST /recording/stop

Stops the session and runs transcription:

```json
{"event":"button_long_stop","source":"sticks3","paste":true,"session_id":"<firmware-generated-id>"}
```

When transcription succeeds, the bridge pastes the transcript into the focused macOS app. Recording status does not trigger agent alert sounds.

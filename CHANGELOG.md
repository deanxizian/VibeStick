# Changelog

## v0.1.5

- Notify for completed root conversations across Codex and Claude without subagent noise.
- Cache provider session summaries so the two-second device poll no longer reparses large JSONL logs.
- Make recording ownership thread-safe and idempotent, persist stop recovery, validate uploaded PCM, and bound synchronous ASR/external-hook work to the device timeout.
- Harden the Bridge API with authenticated state reads, bounded request bodies, strict HTTP failures, private atomic persistence, and transcript-safe device responses.
- Fix StickS3 audio task shutdown, HTTP status propagation, and deferred alerts during recording.
- Harden install, diagnostics, permissions, documentation, and CI coverage.

## v0.1.4

Initial public release of VibeStick — a tiny desktop companion for coding agents on M5Stack StickS3.

- Home screen shows Codex and Claude providers with live status (running / idle / done / approval / error / offline) and independent 5-hour / 7-day usage bars.
- Opt-in real Claude Code subscription usage (5H / 7D) via an undocumented Anthropic endpoint using local credentials; disabled by default, and the token / raw responses are never logged.
- Push-to-talk voice input: record on the StickS3, transcribe via any OpenAI-compatible ASR (e.g. SiliconFlow), and paste into the focused app; a local-command / fully-offline path is also supported.
- Alerts (done / approval / error) play from whichever provider raises them, on the StickS3 speaker.
- First-run helpers (`scripts/setup.sh`, `scripts/doctor.sh`), bridge token authentication, and a bilingual README (English + 中文) with clearly-marked physical steps.

Licensed under MIT.

# Changelog

## v0.1.6

- Add a Roxy pet view whose animation follows Codex idle, running, approval, done, and error states; use the StickS3 right-side button to switch between Roxy and the dashboard.
- Limit blue-button single-click send and double-click pause actions to the 30 seconds after a successful recording, enforced independently by both firmware and Bridge.
- Keep device state labels in Chinese and remove the Roxy title and button-hint labels for a cleaner pet screen.
- Increase the LVGL task stack to prevent display flicker and repeated firmware resets after adding the animated view.
- Bundle the updated Bridge, firmware, and generated Roxy assets in the universal macOS Setup App.

## v0.1.5

- Add a three-step native macOS installer that prepares Python and ESP-IDF, configures Wi-Fi and ASR, flashes StickS3, installs Bridge/HUD LaunchAgents, and verifies the device end to end.
- Make the device and Bridge Codex-only, remove the unused secondary-provider integration, and simplify the bilingual documentation with Chinese as the default README.
- Show the active Codex conversation count, Wi-Fi state, battery level, and quota more reliably on StickS3.
- Support voice input plus blue-button send and pause controls from the device.
- Notify for completed root Codex conversations without subagent noise.
- Cache Codex session summaries so the two-second device poll no longer reparses large JSONL logs.
- Make recording ownership thread-safe and idempotent, persist stop recovery, validate uploaded PCM, and bound synchronous ASR/external-hook work to the device timeout.
- Harden the Bridge API with authenticated state reads, bounded request bodies, strict HTTP failures, private atomic persistence, and transcript-safe device responses.
- Fix StickS3 audio task shutdown, HTTP status propagation, and deferred alerts during recording.
- Harden install, diagnostics, permissions, documentation, and CI coverage.

## v0.1.4

Initial public release of VibeStick — a tiny desktop companion for coding agents on M5Stack StickS3.

- Home screen shows Codex with live status (running / idle / done / approval / error / offline) and 5-hour / 7-day usage bars.
- Push-to-talk voice input: record on the StickS3, transcribe via any OpenAI-compatible ASR (e.g. SiliconFlow), and paste into the focused app; a local-command / fully-offline path is also supported.
- Codex alerts (done / approval / error) play on the StickS3 speaker.
- First-run helpers (`scripts/setup.sh`, `scripts/doctor.sh`), bridge token authentication, and a bilingual README (English + 中文) with clearly-marked physical steps.

Licensed under MIT.

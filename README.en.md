# VibeStick

[中文](README.md)

![VibeStick voice-input flow showing StickS3 recording states and the Mac HUD](assets/brand/voice-input-preview.png)

VibeStick turns an M5Stack StickS3 into a Codex desktop companion with task status, active-conversation count, 5H/7D usage, alerts, and speech transcription into your Mac.

VibeStick targets M5Stack StickS3 hardware and is not an official M5Stack project.

## Quick install

The macOS installer handles Python, ESP-IDF, serial detection, firmware, and LaunchAgents automatically.

You need:

- macOS 14 or newer.
- An M5Stack StickS3 and a USB-C data cable.
- A 2.4 GHz Wi-Fi name and password.
- An optional ASR API key. [SiliconFlow](https://cloud.siliconflow.cn) is recommended; other OpenAI-compatible services are supported.

The recommended route is the [VibeStickSetup v0.1.6 universal macOS installer](https://github.com/deanxizian/VibeStick/releases/download/v0.1.6/VibeStickSetup-v0.1.6-macos-universal.zip). It supports both Apple Silicon and Intel. Unzip it and open the app. The installer is signed with hardened runtime but is not Apple-notarized yet; if macOS blocks the first launch, right-click the app and choose Open.

You can also build it from source:

```sh
git clone https://github.com/deanxizian/VibeStick.git
cd VibeStick
./script/build_and_run.sh
```

The installer opens automatically and remains at `dist/VibeStickSetup.app`. You can open it directly next time or move it to Applications. Building from source requires Xcode Command Line Tools; the app prepares the remaining runtime automatically.

Setup has three steps:

1. Enter Wi-Fi details and optionally configure and test an ASR API.
2. Connect the StickS3 and follow the prompt to enter install mode.
3. Confirm installation; the app prepares components, flashes firmware, installs Mac services, and verifies connectivity.

The first installation downloads about 1 GB of ESP-IDF components. Keep the Mac online and the USB cable connected during installation.

## Controls

- Hold the front blue button to speak; release it to transcribe and paste.
- For 30 seconds after a successful recording, single-click the blue button to send the current draft.
- For 30 seconds after a successful recording, double-click the blue button to pause the current Codex task.
- Single-click the large right-side button to switch between the Codex dashboard and the Roxy pet view. Roxy's animation follows Codex status.
- Reopen the installer to change Wi-Fi or ASR settings, or to reflash the device.

Bridge and HUD start automatically at login. The Mac and StickS3 must be on the same LAN.

## Troubleshooting

- **Device not detected**: use a USB-C data cable, reconnect it, and follow the install-mode prompt.
- **Wi-Fi does not connect**: StickS3 supports 2.4 GHz Wi-Fi only.
- **ASR API test fails**: check the API URL, key, model, and network.
- **Transcription works but paste does not**: grant Microphone and Accessibility access in System Settings → Privacy & Security.
- **Installation was interrupted**: keep the cable connected and run the installer again.

## Uninstall Mac services

```sh
./scripts/uninstall.sh
```

Add `--purge` to also remove configuration, logs, and runtime data from `~/Library/Application Support/VibeStick/`.

## Developer documentation

- [Build, test, and package the macOS installer](app/macos/README.md)
- [Hardware and firmware](docs/HARDWARE.md)
- [Architecture](docs/ARCHITECTURE.md) and [protocol](docs/PROTOCOL.md)
- [Environment-variable reference](.env.example)
- [Contributing](CONTRIBUTING.md) and [security reporting](SECURITY.md)

Never commit real API keys, Wi-Fi passwords, local tokens, recordings, or logs.

## Current limits

- M5Stack StickS3 and macOS 14 or newer only.
- The installer is not yet distributed as a notarized DMG.
- StickS3 uses plain HTTP to reach Bridge. Use it only on a trusted LAN and do not expose port `8765` to the internet.
- Codex usage is inferred from local session data, not an official quota API.
- Audio leaves the Mac when cloud transcription is enabled.

## License

VibeStick is released under the [MIT License](LICENSE).

Roxy is a Codex custom pet created for this project. The repository and installer contain only the generated, compressed StickS3 firmware assets, not the original local Codex atlas.

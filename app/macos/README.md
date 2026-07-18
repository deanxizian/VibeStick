# VibeStick macOS Developer Notes

This document covers development and delivery details for the macOS apps. For normal installation, see the root [README](../../README.md).

This directory contains two separate macOS components:

- `VibeStickSetup` is the native SwiftUI setup app. Its three-step wizard collects Wi‑Fi and optional voice-input settings, finds the StickS3 automatically, then prepares the toolchain, builds and flashes firmware, explicitly starts the device after flashing, installs the Bridge, and verifies the result. Advanced fields, diagnostics, and technical logs stay out of the main path.
- `VibeStickHUD` is the small AppKit recording-status overlay installed with the Bridge LaunchAgent.

## Run the setup app

VibeStickSetup is a SwiftPM app that requires macOS 14 or newer:

```sh
./script/build_and_run.sh
```

The script builds `app/macos/Package.swift`, embeds a clean VibeStick project template, and stages the app at `dist/VibeStickSetup.app`. It prefers a Developer ID Application identity, then Apple Development, and falls back to an ad-hoc signature when neither exists. Other supported modes are `--debug`, `--logs`, `--telemetry`, and `--verify`.

For a release artifact, use `./script/build_and_run.sh --package`. It creates a hardened-runtime, universal (`arm64` + `x86_64`) release build without opening the app and verifies the resulting bundle. A Developer ID Application certificate and notarization credentials are still required before it can be described as a trusted public macOS distribution.

Run its tests with:

```sh
swift test --package-path app/macos
```

## Current delivery boundary

This is a developer-preview installer, but the built `.app` is self-contained: it embeds only the audited firmware, Bridge, HUD, and installer sources required for deployment. On first launch those signed resources are copied to `~/Library/Application Support/VibeStick/InstallerProject`; updates replace that workspace while preserving its `.env` and firmware secrets. The app never scans the bundle's parent directories, so it can be moved away from the checkout and does not require Documents-folder access. If Python 3.11+ is unavailable, it downloads a pinned, checksum-verified Python 3.12 runtime. A first-time firmware build also downloads ESP-IDF and tools (about 1 GB). Xcode Command Line Tools are still required; the app opens Apple's system installer and rechecks automatically when they are missing.

A public installer should instead ship a notarized app, signed privileged/helper components where required, a versioned and signed firmware manifest, precompiled universal firmware, and a small per-device NVS configuration image. That removes the source checkout, Git, Xcode Command Line Tools, and the full ESP-IDF download from the normal user path.

The app never writes secrets to UserDefaults. The current VibeStick runtime still requires Wi‑Fi credentials in the firmware header and ASR credentials in `.env`; those files are written atomically with mode `0600` and mirrored to a versioned macOS login-Keychain namespace for form reuse. Startup Keychain reads are explicitly non-interactive, so stale entries from an older development signature cannot block launch or show repeated password dialogs. The Data Protection backend remains reserved for a correctly entitled release build. Technical logs are bounded and redact all managed secrets, inherited proxy credentials, and terminal control characters. Only a non-secret interrupted-flash recovery flag is kept in UserDefaults.

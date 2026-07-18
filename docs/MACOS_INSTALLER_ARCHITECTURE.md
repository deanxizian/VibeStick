# macOS Installer Architecture

## Product goal

VibeStick Setup should take a new StickS3 from USB connection to a verified, working VibeStick without asking the user to edit source files or use Terminal.

## Developer preview

The current SwiftUI app embeds a minimal clean project template and installs it into a stable,
writable `~/Library/Application Support/VibeStick/InstallerProject` workspace. It never scans the
app bundle's parent checkout, and template updates preserve the workspace's `.env` and firmware
secrets. Its normal UI is a single three-step
wizard—network and optional voice input, device connection, then automatic installation. Serial
metadata, model endpoints, diagnostics, and raw logs are available only as advanced or technical
details.

Under that simple flow it:

1. Validate and atomically save Wi‑Fi, Bridge, and ASR configuration, then verify the API key and model with a one-second silent transcription request.
2. Keep reusable secrets in a versioned macOS login-Keychain namespace while writing the runtime files required by the existing firmware and Bridge. Startup reads disallow authentication UI, and local packaging prefers an available Apple Development identity so rebuilds keep a stable code-signing identity. A release may opt into the Data Protection backend with the proper entitlement.
3. Discover serial devices and stable USB identity through IOKit.
4. Install a pinned, checksum-verified user-local Python 3.12 runtime and ESP-IDF 5.5.1 when needed; if Apple Command Line Tools are absent, open the macOS system installer and keep checking until they are available.
5. Build firmware, install the Bridge, re-check the selected USB identity, flash that StickS3, explicitly start it after the USB flashing reset, and require a fresh authenticated heartbeat carrying this deployment's nonce before diagnostics pass.
6. Stream bounded, redacted logs, allow cancellation of the whole child process group, and retain a non-secret recovery journal if flashing is interrupted.

The app uses native SwiftUI with separate Core and Platform targets so validation, redaction, parsing, and repository writes can be tested without launching the UI.

## Public installer target

The embedded-source path removes the checkout dependency but is still too large for polished public distribution. The release design should use:

- a Developer ID signed and notarized `.app`/DMG;
- an embedded, signed manifest describing hardware, flash offsets, firmware version, hashes, and minimum installer version;
- precompiled StickS3 bootloader, partition table, application, and other fixed images;
- a generated NVS image for Wi‑Fi host/token values, so user configuration does not require recompiling firmware;
- a minimal signed flashing helper with fixed operations, strict device identity checks, process-group cancellation, and no arbitrary script execution;
- post-flash verification tied to a fresh device heartbeat and the expected firmware build;
- resumable downloads and explicit recovery instructions if USB is disconnected during flash.

With that design, an end user needs only the app, a USB-C data cable, Wi‑Fi credentials, and an optional ASR API key. Git, a source checkout, Xcode tools, and the roughly 1 GB ESP-IDF install disappear from the normal path.

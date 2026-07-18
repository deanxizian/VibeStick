#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="VibeStickSetup"
BUNDLE_ID="com.vibestick.setup"
MIN_SYSTEM_VERSION="14.0"
APP_VERSION="${VIBE_STICK_APP_VERSION:-0.1.5}"
APP_BUILD_VERSION="${VIBE_STICK_APP_BUILD_VERSION:-1}"

if [[ ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "VIBE_STICK_APP_VERSION must use semantic version format, for example 0.1.5." >&2
  exit 2
fi
if [[ ! "$APP_BUILD_VERSION" =~ ^[1-9][0-9]*$ ]]; then
  echo "VIBE_STICK_APP_BUILD_VERSION must be a positive integer." >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$ROOT_DIR/app/macos"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
PROJECT_TEMPLATE="$APP_RESOURCES/VibeStickProject"

if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  pkill -TERM -x "$APP_NAME" >/dev/null 2>&1 || true
  for _ in {1..100}; do
    if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done
  if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    echo "VibeStick Setup is still shutting down; wait for its active operation to cancel safely." >&2
    exit 1
  fi
fi

if [[ "$MODE" == "--package" || "$MODE" == "package" ]]; then
  ARM64_TRIPLE="arm64-apple-macosx${MIN_SYSTEM_VERSION}"
  X86_64_TRIPLE="x86_64-apple-macosx${MIN_SYSTEM_VERSION}"
  swift build --package-path "$PACKAGE_DIR" --configuration release --triple "$ARM64_TRIPLE"
  swift build --package-path "$PACKAGE_DIR" --configuration release --triple "$X86_64_TRIPLE"
  ARM64_BUILD_DIR="$(swift build --package-path "$PACKAGE_DIR" --configuration release --triple "$ARM64_TRIPLE" --show-bin-path)"
  X86_64_BUILD_DIR="$(swift build --package-path "$PACKAGE_DIR" --configuration release --triple "$X86_64_TRIPLE" --show-bin-path)"
else
  swift build --package-path "$PACKAGE_DIR"
  BUILD_DIR="$(swift build --package-path "$PACKAGE_DIR" --show-bin-path)"
  BUILD_BINARY="$BUILD_DIR/$APP_NAME"
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$PROJECT_TEMPLATE"
if [[ "$MODE" == "--package" || "$MODE" == "package" ]]; then
  /usr/bin/lipo -create \
    "$ARM64_BUILD_DIR/$APP_NAME" \
    "$X86_64_BUILD_DIR/$APP_NAME" \
    -output "$APP_BINARY"
else
  cp "$BUILD_BINARY" "$APP_BINARY"
fi
chmod +x "$APP_BINARY"

# Bundle a clean, writable-on-first-run project template. Never copy the
# checkout's .env, firmware secrets, build products, or downloaded components.
cp "$ROOT_DIR/.env.example" "$PROJECT_TEMPLATE/.env.example"
mkdir -p \
  "$PROJECT_TEMPLATE/app/macos" \
  "$PROJECT_TEMPLATE/bridge" \
  "$PROJECT_TEMPLATE/firmware/sticks3" \
  "$PROJECT_TEMPLATE/scripts"
/usr/bin/rsync -a --exclude '__pycache__/' \
  "$ROOT_DIR/bridge/src" "$PROJECT_TEMPLATE/bridge/"
/usr/bin/rsync -a --exclude '__pycache__/' \
  "$ROOT_DIR/bridge/tools" "$PROJECT_TEMPLATE/bridge/"
cp "$ROOT_DIR/bridge/pyproject.toml" "$PROJECT_TEMPLATE/bridge/pyproject.toml"
/usr/bin/rsync -a --exclude 'vibe_stick_secrets.h' \
  "$ROOT_DIR/firmware/sticks3/include" "$PROJECT_TEMPLATE/firmware/sticks3/"
/usr/bin/rsync -a \
  "$ROOT_DIR/firmware/sticks3/src" \
  "$ROOT_DIR/firmware/sticks3/generated" \
  "$PROJECT_TEMPLATE/firmware/sticks3/"
cp \
  "$ROOT_DIR/firmware/sticks3/CMakeLists.txt" \
  "$ROOT_DIR/firmware/sticks3/sdkconfig.defaults" \
  "$ROOT_DIR/firmware/sticks3/dependencies.lock" \
  "$PROJECT_TEMPLATE/firmware/sticks3/"
/usr/bin/rsync -a --include '*.sh' --exclude '*' \
  "$ROOT_DIR/scripts/" "$PROJECT_TEMPLATE/scripts/"
/usr/bin/rsync -a \
  "$ROOT_DIR/app/macos/VibeStickHUD" "$PROJECT_TEMPLATE/app/macos/"

PROJECT_TEMPLATE_VERSION="$(
  cd "$PROJECT_TEMPLATE"
  find . -type f -print \
    | LC_ALL=C sort \
    | while IFS= read -r file; do /usr/bin/shasum -a 256 "$file"; done \
    | /usr/bin/shasum -a 256 \
    | /usr/bin/awk '{ print $1 }'
)"
printf '%s\n' "$PROJECT_TEMPLATE_VERSION" > "$PROJECT_TEMPLATE/.vibestick-template-version"

for required in \
  .env.example \
  scripts/install.sh \
  scripts/install-esp-idf.sh \
  scripts/install-python-runtime.sh \
  scripts/run-idf.sh \
  scripts/probe-rom-mode.sh \
  scripts/start-device.sh \
  scripts/wait-for-device.sh \
  scripts/doctor.sh \
  bridge/src/vibe_stick/__init__.py \
  bridge/tools/vibe_stick_mic_recorder.swift \
  app/macos/VibeStickHUD/main.swift \
  firmware/sticks3/CMakeLists.txt \
  firmware/sticks3/include/vibe_stick_secrets.example.h; do
  if [[ ! -f "$PROJECT_TEMPLATE/$required" ]]; then
    echo "Missing bundled project resource: $required" >&2
    exit 1
  fi
done
if [[ -e "$PROJECT_TEMPLATE/.env" \
   || -e "$PROJECT_TEMPLATE/firmware/sticks3/include/vibe_stick_secrets.h" ]]; then
  echo "Refusing to package local VibeStick secrets." >&2
  exit 1
fi

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh_CN</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>VibeStick 安装器</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD_VERSION</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.developer-tools</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
  </dict>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

/usr/bin/plutil -lint "$INFO_PLIST" >/dev/null
SIGNING_IDENTITY="${VIBE_STICK_SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(
    /usr/bin/security find-identity -v -p codesigning 2>/dev/null \
      | /usr/bin/awk '/Developer ID Application:/ { print $2; exit }'
  )"
fi
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(
    /usr/bin/security find-identity -v -p codesigning 2>/dev/null \
      | /usr/bin/awk '/Apple Development:/ { print $2; exit }'
  )"
fi
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="-"
fi
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  /usr/bin/codesign --force --options runtime --sign - "$APP_BUNDLE" >/dev/null
else
  /usr/bin/codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP_BUNDLE" >/dev/null
fi

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    /usr/bin/codesign --verify --strict "$APP_BUNDLE"
    ;;
  --package|package)
    /usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"
    /usr/bin/file "$APP_BINARY"
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--package]" >&2
    exit 2
    ;;
esac

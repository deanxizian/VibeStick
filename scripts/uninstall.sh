#!/usr/bin/env sh
set -eu
umask 077

CONFIG_DIR="$HOME/Library/Application Support/VibeStick"
PLIST_PATH="$HOME/Library/LaunchAgents/com.vibestick.bridge.plist"
HUD_PLIST_PATH="$HOME/Library/LaunchAgents/com.vibestick.hud.plist"
PURGE=0

case "${1:-}" in
  "")
    ;;
  --purge)
    PURGE=1
    ;;
  -h|--help)
    printf '%s\n' "Usage: scripts/uninstall.sh [--purge]"
    printf '%s\n' "Without --purge, local config, logs, runtime, and recordings are retained."
    exit 0
    ;;
  *)
    printf '%s\n' "Unknown option: $1" >&2
    printf '%s\n' "Usage: scripts/uninstall.sh [--purge]" >&2
    exit 64
    ;;
esac
if [ "$#" -gt 1 ]; then
  printf '%s\n' "Usage: scripts/uninstall.sh [--purge]" >&2
  exit 64
fi

printf '%s\n' "VibeStick uninstall helper"
launchctl bootout "gui/$(id -u)" "$PLIST_PATH" >/dev/null 2>&1 || true
launchctl bootout "gui/$(id -u)" "$HUD_PLIST_PATH" >/dev/null 2>&1 || true
rm -f "$PLIST_PATH"
rm -f "$HUD_PLIST_PATH"
printf '%s\n' "LaunchAgent removed:"
printf '%s\n' "$PLIST_PATH"
printf '%s\n' "$HUD_PLIST_PATH"
if [ "$PURGE" -eq 1 ]; then
  rm -rf "$CONFIG_DIR"
  printf '%s\n' "Purged installed config, runtime, logs, and recordings:"
  printf '%s\n' "$CONFIG_DIR"
  printf '%s\n' "Repository .env and firmware secrets were not removed."
else
  printf '%s\n' "Retained installed config, runtime, logs, and recordings:"
  printf '%s\n' "$CONFIG_DIR"
  printf '%s\n' "Run scripts/uninstall.sh --purge to remove that installed data."
fi

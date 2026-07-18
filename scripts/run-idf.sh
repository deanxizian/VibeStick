#!/usr/bin/env sh
set -eu

IDF_EXPORT=""
if [ "${1:-}" = "--export" ]; then
  [ "$#" -ge 3 ] || {
    printf '%s\n' "Usage: scripts/run-idf.sh [--export /path/to/export.sh] <idf.py arguments...>" >&2
    exit 2
  }
  IDF_EXPORT="$2"
  shift 2
elif [ -n "${IDF_PATH:-}" ] && [ -f "$IDF_PATH/export.sh" ]; then
  IDF_EXPORT="$IDF_PATH/export.sh"
elif [ -f "$HOME/esp/esp-idf/export.sh" ]; then
  IDF_EXPORT="$HOME/esp/esp-idf/export.sh"
fi

if [ -z "$IDF_EXPORT" ] || [ ! -f "$IDF_EXPORT" ] || [ -L "$IDF_EXPORT" ]; then
  printf '%s\n' "ESP-IDF export.sh was not found or is unsafe." >&2
  exit 1
fi

case "$IDF_EXPORT" in
  /*) ;;
  *)
    printf '%s\n' "ESP-IDF export path must be absolute." >&2
    exit 1
    ;;
esac

IDF_ROOT="$(CDPATH= cd -- "$(dirname -- "$IDF_EXPORT")" && pwd)"
IDF_VERSION="$(awk '
  /set\(IDF_VERSION_MAJOR / { major = $2; gsub(/\)/, "", major) }
  /set\(IDF_VERSION_MINOR / { minor = $2; gsub(/\)/, "", minor) }
  /set\(IDF_VERSION_PATCH / { patch = $2; gsub(/\)/, "", patch) }
  END { if (major != "" && minor != "" && patch != "") print major "." minor "." patch }
' "$IDF_ROOT/tools/cmake/version.cmake" 2>/dev/null || true)"
case "$IDF_VERSION" in
  5.5.*) ;;
  *)
    printf '%s\n' "VibeStick requires ESP-IDF 5.5.x; found ${IDF_VERSION:-an unknown version}." >&2
    exit 1
    ;;
esac

. "$IDF_EXPORT" >/dev/null
exec idf.py "$@"

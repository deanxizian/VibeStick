#!/usr/bin/env sh
set -eu
umask 077

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
ENV_PATH="$ROOT_DIR/.env"

env_value() {
  key="$1"
  file="$2"
  [ -f "$file" ] || return 0
  awk -F= -v key="$key" '
    /^[[:space:]]*#/ { next }
    {
      k = $1
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
      if (k == key) {
        sub(/^[^=]*=/, "")
        gsub(/^[[:space:]]+|[[:space:]]+$/, "")
        if ((substr($0, 1, 1) == "\"" && substr($0, length($0), 1) == "\"") ||
            (substr($0, 1, 1) == "\047" && substr($0, length($0), 1) == "\047")) {
          $0 = substr($0, 2, length($0) - 2)
        }
        print
        exit
      }
    }
  ' "$file"
}

validate_unique_env_keys() {
  file="$1"
  [ -f "$file" ] || return 0
  awk -F= '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    {
      key = $1
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
      if (key != "" && ++seen[key] > 1) {
        printf "Duplicate .env key: %s\n", key > "/dev/stderr"
        bad = 1
      }
    }
    END { exit(bad ? 1 : 0) }
  ' "$file"
}

is_valid_token() {
  printf '%s\n' "${1:-}" | awk '
    length($0) >= 32 && length($0) <= 256 && $0 ~ /^[[:alnum:]_.~-]+$/ { ok = 1 }
    END { exit(ok ? 0 : 1) }
  '
}

validate_unique_env_keys "$ENV_PATH"
bridge_token="$(env_value VIBE_STICK_BRIDGE_TOKEN "$ENV_PATH")"
case "$bridge_token" in
  ""|change-this-shared-token|paste-generated-token-here|changeme|change-me|your-token)
    printf '%s\n' "VIBE_STICK_BRIDGE_TOKEN is required because dev.sh exposes the bridge on 0.0.0.0." >&2
    printf '%s\n' "Run scripts/setup.sh to generate one." >&2
    exit 1
    ;;
esac
if ! is_valid_token "$bridge_token"; then
  printf '%s\n' "VIBE_STICK_BRIDGE_TOKEN must be 32-256 URL-safe characters." >&2
  exit 1
fi

configured_python="$(env_value VIBE_STICK_PYTHON "$ENV_PATH")"
PYTHON_BIN="${configured_python:-python3}"
if ! resolved_python="$(command -v "$PYTHON_BIN" 2>/dev/null)" || [ -z "$resolved_python" ]; then
  printf '%s\n' "Configured Python is not installed or executable: $PYTHON_BIN" >&2
  exit 1
fi
PYTHON_BIN="$resolved_python"
if ! "$PYTHON_BIN" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)' >/dev/null 2>&1; then
  printf '%s\n' "Python >= 3.11 is required; set VIBE_STICK_PYTHON in .env." >&2
  exit 1
fi

exec "$PYTHON_BIN" - "$ENV_PATH" "$ROOT_DIR/bridge/src" <<'PY'
import os
from pathlib import Path
import re
import shlex
import sys

env_path = Path(sys.argv[1])
bridge_src = sys.argv[2]
env = os.environ.copy()
allowed_key = re.compile(r"[A-Za-z_][A-Za-z0-9_]*\Z")
seen_keys: set[str] = set()

try:
    lines = env_path.read_text(encoding="utf-8").splitlines()
except OSError as exc:
    raise SystemExit(f"Could not read VibeStick config: {exc}")

for line_number, source_line in enumerate(lines, 1):
    line = source_line.strip()
    if not line or line.startswith("#"):
        continue
    if "=" not in line:
        raise SystemExit(f"Invalid .env line {line_number}: expected KEY=VALUE")
    key, raw_value = line.split("=", 1)
    key = key.strip()
    raw_value = raw_value.strip()
    if not allowed_key.fullmatch(key):
        raise SystemExit(f"Invalid .env key on line {line_number}")
    if not (key.startswith("VIBE_STICK_") or key == "CLAUDE_CODE_OAUTH_TOKEN"):
        raise SystemExit(f"Unsupported .env key on line {line_number}: {key}")
    if key in seen_keys:
        raise SystemExit(f"Duplicate .env key on line {line_number}: {key}")
    seen_keys.add(key)
    try:
        words = shlex.split(raw_value, comments=False, posix=True)
    except ValueError as exc:
        raise SystemExit(f"Invalid quoted value on .env line {line_number}: {exc}")
    if len(words) > 1:
        raise SystemExit(f"Whitespace in .env value on line {line_number} must be quoted")
    env[key] = words[0] if words else ""

env["PYTHONPATH"] = bridge_src
os.execvpe(
    sys.executable,
    [sys.executable, "-m", "vibe_stick", "--host", "0.0.0.0", "--port", "8765"],
    env,
)
PY

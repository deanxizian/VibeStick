#!/usr/bin/env sh
set -eu
umask 077

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SETUP_PATH="$ROOT_DIR/scripts/setup.sh"
ENV_PATH="$ROOT_DIR/.env"
SECRETS_PATH="$ROOT_DIR/firmware/sticks3/include/vibe_stick_secrets.h"
CONFIG_DIR="$HOME/Library/Application Support/VibeStick"
RUNTIME_DIR="$CONFIG_DIR/runtime"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST_PATH="$LAUNCH_AGENTS_DIR/com.vibestick.bridge.plist"
HUD_PLIST_PATH="$LAUNCH_AGENTS_DIR/com.vibestick.hud.plist"
RUNNER_PATH="$CONFIG_DIR/run-bridge.sh"
HUD_BINARY_PATH="$CONFIG_DIR/VibeStickHUD"
HUD_SOURCE_PATH="$ROOT_DIR/app/macos/VibeStickHUD/main.swift"
DOMAIN="gui/$(id -u)"

STAGING_DIR=""
BACKUP_DIR=""
DEPLOYMENT_STARTED=0
INSTALL_COMMITTED=0

is_placeholder_token() {
  case "${1:-}" in
    ""|change-this-shared-token|paste-generated-token-here|changeme|change-me|your-token)
      return 0
      ;;
  esac
  return 1
}

is_valid_token() {
  printf '%s\n' "${1:-}" | awk '
    length($0) >= 32 && length($0) <= 256 && $0 ~ /^[[:alnum:]_.~-]+$/ { ok = 1 }
    END { exit(ok ? 0 : 1) }
  '
}

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

secret_value() {
  key="$1"
  file="$2"
  [ -f "$file" ] || return 0
  awk -v key="$key" '
    $1 == "#define" && $2 == key {
      value = $0
      sub(/^[^"]*"/, "", value)
      sub(/".*$/, "", value)
      print value
      exit
    }
  ' "$file"
}

validate_unique_secret_defines() {
  file="$1"
  [ -f "$file" ] || return 0
  awk '
    $1 == "#define" && $2 != "" && ++seen[$2] > 1 {
      printf "Duplicate firmware secret define: %s\n", $2 > "/dev/stderr"
      bad = 1
    }
    END { exit(bad ? 1 : 0) }
  ' "$file"
}

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf '%s\n' "Required command is missing: $1" >&2
    exit 1
  fi
}

preflight_platform() {
  if [ "$(uname -s)" != "Darwin" ]; then
    printf '%s\n' "scripts/install.sh supports macOS only." >&2
    exit 1
  fi
  if [ "$(id -u)" -eq 0 ]; then
    printf '%s\n' "Do not run scripts/install.sh with sudo; LaunchAgents must belong to the signed-in user." >&2
    exit 1
  fi
  for command_name in awk cp curl launchctl mkdir mv sed swiftc; do
    require_command "$command_name"
  done
  if [ ! -d "$ROOT_DIR/bridge/src/vibe_stick" ] || [ ! -f "$HUD_SOURCE_PATH" ]; then
    printf '%s\n' "Bridge or HUD source files are missing from this checkout." >&2
    exit 1
  fi
  if ! launchctl print "$DOMAIN" >/dev/null 2>&1; then
    printf '%s\n' "No graphical launchd domain is available for $DOMAIN; sign in locally before installing." >&2
    exit 1
  fi
}

require_bridge_token_ready() {
  env_token="$(env_value VIBE_STICK_BRIDGE_TOKEN "$ENV_PATH")"
  secret_token="$(secret_value VIBE_STICK_BRIDGE_TOKEN "$SECRETS_PATH")"

  if is_placeholder_token "$env_token"; then
    printf '%s\n' "VIBE_STICK_BRIDGE_TOKEN is required because install.sh exposes the bridge on 0.0.0.0." >&2
    printf '%s\n' "Run scripts/setup.sh to generate and sync the bridge token." >&2
    exit 1
  fi
  if ! is_valid_token "$env_token"; then
    printf '%s\n' "VIBE_STICK_BRIDGE_TOKEN must be 32-256 URL-safe characters." >&2
    exit 1
  fi
  if is_placeholder_token "$secret_token"; then
    printf '%s\n' "Firmware VIBE_STICK_BRIDGE_TOKEN is missing or still a placeholder." >&2
    printf '%s\n' "Run scripts/setup.sh to sync the same token into firmware secrets." >&2
    exit 1
  fi
  if ! is_valid_token "$secret_token"; then
    printf '%s\n' "Firmware VIBE_STICK_BRIDGE_TOKEN must be 32-256 URL-safe characters." >&2
    exit 1
  fi
  if [ "$env_token" != "$secret_token" ]; then
    printf '%s\n' "VIBE_STICK_BRIDGE_TOKEN differs between .env and firmware secrets." >&2
    printf '%s\n' "Refusing to install because the device would receive 401 responses for protected requests." >&2
    exit 1
  fi
}

backup_if_present() {
  source_path="$1"
  backup_name="$2"
  if [ -e "$source_path" ]; then
    cp -pR "$source_path" "$BACKUP_DIR/$backup_name"
  fi
}

restore_if_present() {
  backup_name="$1"
  destination="$2"
  if [ -e "$BACKUP_DIR/$backup_name" ]; then
    mv "$BACKUP_DIR/$backup_name" "$destination"
  fi
}

remove_deployed_payload() {
  rm -rf "$RUNTIME_DIR"
  rm -f "$CONFIG_DIR/.env" "$RUNNER_PATH" "$HUD_BINARY_PATH"
  rm -f "$PLIST_PATH" "$HUD_PLIST_PATH"
}

rollback_deployment() {
  printf '%s\n' "Install failed; restoring the previous VibeStick deployment." >&2
  launchctl bootout "$DOMAIN" "$PLIST_PATH" >/dev/null 2>&1 || true
  launchctl bootout "$DOMAIN" "$HUD_PLIST_PATH" >/dev/null 2>&1 || true
  remove_deployed_payload
  restore_if_present runtime "$RUNTIME_DIR"
  restore_if_present installed.env "$CONFIG_DIR/.env"
  restore_if_present run-bridge.sh "$RUNNER_PATH"
  restore_if_present VibeStickHUD "$HUD_BINARY_PATH"
  restore_if_present bridge.plist "$PLIST_PATH"
  restore_if_present hud.plist "$HUD_PLIST_PATH"
  if [ -f "$PLIST_PATH" ]; then
    launchctl bootstrap "$DOMAIN" "$PLIST_PATH" >/dev/null 2>&1 || true
  fi
  if [ -f "$HUD_PLIST_PATH" ]; then
    launchctl bootstrap "$DOMAIN" "$HUD_PLIST_PATH" >/dev/null 2>&1 || true
  fi
}

on_exit() {
  status="$1"
  trap - 0 HUP INT TERM
  set +e
  if [ "$status" -ne 0 ] && [ "$DEPLOYMENT_STARTED" -eq 1 ] && [ "$INSTALL_COMMITTED" -eq 0 ]; then
    rollback_deployment
  fi
  if [ -n "$STAGING_DIR" ]; then
    rm -rf "$STAGING_DIR"
  fi
  if [ -n "$BACKUP_DIR" ]; then
    rm -rf "$BACKUP_DIR"
  fi
  exit "$status"
}

health_matches_expected() {
  health_payload="$(curl -fsS --max-time 2 http://127.0.0.1:8765/health 2>/dev/null)" || return 1
  printf '%s' "$health_payload" | "$PYTHON_BIN" -c '
import json
import sys

try:
    payload = json.load(sys.stdin)
except (json.JSONDecodeError, OSError):
    raise SystemExit(1)

expected_version = sys.argv[1]
expected_instance = sys.argv[2]
ok = (
    payload.get("ok") is True
    and payload.get("bridge_name") == "vibestick-bridge"
    and payload.get("bridge_version") == expected_version
    and payload.get("bridge_instance") == expected_instance
)
raise SystemExit(0 if ok else 1)
' "$EXPECTED_BRIDGE_VERSION" "$INSTALL_NONCE"
}

protected_state_matches_expected() {
  state_payload="$(curl -fsS --max-time 2 \
    -H "X-Vibe-Stick-Token: $EXPECTED_BRIDGE_TOKEN" \
    http://127.0.0.1:8765/state 2>/dev/null)" || return 1
  printf '%s' "$state_payload" | "$PYTHON_BIN" -c '
import json
import sys

try:
    payload = json.load(sys.stdin)
except (json.JSONDecodeError, OSError):
    raise SystemExit(1)

ok = (
    payload.get("bridge_name") == "vibestick-bridge"
    and payload.get("bridge_version") == sys.argv[1]
)
raise SystemExit(0 if ok else 1)
' "$EXPECTED_BRIDGE_VERSION"
}

bridge_job_is_running() {
  launchctl print "$DOMAIN/com.vibestick.bridge" 2>/dev/null | awk '
    /state = running/ { running = 1 }
    /pid = [0-9]+/ { pid = 1 }
    END { exit(running && pid ? 0 : 1) }
  '
}

trap 'on_exit $?' 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

preflight_platform
"$SETUP_PATH"
validate_unique_env_keys "$ENV_PATH"
validate_unique_secret_defines "$SECRETS_PATH"
require_bridge_token_ready

configured_python="$(env_value VIBE_STICK_PYTHON "$ENV_PATH")"
managed_arch="$(uname -m)"
if [ "$managed_arch" = "arm64" ]; then
  managed_arch="aarch64"
fi
managed_python="$HOME/.local/share/vibestick/python/cpython-3.12-macos-$managed_arch-none/bin/python3.12"
if [ -n "$configured_python" ]; then
  PYTHON_BIN="$configured_python"
elif [ -x "$managed_python" ]; then
  PYTHON_BIN="$managed_python"
else
  PYTHON_BIN="python3"
fi
if ! resolved_python="$(command -v "$PYTHON_BIN" 2>/dev/null)" || [ -z "$resolved_python" ]; then
  printf '%s\n' "Configured Python is not installed or executable: $PYTHON_BIN" >&2
  printf '%s\n' "Install Python >= 3.11 and set VIBE_STICK_PYTHON to its absolute path in .env." >&2
  exit 1
fi
PYTHON_BIN="$resolved_python"
if ! "$PYTHON_BIN" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)' >/dev/null 2>&1; then
  printf '%s\n' "Python >= 3.11 is required; set VIBE_STICK_PYTHON in .env to a compatible interpreter." >&2
  exit 1
fi
EXPECTED_BRIDGE_TOKEN="$(env_value VIBE_STICK_BRIDGE_TOKEN "$ENV_PATH")"
INSTALL_NONCE="$("$PYTHON_BIN" -c 'import secrets; print(secrets.token_urlsafe(24))')"

mkdir -p "$CONFIG_DIR" "$LAUNCH_AGENTS_DIR"
chmod 700 "$CONFIG_DIR"
STAGING_DIR="$CONFIG_DIR/.install-staging.$$"
BACKUP_DIR="$CONFIG_DIR/.install-backup.$$"
mkdir -p "$STAGING_DIR/runtime" "$BACKUP_DIR"
chmod 700 "$STAGING_DIR" "$STAGING_DIR/runtime" "$BACKUP_DIR"

cp -R "$ROOT_DIR/bridge" "$STAGING_DIR/runtime/bridge"
cp "$ENV_PATH" "$STAGING_DIR/installed.env"
chmod 600 "$STAGING_DIR/installed.env"
swiftc "$HUD_SOURCE_PATH" -o "$STAGING_DIR/VibeStickHUD" -framework AppKit -framework QuartzCore
chmod 700 "$STAGING_DIR/VibeStickHUD"

{
  printf '%s\n' '#!/usr/bin/env sh' 'set -eu' 'umask 077'
  printf 'PYTHON_BIN=%s\n' "$(shell_quote "$PYTHON_BIN")"
  printf 'ENV_PATH=%s\n' "$(shell_quote "$CONFIG_DIR/.env")"
  printf 'BRIDGE_SRC=%s\n' "$(shell_quote "$RUNTIME_DIR/bridge/src")"
  printf 'VIBE_STICK_INSTALL_NONCE=%s\n' "$(shell_quote "$INSTALL_NONCE")"
  printf '%s\n' 'export VIBE_STICK_INSTALL_NONCE'
  cat <<'RUNNER'
exec "$PYTHON_BIN" - "$ENV_PATH" "$BRIDGE_SRC" <<'PY'
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
    if not key.startswith("VIBE_STICK_"):
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

env["VIBE_STICK_INSTALL_NONCE"] = os.environ["VIBE_STICK_INSTALL_NONCE"]
env["PYTHONPATH"] = bridge_src
os.execvpe(
    sys.executable,
    [sys.executable, "-m", "vibe_stick", "--host", "0.0.0.0", "--port", "8765"],
    env,
)
PY
RUNNER
} > "$STAGING_DIR/run-bridge.sh"
chmod 700 "$STAGING_DIR/run-bridge.sh"

cat > "$STAGING_DIR/bridge.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.vibestick.bridge</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>$RUNNER_PATH</string>
  </array>
  <key>WorkingDirectory</key>
  <string>$CONFIG_DIR</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$CONFIG_DIR/bridge.log</string>
  <key>StandardErrorPath</key>
  <string>$CONFIG_DIR/bridge.err.log</string>
</dict>
</plist>
PLIST

cat > "$STAGING_DIR/hud.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.vibestick.hud</string>
  <key>ProgramArguments</key>
  <array>
    <string>$HUD_BINARY_PATH</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$CONFIG_DIR/hud.log</string>
  <key>StandardErrorPath</key>
  <string>$CONFIG_DIR/hud.err.log</string>
</dict>
</plist>
PLIST
chmod 600 "$STAGING_DIR/bridge.plist" "$STAGING_DIR/hud.plist"

PYTHONPATH="$STAGING_DIR/runtime/bridge/src" "$PYTHON_BIN" -B -c 'import vibe_stick; import vibe_stick.server.app'
EXPECTED_BRIDGE_VERSION="$(PYTHONPATH="$STAGING_DIR/runtime/bridge/src" "$PYTHON_BIN" -B -c 'import vibe_stick; print(vibe_stick.__version__)')"

backup_if_present "$RUNTIME_DIR" runtime
backup_if_present "$CONFIG_DIR/.env" installed.env
backup_if_present "$RUNNER_PATH" run-bridge.sh
backup_if_present "$HUD_BINARY_PATH" VibeStickHUD
backup_if_present "$PLIST_PATH" bridge.plist
backup_if_present "$HUD_PLIST_PATH" hud.plist

DEPLOYMENT_STARTED=1
launchctl bootout "$DOMAIN" "$PLIST_PATH" >/dev/null 2>&1 || true
launchctl bootout "$DOMAIN" "$HUD_PLIST_PATH" >/dev/null 2>&1 || true
remove_deployed_payload

mv "$STAGING_DIR/runtime" "$RUNTIME_DIR"
mv "$STAGING_DIR/installed.env" "$CONFIG_DIR/.env"
mv "$STAGING_DIR/run-bridge.sh" "$RUNNER_PATH"
mv "$STAGING_DIR/VibeStickHUD" "$HUD_BINARY_PATH"
mv "$STAGING_DIR/bridge.plist" "$PLIST_PATH"
mv "$STAGING_DIR/hud.plist" "$HUD_PLIST_PATH"

touch "$CONFIG_DIR/bridge.log" "$CONFIG_DIR/bridge.err.log" "$CONFIG_DIR/hud.log" "$CONFIG_DIR/hud.err.log"
chmod 600 "$CONFIG_DIR/.env" "$CONFIG_DIR/bridge.log" "$CONFIG_DIR/bridge.err.log" \
  "$CONFIG_DIR/hud.log" "$CONFIG_DIR/hud.err.log" "$PLIST_PATH" "$HUD_PLIST_PATH"
chmod 700 "$RUNNER_PATH" "$HUD_BINARY_PATH" "$RUNTIME_DIR"

launchctl bootstrap "$DOMAIN" "$PLIST_PATH"
launchctl bootstrap "$DOMAIN" "$HUD_PLIST_PATH"

attempt=0
while [ "$attempt" -lt 15 ]; do
  if bridge_job_is_running && health_matches_expected && protected_state_matches_expected; then
    break
  fi
  attempt=$((attempt + 1))
  sleep 1
done
if [ "$attempt" -ge 15 ]; then
  printf '%s\n' "The new Bridge LaunchAgent did not prove its identity and protected state within 15 seconds." >&2
  exit 1
fi
if ! launchctl print "$DOMAIN/com.vibestick.hud" >/dev/null 2>&1; then
  printf '%s\n' "The HUD LaunchAgent did not remain loaded." >&2
  exit 1
fi

INSTALL_COMMITTED=1
rm -rf "$BACKUP_DIR"
BACKUP_DIR=""

printf '%s\n' "VibeStick config directory is ready:"
printf '%s\n' "$CONFIG_DIR"
printf '%s\n' "VibeStick Bridge LaunchAgent installed and healthy:"
printf '%s\n' "$PLIST_PATH"
printf '%s\n' "VibeStick Bridge HUD LaunchAgent installed:"
printf '%s\n' "$HUD_PLIST_PATH"

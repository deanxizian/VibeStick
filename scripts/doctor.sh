#!/usr/bin/env sh
set -u
umask 077

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
ENV_PATH="$ROOT_DIR/.env"
SECRETS_PATH="$ROOT_DIR/firmware/sticks3/include/vibe_stick_secrets.h"
APP_SUPPORT_DIR="$HOME/Library/Application Support/VibeStick"
INSTALLED_ENV_PATH="$APP_SUPPORT_DIR/.env"
BRIDGE_PLIST_PATH="$HOME/Library/LaunchAgents/com.vibestick.bridge.plist"
BRIDGE_RUNNER_PATH="$APP_SUPPORT_DIR/run-bridge.sh"

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf 'PASS %s\n' "$1"
}

warn() {
  WARN_COUNT=$((WARN_COUNT + 1))
  printf 'WARN %s\n' "$1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf 'FAIL %s\n' "$1"
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

has_unique_env_keys() {
  file="$1"
  [ -f "$file" ] || return 1
  awk -F= '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    {
      key = $1
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
      if (key != "" && ++seen[key] > 1) bad = 1
    }
    END { exit(bad ? 1 : 0) }
  ' "$file"
}

has_unique_secret_defines() {
  file="$1"
  [ -f "$file" ] || return 1
  awk '
    $1 == "#define" && $2 != "" && ++seen[$2] > 1 { bad = 1 }
    END { exit(bad ? 1 : 0) }
  ' "$file"
}

python_bin() {
  configured_python="$(env_value VIBE_STICK_PYTHON "$ENV_PATH")"
  printf '%s\n' "${configured_python:-python3}"
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

valid_c_string_define() {
  key="$1"
  file="$2"
  awk -v key="$key" '
    $1 == "#define" && $2 == key {
      count++
      value = $0
      sub(/^[[:space:]]*#define[[:space:]]+[^[:space:]]+[[:space:]]+/, "", value)
      if (value ~ /^"([^"\\]|\\.)*"[[:space:]]*$/) {
        valid++
      }
    }
    END { exit(count == 1 && valid == 1 ? 0 : 1) }
  ' "$file"
}

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

is_placeholder_wifi() {
  case "${1:-}" in
    ""|your-wifi|YOUR_WIFI_SSID|ssid|wifi-ssid)
      return 0
      ;;
  esac
  return 1
}

is_placeholder_password() {
  case "${1:-}" in
    ""|your-password|YOUR_WIFI_PASSWORD|password|wifi-password)
      return 0
      ;;
  esac
  return 1
}

is_placeholder_host() {
  case "${1:-}" in
    ""|127.0.0.1|0.0.0.0|192.168.1.10|192.168.0.10|10.0.0.10|YOUR_MAC_IP|your-mac-ip)
      return 0
      ;;
  esac
  return 1
}

check_python() {
  python_cmd="$(python_bin)"
  if ! command -v "$python_cmd" >/dev/null 2>&1; then
    fail "Configured Python is not installed or executable."
    return
  fi
  if "$python_cmd" - <<'PY' >/dev/null 2>&1
import sys
raise SystemExit(0 if sys.version_info >= (3, 11) else 1)
PY
  then
    pass "Python >= 3.11 is available."
  else
    fail "Python >= 3.11 is required."
  fi
}

check_esp_idf() {
  if command -v idf.py >/dev/null 2>&1; then
    pass "ESP-IDF is available on PATH."
    return
  fi
  export_path=""
  if [ -d "$HOME/esp" ]; then
    export_path="$(find "$HOME/esp" -path '*/esp-idf/export.sh' -print -quit 2>/dev/null || true)"
  fi
  if [ -n "$export_path" ]; then
    pass "ESP-IDF export script was found."
  else
    warn "ESP-IDF was not found; only firmware build/flash needs it."
  fi
}

check_dotenv() {
  if [ -f "$ENV_PATH" ]; then
    pass ".env exists."
  else
    fail ".env is missing; run scripts/setup.sh."
    return
  fi
  if ! has_unique_env_keys "$ENV_PATH"; then
    fail ".env contains duplicate keys; remove the ambiguity before running the Bridge."
    return
  fi

  env_token="$(env_value VIBE_STICK_BRIDGE_TOKEN "$ENV_PATH")"
  if is_placeholder_token "$env_token"; then
    warn "VIBE_STICK_BRIDGE_TOKEN is empty or placeholder; binding 0.0.0.0 would be unsafe and install/dev scripts will refuse it."
  elif ! is_valid_token "$env_token"; then
    fail "VIBE_STICK_BRIDGE_TOKEN must be 32-256 URL-safe characters."
  else
    pass "VIBE_STICK_BRIDGE_TOKEN is set in .env."
  fi
}

check_secrets() {
  if [ -f "$SECRETS_PATH" ]; then
    pass "firmware secrets file exists."
  else
    fail "firmware secrets file is missing; run scripts/setup.sh."
    return
  fi
  if ! has_unique_secret_defines "$SECRETS_PATH"; then
    fail "Firmware secrets contain duplicate #define names."
    return
  fi

  invalid_secret=0
  for secret_key in \
    VIBE_STICK_WIFI_SSID \
    VIBE_STICK_WIFI_PASSWORD \
    VIBE_STICK_BRIDGE_HOST \
    VIBE_STICK_BRIDGE_TOKEN; do
    if ! valid_c_string_define "$secret_key" "$SECRETS_PATH"; then
      fail "$secret_key is not one valid, quoted C string in firmware secrets."
      invalid_secret=1
    fi
  done
  if [ "$invalid_secret" -eq 1 ]; then
    return
  fi

  wifi_ssid="$(secret_value VIBE_STICK_WIFI_SSID "$SECRETS_PATH")"
  wifi_password="$(secret_value VIBE_STICK_WIFI_PASSWORD "$SECRETS_PATH")"
  bridge_host="$(secret_value VIBE_STICK_BRIDGE_HOST "$SECRETS_PATH")"

  if is_placeholder_wifi "$wifi_ssid"; then
    fail "Wi-Fi SSID is empty or placeholder in firmware secrets."
  else
    pass "Wi-Fi SSID is configured in firmware secrets."
  fi

  if is_placeholder_password "$wifi_password"; then
    fail "Wi-Fi password is empty or placeholder in firmware secrets."
  else
    pass "Wi-Fi password is configured in firmware secrets."
  fi

  if is_placeholder_host "$bridge_host"; then
    fail "VIBE_STICK_BRIDGE_HOST is empty, loopback, wildcard, or example placeholder."
  else
    pass "VIBE_STICK_BRIDGE_HOST is configured in firmware secrets."
    lan_ip="$(ipconfig getifaddr en0 2>/dev/null || true)"
    if [ -n "$lan_ip" ] && [ "$bridge_host" != "$lan_ip" ]; then
      warn "VIBE_STICK_BRIDGE_HOST ($bridge_host) does not match detected en0 IP ($lan_ip). Keep it only if the bridge runs at that address."
    fi
  fi
}

check_token_match() {
  [ -f "$ENV_PATH" ] && [ -f "$SECRETS_PATH" ] || return
  env_token="$(env_value VIBE_STICK_BRIDGE_TOKEN "$ENV_PATH")"
  secret_token="$(secret_value VIBE_STICK_BRIDGE_TOKEN "$SECRETS_PATH")"
  if [ "$env_token" = "$secret_token" ]; then
    if is_placeholder_token "$env_token"; then
      warn "Bridge tokens match but are empty or placeholder."
    elif ! is_valid_token "$env_token"; then
      fail "Bridge tokens match but do not use the required URL-safe format."
    else
      pass "Bridge token matches between .env and firmware secrets."
    fi
  else
    fail "Bridge token differs between .env and firmware secrets; protected requests will get 401."
  fi
}

check_bridge_health() {
  installed=0
  if [ -f "$BRIDGE_PLIST_PATH" ] || [ -f "$BRIDGE_RUNNER_PATH" ]; then
    installed=1
  fi
  if [ "$installed" -eq 1 ]; then
    domain="gui/$(id -u)"
    if launchctl print "$domain/com.vibestick.bridge" 2>/dev/null | awk '
      /state = running/ { running = 1 }
      /pid = [0-9]+/ { pid = 1 }
      END { exit(running && pid ? 0 : 1) }
    '; then
      pass "Bridge LaunchAgent is running with a process id."
    else
      fail "Bridge LaunchAgent is not running; another process on port 8765 must not count as the installed service."
    fi
  fi
  if ! command -v curl >/dev/null 2>&1; then
    if [ "$installed" -eq 1 ]; then
      fail "curl is unavailable, so the installed Bridge cannot be health-checked."
    else
      warn "curl is unavailable; Bridge health was not checked."
    fi
    return
  fi

  health_payload="$(curl -fsS --max-time 3 http://127.0.0.1:8765/health 2>/dev/null)"
  if [ -z "$health_payload" ]; then
    if [ "$installed" -eq 1 ]; then
      fail "Installed Bridge is not responding on 127.0.0.1:8765."
    else
      warn "Bridge health endpoint is not responding on 127.0.0.1:8765."
    fi
    return
  fi

  expected_version="$(awk -F'"' '/__version__[[:space:]]*=/{print $2; exit}' "$ROOT_DIR/bridge/src/vibe_stick/__init__.py" 2>/dev/null)"
  metadata_python="$(python_bin)"
  if ! command -v "$metadata_python" >/dev/null 2>&1; then
    metadata_python="/usr/bin/python3"
  fi
  metadata_ok=0
  if [ -x "$metadata_python" ] && printf '%s' "$health_payload" | "$metadata_python" -c '
import json
import sys

try:
    payload = json.load(sys.stdin)
except (json.JSONDecodeError, OSError):
    raise SystemExit(1)

expected = sys.argv[1]
installed = sys.argv[2] == "1"
ok = payload.get("ok") is True and payload.get("bridge_name") == "vibestick-bridge"
if expected:
    ok = ok and payload.get("bridge_version") == expected
if installed:
    ok = ok and bool(payload.get("bridge_instance"))
raise SystemExit(0 if ok else 1)
' "$expected_version" "$installed" >/dev/null 2>&1; then
    metadata_ok=1
  fi

  if [ "$metadata_ok" -eq 1 ]; then
    pass "Bridge health metadata matches this checkout on 127.0.0.1:8765."
  elif [ "$installed" -eq 1 ]; then
    fail "Installed Bridge health metadata is invalid or its version differs from this checkout."
  else
    warn "A service responded on port 8765, but its VibeStick health metadata was invalid."
  fi

  if [ "$installed" -eq 1 ]; then
    installed_token="$(env_value VIBE_STICK_BRIDGE_TOKEN "$INSTALLED_ENV_PATH")"
    protected_payload="$(curl -fsS --max-time 3 \
      -H "X-Vibe-Stick-Token: $installed_token" \
      http://127.0.0.1:8765/state 2>/dev/null)"
    if [ -n "$protected_payload" ] && printf '%s' "$protected_payload" | "$metadata_python" -c '
import json
import sys

try:
    payload = json.load(sys.stdin)
except (json.JSONDecodeError, OSError):
    raise SystemExit(1)
raise SystemExit(0 if payload.get("bridge_name") == "vibestick-bridge" else 1)
' >/dev/null 2>&1; then
      pass "Installed Bridge token authorizes the protected state endpoint."
    else
      fail "Installed Bridge token cannot authorize /state."
    fi
  fi
}

check_installed_config() {
  if [ ! -f "$BRIDGE_PLIST_PATH" ] && [ ! -f "$BRIDGE_RUNNER_PATH" ]; then
    return
  fi
  if [ ! -f "$INSTALLED_ENV_PATH" ]; then
    fail "Bridge is installed but its installed .env copy is missing."
    return
  fi
  if ! has_unique_env_keys "$INSTALLED_ENV_PATH"; then
    fail "Installed .env contains duplicate keys; rerun scripts/install.sh after fixing the repository copy."
    return
  fi
  repository_token="$(env_value VIBE_STICK_BRIDGE_TOKEN "$ENV_PATH")"
  installed_token="$(env_value VIBE_STICK_BRIDGE_TOKEN "$INSTALLED_ENV_PATH")"
  if [ "$repository_token" = "$installed_token" ]; then
    pass "Installed Bridge token matches the repository and firmware configuration."
  else
    fail "Installed Bridge token is stale; rerun scripts/install.sh before using the reflashed device."
  fi
  if ! command -v cmp >/dev/null 2>&1; then
    warn "cmp is unavailable; repository and installed .env copies were not compared."
  elif cmp -s "$ENV_PATH" "$INSTALLED_ENV_PATH"; then
    pass "Installed .env matches the repository copy."
  else
    warn "Repository .env differs from the installed copy; rerun scripts/install.sh to deploy config changes."
  fi
}

check_private_permissions() {
  for private_path in "$ENV_PATH" "$SECRETS_PATH" "$INSTALLED_ENV_PATH"; do
    [ -f "$private_path" ] || continue
    mode="$(stat -f '%Lp' "$private_path" 2>/dev/null || printf 'unknown')"
    case "$mode" in
      600|400)
        pass "Private config permissions are restricted: $private_path"
        ;;
      *)
        warn "Private config should be mode 600: $private_path (mode $mode)"
        ;;
    esac
  done
}

check_asr() {
  python_cmd="$(python_bin)"
  if "$python_cmd" - "$ENV_PATH" "$APP_SUPPORT_DIR" <<'PY'
import sys
import tomllib
from pathlib import Path

env_path = Path(sys.argv[1])
app_support = Path(sys.argv[2])

def clean(value):
    if value is None:
        return ""
    value = str(value).strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        value = value[1:-1].strip()
    return value

def present(value):
    value = clean(value)
    return bool(value) and value.lower() not in {
        "changeme",
        "change-me",
        "your-key",
        "your-api-key",
        "paste-api-key-here",
    }

def read_dotenv(path):
    data = {}
    try:
        lines = path.read_text().splitlines()
    except OSError:
        return data
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        data[key.strip()] = clean(value)
    return data

def env_has_asr(data):
    if present(data.get("VIBE_STICK_TRANSCRIBE_CMD")):
        return True
    provider = clean(data.get("VIBE_STICK_ASR_PROVIDER")).lower()
    base_url = data.get("VIBE_STICK_ASR_BASE_URL")
    asr_key = data.get("VIBE_STICK_ASR_API_KEY")
    groq_key = data.get("VIBE_STICK_GROQ_API_KEY")
    if provider == "groq":
        return present(asr_key) or present(groq_key)
    if provider == "openai-compatible" or present(base_url) or present(asr_key):
        return present(base_url) and present(asr_key)
    return present(groq_key)

def toml_has_asr(path):
    try:
        data = tomllib.loads(path.read_text())
    except (OSError, tomllib.TOMLDecodeError):
        return False
    provider = clean(data.get("asr_provider") or data.get("provider")).lower()
    base_url = data.get("base_url")
    api_key = data.get("api_key")
    groq_key = data.get("groq_api_key")
    if provider == "groq":
        return present(groq_key) or present(api_key)
    if provider == "openai-compatible" or present(base_url) or present(api_key):
        return present(base_url) and present(api_key)
    return False

dotenv = read_dotenv(env_path)
ok = env_has_asr(dotenv) or any(
    toml_has_asr(path)
    for path in (app_support / "asr.toml", app_support / "config.toml")
)
raise SystemExit(0 if ok else 1)
PY
  then
    pass "ASR is configured through command or OpenAI-compatible settings."
  else
    warn "ASR is not configured; recording can capture audio but will not transcribe."
  fi
}

check_python
check_esp_idf
check_dotenv
check_secrets
check_token_match
check_bridge_health
check_installed_config
check_private_permissions
check_asr

printf 'INFO macOS permissions: grant Microphone permission for recording and Accessibility permission for the bridge runner/terminal that performs paste injection.\n'
printf 'SUMMARY pass=%s warn=%s fail=%s\n' "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT"
if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0

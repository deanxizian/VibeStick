#!/usr/bin/env sh
set -eu
umask 077

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
ENV_PATH="$ROOT_DIR/.env"

timeout_seconds="${VIBE_STICK_DEVICE_WAIT_TIMEOUT_SECONDS:-45}"
max_age_seconds="${VIBE_STICK_DEVICE_MAX_AGE_SECONDS:-5}"
poll_interval_seconds="${VIBE_STICK_DEVICE_POLL_INTERVAL_SECONDS:-0.5}"
bridge_port="${VIBE_STICK_BRIDGE_PORT:-8765}"
deployment_nonce=""

usage() {
  printf '%s\n' "Usage: scripts/wait-for-device.sh --deployment-nonce NONCE [--timeout SECONDS] [--max-age SECONDS] [--interval SECONDS] [--port PORT]" >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --timeout|--max-age|--interval|--port|--deployment-nonce)
      option="$1"
      shift
      if [ "$#" -eq 0 ]; then
        usage
        exit 2
      fi
      case "$option" in
        --timeout) timeout_seconds="$1" ;;
        --max-age) max_age_seconds="$1" ;;
        --interval) poll_interval_seconds="$1" ;;
        --port) bridge_port="$1" ;;
        --deployment-nonce) deployment_nonce="$1" ;;
      esac
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
  shift
done

case "$deployment_nonce" in
  ""|*[!A-Za-z0-9._~-]*)
    printf '%s\n' "A URL-safe deployment nonce is required." >&2
    exit 2
    ;;
esac
if [ "${#deployment_nonce}" -lt 32 ] || [ "${#deployment_nonce}" -gt 128 ]; then
  printf '%s\n' "The deployment nonce must contain 32-128 characters." >&2
  exit 2
fi

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

configured_python="${VIBE_STICK_PYTHON:-$(env_value VIBE_STICK_PYTHON "$ENV_PATH")}"
PYTHON_BIN="${configured_python:-python3}"
if ! resolved_python="$(command -v "$PYTHON_BIN" 2>/dev/null)" || [ -z "$resolved_python" ]; then
  printf '%s\n' "Python >= 3.11 is required to verify the device." >&2
  exit 1
fi

exec "$resolved_python" - \
  "$ENV_PATH" \
  "$timeout_seconds" \
  "$max_age_seconds" \
  "$poll_interval_seconds" \
  "$bridge_port" \
  "$deployment_nonce" <<'PY'
from __future__ import annotations

from datetime import datetime, timezone
import http.client
import json
import os
from pathlib import Path
import re
import shlex
import sys
import time


def load_env_value(path: Path, wanted_key: str) -> str:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except FileNotFoundError:
        return ""
    except OSError as exc:
        raise SystemExit(f"Could not read VibeStick config: {exc}") from exc

    value = ""
    found = False
    for line_number, source_line in enumerate(lines, 1):
        line = source_line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, raw_value = line.split("=", 1)
        if key.strip() != wanted_key:
            continue
        if found:
            raise SystemExit(f"Duplicate .env key: {wanted_key}")
        found = True
        try:
            words = shlex.split(raw_value.strip(), comments=False, posix=True)
        except ValueError as exc:
            raise SystemExit(f"Invalid quoted value on .env line {line_number}: {exc}") from exc
        if len(words) > 1:
            raise SystemExit(
                f"Whitespace in .env value on line {line_number} must be quoted"
            )
        value = words[0] if words else ""
    return value


def positive_number(raw: str, name: str, maximum: float) -> float:
    try:
        value = float(raw)
    except ValueError as exc:
        raise SystemExit(f"{name} must be a number") from exc
    if not 0 < value <= maximum:
        raise SystemExit(f"{name} must be greater than 0 and no more than {maximum:g}")
    return value


def parse_seen_at(raw: object) -> float | None:
    if not isinstance(raw, str) or not raw:
        return None
    try:
        parsed = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return None
    return parsed.timestamp()


env_path = Path(sys.argv[1])
timeout_seconds = positive_number(sys.argv[2], "timeout", 300)
max_age_seconds = positive_number(sys.argv[3], "max age", 60)
poll_interval_seconds = positive_number(sys.argv[4], "poll interval", 10)
try:
    bridge_port = int(sys.argv[5])
except ValueError as exc:
    raise SystemExit("port must be an integer") from exc
if not 1 <= bridge_port <= 65535:
    raise SystemExit("port must be between 1 and 65535")
expected_deployment_nonce = sys.argv[6]

token = os.environ.get("VIBE_STICK_BRIDGE_TOKEN", "").strip()
if not token:
    token = load_env_value(env_path, "VIBE_STICK_BRIDGE_TOKEN").strip()
if not re.fullmatch(r"[A-Za-z0-9._~-]{32,256}", token):
    raise SystemExit(
        "A valid VIBE_STICK_BRIDGE_TOKEN is required; run scripts/setup.sh first."
    )

started_wall = time.time()
deadline = time.monotonic() + timeout_seconds
last_reason = "the Bridge has not reported a device yet"

while True:
    try:
        connection = http.client.HTTPConnection(
            "127.0.0.1",
            bridge_port,
            timeout=min(2.0, max(0.1, poll_interval_seconds)),
        )
        try:
            connection.request(
                "GET",
                "/device/health",
                headers={"X-Vibe-Stick-Token": token},
            )
            response = connection.getresponse()
            raw_payload = response.read(64 * 1024)
        finally:
            connection.close()
        if response.status != 200:
            last_reason = f"Bridge health returned HTTP {response.status}"
        else:
            payload = json.loads(raw_payload)
            if not isinstance(payload, dict) or payload.get("bridge_name") != "vibestick-bridge":
                last_reason = "the health response is not from VibeStick Bridge"
            elif payload.get("device_firmware_name") != "vibestick":
                last_reason = "no authenticated VibeStick firmware poll has been observed"
            elif payload.get("device_deployment_nonce") != expected_deployment_nonce:
                last_reason = "the online device does not match this deployment"
            else:
                seen_at = parse_seen_at(payload.get("device_last_seen_at"))
                age = payload.get("device_last_seen_age_seconds")
                if seen_at is None or not isinstance(age, (int, float)):
                    last_reason = "the device presence metadata is incomplete"
                elif seen_at + 0.001 < started_wall:
                    last_reason = "only a device poll from before this verification was observed"
                elif not 0 <= float(age) <= max_age_seconds:
                    last_reason = f"the latest device poll is {float(age):.1f}s old"
                else:
                    version = payload.get("device_firmware_version") or "unknown"
                    transport = payload.get("device_firmware_transport") or "unknown"
                    print(
                        "VibeStick device is online "
                        f"(firmware={version}, transport={transport}, age={float(age):.1f}s)."
                    )
                    raise SystemExit(0)
    except (OSError, http.client.HTTPException):
        last_reason = "VibeStick Bridge is not reachable on localhost"
    except (UnicodeDecodeError, json.JSONDecodeError):
        last_reason = "Bridge health returned invalid JSON"

    remaining = deadline - time.monotonic()
    if remaining <= 0:
        print(
            f"Timed out after {timeout_seconds:g}s waiting for a newly online VibeStick device: "
            f"{last_reason}.",
            file=sys.stderr,
        )
        # EX_TEMPFAIL: the installer may safely retry with the same deployment
        # nonce. Configuration/authentication failures exit with code 1 or 2.
        raise SystemExit(75)
    time.sleep(min(poll_interval_seconds, remaining))
PY

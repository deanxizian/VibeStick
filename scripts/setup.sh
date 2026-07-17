#!/usr/bin/env sh
set -eu
umask 077

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
ENV_PATH="$ROOT_DIR/.env"
ENV_EXAMPLE_PATH="$ROOT_DIR/.env.example"
SECRETS_PATH="$ROOT_DIR/firmware/sticks3/include/vibe_stick_secrets.h"
SECRETS_EXAMPLE_PATH="$ROOT_DIR/firmware/sticks3/include/vibe_stick_secrets.example.h"

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

is_placeholder_host() {
  case "${1:-}" in
    ""|127.0.0.1|0.0.0.0|192.168.1.10|192.168.0.10|10.0.0.10|YOUR_MAC_IP|your-mac-ip)
      return 0
      ;;
  esac
  return 1
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

shell_quote() {
  # Emit one POSIX-shell-safe word. The bridge's dotenv loader also accepts
  # this representation without evaluating substitutions.
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
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

set_env_value() {
  key="$1"
  value="$2"
  file="$3"
  tmp="$file.tmp.$$"
  quoted_value="$(shell_quote "$value")"
  if ! VIBE_STICK_ENV_VALUE="$quoted_value" awk -v key="$key" '
    BEGIN { done = 0 }
    /^[[:space:]]*#/ { print; next }
    {
      line = $0
      k = line
      sub(/=.*/, "", k)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
      if (k == key) {
        print key "=" ENVIRON["VIBE_STICK_ENV_VALUE"]
        done = 1
        next
      }
      print
    }
    END {
      if (!done) {
        print key "=" ENVIRON["VIBE_STICK_ENV_VALUE"]
      }
    }
  ' "$file" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$file"
}

set_secret_value() {
  key="$1"
  value="$2"
  file="$3"
  tmp="$file.tmp.$$"
  newline='
'
  carriage_return="$(printf '\r')"
  case "$value" in
    *"$newline"*|*"$carriage_return"*)
      printf '%s\n' "ERROR: $key cannot contain a literal newline or carriage return." >&2
      return 1
      ;;
  esac
  escaped_value="$(printf '%s' "$value" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  if ! VIBE_STICK_SECRET_VALUE="$escaped_value" awk -v key="$key" '
    BEGIN { done = 0 }
    $1 == "#define" && $2 == key {
      print "#define " key " \"" ENVIRON["VIBE_STICK_SECRET_VALUE"] "\""
      done = 1
      next
    }
    { print }
    END {
      if (!done) {
        print "#define " key " \"" ENVIRON["VIBE_STICK_SECRET_VALUE"] "\""
      }
    }
  ' "$file" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! valid_c_string_define "$key" "$tmp"; then
    printf '%s\n' "ERROR: Failed to write a valid C string for $key." >&2
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$file"
}

if [ ! -f "$ENV_PATH" ]; then
  cp "$ENV_EXAMPLE_PATH" "$ENV_PATH"
  printf '%s\n' "Created .env from .env.example."
else
  printf '%s\n' "Kept existing .env."
fi
chmod 600 "$ENV_PATH"

if [ ! -f "$SECRETS_PATH" ]; then
  cp "$SECRETS_EXAMPLE_PATH" "$SECRETS_PATH"
  printf '%s\n' "Created firmware/sticks3/include/vibe_stick_secrets.h from example."
else
  printf '%s\n' "Kept existing firmware/sticks3/include/vibe_stick_secrets.h."
fi
chmod 600 "$SECRETS_PATH"
validate_unique_env_keys "$ENV_PATH"
validate_unique_secret_defines "$SECRETS_PATH"

for required_secret in \
  VIBE_STICK_WIFI_SSID \
  VIBE_STICK_WIFI_PASSWORD \
  VIBE_STICK_BRIDGE_HOST \
  VIBE_STICK_BRIDGE_TOKEN; do
  if ! valid_c_string_define "$required_secret" "$SECRETS_PATH"; then
    printf '%s\n' "ERROR: $required_secret must be one valid, quoted C string in $SECRETS_PATH." >&2
    exit 1
  fi
done

project_root="$(env_value VIBE_STICK_PROJECT_ROOT "$ENV_PATH")"
if [ -z "$project_root" ]; then
  set_env_value VIBE_STICK_PROJECT_ROOT "$ROOT_DIR" "$ENV_PATH"
  printf '%s\n' "Set VIBE_STICK_PROJECT_ROOT to $ROOT_DIR."
fi

env_token="$(env_value VIBE_STICK_BRIDGE_TOKEN "$ENV_PATH")"
secret_token="$(secret_value VIBE_STICK_BRIDGE_TOKEN "$SECRETS_PATH")"

if ! is_placeholder_token "$env_token" && ! is_valid_token "$env_token"; then
  printf '%s\n' "ERROR: .env bridge token must be 32-256 URL-safe characters (letters, digits, . _ ~ -)." >&2
  exit 1
fi
if ! is_placeholder_token "$secret_token" && ! is_valid_token "$secret_token"; then
  printf '%s\n' "ERROR: Firmware bridge token must be 32-256 URL-safe characters (letters, digits, . _ ~ -)." >&2
  exit 1
fi

if ! is_placeholder_token "$env_token" && ! is_placeholder_token "$secret_token"; then
  if [ "$env_token" = "$secret_token" ]; then
    printf '%s\n' "Bridge token is already configured in both files."
  else
    printf '%s\n' "WARN: Bridge tokens are already set but differ; existing non-empty tokens were preserved."
    printf '%s\n' "      Run scripts/doctor.sh after deciding which token should be shared."
  fi
elif ! is_placeholder_token "$env_token"; then
  set_secret_value VIBE_STICK_BRIDGE_TOKEN "$env_token" "$SECRETS_PATH"
  printf '%s\n' "Copied existing .env bridge token into firmware secrets."
elif ! is_placeholder_token "$secret_token"; then
  set_env_value VIBE_STICK_BRIDGE_TOKEN "$secret_token" "$ENV_PATH"
  printf '%s\n' "Copied existing firmware bridge token into .env."
else
  if ! command -v openssl >/dev/null 2>&1; then
    printf '%s\n' "ERROR: openssl is required to generate VIBE_STICK_BRIDGE_TOKEN." >&2
    exit 1
  fi
  token="$(openssl rand -hex 32)"
  set_env_value VIBE_STICK_BRIDGE_TOKEN "$token" "$ENV_PATH"
  set_secret_value VIBE_STICK_BRIDGE_TOKEN "$token" "$SECRETS_PATH"
  printf '%s\n' "Generated and wrote one shared bridge token to .env and firmware secrets."
fi

lan_ip="$(ipconfig getifaddr en0 2>/dev/null || true)"
if [ -n "$lan_ip" ]; then
  printf '%s\n' "Detected Mac LAN IP on en0: $lan_ip"
  bridge_host="$(secret_value VIBE_STICK_BRIDGE_HOST "$SECRETS_PATH")"
  if is_placeholder_host "$bridge_host"; then
    set_secret_value VIBE_STICK_BRIDGE_HOST "$lan_ip" "$SECRETS_PATH"
    printf '%s\n' "Set VIBE_STICK_BRIDGE_HOST in firmware secrets to detected Mac LAN IP."
  elif [ "$bridge_host" = "$lan_ip" ]; then
    printf '%s\n' "VIBE_STICK_BRIDGE_HOST already matches detected Mac LAN IP."
  else
    printf '%s\n' "Kept existing VIBE_STICK_BRIDGE_HOST ($bridge_host); detected en0 IP is $lan_ip."
  fi
else
  printf '%s\n' "WARN: Could not detect a LAN IP from en0; set VIBE_STICK_BRIDGE_HOST manually."
fi

printf '\n%s\n' "Next steps:"
printf '%s\n' "1. Edit firmware/sticks3/include/vibe_stick_secrets.h with Wi-Fi SSID, password, and Mac IP."
printf '%s\n' "2. Optionally edit .env with ASR settings such as VIBE_STICK_ASR_PROVIDER and VIBE_STICK_ASR_API_KEY."
printf '%s\n' "3. Run scripts/doctor.sh to check the local setup before building or flashing."

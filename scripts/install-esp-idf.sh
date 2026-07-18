#!/usr/bin/env sh
set -eu
umask 077

VERSION="v5.5.1"
EXPECTED_VERSION="5.5.1"
TARGET_DIR="${VIBE_STICK_IDF_INSTALL_DIR:-$HOME/esp/vibestick-esp-idf-v5.5.1}"
PARENT_DIR="$(dirname -- "$TARGET_DIR")"
STAGING_DIR=""

managed_arch="$(uname -m)"
if [ "$managed_arch" = "arm64" ]; then
  managed_arch="aarch64"
fi
managed_python_bin="$HOME/.local/share/vibestick/python/cpython-3.12-macos-$managed_arch-none/bin"
if [ -x "$managed_python_bin/python3.12" ]; then
  PATH="$managed_python_bin:$PATH"
  export PATH
fi

cleanup() {
  status="$?"
  trap - 0 HUP INT TERM
  if [ -n "$STAGING_DIR" ]; then
    rm -rf "$STAGING_DIR"
  fi
  exit "$status"
}

trap cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

idf_version() {
  awk '
    /set\(IDF_VERSION_MAJOR / { major = $2; gsub(/\)/, "", major) }
    /set\(IDF_VERSION_MINOR / { minor = $2; gsub(/\)/, "", minor) }
    /set\(IDF_VERSION_PATCH / { patch = $2; gsub(/\)/, "", patch) }
    END { if (major != "" && minor != "" && patch != "") print major "." minor "." patch }
  ' "$1/tools/cmake/version.cmake" 2>/dev/null || true
}

case "$TARGET_DIR" in
  "$HOME"/*) ;;
  *)
    printf '%s\n' "ESP-IDF install directory must be inside the current user's home directory." >&2
    exit 1
    ;;
esac

if [ -L "$TARGET_DIR" ] || [ -L "$PARENT_DIR" ]; then
  printf '%s\n' "Refusing to install through a symbolic link." >&2
  exit 1
fi

mkdir -p "$PARENT_DIR"
if [ ! -e "$TARGET_DIR" ]; then
  printf '%s\n' "Downloading ESP-IDF $VERSION (this is approximately 1 GB with tools)..."
  STAGING_DIR="$PARENT_DIR/.vibestick-esp-idf-$VERSION.$$"
  rm -rf "$STAGING_DIR"
  /usr/bin/git clone --branch "$VERSION" --recursive --depth 1 \
    https://github.com/espressif/esp-idf.git "$STAGING_DIR"
  version_line="$(idf_version "$STAGING_DIR")"
  if [ "$version_line" != "$EXPECTED_VERSION" ] || [ ! -f "$STAGING_DIR/export.sh" ] || [ ! -x "$STAGING_DIR/install.sh" ]; then
    printf '%s\n' "The downloaded ESP-IDF checkout failed validation." >&2
    exit 1
  fi
  mv "$STAGING_DIR" "$TARGET_DIR"
  STAGING_DIR=""
elif [ ! -f "$TARGET_DIR/export.sh" ] || [ ! -x "$TARGET_DIR/install.sh" ] || \
     [ "$(idf_version "$TARGET_DIR")" != "$EXPECTED_VERSION" ]; then
  printf '%s\n' "An unrelated, incomplete, or wrong-version directory exists at $TARGET_DIR." >&2
  printf '%s\n' "Move it aside and retry; the installer will not delete existing files." >&2
  exit 1
else
  printf '%s\n' "Using existing ESP-IDF checkout at $TARGET_DIR."
fi

"$TARGET_DIR/install.sh" esp32s3
printf '%s\n' "ESP-IDF $VERSION toolchain is ready."

#!/bin/sh
set -eu

umask 077

PYTHON_VERSION="3.12.13"
RELEASE="20260510"

case "$(uname -m)" in
  arm64)
    ASSET_ARCH="aarch64"
    SHA256="5a30271f8d345a5b02b0c9e4e31e0f1e1455a8e4a04fba95cd9762472abc3b17"
    ;;
  x86_64)
    ASSET_ARCH="x86_64"
    SHA256="cd369e76973c3179bc578230d8615ab621968ed758c5e32f636eecef4ad79894"
    ;;
  *)
    printf '%s\n' "Unsupported Mac architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

BASE_DIR="$HOME/.local/share/vibestick/python"
DESTINATION="$BASE_DIR/cpython-$PYTHON_VERSION-macos-$ASSET_ARCH-none"
CURRENT_LINK="$BASE_DIR/cpython-3.12-macos-$ASSET_ARCH-none"
PYTHON_BIN="$DESTINATION/bin/python3.12"
ASSET="cpython-$PYTHON_VERSION+$RELEASE-$ASSET_ARCH-apple-darwin-install_only.tar.gz"
URL="https://github.com/astral-sh/python-build-standalone/releases/download/$RELEASE/$ASSET"
LOCK_DIR="$BASE_DIR/.install.lock"

case "$BASE_DIR" in
  "$HOME"/*) ;;
  *)
    printf '%s\n' "Python runtime directory must be inside the current user's home directory." >&2
    exit 1
    ;;
esac
if [ -L "$BASE_DIR" ] || [ -L "$DESTINATION" ]; then
  printf '%s\n' "Refusing to install the Python runtime through a symbolic link." >&2
  exit 1
fi

mkdir -p "$BASE_DIR"
chmod 700 "$BASE_DIR"

if [ -x "$PYTHON_BIN" ] && "$PYTHON_BIN" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)' >/dev/null 2>&1; then
  printf '%s\n' "Python runtime is already ready."
  exit 0
fi

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  printf '%s\n' "Another Python runtime installation is already running." >&2
  exit 1
fi

TEMP_DIR="$(mktemp -d "$BASE_DIR/.install.XXXXXX")"
cleanup() {
  rm -rf "$TEMP_DIR"
  rmdir "$LOCK_DIR" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

ARCHIVE="$TEMP_DIR/$ASSET"
printf '%s\n' "Downloading the VibeStick Python runtime..."
curl --fail --location --retry 3 --connect-timeout 20 --output "$ARCHIVE" "$URL"
printf '%s  %s\n' "$SHA256" "$ARCHIVE" | shasum -a 256 --check

mkdir "$TEMP_DIR/unpacked"
tar -xzf "$ARCHIVE" -C "$TEMP_DIR/unpacked"
if [ ! -x "$TEMP_DIR/unpacked/python/bin/python3.12" ]; then
  printf '%s\n' "Downloaded Python runtime has an unexpected layout." >&2
  exit 1
fi
if ! "$TEMP_DIR/unpacked/python/bin/python3.12" -c 'import sys; raise SystemExit(0 if sys.version_info[:2] == (3, 12) else 1)' >/dev/null 2>&1; then
  printf '%s\n' "Downloaded Python runtime failed its version check." >&2
  exit 1
fi

STAGED_DESTINATION="$BASE_DIR/.cpython-$PYTHON_VERSION-macos-$ASSET_ARCH-none.$$"
mv "$TEMP_DIR/unpacked/python" "$STAGED_DESTINATION"
if [ -e "$DESTINATION" ]; then
  rm -rf "$STAGED_DESTINATION"
else
  mv "$STAGED_DESTINATION" "$DESTINATION"
fi

TEMP_LINK="$BASE_DIR/.current.$$"
ln -s "$DESTINATION" "$TEMP_LINK"
mv -f "$TEMP_LINK" "$CURRENT_LINK"

printf '%s\n' "Python $PYTHON_VERSION is ready."

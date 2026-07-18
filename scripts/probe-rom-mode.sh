#!/usr/bin/env sh
set -eu

# Stable result codes consumed by the macOS installer:
#   0  ESP32-S3 ROM downloader is ready
#   10 device is running normal firmware / did not answer ROM sync
#   11 connected ROM is not an ESP32-S3
#   12 a RAM flasher stub answered instead of the ROM downloader
#   13 serial port is busy or permission was denied
#   14 device disappeared or its USB identity changed
#   15 secure-download mode is enabled
#   20 invalid invocation, unsafe runtime, or unexpected probe failure

idf_export=""
serial_port=""
expected_serial=""

usage() {
  printf '%s\n' \
    "Usage: scripts/probe-rom-mode.sh --export /path/to/export.sh --port /dev/cu.usbmodem... --serial USB_SERIAL" >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --export|--port|--serial)
      option="$1"
      shift
      if [ "$#" -eq 0 ]; then
        usage
        exit 20
      fi
      case "$option" in
        --export) idf_export="$1" ;;
        --port) serial_port="$1" ;;
        --serial) expected_serial="$1" ;;
      esac
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 20
      ;;
  esac
  shift
done

case "$idf_export" in
  /*) ;;
  *)
    printf '%s\n' "ESP-IDF export path must be absolute." >&2
    exit 20
    ;;
esac
if [ ! -f "$idf_export" ] || [ -L "$idf_export" ]; then
  printf '%s\n' "ESP-IDF export.sh was not found or is unsafe." >&2
  exit 20
fi

case "$serial_port" in
  /dev/cu.*) ;;
  *)
    printf '%s\n' "A macOS callout serial device path is required." >&2
    exit 14
    ;;
esac
if [ ! -c "$serial_port" ] || [ -L "$serial_port" ]; then
  printf '%s\n' "The serial device is unavailable or unsafe." >&2
  exit 14
fi
if [ -z "$expected_serial" ]; then
  printf '%s\n' "The expected USB serial number is required." >&2
  exit 20
fi

idf_root="$(CDPATH= cd -P -- "$(dirname -- "$idf_export")" && pwd)"
canonical_export="$idf_root/$(basename -- "$idf_export")"
if [ "$canonical_export" != "$idf_export" ]; then
  printf '%s\n' "ESP-IDF export path must be canonical." >&2
  exit 20
fi

version_file="$idf_root/tools/cmake/version.cmake"
if [ ! -f "$version_file" ] || [ -L "$version_file" ]; then
  printf '%s\n' "ESP-IDF version metadata is missing or unsafe." >&2
  exit 20
fi
idf_version="$(awk '
  /set\(IDF_VERSION_MAJOR / { major = $2; gsub(/\)/, "", major) }
  /set\(IDF_VERSION_MINOR / { minor = $2; gsub(/\)/, "", minor) }
  /set\(IDF_VERSION_PATCH / { patch = $2; gsub(/\)/, "", patch) }
  END { if (major != "" && minor != "" && patch != "") print major "." minor "." patch }
' "$version_file" 2>/dev/null || true)"
case "$idf_version" in
  5.5.*) ;;
  *)
    printf '%s\n' "VibeStick requires ESP-IDF 5.5.x; found ${idf_version:-an unknown version}." >&2
    exit 20
    ;;
esac

if ! . "$idf_export" >/dev/null 2>&1; then
  printf '%s\n' "ESP-IDF 5.5.x could not initialize its Python environment." >&2
  exit 20
fi
python_bin="$(command -v python 2>/dev/null || true)"
case "$python_bin" in
  /*) ;;
  *)
    printf '%s\n' "ESP-IDF did not provide an absolute Python executable." >&2
    exit 20
    ;;
esac
if [ ! -x "$python_bin" ]; then
  printf '%s\n' "ESP-IDF Python is unavailable." >&2
  exit 20
fi

exec "$python_bin" - "$serial_port" "$expected_serial" <<'PY'
import errno
import os
import re
import sys


READY = 0
NOT_IN_ROM = 10
WRONG_CHIP = 11
STUB_LOADER = 12
PORT_BUSY = 13
IDENTITY_CHANGED = 14
SECURE_DOWNLOAD = 15
INTERNAL_ERROR = 20
EXPECTED_VID = 0x303A
EXPECTED_PID = 0x1001
EXPECTED_CHIP_ID = 9


def normalize_serial(value):
    if not value:
        return ""
    return "".join(character for character in value.casefold() if character.isalnum())


def matching_usb_port(device, expected_serial):
    from serial.tools import list_ports

    normalized_expected = normalize_serial(expected_serial)
    if not normalized_expected:
        return False
    for candidate in list_ports.comports():
        if candidate.device != device:
            continue
        return (
            candidate.vid == EXPECTED_VID
            and candidate.pid == EXPECTED_PID
            and normalize_serial(candidate.serial_number) == normalized_expected
        )
    return False


def exception_errno(error):
    current = error
    seen = set()
    while current is not None and id(current) not in seen:
        seen.add(id(current))
        value = getattr(current, "errno", None)
        if isinstance(value, int):
            return value
        current = getattr(current, "__cause__", None) or getattr(current, "__context__", None)
    match = re.search(r"\[Errno\s+(\d+)\]", str(error))
    return int(match.group(1)) if match else None


def classify_serial_error(error):
    code = exception_errno(error)
    message = str(error).casefold()
    if code in (errno.EBUSY, errno.EACCES, errno.EPERM) or any(
        marker in message
        for marker in ("resource busy", "permission denied", "access is denied")
    ):
        return PORT_BUSY
    if code in (errno.ENOENT, errno.ENXIO, errno.ENODEV) or any(
        marker in message
        for marker in ("no such file", "device disconnected", "doesn't exist")
    ):
        return IDENTITY_CHANGED
    return INTERNAL_ERROR


def probe(device, expected_serial):
    try:
        import serial
        from esptool.targets.esp32s3 import ESP32S3ROM
        from esptool.util import FatalError
    except (ImportError, AttributeError) as error:
        print(f"ESP-IDF Python is missing a compatible pyserial/esptool API: {error}", file=sys.stderr)
        return INTERNAL_ERROR

    try:
        if not matching_usb_port(device, expected_serial):
            return IDENTITY_CHANGED
    except Exception as error:
        print(f"Could not enumerate the serial device: {error}", file=sys.stderr)
        return INTERNAL_ERROR

    port = None
    loader = None
    result = INTERNAL_ERROR
    try:
        # Construct the pyserial object without opening it. Setting both active-low
        # control lines to their inactive levels first guarantees this read-only
        # probe cannot reset the StickS3 or pull GPIO0 into download mode.
        port = serial.serial_for_url(device, exclusive=True, do_not_open=True)
        port.dtr = False
        port.rts = False
        port.open()

        loader = ESP32S3ROM(port)
        try:
            loader.connect(
                mode="no_reset",
                attempts=1,
                detecting=True,
                warnings=False,
            )
        except FatalError:
            result = NOT_IN_ROM
        else:
            if getattr(loader, "IS_STUB", False) or getattr(loader, "sync_stub_detected", False):
                result = STUB_LOADER
            else:
                security_info = loader.get_security_info(cache=False)
                if security_info.get("chip_id") != EXPECTED_CHIP_ID:
                    result = WRONG_CHIP
                elif security_info.get("parsed_flags", {}).get("SECURE_DOWNLOAD_ENABLE", False):
                    result = SECURE_DOWNLOAD
                else:
                    result = READY
    except serial.SerialException as error:
        result = classify_serial_error(error)
    except OSError as error:
        result = classify_serial_error(error)
    except Exception as error:
        print(f"Unexpected ESP32-S3 ROM probe failure: {error}", file=sys.stderr)
        result = INTERNAL_ERROR
    finally:
        active_port = getattr(loader, "_port", None) if loader is not None else port
        if active_port is not None:
            try:
                if getattr(active_port, "is_open", False):
                    active_port.dtr = False
                    active_port.rts = False
                    active_port.close()
            except Exception:
                pass

    try:
        if not matching_usb_port(device, expected_serial):
            return IDENTITY_CHANGED
    except Exception as error:
        print(f"Could not re-enumerate the serial device: {error}", file=sys.stderr)
        return INTERNAL_ERROR
    return result


def main():
    device = sys.argv[1]
    expected_serial = sys.argv[2]
    if not os.path.isabs(device) or not device.startswith("/dev/cu."):
        return IDENTITY_CHANGED
    return probe(device, expected_serial)


raise SystemExit(main())
PY

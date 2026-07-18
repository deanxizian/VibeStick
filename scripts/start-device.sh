#!/usr/bin/env sh
set -eu

idf_export=""
serial_port=""

usage() {
  printf '%s\n' "Usage: scripts/start-device.sh --export /path/to/export.sh --port /dev/cu.usbmodem..." >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --export|--port)
      option="$1"
      shift
      if [ "$#" -eq 0 ]; then
        usage
        exit 2
      fi
      case "$option" in
        --export) idf_export="$1" ;;
        --port) serial_port="$1" ;;
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

case "$idf_export" in
  /*) ;;
  *)
    printf '%s\n' "ESP-IDF export path must be absolute." >&2
    exit 1
    ;;
esac
if [ ! -f "$idf_export" ] || [ -L "$idf_export" ]; then
  printf '%s\n' "ESP-IDF export.sh was not found or is unsafe." >&2
  exit 1
fi

case "$serial_port" in
  /dev/cu.*|/dev/tty.*) ;;
  *)
    printf '%s\n' "A macOS serial device path is required." >&2
    exit 1
    ;;
esac
if [ ! -c "$serial_port" ] || [ -L "$serial_port" ]; then
  printf '%s\n' "The serial device is unavailable or unsafe." >&2
  exit 1
fi

idf_root="$(CDPATH= cd -- "$(dirname -- "$idf_export")" && pwd)"
idf_version="$(awk '
  /set\(IDF_VERSION_MAJOR / { major = $2; gsub(/\)/, "", major) }
  /set\(IDF_VERSION_MINOR / { minor = $2; gsub(/\)/, "", minor) }
  /set\(IDF_VERSION_PATCH / { patch = $2; gsub(/\)/, "", patch) }
  END { if (major != "" && minor != "" && patch != "") print major "." minor "." patch }
' "$idf_root/tools/cmake/version.cmake" 2>/dev/null || true)"
case "$idf_version" in
  5.5.*) ;;
  *)
    printf '%s\n' "VibeStick requires ESP-IDF 5.5.x; found ${idf_version:-an unknown version}." >&2
    exit 1
    ;;
esac

. "$idf_export" >/dev/null
python_bin="$(command -v python 2>/dev/null || true)"
esptool_path="$idf_root/components/esptool_py/esptool/esptool.py"
if [ -z "$python_bin" ] || [ ! -x "$python_bin" ] || [ ! -f "$esptool_path" ]; then
  printf '%s\n' "ESP-IDF could not provide Python and esptool." >&2
  exit 1
fi

# ESP32-S3's native USB-Serial/JTAG peripheral can leave the force-download
# latch asserted after flashing. A regular RTS hard reset then returns to the
# ROM downloader. Clear that latch while connected to the ROM and perform a
# normal boot reset with GPIO0 released before toggling EN.
"$python_bin" "$esptool_path" \
  --chip esp32s3 \
  --port "$serial_port" \
  --before default_reset \
  --after no_reset \
  --no-stub \
  write_mem 0x6000812c 0x0 0x1

"$python_bin" - "$serial_port" <<'PY'
import sys
import time

import serial


serial_path = sys.argv[1]
deadline = time.monotonic() + 5
port = serial.Serial()
port.port = serial_path
port.baudrate = 115200
port.timeout = 0.2
# Set the idle levels before opening the native USB serial port so opening it
# cannot hold GPIO0 low and select download mode during the next reset.
port.dtr = False
port.rts = False

while True:
    try:
        port.open()
        break
    except (OSError, serial.SerialException):
        if time.monotonic() >= deadline:
            raise
        time.sleep(0.1)

try:
    port.reset_input_buffer()
    port.setDTR(False)  # GPIO0 high: boot from SPI flash
    port.setRTS(True)   # EN low: hold the chip in reset
    time.sleep(0.25)
    port.setRTS(False)  # EN high: leave reset
    port.setDTR(False)
    time.sleep(0.25)
finally:
    if port.is_open:
        port.setDTR(False)
        port.setRTS(False)
        port.close()
PY

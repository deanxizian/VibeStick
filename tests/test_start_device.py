from pathlib import Path
import unittest


PROJECT_ROOT = Path(__file__).resolve().parents[1]


class StartDeviceScriptTests(unittest.TestCase):
    def test_releases_esp32s3_from_native_usb_download_mode(self) -> None:
        script = (PROJECT_ROOT / "scripts/start-device.sh").read_text(encoding="utf-8")

        self.assertIn("--before default_reset", script)
        self.assertIn("--after no_reset", script)
        self.assertIn("--no-stub", script)
        self.assertIn("write_mem 0x6000812c 0x0 0x1", script)
        self.assertNotIn("--after hard_reset", script)

        release_boot_pin = script.index("port.setDTR(False)  # GPIO0 high")
        enter_reset = script.index("port.setRTS(True)   # EN low")
        leave_reset = script.index("port.setRTS(False)  # EN high")
        self.assertLess(release_boot_pin, enter_reset)
        self.assertLess(enter_reset, leave_reset)


if __name__ == "__main__":
    unittest.main()

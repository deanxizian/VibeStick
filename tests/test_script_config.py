import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
VALID_TOKEN = "a" * 40


class ScriptConfigTests(unittest.TestCase):
    def _project(self, temporary: str) -> Path:
        root = Path(temporary) / "project"
        (root / "scripts").mkdir(parents=True)
        (root / "firmware/sticks3/include").mkdir(parents=True)
        for name in ("setup.sh", "dev.sh"):
            shutil.copy2(PROJECT_ROOT / "scripts" / name, root / "scripts" / name)
        (root / ".env.example").write_text(
            f"VIBE_STICK_BRIDGE_TOKEN='{VALID_TOKEN}'\n",
            encoding="utf-8",
        )
        (root / "firmware/sticks3/include/vibe_stick_secrets.example.h").write_text(
            self._valid_secrets(),
            encoding="utf-8",
        )
        return root

    @staticmethod
    def _valid_secrets() -> str:
        return "\n".join(
            (
                '#define VIBE_STICK_WIFI_SSID "wifi"',
                '#define VIBE_STICK_WIFI_PASSWORD "password"',
                '#define VIBE_STICK_BRIDGE_HOST "192.168.1.2"',
                f'#define VIBE_STICK_BRIDGE_TOKEN "{VALID_TOKEN}"',
                "",
            )
        )

    def _run(self, root: Path, script: str) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment["HOME"] = str(root.parent / "home")
        return subprocess.run(
            ["/bin/sh", str(root / "scripts" / script)],
            cwd=root,
            env=environment,
            input="",
            text=True,
            capture_output=True,
            check=False,
            timeout=5,
        )

    def test_setup_rejects_duplicate_dotenv_keys(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = self._project(temporary)
            (root / ".env").write_text(
                "VIBE_STICK_BRIDGE_TOKEN='first'\n"
                "VIBE_STICK_BRIDGE_TOKEN='second'\n",
                encoding="utf-8",
            )
            (root / "firmware/sticks3/include/vibe_stick_secrets.h").write_text(
                self._valid_secrets(),
                encoding="utf-8",
            )

            result = self._run(root, "setup.sh")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Duplicate .env key", result.stderr)

    def test_setup_rejects_duplicate_firmware_defines(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = self._project(temporary)
            (root / ".env").write_text(
                f"VIBE_STICK_BRIDGE_TOKEN='{VALID_TOKEN}'\n",
                encoding="utf-8",
            )
            secrets = self._valid_secrets() + '#define VIBE_STICK_BRIDGE_HOST "192.168.1.3"\n'
            (root / "firmware/sticks3/include/vibe_stick_secrets.h").write_text(
                secrets,
                encoding="utf-8",
            )

            result = self._run(root, "setup.sh")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Duplicate firmware secret define", result.stderr)

    def test_dev_rejects_duplicate_dotenv_before_starting_bridge(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = self._project(temporary)
            (root / ".env").write_text(
                f"VIBE_STICK_BRIDGE_TOKEN='{VALID_TOKEN}'\n"
                f"VIBE_STICK_BRIDGE_TOKEN='{'b' * 40}'\n",
                encoding="utf-8",
            )

            result = self._run(root, "dev.sh")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Duplicate .env key", result.stderr)


if __name__ == "__main__":
    unittest.main()

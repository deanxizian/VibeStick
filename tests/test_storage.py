import os
import stat
import tempfile
import unittest
from pathlib import Path

from vibe_stick.config.storage import atomic_write_text, ensure_private_dir


class PrivateStorageTests(unittest.TestCase):
    def test_private_directory_and_atomic_file_modes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp) / "private"
            path = directory / "state.json"

            ensure_private_dir(directory)
            changed = atomic_write_text(path, '{"ok":true}\n')

            self.assertTrue(changed)
            self.assertEqual(stat.S_IMODE(directory.stat().st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)

    def test_unchanged_write_preserves_mtime(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "quota.json"
            atomic_write_text(path, "same\n")
            first_mtime = path.stat().st_mtime_ns

            changed = atomic_write_text(path, "same\n", skip_if_unchanged=True)

            self.assertFalse(changed)
            self.assertEqual(path.stat().st_mtime_ns, first_mtime)

    def test_atomic_replace_does_not_leave_temp_files(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            path = directory / "state.json"
            atomic_write_text(path, "first\n")
            atomic_write_text(path, "second\n")

            self.assertEqual(path.read_text(), "second\n")
            self.assertEqual(
                [candidate for candidate in directory.iterdir() if candidate != path],
                [],
            )


if __name__ == "__main__":
    unittest.main()

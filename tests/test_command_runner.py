import os
import shlex
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

from vibe_stick import command_runner


class CommandRunnerTests(unittest.TestCase):
    def test_json_hook_preserves_shell_pipeline_configuration(self) -> None:
        with mock.patch.dict(
            os.environ,
            {"VIBE_STICK_TEST_HOOK": "cat | tr a-z A-Z"},
            clear=False,
        ):
            result = command_runner.run_json_command_hook(
                "VIBE_STICK_TEST_HOOK",
                {"message": "hello"},
                timeout=1,
            )

        self.assertIsNotNone(result)
        assert result is not None
        self.assertTrue(result.success)
        self.assertIn('"MESSAGE": "HELLO"', result.stdout)

    def test_oversized_input_is_rejected_before_process_start(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            marker = Path(tmp) / "started"
            command = f"touch {shlex.quote(str(marker))}"

            result = command_runner.run_shell_command(
                command,
                input_text="12345",
                timeout=1,
                max_input_bytes=4,
            )

            self.assertFalse(marker.exists())
        self.assertFalse(result.success)
        self.assertIn("input exceeds 4 bytes", result.error)

    def test_stdout_and_stderr_are_bounded_and_reported(self) -> None:
        script = (
            "import sys; "
            "sys.stdout.write('o' * 4096); "
            "sys.stderr.write('e' * 4096)"
        )
        command = f"{shlex.quote(sys.executable)} -c {shlex.quote(script)}"

        result = command_runner.run_shell_command(
            command,
            input_text="",
            timeout=2,
            max_stdout_bytes=31,
            max_stderr_bytes=17,
        )

        self.assertEqual(result.returncode, 0)
        self.assertFalse(result.success)
        self.assertEqual(len(result.stdout.encode("utf-8")), 31)
        self.assertEqual(len(result.stderr.encode("utf-8")), 17)
        self.assertTrue(result.stdout_truncated)
        self.assertTrue(result.stderr_truncated)
        self.assertIn("stdout exceeds 31 bytes", result.error)
        self.assertIn("stderr exceeds 17 bytes", result.error)

    def test_multibyte_output_remains_within_byte_limit(self) -> None:
        script = "import os; os.write(1, '你'.encode())"
        command = f"{shlex.quote(sys.executable)} -c {shlex.quote(script)}"

        result = command_runner.run_shell_command(
            command,
            input_text="",
            timeout=2,
            max_stdout_bytes=2,
        )

        self.assertLessEqual(len(result.stdout.encode("utf-8")), 2)
        self.assertTrue(result.stdout_truncated)

    @unittest.skipUnless(os.name == "posix", "process-group cleanup requires POSIX")
    def test_timeout_terminates_the_entire_process_group(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            child_pid_path = Path(tmp) / "child.pid"
            quoted_path = shlex.quote(str(child_pid_path))
            command = (
                "trap 'kill \"$child\" 2>/dev/null; wait \"$child\" 2>/dev/null; exit 0' TERM; "
                "sleep 30 & child=$!; "
                f"echo $child > {quoted_path}; "
                "wait $child"
            )

            result = command_runner.run_shell_command(
                command,
                input_text="",
                timeout=0.3,
            )

            self.assertTrue(result.timed_out)
            self.assertTrue(child_pid_path.exists())
            child_pid = int(child_pid_path.read_text().strip())
            deadline = time.monotonic() + 2
            while _process_exists(child_pid) and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertFalse(_process_exists(child_pid))


def _process_exists(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


if __name__ == "__main__":
    unittest.main()

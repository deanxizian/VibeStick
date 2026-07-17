from __future__ import annotations

import json
import math
import os
import signal
import subprocess
import threading
import time
from dataclasses import dataclass
from typing import Any, BinaryIO


MAX_COMMAND_BYTES = 32 * 1024
MAX_COMMAND_INPUT_BYTES = 256 * 1024
MAX_COMMAND_STDOUT_BYTES = 512 * 1024
MAX_COMMAND_STDERR_BYTES = 64 * 1024
COMMAND_TERMINATE_GRACE_SECONDS = 0.1
COMMAND_IO_JOIN_SECONDS = 0.5
_IO_CHUNK_BYTES = 64 * 1024


@dataclass(frozen=True)
class ShellCommandResult:
    returncode: int | None = None
    stdout: str = ""
    stderr: str = ""
    error: str = ""
    timed_out: bool = False
    stdout_truncated: bool = False
    stderr_truncated: bool = False

    @property
    def success(self) -> bool:
        return self.returncode == 0 and not self.error


class _BoundedCapture:
    def __init__(self, limit: int) -> None:
        self.limit = max(0, limit)
        self.data = bytearray()
        self.truncated = False

    def append(self, chunk: bytes) -> None:
        remaining = self.limit - len(self.data)
        if remaining > 0:
            self.data.extend(chunk[:remaining])
        if len(chunk) > max(0, remaining):
            self.truncated = True

    def text(self) -> str:
        # A replacement character can itself encode to more bytes than the
        # incomplete UTF-8 suffix it replaces, breaking the advertised bound.
        return bytes(self.data).decode("utf-8", errors="ignore")


def run_json_command_hook(
    env_name: str,
    payload: dict[str, Any],
    *,
    timeout: float,
    max_input_bytes: int = MAX_COMMAND_INPUT_BYTES,
    max_stdout_bytes: int = MAX_COMMAND_STDOUT_BYTES,
    max_stderr_bytes: int = MAX_COMMAND_STDERR_BYTES,
) -> ShellCommandResult | None:
    """Run a configured JSON hook without allowing unbounded process I/O."""

    command = os.environ.get(env_name, "").strip()
    if not command:
        return None
    try:
        input_text = json.dumps(payload)
    except (RecursionError, TypeError, ValueError):
        return ShellCommandResult(error="Command input could not be serialized")
    return run_shell_command(
        command,
        input_text=input_text,
        timeout=timeout,
        max_input_bytes=max_input_bytes,
        max_stdout_bytes=max_stdout_bytes,
        max_stderr_bytes=max_stderr_bytes,
    )


def run_shell_command(
    command: str,
    *,
    input_text: str,
    timeout: float,
    max_input_bytes: int = MAX_COMMAND_INPUT_BYTES,
    max_stdout_bytes: int = MAX_COMMAND_STDOUT_BYTES,
    max_stderr_bytes: int = MAX_COMMAND_STDERR_BYTES,
) -> ShellCommandResult:
    """Run a shell command in its own process group with bounded captured I/O."""

    command_bytes = command.encode("utf-8", errors="replace")
    if not command_bytes:
        return ShellCommandResult(error="Command configuration was empty")
    if len(command_bytes) > MAX_COMMAND_BYTES:
        return ShellCommandResult(
            error=f"Command configuration exceeds {MAX_COMMAND_BYTES} bytes"
        )
    input_bytes = input_text.encode("utf-8", errors="replace")
    if len(input_bytes) > max(0, max_input_bytes):
        return ShellCommandResult(
            error=f"Command input exceeds {max(0, max_input_bytes)} bytes"
        )
    if not math.isfinite(timeout) or timeout <= 0:
        return ShellCommandResult(error="Command timeout must be positive")

    try:
        process = subprocess.Popen(
            command,
            shell=True,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=os.name == "posix",
            bufsize=0,
        )
    except OSError as exc:
        return ShellCommandResult(
            error=f"Could not start command: {type(exc).__name__}"
        )

    assert process.stdin is not None
    assert process.stdout is not None
    assert process.stderr is not None
    stdout = _BoundedCapture(max_stdout_bytes)
    stderr = _BoundedCapture(max_stderr_bytes)
    writer = threading.Thread(
        target=_write_input,
        args=(process.stdin, input_bytes),
        name="vibestick-command-stdin",
        daemon=True,
    )
    stdout_reader = threading.Thread(
        target=_drain_output,
        args=(process.stdout, stdout),
        name="vibestick-command-stdout",
        daemon=True,
    )
    stderr_reader = threading.Thread(
        target=_drain_output,
        args=(process.stderr, stderr),
        name="vibestick-command-stderr",
        daemon=True,
    )
    threads = (writer, stdout_reader, stderr_reader)
    for thread in threads:
        thread.start()

    timed_out = False
    wait_error = ""
    try:
        process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
    except OSError as exc:
        wait_error = f"Command wait failed: {type(exc).__name__}"
    finally:
        # A hook is synchronous by contract. Clean up background descendants
        # even when the shell itself has already exited.
        _terminate_process_group(process)

    for thread in threads:
        thread.join(timeout=COMMAND_IO_JOIN_SECONDS)
    io_incomplete = any(thread.is_alive() for thread in threads)
    for stream in (process.stdin, process.stdout, process.stderr):
        try:
            stream.close()
        except OSError:
            pass
    if io_incomplete:
        for thread in threads:
            thread.join(timeout=0.05)

    errors: list[str] = []
    if timed_out:
        errors.append(f"Command timed out after {timeout:g} seconds")
    if wait_error:
        errors.append(wait_error)
    if stdout.truncated:
        errors.append(f"Command stdout exceeds {max(0, max_stdout_bytes)} bytes")
    if stderr.truncated:
        errors.append(f"Command stderr exceeds {max(0, max_stderr_bytes)} bytes")
    if io_incomplete:
        errors.append("Command I/O did not shut down cleanly")

    return ShellCommandResult(
        returncode=process.returncode,
        stdout=stdout.text(),
        stderr=stderr.text(),
        error="; ".join(errors),
        timed_out=timed_out,
        stdout_truncated=stdout.truncated,
        stderr_truncated=stderr.truncated,
    )


def _write_input(stream: BinaryIO, data: bytes) -> None:
    try:
        view = memoryview(data)
        while view:
            written = stream.write(view[:_IO_CHUNK_BYTES])
            if not written:
                break
            view = view[written:]
        stream.flush()
    except (BrokenPipeError, OSError, ValueError):
        pass
    finally:
        try:
            stream.close()
        except OSError:
            pass


def _drain_output(stream: BinaryIO, capture: _BoundedCapture) -> None:
    try:
        while True:
            chunk = stream.read(_IO_CHUNK_BYTES)
            if not chunk:
                return
            capture.append(chunk)
    except (OSError, ValueError):
        return


def _terminate_process_group(process: subprocess.Popen[bytes]) -> None:
    if os.name != "posix":
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=COMMAND_TERMINATE_GRACE_SECONDS)
            except subprocess.TimeoutExpired:
                process.kill()
        return

    process.poll()
    group_id = process.pid
    if _signal_group(group_id, signal.SIGTERM):
        deadline = time.monotonic() + COMMAND_TERMINATE_GRACE_SECONDS
        while time.monotonic() < deadline:
            process.poll()
            if not _group_exists(group_id):
                break
            time.sleep(0.01)
        if _group_exists(group_id):
            _signal_group(group_id, signal.SIGKILL)

    if process.poll() is None:
        try:
            process.wait(timeout=COMMAND_TERMINATE_GRACE_SECONDS)
        except subprocess.TimeoutExpired:
            process.kill()
            try:
                process.wait(timeout=COMMAND_TERMINATE_GRACE_SECONDS)
            except subprocess.TimeoutExpired:
                pass


def _signal_group(group_id: int, signum: int) -> bool:
    try:
        os.killpg(group_id, signum)
        return True
    except ProcessLookupError:
        return False
    except OSError:
        return False


def _group_exists(group_id: int) -> bool:
    try:
        os.killpg(group_id, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False

from __future__ import annotations

import os
import tempfile
from pathlib import Path


PRIVATE_DIRECTORY_MODE = 0o700
PRIVATE_FILE_MODE = 0o600
PRIVATE_EXECUTABLE_MODE = 0o700


def ensure_private_dir(path: Path) -> Path:
    """Create a local data directory and keep it private to the current user."""

    path.mkdir(parents=True, exist_ok=True, mode=PRIVATE_DIRECTORY_MODE)
    try:
        path.chmod(PRIVATE_DIRECTORY_MODE)
    except OSError:
        pass
    return path


def ensure_private_file(path: Path, *, executable: bool = False) -> None:
    if not path.exists():
        return
    mode = PRIVATE_EXECUTABLE_MODE if executable else PRIVATE_FILE_MODE
    try:
        path.chmod(mode)
    except OSError:
        pass


def atomic_write_text(
    path: Path,
    data: str,
    *,
    encoding: str = "utf-8",
    mode: int = PRIVATE_FILE_MODE,
    skip_if_unchanged: bool = False,
) -> bool:
    """Atomically replace ``path`` and return whether its contents changed."""

    ensure_private_dir(path.parent)
    if skip_if_unchanged:
        try:
            if path.read_text(encoding=encoding) == data:
                ensure_private_file(path, executable=bool(mode & 0o100))
                return False
        except (FileNotFoundError, OSError, UnicodeError):
            pass

    file_descriptor = -1
    temporary_name = ""
    try:
        file_descriptor, temporary_name = tempfile.mkstemp(
            prefix=f".{path.name}.",
            suffix=".tmp",
            dir=path.parent,
        )
        os.fchmod(file_descriptor, mode)
        with os.fdopen(file_descriptor, "w", encoding=encoding) as handle:
            file_descriptor = -1
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_name, path)
        temporary_name = ""
        ensure_private_file(path, executable=bool(mode & 0o100))
        return True
    finally:
        if file_descriptor >= 0:
            os.close(file_descriptor)
        if temporary_name:
            try:
                Path(temporary_name).unlink(missing_ok=True)
            except OSError:
                pass

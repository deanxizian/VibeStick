from __future__ import annotations

import json
import os
import stat as stat_module
import subprocess
import threading
import time
from pathlib import Path
from typing import Any, Callable, Generic, Iterable, TypeVar


T = TypeVar("T")
FileFingerprint = tuple[int, int]
PROCESS_COMMAND_CACHE_SECONDS = 2.0

_PROCESS_COMMAND_LOCK = threading.RLock()
_PROCESS_COMMANDS: tuple[str, ...] | None = None
_PROCESS_COMMANDS_AT = 0.0


def session_files(
    root: Path,
    *,
    max_files: int,
    pattern: str = "*.jsonl",
    accept: Callable[[Path, FileFingerprint], bool] | None = None,
) -> list[Path]:
    """Return the newest session files that still exist and pass ``accept``.

    Session directories are written concurrently by the provider. A file can
    therefore disappear between ``rglob`` and ``stat``; that race should make
    the file ineligible for this observation rather than fail the whole state
    request. The optional predicate is applied before the limit so callers can
    cap root sessions instead of allowing newer subagent files to consume the
    budget.
    """

    if max_files <= 0:
        return []
    try:
        candidates = root.rglob(pattern)
        ranked: list[tuple[int, int, Path]] = []
        for path in candidates:
            try:
                file_stat = path.stat()
            except OSError:
                continue
            if not stat_module.S_ISREG(file_stat.st_mode):
                continue
            ranked.append((file_stat.st_mtime_ns, file_stat.st_size, path))
    except OSError:
        return []

    ranked.sort(key=lambda item: (item[0], str(item[2])), reverse=True)
    selected: list[Path] = []
    for mtime_ns, size, path in ranked:
        if accept is not None:
            try:
                if not accept(path, (mtime_ns, size)):
                    continue
            except OSError:
                continue
        selected.append(path)
        if len(selected) >= max_files:
            break
    return selected


class FileSummaryCache(Generic[T]):
    """Thread-safe cache keyed by path, nanosecond mtime, and file size.

    Missing/fake paths deliberately bypass the cache. This keeps unit tests
    that inject synthetic paths deterministic and also avoids retaining a
    summary when a live session disappears during observation.
    """

    def __init__(self, *, max_entries: int | None = None) -> None:
        self._lock = threading.RLock()
        self._entries: dict[Path, tuple[int, int, T]] = {}
        self._max_entries = max_entries if max_entries is None else max(1, max_entries)

    def get_or_load(self, path: Path, loader: Callable[[], T]) -> T:
        fingerprint = _file_fingerprint(path)
        if fingerprint is None:
            return loader()
        return self.get_or_load_with_fingerprint(path, fingerprint, loader)

    def get_or_load_with_fingerprint(
        self,
        path: Path,
        fingerprint: FileFingerprint,
        loader: Callable[[], T],
    ) -> T:
        """Load using a fingerprint already collected by a directory scan."""

        mtime_ns, size = fingerprint
        with self._lock:
            cached = self._entries.get(path)
            if cached is not None and cached[:2] == fingerprint:
                return cached[2]

            value = loader()
            # Do not cache a summary assembled while the provider was still
            # appending to the file. The next observation will retry it.
            if _file_fingerprint(path) == fingerprint:
                self._entries.pop(path, None)
                self._entries[path] = (mtime_ns, size, value)
                if self._max_entries is not None:
                    while len(self._entries) > self._max_entries:
                        self._entries.pop(next(iter(self._entries)))
            else:
                self._entries.pop(path, None)
            return value

    def retain(self, paths: Iterable[Path]) -> None:
        retained = set(paths)
        with self._lock:
            for path in self._entries.keys() - retained:
                self._entries.pop(path, None)

    def clear(self) -> None:
        with self._lock:
            self._entries.clear()


def _file_fingerprint(path: Path) -> tuple[int, int] | None:
    try:
        stat = path.stat()
    except OSError:
        return None
    return (stat.st_mtime_ns, stat.st_size)


def process_commands(*, ttl_seconds: float = PROCESS_COMMAND_CACHE_SECONDS) -> tuple[str, ...]:
    """Return one short-lived, shared snapshot of local process commands."""

    global _PROCESS_COMMANDS, _PROCESS_COMMANDS_AT
    now = time.monotonic()
    with _PROCESS_COMMAND_LOCK:
        if (
            _PROCESS_COMMANDS is not None
            and now - _PROCESS_COMMANDS_AT < max(0.0, ttl_seconds)
        ):
            return _PROCESS_COMMANDS
        try:
            result = subprocess.run(
                ["ps", "-axo", "command="],
                check=False,
                capture_output=True,
                text=True,
                timeout=2,
            )
        except (OSError, subprocess.TimeoutExpired):
            commands: tuple[str, ...] = ()
        else:
            commands = tuple(result.stdout.splitlines()) if result.returncode == 0 else ()
        _PROCESS_COMMANDS = commands
        _PROCESS_COMMANDS_AT = time.monotonic()
        return commands


def clear_process_command_cache() -> None:
    global _PROCESS_COMMANDS, _PROCESS_COMMANDS_AT
    with _PROCESS_COMMAND_LOCK:
        _PROCESS_COMMANDS = None
        _PROCESS_COMMANDS_AT = 0.0


def tail_json_events(path: Path, *, tail_bytes: int) -> Iterable[dict[str, Any]]:
    try:
        with path.open("rb") as handle:
            handle.seek(0, os.SEEK_END)
            size = handle.tell()
            start = max(0, size - tail_bytes)
            handle.seek(start)
            if start > 0:
                # The seek usually lands inside a JSON line. Discard that
                # fragment so an embedded object cannot be mistaken for an
                # independent provider event.
                handle.readline()
            data = handle.read().decode("utf-8", errors="ignore")
    except OSError:
        return []

    events: list[dict[str, Any]] = []
    for line in data.splitlines():
        if not line.startswith("{"):
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(event, dict):
            events.append(event)
    return events

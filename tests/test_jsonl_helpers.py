import json
import os
import tempfile
import threading
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from unittest import mock

from vibe_stick.providers import _jsonl
from vibe_stick.providers._jsonl import FileSummaryCache, session_files, tail_json_events


class JsonlHelperTests(unittest.TestCase):
    def test_tail_json_events_ignores_partial_and_invalid_lines(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "events.jsonl"
            path.write_text(
                "\n".join(
                    [
                        "not-json",
                        json.dumps({"type": "user", "message": "hello"}),
                        "[1, 2, 3]",
                        "{bad json",
                        json.dumps({"type": "assistant", "message": "done"}),
                    ]
                )
            )

            events = list(tail_json_events(path, tail_bytes=2048))

        self.assertEqual([event["type"] for event in events], ["user", "assistant"])

    def test_tail_json_events_discards_first_partial_line(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "events.jsonl"
            path.write_text(
                json.dumps({"type": "user", "nested": {"type": "fake"}})
                + "\n"
                + json.dumps({"type": "assistant"})
                + "\n"
            )

            events = list(tail_json_events(path, tail_bytes=30))

        self.assertEqual(events, [{"type": "assistant"}])

    def test_session_files_returns_newest_jsonl_files_first(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            older = root / "older.jsonl"
            newer = root / "nested" / "newer.jsonl"
            ignored = root / "ignored.txt"
            newer.parent.mkdir()
            older.write_text("{}\n")
            newer.write_text("{}\n")
            ignored.write_text("{}\n")
            os.utime(older, (1000, 1000))
            os.utime(newer, (2000, 2000))

            files = session_files(root, max_files=1)

        self.assertEqual(files, [newer])

    def test_session_files_skips_file_that_disappears_before_stat(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            live = Path(tmp) / "live.jsonl"
            missing = Path(tmp) / "already-gone.jsonl"
            live.write_text("{}\n")

            class _Root:
                def rglob(self, pattern: str):  # noqa: ANN202
                    self.pattern = pattern
                    return iter((missing, live))

            root = _Root()
            files = session_files(root, max_files=5)  # type: ignore[arg-type]

        self.assertEqual(files, [live])
        self.assertEqual(root.pattern, "*.jsonl")

    def test_session_files_applies_filter_before_limit(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            newer_subagent = root / "newer-subagent.jsonl"
            older_root = root / "older-root.jsonl"
            newer_subagent.write_text("{}\n")
            older_root.write_text("{}\n")
            os.utime(older_root, (1000, 1000))
            os.utime(newer_subagent, (2000, 2000))

            files = session_files(
                root,
                max_files=1,
                accept=lambda path, _fingerprint: "subagent" not in path.name,
            )

        self.assertEqual(files, [older_root])

    def test_file_summary_cache_reuses_unchanged_file_and_invalidates_on_growth(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "session.jsonl"
            path.write_text("{}\n")
            cache: FileSummaryCache[int] = FileSummaryCache()
            calls = 0

            def load() -> int:
                nonlocal calls
                calls += 1
                return calls

            self.assertEqual(cache.get_or_load(path, load), 1)
            self.assertEqual(cache.get_or_load(path, load), 1)
            path.write_text("{}\n{}\n")
            self.assertEqual(cache.get_or_load(path, load), 2)

        self.assertEqual(calls, 2)

    def test_file_summary_cache_does_not_cache_fake_path(self) -> None:
        cache: FileSummaryCache[int] = FileSummaryCache()
        path = Path("/tmp/vibestick-test-path-that-does-not-exist.jsonl")
        calls = 0

        def load() -> int:
            nonlocal calls
            calls += 1
            return calls

        self.assertEqual(cache.get_or_load(path, load), 1)
        self.assertEqual(cache.get_or_load(path, load), 2)

    def test_file_summary_cache_serializes_concurrent_loads(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "session.jsonl"
            path.write_text("{}\n")
            cache: FileSummaryCache[int] = FileSummaryCache()
            calls = 0
            calls_lock = threading.Lock()

            def load() -> int:
                nonlocal calls
                with calls_lock:
                    calls += 1
                time.sleep(0.01)
                return 42

            with ThreadPoolExecutor(max_workers=4) as executor:
                results = list(executor.map(lambda _: cache.get_or_load(path, load), range(4)))

        self.assertEqual(results, [42, 42, 42, 42])
        self.assertEqual(calls, 1)

    def test_process_command_snapshot_is_shared_within_ttl(self) -> None:
        completed = mock.Mock(returncode=0, stdout="codex app-server\nclaude\n")
        _jsonl.clear_process_command_cache()
        with mock.patch.object(_jsonl.subprocess, "run", return_value=completed) as run:
            first = _jsonl.process_commands()
            second = _jsonl.process_commands()
        _jsonl.clear_process_command_cache()

        self.assertEqual(first, ("codex app-server", "claude"))
        self.assertEqual(second, first)
        run.assert_called_once()


if __name__ == "__main__":
    unittest.main()

import json
import os
import stat
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from unittest import mock

from vibe_stick.audio import recorder
from vibe_stick.command_runner import ShellCommandResult


class RecordingControllerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.recordings = self.root / "Recordings"
        self.patches = (
            mock.patch.object(recorder, "RECORDINGS_DIR", self.recordings),
            mock.patch.object(recorder, "show_hud"),
            mock.patch.object(recorder, "hide_hud"),
        )
        for patcher in self.patches:
            patcher.start()
        self.controller = recorder.RecordingController(self.root / "recording.json")

    def tearDown(self) -> None:
        for patcher in reversed(self.patches):
            patcher.stop()
        self.temporary.cleanup()

    @staticmethod
    def _request(session_id: str) -> dict[str, object]:
        return {"session_id": session_id, "audio_source": "sticks3_pcm"}

    def test_start_is_idempotent_for_same_session_and_rejects_another(self) -> None:
        first = self.controller.start(self._request("aaaaaaaa"))
        repeated = self.controller.start(self._request("aaaaaaaa"))

        self.assertIs(first, repeated)
        with self.assertRaises(recorder.RecordingConflictError):
            self.controller.start(self._request("bbbbbbbb"))

    def test_abandoned_sticks3_lease_does_not_block_new_session_forever(self) -> None:
        self.controller.start(self._request("aaaaaaaa"))
        self.controller._active_lease_started = (
            recorder.time.monotonic() - recorder.DEFAULT_STICKS3_LEASE_SECONDS - 1
        )

        replacement = self.controller.start(self._request("bbbbbbbb"))

        self.assertEqual(replacement.session_id, "bbbbbbbb")
        self.assertTrue(replacement.active)

    def test_dead_mac_mic_helper_does_not_hold_permanent_lease(self) -> None:
        self.controller.session = recorder.RecordingSession(
            session_id="aaaaaaaa",
            active=True,
            status="recording",
            audio_source="mac_mic",
        )
        with mock.patch.object(self.controller.audio_recorder, "is_running", return_value=False):
            with mock.patch.object(self.controller.audio_recorder, "stop"):
                replacement = self.controller.start(self._request("bbbbbbbb"))

        self.assertEqual(replacement.session_id, "bbbbbbbb")
        self.assertTrue(replacement.active)

    def test_disabled_mac_mic_without_external_recorder_fails_start(self) -> None:
        with mock.patch.dict(
            recorder.os.environ,
            {
                "VIBE_STICK_RECORDING_USE_MAC_MIC": "0",
                "VIBE_STICK_RECORDING_START_CMD": "",
            },
            clear=False,
        ):
            session = self.controller.start({"session_id": "aaaaaaaa"})

        self.assertFalse(session.active)
        self.assertEqual(session.status, "start_failed")

    def test_concurrent_starts_have_one_owner(self) -> None:
        def attempt(session_id: str) -> str:
            try:
                return self.controller.start(self._request(session_id)).session_id
            except recorder.RecordingConflictError:
                return "conflict"

        with ThreadPoolExecutor(max_workers=2) as executor:
            results = list(executor.map(attempt, ("aaaaaaaa", "bbbbbbbb")))

        self.assertEqual(results.count("conflict"), 1)
        self.assertEqual(len([value for value in results if value != "conflict"]), 1)

    def test_audio_upload_is_private_and_public_status_hides_sensitive_fields(self) -> None:
        self.controller.start(self._request("aaaaaaaa"))
        session = self.controller.attach_pcm(
            b"\x00\x00" * 160,
            session_id="aaaaaaaa",
        )

        audio_path = Path(session.audio_file)
        self.assertTrue(audio_path.is_file())
        self.assertEqual(stat.S_IMODE(audio_path.stat().st_mode), 0o600)
        public = session.to_public_jsonable()
        self.assertNotIn("audio_file", public)
        self.assertNotIn("transcript", public)

    def test_public_recording_message_uses_utf8_byte_budget(self) -> None:
        self.controller.session.message = "供" * 1000 + "\ud800"

        public = self.controller.session.to_public_jsonable()

        self.assertLessEqual(len(public["message"].encode("utf-8")), 256)
        self.assertNotIn("\ud800", public["message"])

    def test_invalid_pcm_format_is_rejected_before_wave_writer(self) -> None:
        self.controller.start(self._request("aaaaaaaa"))
        before = self.controller.session.to_jsonable()

        with self.assertRaises(recorder.RecordingRequestError):
            self.controller.attach_pcm(
                b"\x00\x00" * 16,
                session_id="aaaaaaaa",
                channels=100_000_000,
            )

        self.assertEqual(self.controller.session.to_jsonable(), before)
        self.assertFalse(self.recordings.exists())

    def test_invalid_audio_upload_cannot_mutate_active_session(self) -> None:
        self.controller.start(self._request("aaaaaaaa"))
        before = self.controller.session.to_jsonable()

        invalid_requests = (
            {"pcm": b"", "session_id": "aaaaaaaa"},
            {"pcm": b"\x00", "session_id": "aaaaaaaa"},
            {"pcm": b"\x00\x00", "session_id": "bbbbbbbb"},
        )
        for request in invalid_requests:
            with self.subTest(request=request):
                with self.assertRaises(recorder.RecordingRequestError):
                    self.controller.attach_pcm(**request)
                self.assertEqual(self.controller.session.to_jsonable(), before)
        self.assertFalse(self.recordings.exists())

    def test_audio_upload_requires_valid_session_id(self) -> None:
        self.controller.start(self._request("aaaaaaaa"))

        for session_id in ("", "bad id!"):
            with self.subTest(session_id=session_id):
                with self.assertRaises(recorder.RecordingRequestError):
                    self.controller.attach_pcm(b"\x00\x00", session_id=session_id)

    def test_stop_rejects_another_session(self) -> None:
        self.controller.start(self._request("aaaaaaaa"))

        with self.assertRaises(recorder.RecordingConflictError):
            self.controller.stop({"session_id": "bbbbbbbb"})

        self.assertTrue(self.controller.session.active)

    def test_active_stop_requires_session_id(self) -> None:
        self.controller.start(self._request("aaaaaaaa"))

        with self.assertRaises(recorder.RecordingRequestError):
            self.controller.stop({})

    def test_empty_stop_hook_does_not_fall_through_to_second_transcriber(self) -> None:
        self.controller.start(self._request("aaaaaaaa"))
        with mock.patch.object(
            recorder,
            "_run_command_hook",
            return_value=(True, "", ""),
        ), mock.patch.object(self.controller.transcriber, "transcribe") as transcribe:
            session = self.controller.stop({"session_id": "aaaaaaaa"})

        self.assertEqual(session.status, "stop_failed")
        transcribe.assert_not_called()

    def test_unexpected_stop_error_becomes_terminal_and_retry_is_idempotent(self) -> None:
        self.controller.start(self._request("aaaaaaaa"))
        with mock.patch.object(
            self.controller.audio_recorder,
            "stop",
            side_effect=RuntimeError("helper exploded"),
        ):
            session = self.controller.stop({"session_id": "aaaaaaaa"})

        self.assertFalse(session.active)
        self.assertEqual(session.status, "stop_failed")
        persisted = json.loads((self.root / "recording.json").read_text())
        self.assertEqual(persisted["status"], "stop_failed")

        repeated = self.controller.stop({"session_id": "aaaaaaaa"})
        self.assertIs(repeated, session)
        self.assertEqual(repeated.status, "stop_failed")

    def test_restart_during_stop_recovers_durable_audio_for_retry(self) -> None:
        audio_path = self.recordings / "aaaaaaaa.wav"
        audio_path.parent.mkdir()
        audio_path.write_bytes(b"durable-audio")
        state_path = self.root / "recording.json"
        state_path.write_text(
            json.dumps(
                {
                    "session_id": "aaaaaaaa",
                    "active": False,
                    "started_at": "2026-07-17T10:00:00",
                    "stopped_at": "2026-07-17T10:00:01",
                    "status": "stopping",
                    "audio_source": "sticks3_pcm",
                    "audio_file": str(audio_path),
                }
            )
        )

        restarted = recorder.RecordingController(state_path)
        self.assertEqual(restarted.session.status, "interrupted")

        session = restarted.stop(
            {
                "session_id": "aaaaaaaa",
                "text": "recovered transcript",
                "paste": False,
            }
        )
        self.assertEqual(session.status, "transcribed")

    def test_recording_hook_timeouts_fit_firmware_request_budget(self) -> None:
        with mock.patch.dict(
            recorder.os.environ,
            {
                "VIBE_STICK_RECORDING_START_TIMEOUT_SECONDS": "99",
                "VIBE_STICK_RECORDING_STOP_TIMEOUT_SECONDS": "99",
            },
        ):
            self.assertEqual(recorder._start_hook_timeout_seconds(), 2)
            self.assertEqual(recorder._stop_hook_timeout_seconds(), 18)

    def test_recording_hook_uses_shared_bounded_runner_failure(self) -> None:
        with mock.patch.object(
            recorder,
            "run_json_command_hook",
            return_value=ShellCommandResult(
                returncode=-15,
                error="Command timed out after 2 seconds",
                timed_out=True,
            ),
        ) as run:
            result = recorder._run_command_hook(
                "VIBE_STICK_RECORDING_STOP_CMD",
                {"session_id": "aaaaaaaa"},
                timeout=2,
            )

        self.assertEqual(
            result,
            (False, "", "Command timed out after 2 seconds"),
        )
        run.assert_called_once_with(
            "VIBE_STICK_RECORDING_STOP_CMD",
            {"session_id": "aaaaaaaa"},
            timeout=2,
        )

    def test_transcript_is_not_persisted_by_default(self) -> None:
        self.controller.session.transcript = "private transcript"
        with mock.patch.dict(recorder.os.environ, {}, clear=True):
            self.controller._save()

        payload = json.loads((self.root / "recording.json").read_text())
        self.assertEqual(payload["transcript"], "")

    def test_restart_releases_stale_session_and_same_stick_upload_can_recover(self) -> None:
        state_path = self.root / "recording.json"
        state_path.write_text(
            json.dumps(
                {
                    "session_id": "aaaaaaaa",
                    "active": True,
                    "started_at": "2026-07-17T10:00:00",
                    "status": "recording",
                    "audio_source": "sticks3_pcm",
                }
            )
        )

        restarted = recorder.RecordingController(state_path)
        self.assertFalse(restarted.session.active)
        self.assertEqual(restarted.session.status, "interrupted")

        recovered = restarted.attach_pcm(
            b"\x00\x00" * 160,
            session_id="aaaaaaaa",
        )
        self.assertTrue(recovered.active)
        self.assertEqual(recovered.status, "recording")

    def test_non_object_persisted_state_is_ignored(self) -> None:
        state_path = self.root / "recording.json"
        state_path.write_text("[]")

        restarted = recorder.RecordingController(state_path)

        self.assertEqual(restarted.session, recorder.RecordingSession())

    def test_restart_after_upload_can_resume_stop_from_durable_audio(self) -> None:
        audio_path = self.recordings / "aaaaaaaa.wav"
        audio_path.parent.mkdir()
        audio_path.write_bytes(b"durable-audio")
        state_path = self.root / "recording.json"
        state_path.write_text(
            json.dumps(
                {
                    "session_id": "aaaaaaaa",
                    "active": True,
                    "started_at": "2026-07-17T10:00:00",
                    "status": "recording",
                    "audio_source": "sticks3_pcm",
                    "audio_file": str(audio_path),
                }
            )
        )
        restarted = recorder.RecordingController(state_path)

        session = restarted.stop(
            {
                "session_id": "aaaaaaaa",
                "text": "recovered transcript",
                "paste": False,
            }
        )

        self.assertEqual(session.status, "transcribed")
        self.assertEqual(session.transcript, "recovered transcript")

    def test_restart_preserves_interrupted_audio_even_with_zero_retention(self) -> None:
        audio_path = self.recordings / "aaaaaaaa.wav"
        audio_path.parent.mkdir()
        audio_path.write_bytes(b"durable-audio")
        state_path = self.root / "recording.json"
        state_path.write_text(
            json.dumps(
                {
                    "session_id": "aaaaaaaa",
                    "active": True,
                    "status": "recording",
                    "audio_source": "sticks3_pcm",
                    "audio_file": str(audio_path),
                }
            )
        )

        with mock.patch.dict(recorder.os.environ, {"VIBE_STICK_RECORDING_RETENTION_DAYS": "0"}):
            restarted = recorder.RecordingController(state_path)

        self.assertEqual(restarted.session.status, "interrupted")
        self.assertTrue(audio_path.exists())

    def test_interrupted_stop_without_audio_reports_failure(self) -> None:
        self.controller.session = recorder.RecordingSession(
            session_id="aaaaaaaa",
            active=False,
            status="interrupted",
            audio_source="sticks3_pcm",
        )

        session = self.controller.stop({"session_id": "aaaaaaaa"})

        self.assertEqual(session.status, "stop_failed")

    def test_retention_runs_during_long_lived_process(self) -> None:
        old_audio = self.recordings / "old.wav"
        old_audio.parent.mkdir()
        old_audio.write_bytes(b"old")
        old_time = recorder.time.time() - 9 * 86400
        os.utime(old_audio, (old_time, old_time))

        self.controller.start(self._request("aaaaaaaa"))

        self.assertFalse(old_audio.exists())

    def test_late_audio_retry_cannot_reactivate_completed_session(self) -> None:
        self.controller.session = recorder.RecordingSession(
            session_id="aaaaaaaa",
            active=False,
            stopped_at="2026-07-17T10:01:00",
            status="pasted",
            transcript="already pasted",
            pasted=True,
            audio_source="sticks3_pcm",
        )

        session = self.controller.attach_pcm(
            b"\x00\x00" * 160,
            session_id="aaaaaaaa",
        )
        with mock.patch.object(self.controller.transcriber, "transcribe") as transcribe:
            stopped = self.controller.stop({"session_id": "aaaaaaaa"})

        self.assertFalse(session.active)
        self.assertEqual(session.status, "pasted")
        self.assertIs(stopped, session)
        transcribe.assert_not_called()

    def test_restart_during_paste_suppresses_ambiguous_replay(self) -> None:
        state_path = self.root / "recording.json"
        state_path.write_text(
            json.dumps(
                {
                    "session_id": "aaaaaaaa",
                    "active": False,
                    "stopped_at": "2026-07-17T10:01:00",
                    "status": "pasting",
                    "audio_source": "sticks3_pcm",
                }
            )
        )

        restarted = recorder.RecordingController(state_path)
        with mock.patch.object(restarted.transcriber, "transcribe") as transcribe:
            session = restarted.stop({"session_id": "aaaaaaaa"})

        self.assertEqual(session.status, "paste_failed")
        transcribe.assert_not_called()

    def test_paste_guard_is_durable_before_keyboard_injection(self) -> None:
        self.controller.start(self._request("aaaaaaaa"))

        def paste(_text: str, *, press_enter: bool):
            self.assertFalse(press_enter)
            persisted = json.loads((self.root / "recording.json").read_text())
            self.assertEqual(persisted["status"], "pasting")
            return mock.Mock(success=True, message="Pasted")

        with mock.patch.object(
            self.controller.paste_injector,
            "paste",
            side_effect=paste,
        ):
            session = self.controller.stop(
                {
                    "session_id": "aaaaaaaa",
                    "text": "hello",
                    "paste": True,
                }
            )

        self.assertEqual(session.status, "pasted")

    def test_restart_does_not_block_a_new_session(self) -> None:
        state_path = self.root / "recording.json"
        state_path.write_text(
            json.dumps(
                {
                    "session_id": "aaaaaaaa",
                    "active": True,
                    "status": "recording",
                    "audio_source": "mac_mic",
                }
            )
        )

        restarted = recorder.RecordingController(state_path)
        session = restarted.start(self._request("bbbbbbbb"))

        self.assertEqual(session.session_id, "bbbbbbbb")
        self.assertTrue(session.active)


if __name__ == "__main__":
    unittest.main()

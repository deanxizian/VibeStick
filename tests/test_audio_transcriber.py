import os
import tempfile
import threading
import unittest
import urllib.error
from pathlib import Path
from unittest import mock

from vibe_stick.audio import transcriber
from vibe_stick.command_runner import ShellCommandResult


class _FakeResponse:
    def __init__(self, body: bytes) -> None:
        self._body = body

    def __enter__(self) -> "_FakeResponse":
        return self

    def __exit__(self, *exc: object) -> bool:
        return False

    def read(self, limit: int = -1) -> bytes:
        return self._body if limit < 0 else self._body[:limit]


class TranscriberConfigTests(unittest.TestCase):
    def test_local_command_uses_shared_bounded_runner_failure(self) -> None:
        with mock.patch.object(
            transcriber,
            "run_json_command_hook",
            return_value=ShellCommandResult(
                returncode=-9,
                error="Command stdout exceeds 512 bytes",
                stdout_truncated=True,
            ),
        ) as run:
            result = transcriber.TranscriptionAdapter().transcribe(
                {"audio_file": "/tmp/sample.wav"}
            )

        self.assertFalse(result.success)
        self.assertEqual(result.source, "command")
        self.assertIn("stdout exceeds 512 bytes", result.message)
        run.assert_called_once()

    def test_synchronous_command_timeout_is_bounded_by_device_protocol(self) -> None:
        with mock.patch.dict(
            os.environ,
            {"VIBE_STICK_TRANSCRIBE_TIMEOUT_SECONDS": "600"},
            clear=True,
        ):
            self.assertEqual(
                transcriber._command_timeout_seconds(),
                transcriber.MAX_SYNCHRONOUS_TRANSCRIPTION_SECONDS,
            )

    def test_load_asr_config_reads_vibestick_asr_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            app_support = root / "VibeStick"
            app_support.mkdir(parents=True)
            (app_support / "asr.toml").write_text(
                "\n".join(
                    [
                        'asr_provider = "groq"',
                        'groq_api_key = "local-key"',
                        'groq_model = "whisper-large-v3-turbo"',
                        'groq_language = "zh"',
                    ]
                )
            )

            with mock.patch.dict(os.environ, {}, clear=True):
                with mock.patch.object(transcriber, "APP_SUPPORT_DIR", app_support):
                    config = transcriber._load_asr_config()

        self.assertEqual(config["provider"], "groq")
        self.assertEqual(config["base_url"], "https://api.groq.com/openai/v1")
        self.assertEqual(config["api_key"], "local-key")
        self.assertEqual(config["model"], "whisper-large-v3-turbo")
        self.assertEqual(config["language"], "zh")

    def test_environment_api_key_takes_precedence_over_files(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            app_support = root / "VibeStick"
            app_support.mkdir(parents=True)
            (app_support / "config.toml").write_text(
                'asr_provider = "groq"\ngroq_api_key = "local-key"\n'
            )

            with mock.patch.dict(os.environ, {"VIBE_STICK_GROQ_API_KEY": "env-key"}, clear=True):
                with mock.patch.object(transcriber, "APP_SUPPORT_DIR", app_support):
                    config = transcriber._load_asr_config()

        self.assertEqual(config["api_key"], "env-key")

    def test_groq_key_without_generic_provider_uses_groq_preset(self) -> None:
        with mock.patch.dict(
            os.environ,
            {
                "VIBE_STICK_GROQ_API_KEY": "env-key",
                "VIBE_STICK_ASR_PROVIDER": "",
                "VIBE_STICK_ASR_MODEL": transcriber.DEFAULT_ASR_MODEL,
            },
            clear=True,
        ):
            with mock.patch.object(transcriber, "APP_SUPPORT_DIR", Path("/tmp/does-not-exist-vibestick")):
                config = transcriber._load_asr_config()

        self.assertEqual(config["provider"], "groq")
        self.assertEqual(config["api_key"], "env-key")
        self.assertEqual(config["base_url"], transcriber.GROQ_ASR_BASE_URL)

    def test_openai_compatible_toml_config_parses_fields(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            app_support = root / "VibeStick"
            app_support.mkdir(parents=True)
            (app_support / "asr.toml").write_text(
                "\n".join(
                    [
                        'asr_provider = "openai-compatible"',
                        'base_url = "https://asr.example.test/openai/v1/"',
                        'api_key = "local-key"',
                        'model = "whisper-test"',
                        'language = "en"',
                    ]
                )
            )

            with mock.patch.dict(os.environ, {}, clear=True):
                with mock.patch.object(transcriber, "APP_SUPPORT_DIR", app_support):
                    config = transcriber._load_asr_config()

        self.assertEqual(config["provider"], "openai-compatible")
        self.assertEqual(config["base_url"], "https://asr.example.test/openai/v1/")
        self.assertEqual(config["api_key"], "local-key")
        self.assertEqual(config["model"], "whisper-test")
        self.assertEqual(config["language"], "en")

    def test_openai_compatible_url_joins_trailing_slash(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            audio = Path(tmp) / "sample.wav"
            audio.write_bytes(b"RIFFtest")
            seen: dict[str, str] = {}

            def opener(request, timeout=None):  # noqa: ANN001
                seen["url"] = request.full_url
                seen["authorization"] = request.headers.get("Authorization", "")
                return _FakeResponse(b'{"text":"hello"}')

            result = transcriber._transcribe_openai_compatible_once(
                audio,
                {
                    "provider": "openai-compatible",
                    "base_url": "https://asr.example.test/openai/v1/",
                    "api_key": "secret-key",
                    "model": "whisper-test",
                    "language": "en",
                },
                attempt=1,
                opener=opener,
            )

        self.assertTrue(result.success)
        self.assertEqual(result.source, "openai-compatible")
        self.assertEqual(seen["url"], "https://asr.example.test/openai/v1/audio/transcriptions")
        self.assertEqual(seen["authorization"], "Bearer secret-key")

    def test_legacy_groq_config_uses_openai_compatible_endpoint(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            audio = Path(tmp) / "sample.wav"
            audio.write_bytes(b"RIFFtest")
            seen: dict[str, str] = {}

            def opener(request, timeout=None):  # noqa: ANN001
                seen["url"] = request.full_url
                return _FakeResponse(b'{"text":"hello"}')

            result = transcriber._transcribe_openai_compatible_once(
                audio,
                {
                    "provider": "groq",
                    "base_url": transcriber.GROQ_ASR_BASE_URL,
                    "api_key": "secret-key",
                    "model": "whisper-large-v3-turbo",
                    "language": "zh",
                },
                attempt=1,
                opener=opener,
            )

        self.assertTrue(result.success)
        self.assertEqual(result.source, "groq")
        self.assertEqual(seen["url"], "https://api.groq.com/openai/v1/audio/transcriptions")

    def test_missing_openai_compatible_key_fails_gracefully(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            app_support = root / "VibeStick"
            app_support.mkdir(parents=True)
            (app_support / "asr.toml").write_text(
                "\n".join(
                    [
                        'asr_provider = "openai-compatible"',
                        'base_url = "https://asr.example.test/openai/v1"',
                    ]
                )
            )
            audio = root / "sample.wav"
            audio.write_bytes(b"RIFFtest")

            with mock.patch.dict(os.environ, {}, clear=True):
                with mock.patch.object(transcriber, "APP_SUPPORT_DIR", app_support):
                    result = transcriber.TranscriptionAdapter().transcribe({"audio_file": str(audio)})

        self.assertFalse(result.success)
        self.assertEqual(result.source, "none")
        self.assertEqual(result.message, "No transcription adapter configured")

    def test_non_object_or_non_utf8_asr_response_fails_gracefully(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            audio = Path(tmp) / "sample.wav"
            audio.write_bytes(b"RIFFtest")
            config = {
                "provider": "openai-compatible",
                "base_url": "https://asr.example.test/v1",
                "api_key": "secret-key",
                "model": "whisper-test",
                "language": "zh",
            }
            for body in (b"[]", b'{"text":["not-a-string"]}', b"\xff"):
                with self.subTest(body=body):
                    result = transcriber._transcribe_openai_compatible_once(
                        audio,
                        config,
                        attempt=1,
                        opener=lambda request, timeout=None, body=body: _FakeResponse(body),
                    )
                    self.assertFalse(result.success)

    def test_oversized_asr_response_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            audio = Path(tmp) / "sample.wav"
            audio.write_bytes(b"RIFFtest")
            body = b"x" * (transcriber.MAX_ASR_RESPONSE_BYTES + 1)
            result = transcriber._transcribe_openai_compatible_once(
                audio,
                {
                    "provider": "openai-compatible",
                    "base_url": "https://asr.example.test/v1",
                    "api_key": "secret-key",
                    "model": "whisper-test",
                    "language": "zh",
                },
                attempt=1,
                opener=lambda request, timeout=None: _FakeResponse(body),
            )

        self.assertFalse(result.success)
        self.assertIn("too large", result.message)

    def test_openai_compatible_transcription_has_hard_wall_clock_deadline(self) -> None:
        release = threading.Event()
        worker_finished = threading.Event()
        slots = threading.BoundedSemaphore(1)

        def blocking(_audio_file, _config):
            release.wait(timeout=1)
            worker_finished.set()
            return transcriber.TranscriptionResult(text="late", success=True)

        with mock.patch.object(transcriber, "_ASR_WORKER_SLOTS", slots):
            with mock.patch.object(transcriber, "MAX_SYNCHRONOUS_TRANSCRIPTION_SECONDS", 0.01):
                with mock.patch.object(
                    transcriber,
                    "_transcribe_openai_compatible_blocking",
                    side_effect=blocking,
                ):
                    result = transcriber._transcribe_openai_compatible(
                        Path("unused.wav"),
                        {"provider": "openai-compatible"},
                    )
                    busy = transcriber._transcribe_openai_compatible(
                        Path("unused.wav"),
                        {"provider": "openai-compatible"},
                    )
                    release.set()
                    self.assertTrue(worker_finished.wait(timeout=1))

        self.assertFalse(result.success)
        self.assertIn("deadline", result.message)
        self.assertFalse(busy.success)
        self.assertIn("busy", busy.message)

    def test_http_error_body_is_closed_without_being_read(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            audio = Path(tmp) / "sample.wav"
            audio.write_bytes(b"RIFFtest")
            error = urllib.error.HTTPError(
                "https://asr.example.test/v1/audio/transcriptions",
                429,
                "Too Many Requests",
                {},
                None,
            )
            error.close = mock.Mock()
            error.read = mock.Mock(side_effect=RuntimeError("must not read"))

            result = transcriber._transcribe_openai_compatible_once(
                audio,
                {
                    "provider": "openai-compatible",
                    "base_url": "https://asr.example.test/v1",
                    "api_key": "secret-key",
                    "model": "whisper-test",
                    "language": "zh",
                },
                attempt=1,
                opener=mock.Mock(side_effect=error),
            )

        self.assertFalse(result.success)
        self.assertIn("HTTP 429", result.message)
        error.close.assert_called_once_with()
        error.read.assert_not_called()


if __name__ == "__main__":
    unittest.main()

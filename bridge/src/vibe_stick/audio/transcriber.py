from __future__ import annotations

import json
import os
import queue
import threading
import time
import tomllib
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from uuid import uuid4

from vibe_stick.command_runner import run_json_command_hook
from vibe_stick.config.paths import APP_SUPPORT_DIR

GROQ_ASR_BASE_URL = "https://api.groq.com/openai/v1"
DEFAULT_ASR_MODEL = "whisper-large-v3-turbo"
DEFAULT_ASR_LANGUAGE = "zh"
MAX_SYNCHRONOUS_TRANSCRIPTION_SECONDS = 18
MAX_ASR_RESPONSE_BYTES = 1_000_000
MAX_TRANSCRIPT_CHARACTERS = 100_000
MAX_ABANDONED_ASR_WORKERS = 2
_ASR_WORKER_SLOTS = threading.BoundedSemaphore(MAX_ABANDONED_ASR_WORKERS)


@dataclass
class TranscriptionResult:
    text: str = ""
    success: bool = False
    message: str = ""
    source: str = "none"


class TranscriptionAdapter:
    """project-owned boundary for speech-to-text providers.

    V1 does not bake any cloud ASR provider or secret into the bridge. A local
    command can be configured with VIBE_STICK_TRANSCRIBE_CMD and should print
    the final transcript to stdout.
    """

    def transcribe(
        self,
        session_payload: dict[str, Any],
        explicit_text: str = "",
    ) -> TranscriptionResult:
        explicit_text = explicit_text.strip()
        if explicit_text:
            return TranscriptionResult(
                text=explicit_text,
                success=True,
                message="Transcript supplied by request",
                source="request",
            )

        configured_text = os.environ.get("VIBE_STICK_TRANSCRIPT_TEXT", "").strip()
        if configured_text:
            return TranscriptionResult(
                text=configured_text,
                success=True,
                message="Transcript supplied by local development override",
                source="env",
            )

        command_result = run_json_command_hook(
            "VIBE_STICK_TRANSCRIBE_CMD",
            session_payload,
            timeout=_command_timeout_seconds(),
        )
        if command_result is None:
            return self._transcribe_with_configured_asr(session_payload)
        if command_result.error:
            return TranscriptionResult(
                success=False,
                message=f"Transcription command failed: {command_result.error}",
                source="command",
            )

        transcript = command_result.stdout.strip()
        if command_result.returncode != 0:
            message = (
                command_result.stderr
                or command_result.stdout
                or "Transcription command failed"
            ).strip()
            return TranscriptionResult(success=False, message=message, source="command")
        if not transcript:
            return TranscriptionResult(success=False, message="Transcription command returned no text", source="command")
        if len(transcript) > MAX_TRANSCRIPT_CHARACTERS:
            return TranscriptionResult(
                success=False,
                message="Transcription command returned too much text",
                source="command",
            )
        return TranscriptionResult(
            text=transcript,
            success=True,
            message="Transcript supplied by local command",
            source="command",
        )

    def _transcribe_with_configured_asr(self, session_payload: dict[str, Any]) -> TranscriptionResult:
        audio_file_raw = str(session_payload.get("audio_file") or "").strip()
        if not audio_file_raw:
            return TranscriptionResult(
                success=False,
                message="No audio file available for transcription",
                source="none",
            )
        audio_file = Path(audio_file_raw)
        if not audio_file.is_file():
            return TranscriptionResult(
                success=False,
                message="No audio file available for transcription",
                source="none",
            )

        config = _load_asr_config()
        if config.get("provider") not in {"groq", "openai-compatible"} or not config.get("api_key"):
            return TranscriptionResult(
                success=False,
                message="No transcription adapter configured",
                source="none",
            )
        return _transcribe_openai_compatible(audio_file, config)


def _command_timeout_seconds() -> int:
    raw = os.environ.get("VIBE_STICK_TRANSCRIBE_TIMEOUT_SECONDS", "15")
    try:
        value = int(raw)
    except ValueError:
        return 15
    return max(5, min(MAX_SYNCHRONOUS_TRANSCRIPTION_SECONDS, value))


def _asr_timeout_seconds() -> int:
    raw = (
        os.environ.get("VIBE_STICK_ASR_TIMEOUT_SECONDS")
        or os.environ.get("VIBE_STICK_GROQ_TIMEOUT_SECONDS")
        or "15"
    )
    try:
        value = int(raw)
    except ValueError:
        return 15
    return max(3, min(60, value))


def _asr_attempt_count() -> int:
    raw = (
        os.environ.get("VIBE_STICK_ASR_ATTEMPTS")
        or os.environ.get("VIBE_STICK_GROQ_ATTEMPTS")
        or "2"
    )
    try:
        value = int(raw)
    except ValueError:
        return 2
    return max(1, min(5, value))


def _load_asr_config() -> dict[str, str]:
    generic_env = _config_from_generic_env()
    if generic_env:
        return generic_env

    env_key = os.environ.get("VIBE_STICK_GROQ_API_KEY", "").strip()
    if env_key:
        return {
            "provider": "groq",
            "base_url": GROQ_ASR_BASE_URL,
            "api_key": env_key,
            "model": os.environ.get("VIBE_STICK_GROQ_MODEL", DEFAULT_ASR_MODEL).strip(),
            "language": os.environ.get("VIBE_STICK_GROQ_LANGUAGE", DEFAULT_ASR_LANGUAGE).strip(),
        }

    for path in _asr_config_paths():
        try:
            data = tomllib.loads(path.read_text())
        except (FileNotFoundError, OSError, tomllib.TOMLDecodeError):
            continue
        config = _config_from_toml(data)
        if config:
            return config
    return {}


def _config_from_generic_env() -> dict[str, str]:
    provider = _normalize_asr_provider(os.environ.get("VIBE_STICK_ASR_PROVIDER", ""))
    api_key = os.environ.get("VIBE_STICK_ASR_API_KEY", "").strip()
    base_url = os.environ.get("VIBE_STICK_ASR_BASE_URL", "").strip()
    model = os.environ.get("VIBE_STICK_ASR_MODEL", "").strip()
    language = os.environ.get("VIBE_STICK_ASR_LANGUAGE", "").strip()
    if not any((provider, api_key, base_url)):
        return {}
    if not provider:
        provider = "openai-compatible"
    if provider == "groq":
        api_key = api_key or os.environ.get("VIBE_STICK_GROQ_API_KEY", "").strip()
        base_url = base_url or GROQ_ASR_BASE_URL
        model = model or os.environ.get("VIBE_STICK_GROQ_MODEL", DEFAULT_ASR_MODEL).strip()
        language = language or os.environ.get("VIBE_STICK_GROQ_LANGUAGE", DEFAULT_ASR_LANGUAGE).strip()
    else:
        model = model or DEFAULT_ASR_MODEL
        language = language or DEFAULT_ASR_LANGUAGE
    return _asr_config(
        provider=provider,
        base_url=base_url,
        api_key=api_key,
        model=model,
        language=language,
    )


def _config_from_toml(data: dict[str, Any]) -> dict[str, str]:
    provider = _normalize_asr_provider(data.get("asr_provider") or data.get("provider") or "")
    api_key = str(data.get("api_key") or "").strip()
    base_url = str(data.get("base_url") or "").strip()
    model = str(data.get("model") or "").strip()
    language = str(data.get("language") or "").strip()
    groq_api_key = str(data.get("groq_api_key") or "").strip()
    if not provider and (api_key or base_url):
        provider = "openai-compatible"
    if provider == "groq":
        api_key = groq_api_key or api_key
        base_url = base_url or GROQ_ASR_BASE_URL
        model = str(data.get("groq_model") or model or DEFAULT_ASR_MODEL).strip()
        language = str(data.get("groq_language") or language or DEFAULT_ASR_LANGUAGE).strip()
    elif provider == "openai-compatible":
        model = model or DEFAULT_ASR_MODEL
        language = language or DEFAULT_ASR_LANGUAGE
    else:
        return {}
    return _asr_config(
        provider=provider,
        base_url=base_url,
        api_key=api_key,
        model=model,
        language=language,
    )


def _asr_config(
    *,
    provider: str,
    base_url: str,
    api_key: str,
    model: str,
    language: str,
) -> dict[str, str]:
    return {
        "provider": provider,
        "base_url": base_url,
        "api_key": api_key,
        "model": model,
        "language": language,
    }


def _normalize_asr_provider(raw: object) -> str:
    value = str(raw or "").strip().lower()
    if value in {"groq", "openai-compatible"}:
        return value
    return ""


def _asr_config_paths() -> list[Path]:
    return [
        APP_SUPPORT_DIR / "asr.toml",
        APP_SUPPORT_DIR / "config.toml",
    ]


def _transcribe_openai_compatible(audio_file: Path, config: dict[str, str]) -> TranscriptionResult:
    source = config.get("provider") or "openai-compatible"
    label = _asr_label(source)
    worker_slots = _ASR_WORKER_SLOTS
    if not worker_slots.acquire(blocking=False):
        return TranscriptionResult(
            success=False,
            message=f"{label} transcription is busy after earlier timeouts",
            source=source,
        )

    result_queue: queue.Queue[TranscriptionResult] = queue.Queue(maxsize=1)

    def run() -> None:
        try:
            result = _transcribe_openai_compatible_blocking(audio_file, config)
        except Exception as exc:  # A provider adapter must not escape into HTTP handling.
            result = TranscriptionResult(
                success=False,
                message=f"{label} transcription failed: {type(exc).__name__}",
                source=source,
            )
        try:
            result_queue.put_nowait(result)
        finally:
            worker_slots.release()

    worker = threading.Thread(
        target=run,
        name="vibestick-asr",
        daemon=True,
    )
    try:
        worker.start()
    except RuntimeError:
        worker_slots.release()
        return TranscriptionResult(
            success=False,
            message=f"{label} transcription worker could not start",
            source=source,
        )
    try:
        return result_queue.get(timeout=MAX_SYNCHRONOUS_TRANSCRIPTION_SECONDS)
    except queue.Empty:
        # urllib's timeout is an inactivity timeout, not a wall-clock deadline.
        # The daemon may finish later, but it cannot paste or mutate a session;
        # the semaphore bounds how many such workers can remain in flight.
        return TranscriptionResult(
            success=False,
            message=f"{label} transcription exceeded the device request deadline",
            source=source,
        )


def _transcribe_openai_compatible_blocking(audio_file: Path, config: dict[str, str]) -> TranscriptionResult:
    source = config.get("provider") or "openai-compatible"
    label = _asr_label(source)
    if not config.get("api_key") or not config.get("base_url"):
        return TranscriptionResult(success=False, message="No transcription adapter configured", source="none")
    last_result = TranscriptionResult(success=False, message=f"{label} transcription failed", source=source)
    attempts = _asr_attempt_count()
    retry_delay_budget = sum(min(2.0, 0.4 * attempt) for attempt in range(1, attempts))
    per_attempt_timeout = max(
        3.0,
        (MAX_SYNCHRONOUS_TRANSCRIPTION_SECONDS - retry_delay_budget) / attempts,
    )
    per_attempt_timeout = min(float(_asr_timeout_seconds()), per_attempt_timeout)
    for attempt in range(1, attempts + 1):
        result = _transcribe_openai_compatible_once(
            audio_file,
            config,
            attempt,
            timeout_seconds=per_attempt_timeout,
        )
        if result.success:
            return result
        last_result = result
        if attempt >= attempts or not _is_retryable_asr_error(result.message):
            return result
        time.sleep(min(2.0, 0.4 * attempt))
    return last_result


def _transcribe_openai_compatible_once(
    audio_file: Path,
    config: dict[str, str],
    attempt: int,
    opener=urllib.request.urlopen,  # noqa: ANN001
    timeout_seconds: float | None = None,
) -> TranscriptionResult:
    source = config.get("provider") or "openai-compatible"
    label = _asr_label(source)
    boundary = f"VibeStickASR-{uuid4().hex}"
    try:
        body = _multipart_body(
            boundary=boundary,
            audio_file=audio_file,
            model=config.get("model") or DEFAULT_ASR_MODEL,
            language=config.get("language") or DEFAULT_ASR_LANGUAGE,
        )
    except OSError as exc:
        return TranscriptionResult(success=False, message=f"Could not read audio file: {exc}", source=source)

    request = urllib.request.Request(
        _transcription_url(config.get("base_url", "")),
        data=body,
        method="POST",
        headers={
            "Authorization": f"Bearer {config['api_key']}",
            "Content-Type": f"multipart/form-data; boundary={boundary}",
            "User-Agent": "VibeStick/0.1 macOS",
            "Connection": "close",
        },
    )
    try:
        with opener(
            request,
            timeout=timeout_seconds or _asr_timeout_seconds(),
        ) as response:
            response_data = response.read(MAX_ASR_RESPONSE_BYTES + 1)
    except urllib.error.HTTPError as exc:
        _close_http_error(exc)
        return TranscriptionResult(
            success=False,
            message=f"{label} transcription failed on attempt {attempt}: HTTP {exc.code}",
            source=source,
        )
    except (OSError, TimeoutError) as exc:
        return TranscriptionResult(
            success=False,
            message=f"{label} transcription failed on attempt {attempt}: {exc}",
            source=source,
        )

    if len(response_data) > MAX_ASR_RESPONSE_BYTES:
        return TranscriptionResult(success=False, message=f"{label} response was too large", source=source)
    try:
        payload = json.loads(response_data.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return TranscriptionResult(success=False, message=f"{label} returned unreadable JSON", source=source)
    if not isinstance(payload, dict):
        return TranscriptionResult(success=False, message=f"{label} returned invalid JSON", source=source)
    raw_text = payload.get("text")
    if not isinstance(raw_text, str) or not raw_text.strip():
        return TranscriptionResult(success=False, message=f"{label} returned no transcript", source=source)
    text = raw_text.strip()
    if len(text) > MAX_TRANSCRIPT_CHARACTERS:
        return TranscriptionResult(success=False, message=f"{label} transcript was too large", source=source)
    return TranscriptionResult(
        text=text,
        success=True,
        message=f"Transcript supplied by {label} ASR",
        source=source,
    )


def _transcription_url(base_url: str) -> str:
    return f"{base_url.rstrip('/')}/audio/transcriptions"


def _asr_label(provider: str) -> str:
    return "Groq" if provider == "groq" else "OpenAI-compatible"


def _close_http_error(exc: urllib.error.HTTPError) -> None:
    try:
        exc.close()
    except Exception:
        pass


def _is_retryable_asr_error(message: str) -> bool:
    retryable_fragments = (
        "HTTP 408",
        "HTTP 409",
        "HTTP 425",
        "HTTP 429",
        "HTTP 500",
        "HTTP 502",
        "HTTP 503",
        "HTTP 504",
        "UNEXPECTED_EOF",
        "EOF occurred",
        "Remote end closed",
        "Connection reset",
        "Temporary failure",
        "timed out",
        "timeout",
        "SSL",
    )
    return any(fragment in message for fragment in retryable_fragments)


def _multipart_body(boundary: str, audio_file: Path, model: str, language: str) -> bytes:
    body = bytearray()

    def add_field(name: str, value: str) -> None:
        body.extend(f"--{boundary}\r\n".encode())
        body.extend(f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode())
        body.extend(value.encode())
        body.extend(b"\r\n")

    add_field("model", model)
    add_field("response_format", "json")
    add_field("temperature", "0")
    if language:
        add_field("language", language)

    body.extend(f"--{boundary}\r\n".encode())
    body.extend(
        f'Content-Disposition: form-data; name="file"; filename="{audio_file.name}"\r\n'.encode()
    )
    body.extend(f"Content-Type: {_content_type(audio_file)}\r\n\r\n".encode())
    body.extend(audio_file.read_bytes())
    body.extend(b"\r\n")
    body.extend(f"--{boundary}--\r\n".encode())
    return bytes(body)


def _content_type(audio_file: Path) -> str:
    suffix = audio_file.suffix.lower()
    if suffix == ".wav":
        return "audio/wav"
    if suffix == ".ogg":
        return "audio/ogg"
    if suffix == ".mp3":
        return "audio/mpeg"
    return "audio/mp4"

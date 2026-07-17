from __future__ import annotations

import hashlib
import json
import math
import os
import signal
import struct
import subprocess
import threading
import time
import wave
import uuid
from dataclasses import asdict, dataclass
from datetime import datetime
from pathlib import Path
from typing import Any

from vibe_stick.audio.transcriber import TranscriptionAdapter
from vibe_stick.command_runner import run_json_command_hook
from vibe_stick.config.paths import (
    MIC_RECORDER_PATH,
    MIC_RECORDER_STAMP_PATH,
    RECORDINGS_DIR,
)
from vibe_stick.config.storage import (
    atomic_write_text,
    ensure_private_dir,
    ensure_private_file,
)
from vibe_stick.desktop.hud import hide_hud, show_hud
from vibe_stick.paste.input_injector import MacPasteInjector

MIN_AUDIO_DURATION_SECONDS = 0.7
MIN_AUDIO_RMS = 120.0
MIN_SPEECH_SECONDS = 0.28
MIN_SPEECH_WINDOWS = 3
SPEECH_WINDOW_SECONDS = 0.10
SPEECH_RMS_THRESHOLD = 900.0
SPEECH_EDGE_IGNORE_SECONDS = 0.18
KNOWN_ASR_HALLUCINATIONS = (
    "\u8bf7\u4e0d\u541d\u70b9\u8d5e\u8ba2\u9605\u8f6c\u53d1\u6253\u8d4f\u652f\u6301\u660e\u955c\u4e0e\u70b9\u70b9\u680f\u76ee",
    "\u8bf7\u4f7f\u7528\u7b80\u4f53\u4e2d\u6587\u8f93\u51fa\u3002",
)
DEFAULT_RECORDING_RETENTION_DAYS = 7
DEFAULT_STICKS3_LEASE_SECONDS = 90
STICKS3_SAMPLE_RATE = 16000
STICKS3_CHANNELS = 1
STICKS3_BITS_PER_SAMPLE = 16


class RecordingRequestError(ValueError):
    """A recording request cannot be applied to the current session."""


class RecordingConflictError(RecordingRequestError):
    """Another recording session currently owns the recorder."""


@dataclass
class RecordingSession:
    session_id: str = ""
    active: bool = False
    started_at: str = ""
    stopped_at: str = ""
    status: str = "idle"
    message: str = ""
    transcript: str = ""
    transcript_source: str = "none"
    pasted: bool = False
    audio_file: str = ""
    audio_source: str = "none"

    def to_jsonable(self) -> dict[str, Any]:
        return asdict(self)

    def to_public_jsonable(self) -> dict[str, Any]:
        """Return the device-facing status without transcript or local paths."""

        data = self.to_jsonable()
        data.pop("transcript", None)
        data.pop("audio_file", None)
        data["message"] = _bounded_utf8(data.get("message"), 256)
        return data


@dataclass(frozen=True)
class AudioMetrics:
    duration_seconds: float
    audio_bytes: int
    rms: float
    ac_rms: float
    speech_seconds: float
    speech_windows: int


class RecordingController:
    """project-owned push-to-talk session boundary."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self._lock = threading.RLock()
        self.transcriber = TranscriptionAdapter()
        self.paste_injector = MacPasteInjector()
        self.audio_recorder = MacMicRecorder()
        self._active_lease_started = 0.0
        self.session = self._load()
        if self.session.status == "pasting":
            # We cannot know whether the target app consumed the keystroke
            # before a crash. Prefer at-most-once behavior over pasting a
            # command twice on retry.
            self.session.active = False
            self.session.status = "paste_failed"
            self.session.message = (
                "Bridge restarted during paste; automatic replay was suppressed"
            )
            self._save()
        if self.session.status == "stopping":
            # The Bridge persisted this marker before invoking microphone,
            # hook, ASR, or paste work and then exited without a terminal
            # result. Keep any durable audio retryable instead of returning a
            # forever non-terminal status to the Stick.
            self.session.active = False
            self.session.status = "interrupted"
            self.session.message = "Bridge restarted while stopping the recording"
            self._save()
        if self.session.active:
            # A recorder process cannot survive a Bridge restart. Mark the
            # persisted lease interrupted so a fresh session is not locked
            # out. A StickS3 that was still capturing can recover by uploading
            # PCM with the same session_id; attach_pcm reactivates that lease.
            self.session.active = False
            self.session.stopped_at = datetime.now().isoformat(timespec="seconds")
            self.session.status = "interrupted"
            self.session.message = "Recording was interrupted when the Bridge restarted"
            self._save()
        if self.session.transcript and not _env_bool(
            "VIBE_STICK_STORE_TRANSCRIPTS",
            default=False,
        ):
            self._save()
        _prune_recordings(
            exclude=self.session.audio_file
            if self.session.status == "interrupted"
            else ""
        )

    def start(self, request: dict[str, Any] | None = None) -> RecordingSession:
        with self._lock:
            return self._start(request)

    def _start(self, request: dict[str, Any] | None = None) -> RecordingSession:
        request = request or {}
        requested_source = str(request.get("audio_source") or request.get("source") or "")
        requested_session_id = _requested_session_id(request, strict=True)
        self._recover_dead_mac_mic_session()
        self._expire_stale_sticks3_lease()
        if self.session.active or self.audio_recorder.is_running():
            if requested_session_id and requested_session_id == self.session.session_id:
                return self.session
            raise RecordingConflictError(
                f"Recording session {self.session.session_id or 'unknown'} is already active"
            )
        # The LaunchAgent can run for weeks, so retention cannot depend on a
        # Bridge restart. Starting a new lease is a safe point to remove audio
        # from completed or abandoned sessions.
        _prune_recordings()
        self.session = RecordingSession(
            session_id=requested_session_id or uuid.uuid4().hex,
            active=True,
            started_at=datetime.now().isoformat(timespec="seconds"),
            stopped_at="",
            status="recording",
            message="Recording session started",
        )
        self._active_lease_started = time.monotonic()
        use_mac_mic = "sticks3" not in requested_source.lower()
        if not use_mac_mic:
            self.session.audio_source = "sticks3_pcm"
            self.session.message = "Waiting for StickS3 audio upload"
            show_hud("listening")

        mic_result = self.audio_recorder.start(self.session.session_id) if use_mac_mic else None
        if (
            use_mac_mic
            and mic_result is None
            and not os.environ.get("VIBE_STICK_RECORDING_START_CMD", "").strip()
        ):
            self.session.active = False
            self._active_lease_started = 0.0
            self.session.stopped_at = datetime.now().isoformat(timespec="seconds")
            self.session.status = "start_failed"
            self.session.message = "Mac microphone recording is disabled and no external recorder is configured"
            show_hud("failed", hold_seconds=1.8)
            self._save()
            return self.session
        if mic_result is not None:
            ok, audio_file, message = mic_result
            self.session.audio_file = str(audio_file) if audio_file else ""
            self.session.audio_source = "mac_mic"
            self.session.message = message
            if not ok:
                self.session.active = False
                self._active_lease_started = 0.0
                self.session.stopped_at = datetime.now().isoformat(timespec="seconds")
                self.session.status = "start_failed"
                show_hud("failed", hold_seconds=1.8)
                self._save()
                return self.session
            show_hud("listening")

        hook = _run_command_hook(
            "VIBE_STICK_RECORDING_START_CMD",
            self.session.to_jsonable(),
            timeout=_start_hook_timeout_seconds(),
        )
        if hook is not None and not hook[0]:
            self.audio_recorder.stop()
            self.session.active = False
            self._active_lease_started = 0.0
            self.session.stopped_at = datetime.now().isoformat(timespec="seconds")
            self.session.status = "start_failed"
            self.session.message = hook[2] or "Recording start command failed"
            show_hud("failed", hold_seconds=1.8)
        self._save()
        return self.session

    def attach_pcm(
        self,
        pcm: bytes,
        *,
        session_id: str = "",
        sample_rate: int = 16000,
        channels: int = 1,
        bits_per_sample: int = 16,
    ) -> RecordingSession:
        with self._lock:
            return self._attach_pcm(
                pcm,
                session_id=session_id,
                sample_rate=sample_rate,
                channels=channels,
                bits_per_sample=bits_per_sample,
            )

    def _attach_pcm(
        self,
        pcm: bytes,
        *,
        session_id: str = "",
        sample_rate: int = STICKS3_SAMPLE_RATE,
        channels: int = STICKS3_CHANNELS,
        bits_per_sample: int = STICKS3_BITS_PER_SAMPLE,
    ) -> RecordingSession:
        raw_session_id = session_id
        session_id = _clean_session_id(session_id)
        if not raw_session_id or not session_id:
            raise RecordingRequestError("A valid recording session_id is required for audio upload")
        self._expire_stale_sticks3_lease()
        if session_id and self.session.session_id and session_id != self.session.session_id and self.session.active:
            raise RecordingConflictError(
                f"Recording session {self.session.session_id} is already active"
            )
        if (
            session_id == self.session.session_id
            and not self.session.active
            and self.session.status != "interrupted"
        ):
            # A delayed retry after a completed stop is idempotent. Never
            # reactivate a terminal session, which could paste twice.
            return self.session
        if not pcm:
            raise RecordingRequestError("Uploaded audio was empty")
        if (
            sample_rate != STICKS3_SAMPLE_RATE
            or channels != STICKS3_CHANNELS
            or bits_per_sample != STICKS3_BITS_PER_SAMPLE
        ):
            raise RecordingRequestError(
                "StickS3 audio must be 16 kHz mono 16-bit PCM"
            )
        frame_bytes = channels * (bits_per_sample // 8)
        if len(pcm) % frame_bytes:
            raise RecordingRequestError("Uploaded PCM audio ended on a partial frame")

        if session_id and (not self.session.session_id or session_id != self.session.session_id):
            self.session = RecordingSession(
                session_id=session_id,
                active=True,
                started_at=datetime.now().isoformat(timespec="seconds"),
                status="recording",
                message="Recovered recording session from StickS3 audio upload",
                audio_source="sticks3_pcm",
            )
            self._active_lease_started = time.monotonic()
        elif session_id == self.session.session_id and not self.session.active:
            self.session.active = True
            self._active_lease_started = time.monotonic()
            self.session.stopped_at = ""
            self.session.status = "recording"
            self.session.message = "Recovered interrupted StickS3 recording from audio upload"
            self.session.audio_source = "sticks3_pcm"
        ensure_private_dir(RECORDINGS_DIR)
        sid = self.session.session_id or session_id or uuid.uuid4().hex
        audio_file = RECORDINGS_DIR / f"{sid}.wav"
        with wave.open(str(audio_file), "wb") as wav:
            wav.setnchannels(max(1, channels))
            wav.setsampwidth(bits_per_sample // 8)
            wav.setframerate(sample_rate)
            wav.writeframes(pcm)
        ensure_private_file(audio_file)

        self.session.audio_file = str(audio_file)
        self.session.audio_source = "sticks3_pcm"
        self.session.message = "StickS3 audio uploaded"
        show_hud("sending")
        self._save()
        return self.session

    def stop(self, request: dict[str, Any] | None = None) -> RecordingSession:
        with self._lock:
            try:
                return self._stop(request)
            except RecordingRequestError:
                raise
            except Exception as exc:
                # All untrusted/external work happens after `_stop` has
                # persisted the `stopping` marker. Convert an unexpected
                # runtime failure into a terminal response so the firmware
                # does not retain the session forever.
                if self.session.status not in {"stopping", "pasting"} and self.session.active:
                    raise
                return self._finish_unexpected_stop(exc)

    def _stop(self, request: dict[str, Any] | None = None) -> RecordingSession:
        request = request or {}
        requested_session_id = _requested_session_id(request, strict=True)
        if self.session.active and not requested_session_id:
            raise RecordingRequestError("A recording session_id is required to stop recording")
        if requested_session_id and requested_session_id != self.session.session_id:
            raise RecordingConflictError(
                f"Recording session {requested_session_id} is not active"
            )
        if not self.session.active:
            if requested_session_id and self.session.status == "interrupted":
                if self.session.audio_file and Path(self.session.audio_file).is_file():
                    # Upload completed before a Bridge restart, but stop did
                    # not. Resume the durable audio instead of acknowledging
                    # it unused.
                    self.session.active = True
                    self.session.stopped_at = ""
                else:
                    self.session.status = "stop_failed"
                    self.session.message = "Interrupted recording has no recoverable audio"
                    show_hud("failed", hold_seconds=1.8)
                    self._save_stop_result()
                    return self.session
            else:
                # A terminal stop retry is idempotent and cannot paste twice.
                return self.session
        self.session.active = False
        self._active_lease_started = 0.0
        self.session.stopped_at = datetime.now().isoformat(timespec="seconds")
        self.session.status = "stopping"
        self.session.message = "Recording stop in progress"
        self._save()
        explicit_text = str(request.get("text") or request.get("transcript") or "")
        mic_stop = self.audio_recorder.stop()
        if mic_stop is not None:
            ok, audio_file, message = mic_stop
            self.session.audio_file = str(audio_file) if audio_file else self.session.audio_file
            self.session.audio_source = "mac_mic"
            if not ok:
                self.session.status = "stop_failed"
                self.session.message = message
                show_hud("failed", hold_seconds=1.8)
                self._save_stop_result()
                return self.session
        stop_hook_source = False
        stop_hook = _run_command_hook(
            "VIBE_STICK_RECORDING_STOP_CMD",
            self.session.to_jsonable(),
            timeout=_stop_hook_timeout_seconds(),
        )
        if stop_hook is not None:
            hook_ok, hook_stdout, hook_stderr = stop_hook
            if hook_ok and hook_stdout.strip():
                explicit_text = hook_stdout.strip()
                stop_hook_source = True
            else:
                self.session.status = "stop_failed"
                self.session.message = (
                    hook_stderr
                    or (
                        "Recording stop command returned no transcript"
                        if hook_ok
                        else "Recording stop command failed"
                    )
                )
                show_hud("failed", hold_seconds=1.8)
                self._save_stop_result()
                return self.session
        should_paste = bool(request.get("paste", True))
        press_enter = _env_bool("VIBE_STICK_AUTO_ENTER", default=False)
        show_hud("transcribing")

        if not explicit_text:
            metrics = _wav_metrics(self.session.audio_file)
            if metrics is not None:
                print(
                    "recording audio metrics "
                    f"session={self.session.session_id} "
                    f"file={self.session.audio_file} "
                    f"bytes={metrics.audio_bytes} "
                    f"duration={metrics.duration_seconds:.3f}s "
                    f"rms={metrics.rms:.1f} "
                    f"ac_rms={metrics.ac_rms:.1f} "
                    f"speech_seconds={metrics.speech_seconds:.2f} "
                    f"speech_windows={metrics.speech_windows}",
                    flush=True,
                )
                if metrics.duration_seconds < MIN_AUDIO_DURATION_SECONDS:
                    self.session.pasted = False
                    self.session.status = "audio_skipped"
                    self.session.message = (
                        f"Audio too short for transcription: {metrics.duration_seconds:.2f}s"
                    )
                    show_hud("unclear", hold_seconds=1.8)
                    self._save_stop_result()
                    return self.session
                if metrics.rms < MIN_AUDIO_RMS:
                    self.session.pasted = False
                    self.session.status = "audio_skipped"
                    self.session.message = f"Audio appears silent: rms={metrics.rms:.1f}"
                    show_hud("unclear", hold_seconds=1.8)
                    self._save_stop_result()
                    return self.session
                if (
                    metrics.speech_seconds < MIN_SPEECH_SECONDS
                    or metrics.speech_windows < MIN_SPEECH_WINDOWS
                ):
                    self.session.pasted = False
                    self.session.status = "audio_skipped"
                    self.session.message = (
                        "No clear speech detected before transcription: "
                        f"speech_seconds={metrics.speech_seconds:.2f}"
                    )
                    show_hud("unclear", hold_seconds=1.8)
                    self._save_stop_result()
                    return self.session

        transcript = self.transcriber.transcribe(
            self.session.to_jsonable(),
            explicit_text=explicit_text,
        )
        self.session.transcript_source = "recording_stop_cmd" if stop_hook_source else transcript.source
        if transcript.success and transcript.text:
            self.session.transcript = transcript.text
            transcript_message = (
                "Transcript supplied by recording stop command"
                if stop_hook_source else transcript.message
            )
            rejection_reason = _transcript_rejection_reason(transcript.text)
            if rejection_reason:
                self.session.pasted = False
                self.session.status = "transcript_rejected"
                self.session.message = rejection_reason
                show_hud("unclear", hold_seconds=1.8)
                print(
                    "recording transcript rejected "
                    f"session={self.session.session_id} "
                    f"source={self.session.transcript_source} "
                    f"reason={rejection_reason}",
                    flush=True,
                )
                self._save_stop_result()
                return self.session
            if should_paste:
                self.session.status = "pasting"
                self.session.message = "Paste in progress"
                try:
                    self._save()
                except OSError as exc:
                    self.session.status = "paste_failed"
                    self.session.message = f"Could not persist paste guard: {exc}"
                    show_hud("failed", hold_seconds=1.8)
                    return self.session
                paste = self.paste_injector.paste(transcript.text, press_enter=press_enter)
                self.session.pasted = paste.success
                self.session.status = "pasted" if paste.success else "paste_failed"
                self.session.message = paste.message if paste.success else f"{transcript_message}; {paste.message}"
                if paste.success:
                    hide_hud(delay_seconds=0.5)
                else:
                    show_hud("failed", hold_seconds=1.8)
            else:
                self.session.pasted = False
                self.session.status = "transcribed"
                self.session.message = transcript_message
                hide_hud(delay_seconds=0.5)
        else:
            self.session.pasted = False
            self.session.status = "transcription_failed"
            self.session.message = transcript.message
            show_hud("failed", hold_seconds=1.8)
        self._save_stop_result()
        return self.session

    def _finish_unexpected_stop(self, exc: Exception) -> RecordingSession:
        previous_status = self.session.status
        self.session.active = False
        self._active_lease_started = 0.0
        if not self.session.stopped_at:
            self.session.stopped_at = datetime.now().isoformat(timespec="seconds")
        self.session.pasted = False
        if previous_status == "pasting":
            self.session.status = "paste_failed"
            self.session.message = (
                "Paste was interrupted; automatic replay was suppressed"
            )
        else:
            self.session.status = "stop_failed"
            self.session.message = "Recording stop failed unexpectedly"
        print(
            "recording stop unexpected failure "
            f"session={self.session.session_id} "
            f"stage={previous_status} "
            f"error={type(exc).__name__}: {_log_text(exc)}",
            flush=True,
        )
        try:
            show_hud("failed", hold_seconds=1.8)
        except Exception as hud_exc:
            print(
                "recording failure HUD error "
                f"error={type(hud_exc).__name__}: {_log_text(hud_exc)}",
                flush=True,
            )
        try:
            self._save_stop_result()
        except Exception as save_exc:
            print(
                "recording failure persistence error "
                f"error={type(save_exc).__name__}: {_log_text(save_exc)}",
                flush=True,
            )
        return self.session

    def _expire_stale_sticks3_lease(self) -> None:
        if (
            not self.session.active
            or self.session.audio_source != "sticks3_pcm"
            or self.audio_recorder.is_running()
        ):
            return
        started = self._active_lease_started
        if started <= 0 or time.monotonic() - started < _sticks3_lease_seconds():
            return
        self.session.active = False
        self._active_lease_started = 0.0
        self.session.stopped_at = datetime.now().isoformat(timespec="seconds")
        self.session.status = "interrupted"
        self.session.message = "Expired abandoned StickS3 recording session"
        self._save()

    def _recover_dead_mac_mic_session(self) -> None:
        if (
            not self.session.active
            or self.session.audio_source != "mac_mic"
            or self.audio_recorder.is_running()
        ):
            return
        try:
            self.audio_recorder.stop()
        except (OSError, subprocess.SubprocessError):
            pass
        self.session.active = False
        self._active_lease_started = 0.0
        self.session.stopped_at = datetime.now().isoformat(timespec="seconds")
        self.session.status = "start_failed"
        self.session.message = "Mac microphone recorder exited unexpectedly"
        self._save()

    def _load(self) -> RecordingSession:
        try:
            data = json.loads(self.path.read_text())
        except (FileNotFoundError, json.JSONDecodeError, OSError):
            return RecordingSession()
        if not isinstance(data, dict):
            return RecordingSession()
        return RecordingSession(
            session_id=str(data.get("session_id") or ""),
            active=bool(data.get("active", False)),
            started_at=str(data.get("started_at") or ""),
            stopped_at=str(data.get("stopped_at") or ""),
            status=str(data.get("status") or "idle"),
            message=str(data.get("message") or ""),
            transcript=str(data.get("transcript") or ""),
            transcript_source=str(data.get("transcript_source") or "none"),
            pasted=bool(data.get("pasted", False)),
            audio_file=str(data.get("audio_file") or ""),
            audio_source=str(data.get("audio_source") or "none"),
        )

    def _save(self) -> None:
        payload = self.session.to_jsonable()
        if not _env_bool("VIBE_STICK_STORE_TRANSCRIPTS", default=False):
            payload["transcript"] = ""
        atomic_write_text(
            self.path,
            json.dumps(payload, indent=2) + "\n",
            skip_if_unchanged=True,
        )

    def _save_stop_result(self) -> None:
        self._save()
        print(
            "recording stop result "
            f"session={self.session.session_id} "
            f"status={self.session.status} "
            f"source={self.session.transcript_source} "
            f"audio_source={self.session.audio_source} "
            f"transcript_chars={len(self.session.transcript)} "
            f"pasted={self.session.pasted} "
            f"message={_log_text(self.session.message)}",
            flush=True,
        )
        # Audio is no longer being read once a terminal result is saved. This
        # also makes a retention value of zero mean no post-processing copy.
        _prune_recordings()


def _env_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def _wav_metrics(audio_file: str) -> AudioMetrics | None:
    if not audio_file:
        return None
    path = Path(audio_file)
    if not path.is_file() or path.suffix.lower() != ".wav":
        return None
    try:
        with wave.open(str(path), "rb") as wav:
            frames = wav.getnframes()
            rate = wav.getframerate()
            sample_width = wav.getsampwidth()
            raw = wav.readframes(frames)
    except (OSError, wave.Error):
        return None

    duration_seconds = frames / rate if rate else 0.0
    if sample_width != 2 or not raw:
        return AudioMetrics(duration_seconds, len(raw), 0.0, 0.0, 0.0, 0)

    usable_len = len(raw) - (len(raw) % 2)
    samples = [sample for (sample,) in struct.iter_unpack("<h", raw[:usable_len])]
    count = len(samples)
    if count == 0:
        return AudioMetrics(duration_seconds, len(raw), 0.0, 0.0, 0.0, 0)
    total = sum(int(sample) * int(sample) for sample in samples)
    rms = math.sqrt(total / count) if count else 0.0
    mean = sum(samples) / count
    ac_rms = math.sqrt(sum((sample - mean) * (sample - mean) for sample in samples) / count)

    window_size = max(1, int(rate * SPEECH_WINDOW_SECONDS)) if rate else count
    edge_windows = int(math.ceil(SPEECH_EDGE_IGNORE_SECONDS / SPEECH_WINDOW_SECONDS))
    window_rms: list[float] = []
    for start in range(0, count, window_size):
        chunk = samples[start:start + window_size]
        if len(chunk) < max(1, window_size // 2):
            continue
        chunk_mean = sum(chunk) / len(chunk)
        chunk_rms = math.sqrt(
            sum((sample - chunk_mean) * (sample - chunk_mean) for sample in chunk) / len(chunk)
        )
        window_rms.append(chunk_rms)
    speech_windows = 0
    for index, value in enumerate(window_rms):
        if index < edge_windows or index >= len(window_rms) - edge_windows:
            continue
        if value >= SPEECH_RMS_THRESHOLD:
            speech_windows += 1
    speech_seconds = speech_windows * SPEECH_WINDOW_SECONDS
    return AudioMetrics(duration_seconds, len(raw), rms, ac_rms, speech_seconds, speech_windows)


def _transcript_rejection_reason(text: str) -> str:
    normalized = _normalized_transcript(text)
    for phrase in KNOWN_ASR_HALLUCINATIONS:
        if phrase in normalized:
            return "Rejected known ASR hallucination transcript"
    return ""


def _normalized_transcript(text: str) -> str:
    return "".join(str(text).split()).lower()


def _log_text(value: object) -> str:
    return str(value).replace("\r", " ").replace("\n", " ")[:512]


def _bounded_utf8(value: object, max_bytes: int) -> str:
    encoded = str(value or "").encode("utf-8", errors="replace")
    if len(encoded) <= max_bytes:
        return encoded.decode("utf-8")
    return encoded[:max_bytes].decode("utf-8", errors="ignore")


def _requested_session_id(
    request: dict[str, Any],
    *,
    strict: bool = False,
) -> str:
    raw = str(request.get("session_id") or "").strip()
    cleaned = _clean_session_id(raw)
    if strict and raw and not cleaned:
        raise RecordingRequestError("Invalid recording session_id")
    return cleaned


def _clean_session_id(raw: str) -> str:
    value = raw.strip()
    if not 8 <= len(value) <= 64:
        return ""
    if not all(ch.isalnum() or ch in {"-", "_"} for ch in value):
        return ""
    return value


def _run_command_hook(
    env_name: str,
    payload: dict[str, Any],
    timeout: int,
) -> tuple[bool, str, str] | None:
    result = run_json_command_hook(env_name, payload, timeout=timeout)
    if result is None:
        return None
    if result.error:
        return (False, result.stdout, result.error)
    return (result.returncode == 0, result.stdout, result.stderr.strip())


class MacMicRecorder:
    """Small project-owned wrapper around a local AVFoundation recorder helper."""

    def __init__(self) -> None:
        self.process: subprocess.Popen[str] | None = None
        self.audio_file: Path | None = None

    def is_running(self) -> bool:
        return self.process is not None and self.process.poll() is None

    def start(self, session_id: str) -> tuple[bool, Path | None, str] | None:
        if os.environ.get("VIBE_STICK_RECORDING_USE_MAC_MIC", "1").strip().lower() in {"0", "false", "no", "off"}:
            return None
        if self.process and self.process.poll() is None:
            return (False, self.audio_file, "A recording session is already active")

        ensure_private_dir(RECORDINGS_DIR)
        self.audio_file = RECORDINGS_DIR / f"{session_id}.m4a"
        binary = self._ensure_helper_binary()
        if binary is None:
            return (False, self.audio_file, "Could not build VibeStick mic recorder helper")

        try:
            self.process = subprocess.Popen(
                [str(binary), str(self.audio_file)],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
        except OSError as exc:
            self.process = None
            return (False, self.audio_file, f"Could not start mic recorder: {exc}")

        time.sleep(1.0)
        if self.process.poll() is not None:
            _, stderr = self.process.communicate(timeout=1)
            message = stderr.strip() or "Mic recorder exited before recording started"
            self.process = None
            return (False, self.audio_file, message)
        return (True, self.audio_file, "Recording from Mac microphone")

    def stop(self) -> tuple[bool, Path | None, str] | None:
        if not self.process:
            return None
        process = self.process
        audio_file = self.audio_file
        self.process = None
        self.audio_file = None

        if process.poll() is None:
            process.send_signal(signal.SIGINT)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.terminate()
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=2)

        stdout, stderr = process.communicate(timeout=1)
        if process.returncode != 0:
            message = stderr.strip() or stdout.strip() or "Mic recorder stopped with an error"
            return (False, audio_file, message)
        if audio_file is None or not audio_file.exists() or audio_file.stat().st_size == 0:
            return (False, audio_file, "Mic recorder produced no audio")
        ensure_private_file(audio_file)
        return (True, audio_file, "Recording stopped")

    def _ensure_helper_binary(self) -> Path | None:
        source = Path(__file__).resolve().parents[3] / "tools" / "vibe_stick_mic_recorder.swift"
        binary = MIC_RECORDER_PATH
        if not source.exists():
            return None
        try:
            source_digest = hashlib.sha256(source.read_bytes()).hexdigest()
        except OSError:
            return None
        try:
            installed_digest = MIC_RECORDER_STAMP_PATH.read_text().strip()
        except (FileNotFoundError, OSError):
            installed_digest = ""
        if binary.exists() and installed_digest == source_digest:
            ensure_private_file(binary, executable=True)
            return binary

        ensure_private_dir(binary.parent)
        temporary_binary = binary.with_name(f".{binary.name}.{os.getpid()}.tmp")
        try:
            result = subprocess.run(
                [
                    "swiftc",
                    str(source),
                    "-o",
                    str(temporary_binary),
                    "-framework",
                    "AVFoundation",
                ],
                check=False,
                capture_output=True,
                text=True,
                timeout=45,
            )
        except (OSError, subprocess.TimeoutExpired):
            _remove_file(temporary_binary)
            return None
        if result.returncode != 0:
            _remove_file(temporary_binary)
            return None
        try:
            os.replace(temporary_binary, binary)
        except OSError:
            _remove_file(temporary_binary)
            return None
        ensure_private_file(binary, executable=True)
        try:
            atomic_write_text(
                MIC_RECORDER_STAMP_PATH,
                source_digest + "\n",
                skip_if_unchanged=True,
            )
        except OSError as exc:
            print(f"mic helper stamp write failed: {type(exc).__name__}", flush=True)
        return binary


def _recording_retention_days() -> int:
    raw = os.environ.get("VIBE_STICK_RECORDING_RETENTION_DAYS", "").strip()
    if not raw:
        return DEFAULT_RECORDING_RETENTION_DAYS
    try:
        return max(0, min(365, int(raw)))
    except ValueError:
        return DEFAULT_RECORDING_RETENTION_DAYS


def _sticks3_lease_seconds() -> int:
    raw = os.environ.get("VIBE_STICK_RECORDING_LEASE_SECONDS", "").strip()
    if not raw:
        return DEFAULT_STICKS3_LEASE_SECONDS
    try:
        return max(60, min(600, int(raw)))
    except ValueError:
        return DEFAULT_STICKS3_LEASE_SECONDS


def _stop_hook_timeout_seconds() -> int:
    raw = os.environ.get("VIBE_STICK_RECORDING_STOP_TIMEOUT_SECONDS", "15").strip()
    try:
        return max(5, min(18, int(raw)))
    except ValueError:
        return 15


def _start_hook_timeout_seconds() -> int:
    raw = os.environ.get("VIBE_STICK_RECORDING_START_TIMEOUT_SECONDS", "2").strip()
    try:
        return max(1, min(2, int(raw)))
    except ValueError:
        return 2


def _prune_recordings(*, exclude: str | Path = "") -> None:
    if not RECORDINGS_DIR.exists():
        return
    ensure_private_dir(RECORDINGS_DIR)
    retention_days = _recording_retention_days()
    cutoff = time.time() - retention_days * 86400
    protected = Path(exclude) if exclude else None
    try:
        paths = tuple(RECORDINGS_DIR.iterdir())
    except OSError:
        return
    for path in paths:
        try:
            if path.is_symlink() or not path.is_file() or path.suffix.lower() not in {".wav", ".m4a"}:
                continue
            if protected is not None and path == protected:
                ensure_private_file(path)
                continue
            if retention_days == 0 or path.stat().st_mtime < cutoff:
                path.unlink()
            else:
                ensure_private_file(path)
        except OSError:
            continue


def _remove_file(path: Path) -> None:
    try:
        path.unlink(missing_ok=True)
    except OSError:
        pass

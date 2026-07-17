from __future__ import annotations

from pathlib import Path

from vibe_stick.config.storage import ensure_private_dir, ensure_private_file


APP_SUPPORT_DIR = (
    Path.home() / "Library" / "Application Support" / "VibeStick"
)
STATE_PATH = APP_SUPPORT_DIR / "state.json"
QUOTA_PATH = APP_SUPPORT_DIR / "quota.json"
CLAUDE_QUOTA_PATH = APP_SUPPORT_DIR / "claude-quota.json"
RECORDING_PATH = APP_SUPPORT_DIR / "recording.json"
HUD_STATE_PATH = APP_SUPPORT_DIR / "hud-state.json"
RECORDINGS_DIR = APP_SUPPORT_DIR / "Recordings"
MIC_RECORDER_PATH = APP_SUPPORT_DIR / "vibe_stick_mic_recorder"
MIC_RECORDER_STAMP_PATH = APP_SUPPORT_DIR / "vibe_stick_mic_recorder.sha256"


def ensure_app_support() -> Path:
    ensure_private_dir(APP_SUPPORT_DIR)
    for path in (
        STATE_PATH,
        QUOTA_PATH,
        CLAUDE_QUOTA_PATH,
        RECORDING_PATH,
        HUD_STATE_PATH,
    ):
        ensure_private_file(path)
    if RECORDINGS_DIR.exists():
        ensure_private_dir(RECORDINGS_DIR)
        try:
            recording_files = tuple(RECORDINGS_DIR.iterdir())
        except OSError:
            recording_files = ()
        for path in recording_files:
            try:
                if path.is_file():
                    ensure_private_file(path)
            except OSError:
                continue
    ensure_private_file(MIC_RECORDER_PATH, executable=True)
    ensure_private_file(MIC_RECORDER_STAMP_PATH)
    return APP_SUPPORT_DIR

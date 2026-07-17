from __future__ import annotations

import platform
import subprocess
import time
from dataclasses import dataclass


@dataclass
class PasteResult:
    success: bool
    message: str


class MacPasteInjector:
    def press_enter(self) -> PasteResult:
        return self._run_osascript(
            ['tell application "System Events" to key code 36'],
            success_message="Pressed Return in the focused app",
        )

    def pause_current_codex_task(self) -> PasteResult:
        # Codex uses Escape to focus the composer (when needed), show the stop
        # confirmation, and then interrupt the current turn. The final Escape
        # is harmless when the composer was already focused and the turn has
        # stopped after the second one.
        return self._run_osascript(
            [
                'tell application id "com.openai.codex" to activate',
                "delay 0.12",
                'tell application "System Events" to key code 53',
                "delay 0.16",
                'tell application "System Events" to key code 53',
                "delay 0.16",
                'tell application "System Events" to key code 53',
            ],
            success_message="Sent the Codex stop shortcut",
        )

    def paste(self, text: str, press_enter: bool = False) -> PasteResult:
        text = text.strip()
        if not text:
            return PasteResult(False, "No text to paste")
        if platform.system() != "Darwin":
            return PasteResult(False, "Automatic paste is only available on macOS")

        previous_text = self._read_clipboard()
        set_result = self._set_clipboard(text)
        if not set_result.success:
            return set_result

        script = [
            'tell application "System Events" to keystroke "v" using command down',
        ]
        if press_enter:
            script.extend([
                "delay 0.12",
                'tell application "System Events" to key code 36',
            ])

        result = self._run_osascript(script, success_message="Pasted into the focused app")
        time.sleep(0.2)
        if previous_text is not None:
            self._set_clipboard(previous_text)

        return result

    def _run_osascript(self, script: list[str], *, success_message: str) -> PasteResult:
        if platform.system() != "Darwin":
            return PasteResult(False, "macOS keyboard control is only available on macOS")

        args = ["osascript"]
        for line in script:
            args.extend(["-e", line])
        try:
            result = subprocess.run(args, check=False, capture_output=True, text=True, timeout=5)
        except (OSError, subprocess.TimeoutExpired) as exc:
            return PasteResult(False, f"macOS keyboard control failed: {exc}")
        if result.returncode != 0:
            message = (result.stderr or result.stdout or "macOS keyboard control failed").strip()
            return PasteResult(False, message)
        return PasteResult(True, success_message)

    def _read_clipboard(self) -> str | None:
        try:
            result = subprocess.run(
                ["pbpaste"],
                check=False,
                capture_output=True,
                text=True,
                timeout=2,
            )
        except (OSError, subprocess.TimeoutExpired):
            return None
        if result.returncode != 0:
            return None
        return result.stdout

    def _set_clipboard(self, text: str) -> PasteResult:
        try:
            result = subprocess.run(
                ["pbcopy"],
                input=text,
                check=False,
                capture_output=True,
                text=True,
                timeout=2,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            return PasteResult(False, f"Clipboard write failed: {exc}")
        if result.returncode != 0:
            message = (result.stderr or "Clipboard write failed").strip()
            return PasteResult(False, message)
        return PasteResult(True, "Clipboard updated")

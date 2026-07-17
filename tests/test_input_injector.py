from __future__ import annotations

import subprocess
import unittest
from unittest import mock

from vibe_stick.paste.input_injector import MacPasteInjector


class MacInputInjectorTests(unittest.TestCase):
    @mock.patch("vibe_stick.paste.input_injector.platform.system", return_value="Darwin")
    @mock.patch("vibe_stick.paste.input_injector.subprocess.run")
    def test_press_enter_sends_return_key(self, run: mock.Mock, _system: mock.Mock) -> None:
        run.return_value = subprocess.CompletedProcess([], 0, "", "")

        result = MacPasteInjector().press_enter()

        self.assertTrue(result.success)
        args = run.call_args.args[0]
        self.assertIn('tell application "System Events" to key code 36', args)

    @mock.patch("vibe_stick.paste.input_injector.platform.system", return_value="Darwin")
    @mock.patch("vibe_stick.paste.input_injector.subprocess.run")
    def test_pause_targets_codex_and_confirms_stop(self, run: mock.Mock, _system: mock.Mock) -> None:
        run.return_value = subprocess.CompletedProcess([], 0, "", "")

        result = MacPasteInjector().pause_current_codex_task()

        self.assertTrue(result.success)
        args = run.call_args.args[0]
        self.assertIn('tell application id "com.openai.codex" to activate', args)
        self.assertEqual(args.count('tell application "System Events" to key code 53'), 3)

    @mock.patch("vibe_stick.paste.input_injector.platform.system", return_value="Linux")
    @mock.patch("vibe_stick.paste.input_injector.subprocess.run")
    def test_keyboard_actions_fail_cleanly_off_macos(self, run: mock.Mock, _system: mock.Mock) -> None:
        result = MacPasteInjector().press_enter()

        self.assertFalse(result.success)
        run.assert_not_called()


if __name__ == "__main__":
    unittest.main()

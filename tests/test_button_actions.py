from __future__ import annotations

import threading
import unittest
from unittest import mock

from vibe_stick.paste.input_injector import PasteResult
from vibe_stick.protocol.state import AlertState, AlertType, default_state
from vibe_stick.server import app


class ButtonActionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.store = app.BridgeStateStore.__new__(app.BridgeStateStore)
        self.store._lock = threading.RLock()
        self.store._state = default_state()
        self.store._state.alert = AlertState(event_id="done", type=AlertType.DONE, message="done")
        self.store._save_state_locked = mock.Mock()
        self.store.refresh_quota_locked = mock.Mock()
        self.store.input_injector = mock.Mock()
        self.store.input_injector.press_enter.return_value = PasteResult(True, "sent")
        self.store.input_injector.pause_current_codex_task.return_value = PasteResult(True, "paused")

    def test_short_press_sends_and_clears_alert(self) -> None:
        self.store.update_from_event({"event": "button_short"})

        self.store.input_injector.press_enter.assert_called_once_with()
        self.store.input_injector.pause_current_codex_task.assert_not_called()
        self.assertEqual(self.store._state.alert.type, AlertType.NONE)

    def test_double_click_pauses_without_refreshing_quota(self) -> None:
        self.store.update_from_event({"event": "button_double"})

        self.store.input_injector.pause_current_codex_task.assert_called_once_with()
        self.store.input_injector.press_enter.assert_not_called()
        self.store.refresh_quota_locked.assert_not_called()


if __name__ == "__main__":
    unittest.main()

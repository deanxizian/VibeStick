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
        self.store._post_recording_action_until = float("inf")
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

    def test_clicks_are_ignored_before_recording_window_opens(self) -> None:
        self.store._post_recording_action_until = 0.0

        self.store.update_from_event({"event": "button_short"})
        self.store.update_from_event({"event": "button_double"})

        self.store.input_injector.press_enter.assert_not_called()
        self.store.input_injector.pause_current_codex_task.assert_not_called()
        self.assertEqual(self.store._state.alert.type, AlertType.DONE)

    def test_clicks_are_ignored_after_recording_window_expires(self) -> None:
        self.store._post_recording_action_until = 30.0

        with mock.patch.object(app.time, "monotonic", return_value=30.1):
            self.store.update_from_event({"event": "button_short"})
            self.store.update_from_event({"event": "button_double"})

        self.store.input_injector.press_enter.assert_not_called()
        self.store.input_injector.pause_current_codex_task.assert_not_called()
        self.assertEqual(self.store._post_recording_action_until, 0.0)

    def test_successful_recording_stop_opens_thirty_second_window(self) -> None:
        session = mock.Mock(status="pasted")
        session.to_public_jsonable.return_value = {"status": "pasted"}
        self.store.recording = mock.Mock()
        self.store.recording.stop.return_value = session
        self.store.get_state = mock.Mock(return_value=default_state())

        with mock.patch.object(app.time, "monotonic", return_value=100.0):
            self.store.stop_recording({"session_id": "recording"})

        self.assertEqual(self.store._post_recording_action_until, 130.0)

    def test_new_recording_closes_existing_window(self) -> None:
        session = mock.Mock()
        session.to_public_jsonable.return_value = {"status": "recording"}
        self.store.recording = mock.Mock()
        self.store.recording.start.return_value = session
        self.store.get_state = mock.Mock(return_value=default_state())

        self.store.start_recording({"session_id": "next-recording"})

        self.assertEqual(self.store._post_recording_action_until, 0.0)

    def test_failed_recording_stop_closes_existing_window(self) -> None:
        session = mock.Mock(status="transcription_failed")
        session.to_public_jsonable.return_value = {"status": "transcription_failed"}
        self.store.recording = mock.Mock()
        self.store.recording.stop.return_value = session
        self.store.get_state = mock.Mock(return_value=default_state())

        self.store.stop_recording({"session_id": "recording"})

        self.assertEqual(self.store._post_recording_action_until, 0.0)


if __name__ == "__main__":
    unittest.main()

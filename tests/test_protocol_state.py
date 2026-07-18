import unittest
import json

from vibe_stick.protocol.state import AgentStatus, ProviderState, default_state, state_from_dict


class ProtocolStateTests(unittest.TestCase):
    def test_bridge_state_never_serializes_remote_battery(self) -> None:
        state = state_from_dict(
            {
                "wifi": True,
                "battery": 82,
                "codex": {"status": "RUNNING", "project": "VibeStick"},
                "alert": {"type": "NONE"},
            }
        )

        self.assertIsNone(state.to_jsonable()["battery"])

    def test_legacy_codex_block_populates_generic_provider(self) -> None:
        state = state_from_dict(
            {
                "codex": {
                    "status": "RUNNING",
                    "project": "VibeStick",
                    "quota_5h_remaining": 66,
                    "quota_7d_remaining": 96,
                    "quota_updated_at": "09:38",
                    "active_conversations": 2,
                }
            }
        )

        payload = state.to_jsonable()
        self.assertEqual(payload["active_provider"], "codex")
        self.assertEqual(payload["provider"]["id"], "codex")
        self.assertEqual(payload["provider"]["status"], "RUNNING")
        self.assertEqual(payload["provider"]["quota_5h_remaining"], 66)
        self.assertEqual(payload["provider"]["active_conversations"], 2)
        self.assertEqual(payload["codex"]["status"], "RUNNING")
        self.assertEqual(payload["codex"]["active_conversations"], 2)

    def test_generic_provider_block_serializes_status_string(self) -> None:
        state = default_state()
        state.active_provider = "claude"
        state.provider = ProviderState(
            id="claude",
            display_name="Claude",
            implemented=True,
            status=AgentStatus.ERROR,
            project="VibeStick",
            quota_5h_remaining=None,
            quota_7d_remaining=None,
            quota_updated_at="",
            quota_stale=False,
        )

        payload = state.to_jsonable()

        self.assertEqual(payload["active_provider"], "claude")
        self.assertEqual(payload["provider"]["id"], "claude")
        self.assertEqual(payload["provider"]["status"], "ERROR")

    def test_non_object_state_returns_defaults(self) -> None:
        for payload in ([], None, "invalid"):
            with self.subTest(payload=payload):
                self.assertEqual(state_from_dict(payload).to_jsonable(), default_state().to_jsonable())

    def test_malformed_nested_state_is_safely_normalized(self) -> None:
        state = state_from_dict(
            {
                "provider": {"status": [], "quota_5h_remaining": {}},
                "codex": {
                    "status": "NOT_A_STATUS",
                    "quota_5h_remaining": float("inf"),
                    "quota_7d_remaining": 140,
                    "active_conversations": 140,
                },
                "alert": {"type": []},
            }
        )

        self.assertEqual(state.provider.status, AgentStatus.UNKNOWN)
        self.assertIsNone(state.provider.quota_5h_remaining)
        self.assertEqual(state.codex.status, AgentStatus.UNKNOWN)
        self.assertIsNone(state.codex.quota_5h_remaining)
        self.assertEqual(state.codex.quota_7d_remaining, 100)
        self.assertEqual(state.provider.active_conversations, 0)
        self.assertEqual(state.codex.active_conversations, 99)
        self.assertEqual(state.alert.type.value, "NONE")

    def test_device_state_has_bounded_utf8_fields_and_payload(self) -> None:
        state = default_state()
        state.active_provider = "供" * 1000
        state.provider.id = "供" * 1000
        state.provider.display_name = "供" * 1000
        state.provider.project = "供" * 1000
        state.provider.quota_updated_at = "供" * 1000
        state.codex.project = "供" * 1000
        state.codex.quota_updated_at = "供" * 1000
        state.alert.event_id = "evt_" + "x" * 5000
        state.alert.message = "供" * 5000

        payload = state.to_jsonable()
        encoded = json.dumps(payload, ensure_ascii=False).encode("utf-8")

        self.assertLessEqual(len(payload["active_provider"].encode("utf-8")), 15)
        self.assertLessEqual(len(payload["provider"]["project"].encode("utf-8")), 36)
        self.assertLessEqual(len(payload["alert"]["event_id"].encode("utf-8")), 55)
        self.assertLessEqual(len(payload["alert"]["message"].encode("utf-8")), 72)
        self.assertLess(len(encoded), 1400)

    def test_lone_surrogate_is_replaced_at_device_boundary(self) -> None:
        state = default_state()
        state.provider.project = "broken\ud800project"
        state.alert.event_id = "evt_\ud800"
        state.alert.message = "broken\ud800message"

        payload = state.to_jsonable()

        json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.assertNotIn("\ud800", payload["provider"]["project"])
        self.assertNotIn("\ud800", payload["alert"]["message"])


if __name__ == "__main__":
    unittest.main()

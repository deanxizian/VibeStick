import json
import tempfile
import unittest
from pathlib import Path

from vibe_stick.codex.quota import QuotaSnapshot, load_quota, save_quota


class QuotaTests(unittest.TestCase):
    def test_load_quota_clamps_percentages(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "quota.json"
            path.write_text(
                json.dumps(
                    {
                        "quota_5h_remaining": 150,
                        "quota_7d_remaining": -20,
                        "quota_updated_at": "12:00",
                    }
                )
            )

            quota = load_quota(path)

        self.assertEqual(quota.quota_5h_remaining, 100)
        self.assertEqual(quota.quota_7d_remaining, 0)
        self.assertEqual(quota.quota_updated_at, "12:00")

    def test_save_and_load_quota_round_trips(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "quota.json"
            save_quota(path, QuotaSnapshot(53, 93, "13:01", False))
            quota = load_quota(path)

        self.assertEqual(quota, QuotaSnapshot(53, 93, "13:01", False))

    def test_non_object_quota_is_ignored(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "quota.json"
            for payload in ("[]", "null"):
                with self.subTest(payload=payload):
                    path.write_text(payload)
                    self.assertEqual(load_quota(path), QuotaSnapshot())

    def test_non_finite_and_boolean_quota_values_are_ignored(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "quota.json"
            path.write_text('{"quota_5h_remaining": 1e999, "quota_7d_remaining": true}')

            quota = load_quota(path)

        self.assertIsNone(quota.quota_5h_remaining)
        self.assertIsNone(quota.quota_7d_remaining)


if __name__ == "__main__":
    unittest.main()

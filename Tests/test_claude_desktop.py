import sys
import time
import tempfile
import unittest
import types
import urllib.error
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1] / "Scripts"))
import claude_desktop as direct
import claude_bridge as bridge


class DirectUsageTests(unittest.TestCase):
    def test_server_percent_and_reset(self):
        raw = {"five_hour": {"utilization": 89, "resets_at": "2030-01-01T00:00:00Z"},
               "seven_day": {"utilization": 13, "resets_at": "2030-01-02T00:00:00Z"}}
        value = direct.parse_usage(raw, "account-hash", 1800000000)
        self.assertEqual([100-w["usedPercent"] for w in value["windows"]], [11, 87])
        self.assertEqual(value["windows"][0]["resetAt"], "2030-01-01T00:00:00Z")
        self.assertEqual(value["source"], "claude-desktop-direct")

    def test_weekly_fallback_missing_and_invalid(self):
        raw = {"seven_day": {"utilization": 13, "resets_at": "2030-01-02T00:00:00Z"}}
        self.assertEqual(len(direct.parse_usage(raw, "a", 1800000000)["windows"]), 1)
        self.assertEqual(direct.parse_usage({}, "a", 1800000000)["windows"], [])
        for value in [True, -1, 101, float("nan"), "13"]:
            raw["seven_day"]["utilization"] = value
            with self.assertRaises(ValueError):
                direct.parse_usage(raw, "a", 1800000000)

    def test_token_matches_account_org_scope_expiry(self):
        key = "acct:A|client:org:https://api.anthropic.com:user:inference user:profile"
        entries = {key: {"token": "fixture-not-a-secret", "expiresAt": 1900000000000}}
        self.assertEqual(direct.select_token(entries, "A", "org", 1800000000), "fixture-not-a-secret")
        for account, org, now in [("B", "org", 1800000000), ("A", "other", 1800000000),
                                  ("A", "org", 1900000000)]:
            with self.assertRaises(ValueError):
                direct.select_token(entries, account, org, now)

    def test_cache_polling_and_account_switch(self):
        with tempfile.TemporaryDirectory() as folder:
            args = types.SimpleNamespace(data_dir=Path(folder))
            snapshot = direct.parse_usage({}, "A", time.time())
            with patch.object(direct, "fetch", return_value=snapshot) as fetch, \
                 patch.object(bridge, "desktop_identity", return_value=("A", 1)):
                bridge.direct_desktop_snapshot(args, Path(folder), ("A", 1))
                bridge.direct_desktop_snapshot(args, Path(folder), ("A", 1))
                self.assertEqual(fetch.call_count, 1)
            with patch.object(direct, "fetch", return_value=snapshot) as fetch, \
                 patch.object(bridge, "desktop_identity", return_value=("C", 1)):
                result = bridge.direct_desktop_snapshot(args, Path(folder), ("B", 1))
                self.assertEqual(result["windows"], [])
                self.assertIn("계정 변경", result["statusMessage"])
                self.assertEqual(fetch.call_count, 1)
            result = bridge.direct_desktop_snapshot(args, Path(folder), None)
            self.assertEqual(result["windows"], [])

    def test_rate_limit_backoff_and_redacted_error(self):
        with tempfile.TemporaryDirectory() as folder:
            args = types.SimpleNamespace(data_dir=Path(folder))
            error = urllib.error.HTTPError(direct.ENDPOINT, 429, "secret-must-not-appear", {}, None)
            with patch.object(direct, "fetch", side_effect=error) as fetch, \
                 patch.object(bridge, "desktop_identity", return_value=("A", 1)):
                result = bridge.direct_desktop_snapshot(args, Path(folder), ("A", 1))
                bridge.direct_desktop_snapshot(args, Path(folder), ("A", 1))
                self.assertEqual(fetch.call_count, 1)
            saved = (Path(folder) / "claude-direct-state.json").read_text()
            self.assertNotIn("secret-must-not-appear", saved)
            self.assertEqual(result["windows"], [])
            self.assertIn("5분", result["statusMessage"])

    def test_redirect_never_forwards_bearer(self):
        self.assertIsNone(direct.NoRedirect().redirect_request(None, None, None, None, None, None))


if __name__ == "__main__":
    unittest.main()

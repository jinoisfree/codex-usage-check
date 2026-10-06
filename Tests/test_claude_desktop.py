import sys
import datetime as dt
import json
import subprocess
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
            self.assertIn("요청 제한", result["statusMessage"])
            state = json.loads(saved)
            self.assertEqual(state["nextAttempt"] - state["lastAttemptAt"], 300)

    def test_redirect_never_forwards_bearer(self):
        self.assertIsNone(direct.NoRedirect().redirect_request(None, None, None, None, None, None))


class DirectRetentionTests(unittest.TestCase):
    now = 1800000000
    secret = "fixture-sensitive-text-must-not-be-saved"

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.args = types.SimpleNamespace(data_dir=self.directory / "cache")
        self.state_path = self.args.data_dir / "claude-direct-state.json"
        self.context = ("A", self.now - 10)

    def value(self, identity="A", short_reset=None):
        def reset(seconds):
            return dt.datetime.fromtimestamp(seconds, dt.timezone.utc).isoformat().replace("+00:00", "Z")
        return direct.parse_usage(dict(
            five_hour=dict(utilization=23.1, resets_at=reset(short_reset or self.now + 7200)),
            seven_day=dict(utilization=41, resets_at=reset(self.now + 14400))), identity, self.now)

    def read(self, at, value=None, error=None, context=None):
        context = self.context if context is None else context
        with patch.object(bridge.time, "time", return_value=at), \
             patch.object(bridge, "desktop_identity", return_value=context), \
             patch.object(direct, "fetch", return_value=value, side_effect=error) as fetch:
            result = bridge.direct_desktop_snapshot(self.args, self.directory, context)
        return result, fetch.call_count

    def state(self):
        return json.loads(self.state_path.read_text())

    def history(self, identity="A", observed=None):
        bridge.atomic_json(self.directory / "plan-usage-history.json", dict(version=2, samples=[
            dict(t=(observed or self.now)*1000, org="fixture-org", u=dict(fh=70, sd=11))]))

    def command(self, mode):
        with patch.object(sys, "argv", ["claude_bridge.py", "--data-dir", str(self.args.data_dir), mode]):
            bridge.main()

    def test_failure_retains_observation_without_freshening(self):
        initial, _ = self.read(self.now, value=self.value())
        for at, error in [(self.now + 120, urllib.error.URLError(self.secret)),
                          (self.now + 240, ValueError(self.secret))]:
            result, calls = self.read(at, error=error)
            self.assertEqual(calls, 1)
            self.assertEqual(result["windows"], initial["windows"])
            self.assertEqual(result["updatedAt"], initial["updatedAt"])
            self.assertIn("이전 값 표시", result["detail"])
            self.assertNotIn("statusMessage", result)
            self.assertNotIn(self.secret, self.state_path.read_text())
        self.assertEqual(set(self.state()), {"identity", "nextAttempt", "lastSuccess",
                         "lastAttemptAt", "lastResult", "limitedCount", "blocked"})

    def test_sixty_minute_retention_boundary(self):
        self.read(self.now, value=self.value())
        result, _ = self.read(self.now + 3600, error=TimeoutError(self.secret))
        self.assertEqual(len(result["windows"]), 2)
        result, calls = self.read(self.now + 3601, error=TimeoutError(self.secret))
        self.assertEqual(calls, 0)
        self.assertEqual(result["windows"], [])
        self.assertNotIn("이전 값 표시", result["detail"])

    def test_expired_windows_removed_during_backoff(self):
        self.read(self.now, value=self.value(short_reset=self.now + 180))
        self.read(self.now + 120, error=urllib.error.HTTPError(direct.ENDPOINT, 429, self.secret, {}, None))
        result, calls = self.read(self.now + 181)
        self.assertEqual(calls, 0)
        self.assertEqual([w["id"] for w in result["windows"]], ["seven_day"])
        self.assertEqual(result["updatedAt"], self.value()["updatedAt"])

    def test_repeated_429_backoff_cap_and_success_reset(self):
        self.read(self.now, value=self.value())
        at = self.now + 120
        error = urllib.error.HTTPError(direct.ENDPOINT, 429, self.secret, {}, None)
        for delay in (300, 600, 1200, 1200):
            result, calls = self.read(at, error=error)
            self.assertEqual(calls, 1)
            self.assertEqual(self.state()["nextAttempt"], at + delay)
            self.assertEqual(self.state()["lastResult"], "limited")
            self.assertIn("요청 제한", result["detail"])
            self.assertNotIn(self.secret, self.state_path.read_text())
            _, calls = self.read(at + delay - 1, error=error)
            self.assertEqual(calls, 0)
            at += delay
        self.read(at, value=direct.parse_usage(dict(seven_day=dict(
            utilization=50, resets_at="2030-01-01T00:00:00Z")), "A", at))
        self.assertEqual(self.state()["limitedCount"], 0)
        self.assertEqual(self.state()["nextAttempt"], at + 120)
        self.assertEqual(self.state()["lastResult"], "success")
        self.read(at + 120, error=error)
        self.assertEqual(self.state()["nextAttempt"], at + 420)
        self.read(at + 420, error=TimeoutError(self.secret))
        self.assertEqual(self.state()["limitedCount"], 0)
        self.assertEqual(self.state()["nextAttempt"], at + 540)

    def test_keychain_blocks_fetch_until_enable_and_disable_clears_state(self):
        self.read(self.now, value=self.value())
        result, _ = self.read(self.now + 120, error=direct.UsageReadError("keychain_unavailable"))
        self.assertEqual(result["windows"], [])
        self.assertTrue(self.state()["blocked"])
        self.assertIsNone(self.state()["lastSuccess"])
        self.assertEqual(result["detail"], "키체인 접근 거부 · 다시 켜면 재시도")
        for at, context in [(self.now + 240, self.context), (self.now + 3600, ("B", self.now))]:
            _, calls = self.read(at, value=self.value(), context=context)
            self.assertEqual(calls, 0)
            self.assertTrue(self.state()["blocked"])
        self.command("enable-desktop-direct")
        self.assertEqual(self.state(), {})
        self.assertTrue(bridge.read_json(self.args.data_dir / "claude-direct-consent.json", {})["enabled"])
        result, calls = self.read(self.now + 3601, value=self.value())
        self.assertEqual(calls, 1)
        self.assertFalse(self.state()["blocked"])
        self.command("disable-desktop-direct")
        self.assertEqual(self.state(), {})
        self.assertFalse(bridge.read_json(self.args.data_dir / "claude-direct-consent.json", {})["enabled"])

    def test_missing_direct_value_falls_back_to_history_with_binding(self):
        self.history()
        for error in [TimeoutError(self.secret), direct.UsageReadError("keychain_unavailable")]:
            bridge.atomic_json(self.state_path, {})
            result, _ = self.read(self.now, error=error)
            self.assertEqual(result["source"], "claude-desktop-history")
            self.assertEqual(result["windows"][0]["usedPercent"], 70)
            self.assertNotIn("이전 값 표시", result["detail"])
            binding = bridge.read_json(self.args.data_dir / "claude-desktop-binding.json", {})
            self.assertEqual(binding["identity"], "A")

    def test_expired_direct_value_falls_back_to_fresh_history(self):
        self.read(self.now, value=self.value(short_reset=self.now + 180))
        self.history(observed=self.now + 3601)
        result, _ = self.read(self.now + 3601, error=TimeoutError())
        self.assertEqual(result["source"], "claude-desktop-history")
        self.assertNotIn("이전 값 표시", result["detail"])

    def test_account_or_org_transition_never_retains_old_value(self):
        self.history()
        self.read(self.now, value=self.value())
        result, _ = self.read(self.now + 120, error=TimeoutError(), context=("B", self.now - 10))
        self.assertEqual(result["windows"], [])
        self.assertEqual(result["accountKey"], "B")
        self.assertIsNone(self.state()["lastSuccess"])
        binding = bridge.read_json(self.args.data_dir / "claude-desktop-binding.json", {})
        self.assertEqual(binding["identity"], "B")
        self.assertEqual(binding["since"], self.now + 120)

    def test_identity_changes_during_request_discard_response(self):
        self.read(self.now, value=self.value())
        with patch.object(bridge.time, "time", return_value=self.now + 120), \
             patch.object(bridge, "desktop_identity", return_value=("B", self.now)), \
             patch.object(direct, "fetch", return_value=self.value()):
            result = bridge.direct_desktop_snapshot(self.args, self.directory, self.context)
        self.assertEqual(result["windows"], [])
        self.assertIn("계정 변경", result["statusMessage"])
        self.assertIsNone(self.state()["lastSuccess"])

    def test_direct_toggle_takes_effect_with_existing_cli_connection(self):
        bridge.atomic_json(self.args.data_dir / "bridge-config.json", dict(
            executable="/fixture/claude", configDirectory=str(self.directory)))
        bridge.atomic_json(self.args.data_dir / "claude-direct-consent.json", dict(enabled=True))
        with patch.object(sys, "argv", ["claude_bridge.py", "--data-dir", str(self.args.data_dir), "read"]), \
             patch.object(bridge, "read_desktop") as desktop, \
             patch.object(bridge, "account_identity") as cli:
            bridge.main()
        desktop.assert_called_once()
        cli.assert_not_called()

    def test_failure_detail_labels_and_redaction(self):
        clock = dt.datetime.fromtimestamp(self.now).strftime("%H:%M")
        self.assertEqual(bridge.direct_status(None, None, False), "조회 대기 중")
        self.assertEqual(bridge.direct_status(self.now, "success", False), "마지막 조회 " + clock + " 성공")
        cases = [
            (direct.UsageReadError("login_missing"), "로그인 정보 없음", "login_missing"),
            (direct.UsageReadError("token_missing"), "로그인 만료", "token_missing"),
            (urllib.error.HTTPError(direct.ENDPOINT, 401, self.secret, {}, None), "인증 거부", "authentication"),
            (urllib.error.HTTPError(direct.ENDPOINT, 403, self.secret, {}, None), "인증 거부", "authentication"),
            (urllib.error.HTTPError(direct.ENDPOINT, 429, self.secret, {}, None), "요청 제한", "limited"),
            (urllib.error.HTTPError(direct.ENDPOINT, 503, self.secret, {}, None), "HTTP 503", "http_503"),
            (urllib.error.URLError(self.secret), "시간 초과·연결 실패", "network"),
            (TimeoutError(self.secret), "시간 초과·연결 실패", "network"),
            (ValueError(self.secret), "응답 형식 다름", "format")]
        for error, label, code in cases:
            with self.subTest(code=code):
                bridge.atomic_json(self.state_path, {})
                result, _ = self.read(self.now, error=error)
                self.assertEqual(self.state()["lastResult"], code)
                self.assertIn(label, result["detail"])
                self.assertIn(clock, result["detail"])
                self.assertEqual(result["statusMessage"], result["detail"])
                self.assertNotIn(self.secret, self.state_path.read_text())
                if code in ("login_missing", "token_missing", "authentication"):
                    self.assertEqual(result["detail"], clock + " " + label + " · Claude Code 탭 확인")
                else:
                    self.assertEqual(result["detail"], "마지막 조회 " + clock + " 실패: " + label)
        self.assertIn("이전 값 표시", bridge.direct_status(self.now, "limited", True))
        self.assertNotIn("이전 값 표시", bridge.direct_status(self.now, "token_missing", True))


class DirectFailureClassificationTests(unittest.TestCase):
    def test_missing_login_never_opens_keychain(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(direct.subprocess, "run") as security:
            directory = Path(folder)
            for config in [None, {}, [], {"lastKnownAccountUuid": "A"}]:
                if config is not None:
                    (directory / "config.json").write_text(json.dumps(config))
                with self.assertRaises(direct.UsageReadError) as raised:
                    direct.credentials(directory)
                self.assertEqual(raised.exception.code, "login_missing")
            security.assert_not_called()

    def test_keychain_failures_are_classified_without_secret_text(self):
        secret = b"fixture-private-keychain-value"
        with tempfile.TemporaryDirectory() as folder:
            directory = Path(folder)
            (directory / "config.json").write_text(json.dumps(dict(
                lastKnownAccountUuid="A", **{"oauth:tokenCacheV2": "djEw"})))
            for outcome in [types.SimpleNamespace(returncode=1, stdout=secret),
                            subprocess.TimeoutExpired("security", 15, output=secret)]:
                with patch.object(direct.subprocess, "run",
                                  side_effect=outcome if isinstance(outcome, Exception) else None,
                                  return_value=outcome):
                    with self.assertRaises(direct.UsageReadError) as raised:
                        direct.credentials(directory)
                self.assertEqual(raised.exception.code, "keychain_unavailable")
                self.assertNotIn(secret.decode(), str(raised.exception))

    def test_missing_organization_and_expired_token(self):
        with tempfile.TemporaryDirectory() as folder:
            directory = Path(folder)
            (directory / "config.json").write_text(json.dumps(dict(
                lastKnownAccountUuid="A", **{"oauth:tokenCacheV2": "djEw"})))
            with patch.object(direct.subprocess, "run", return_value=types.SimpleNamespace(returncode=0, stdout=b"fixture")), \
                 patch.object(direct, "decrypt", return_value=b"{}"):
                with self.assertRaises(direct.UsageReadError) as raised:
                    direct.credentials(directory)
                self.assertEqual(raised.exception.code, "token_missing")
        with self.assertRaises(direct.UsageReadError) as raised:
            direct.select_token({}, "A", "org", 1800000000)
        self.assertEqual(raised.exception.code, "token_missing")

    def test_fetch_classifies_http_network_and_body_errors(self):
        secret = "fixture-server-body-must-stay-private"
        errors = [(urllib.error.HTTPError(direct.ENDPOINT, code, secret, {}, None), expected)
                  for code, expected in [(401, "authentication"), (403, "authentication"),
                                         (429, "limited"), (503, "http_503"), (302, "http_302")]]
        errors += [(urllib.error.URLError(secret), "network"), (TimeoutError(secret), "network")]
        with patch.object(direct, "credentials", return_value="fixture-token"), \
             patch.object(direct.urllib.request, "build_opener") as opener:
            for error, expected in errors:
                opener.return_value.open.side_effect = error
                with self.assertRaises(direct.UsageReadError) as raised:
                    direct.fetch(Path("/fixture"), "A", 1800000000)
                self.assertEqual(raised.exception.code, expected)
                self.assertNotIn(secret, str(raised.exception))
            opener.return_value.open.side_effect = None
            opener.return_value.open.return_value.__enter__.return_value.read.return_value = secret.encode()
            with self.assertRaises(direct.UsageReadError) as raised:
                direct.fetch(Path("/fixture"), "A", 1800000000)
            self.assertEqual(raised.exception.code, "format")
            self.assertNotIn(secret, str(raised.exception))
            request = opener.return_value.open.call_args.args[0]
            self.assertEqual(request.full_url, direct.ENDPOINT)


if __name__ == "__main__":
    unittest.main()

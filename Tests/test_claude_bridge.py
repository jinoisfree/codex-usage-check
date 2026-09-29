import importlib.util
import json
from pathlib import Path
import tempfile
import subprocess
import sys
import time
import types
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("bridge", Path(__file__).parents[1] /
                                             "Scripts/claude_bridge.py")
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


class ClaudeBridgeTests(unittest.TestCase):
    now = 1800000000

    def payload(self, session="one", used=23.5):
        return dict(session_id=session, rate_limits={
            "five_hour": dict(used_percentage=used, resets_at=self.now+300),
            "seven_day": dict(used_percentage=41, resets_at=self.now+600)})

    def start(self, key="A", session="one", state=None):
        return bridge.update(state or {}, "session",
                             dict(session_id=session, source="startup"), key, None, self.now)

    def test_percent_conversion_and_order(self):
        state = bridge.update(self.start(), "status", self.payload(), "A", None, self.now)
        self.assertEqual([w["usedPercent"] for w in state["snapshot"]["windows"]], [24, 41])
        self.assertEqual(state["snapshot"]["windows"][0]["id"], "five_hour")

    def test_unknown_session_not_accepted(self):
        state = bridge.update(self.start(), "status", self.payload("unknown"), "A", None, self.now)
        self.assertEqual(state["snapshot"]["windows"], [])

    def test_account_switch_rejects_old_session(self):
        state = bridge.update(self.start(), "status", self.payload(), "A", None, self.now)
        state = bridge.update(state, "status", self.payload(), "B", None, self.now)
        self.assertEqual(state["snapshot"]["windows"], [])
        state = self.start("B", "new", state)
        state = bridge.update(state, "status", self.payload("new", 72), "B", None, self.now)
        state = bridge.update(state, "status", self.payload("one", 1), "B", None, self.now)
        self.assertEqual(state["snapshot"]["windows"][0]["usedPercent"], 72)

    def test_logout_and_error_hide_previous_value(self):
        state = bridge.update(self.start(), "status", self.payload(), "A", None, self.now)
        state = bridge.update(state, "read", {}, None, "로그인 필요", self.now)
        self.assertEqual(state["snapshot"]["windows"], [])

    def test_missing_windows_and_expiration(self):
        self.assertEqual(bridge.parse_windows({}, self.now), [])
        state = bridge.update(self.start(), "status", self.payload(), "A", None, self.now)
        state = bridge.update(state, "read", {}, "A", None, self.now+301)
        self.assertEqual([w["id"] for w in state["snapshot"]["windows"]], ["seven_day"])
        state = bridge.update(state, "read", {}, "A", None, self.now+601)
        self.assertEqual(state["snapshot"]["windows"], [])
        self.assertIn("재확인", state["snapshot"]["statusMessage"])

    def test_invalid_values_do_not_become_zero(self):
        for value in (None, True, "10", float("nan"), float("inf"), -1, 101):
            payload = self.payload(used=value)
            self.assertEqual(len(bridge.parse_windows(payload, self.now)), 1)

    def test_repeated_payload_does_not_renew_observation(self):
        state = bridge.update(self.start(), "status", self.payload(), "A", None, self.now)
        state["snapshot"]["updatedAt"] = "2000-01-01T00:00:00Z"
        state = bridge.update(state, "status", self.payload(), "A", None, self.now+1)
        self.assertEqual(state["snapshot"]["updatedAt"], "2000-01-01T00:00:00Z")

    def test_identity_keeps_no_email(self):
        raw = dict(loggedIn=True, authMethod="claude.ai", email="example@example.test",
                   orgId="org")
        with patch.object(bridge.subprocess, "run", return_value=types.SimpleNamespace(
                returncode=0, stdout=json.dumps(raw))):
            key, error = bridge.account_identity("/mock/claude")
        self.assertIsNone(error)
        self.assertEqual(len(key), 64)
        self.assertNotIn("example", key)

    def test_connect_restore_preserves_unrelated_settings(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)/"claude"
            directory.mkdir()
            settings = directory/"settings.json"
            original = dict(statusLine=dict(type="command", command="printf hello", padding=2),
                            permissions=dict(allow=["Read"]))
            settings.write_text(json.dumps(original))
            args = types.SimpleNamespace(config_dir=str(directory), data_dir=Path(temp)/"cache")
            with patch.object(bridge.shutil, "which", return_value="/mock/claude"):
                bridge.configure(args)
                with self.assertRaises(ValueError):
                    bridge.configure(args)
            installed = json.loads(settings.read_text())
            self.assertEqual(installed["statusLine"]["padding"], 2)
            installed["unrelated"] = 42
            settings.write_text(json.dumps(installed))
            bridge.disconnect(args)
            restored = json.loads(settings.read_text())
            self.assertEqual(restored["statusLine"], original["statusLine"])
            self.assertEqual(restored["permissions"], original["permissions"])
            self.assertEqual(restored["unrelated"], 42)

    def test_real_process_pipeline_and_existing_status_output(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            cli = directory/"claude"
            cli.write_text("#!/bin/sh\nprintf '%s' '{\"loggedIn\":true,\"authMethod\":\"claude.ai\","
                           "\"email\":\"test@example.test\",\"orgId\":\"test\"}'\n")
            cli.chmod(0o700)
            bridge.atomic_json(directory/"bridge-config.json", dict(
                executable=str(cli), configDirectory=str(directory),
                previousStatus=dict(type="command", command="printf 'ORIGINAL STATUS'")))
            command = [sys.executable, str(Path(bridge.__file__)), "--data-dir", str(directory)]
            def run(mode, payload=None):
                result = subprocess.run(command+[mode], input=json.dumps(payload or {}),
                                        text=True, capture_output=True, timeout=8)
                self.assertEqual(result.returncode, 0, result.stderr)
                return result.stdout
            run("session", dict(session_id="one", source="startup"))
            payload = self.payload()
            for window in payload["rate_limits"].values():
                window["resets_at"] = time.time()+3600
            self.assertEqual(run("status", payload), "ORIGINAL STATUS")
            snapshot = json.loads(run("read"))
            self.assertEqual(snapshot["windows"][0]["usedPercent"], 24)
            persisted = (directory/"claude-state.json").read_text()
            self.assertNotIn("test@example.test", persisted)
            self.assertNotIn("transcript_path", persisted)

    def test_desktop_requires_observation_after_identity_change(self):
        history = dict(version=2, samples=[dict(t=self.now*1000, org="org", u=dict(fh=70, sd=11))])
        binding, snapshot = bridge.desktop_snapshot(history, {}, "A", self.now+1)
        self.assertEqual(snapshot["windows"], [])
        history["samples"].append(dict(t=(self.now+2)*1000, org="org", u=dict(fh=72, sd=11)))
        binding, snapshot = bridge.desktop_snapshot(history, binding, "A", self.now+3)
        self.assertEqual(snapshot["windows"][0]["usedPercent"], 72)
        self.assertIsNone(snapshot["windows"][0]["resetAt"])
        binding, snapshot = bridge.desktop_snapshot(history, binding, "B", self.now+4)
        self.assertEqual(snapshot["windows"], [])

    def test_desktop_logout_expiration_and_bad_schema(self):
        history = dict(version=2, samples=[dict(t=self.now*1000, org="org", u=dict(fh=0, sd=100))])
        binding = dict(identity="A", since=self.now-1)
        _, snapshot = bridge.desktop_snapshot(history, binding, "A", self.now+1801)
        self.assertEqual(snapshot["windows"], [])

    def test_desktop_bootstrap_requires_sample_after_login_metadata(self):
        history = dict(version=2, samples=[dict(t=self.now*1000, org="org", u=dict(fh=70))])
        _, snapshot = bridge.desktop_snapshot(history, {}, "A", self.now+5,
                                              verified_since=self.now-1)
        self.assertEqual(snapshot["windows"][0]["usedPercent"], 70)
        _, snapshot = bridge.desktop_snapshot(history, {}, "A", self.now+5,
                                              verified_since=self.now+1)
        self.assertEqual(snapshot["windows"], [])
        binding = dict(identity="A", since=self.now-1)
        _, snapshot = bridge.desktop_snapshot(history, binding, None, self.now)
        self.assertEqual(snapshot["windows"], [])
        _, snapshot = bridge.desktop_snapshot(dict(version=3), binding, "A", self.now)
        self.assertEqual(snapshot["windows"], [])


if __name__ == "__main__":
    unittest.main()

import contextlib
import importlib.util
import io
import os
from pathlib import Path
import plistlib
import shlex
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location("install_app", Path(__file__).parents[1] / "Scripts/install_app.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


def bundle(path, identifier=installer.BUNDLE_ID, executable=installer.EXECUTABLE,
           version="0.4.0", marker="old"):
    (path / "Contents/MacOS").mkdir(parents=True)
    with (path / "Contents/Info.plist").open("wb") as output:
        plistlib.dump(dict(CFBundleIdentifier=identifier, CFBundleExecutable=executable,
                          CFBundleShortVersionString=version), output)
    binary = path / "Contents/MacOS" / executable
    binary.write_text(marker)
    binary.chmod(0o755)
    extension = path / installer.EXTENSION
    (extension / "Contents/MacOS").mkdir(parents=True)
    with (extension / "Contents/Info.plist").open("wb") as output:
        plistlib.dump(dict(CFBundleIdentifier="com.jino.codex-usage.widget"), output)
    (extension / "Contents/MacOS" / installer.EXTENSION_EXECUTABLE).write_text(marker)
    return path


def marker(path):
    return (path / "Contents/MacOS" / installer.EXECUTABLE).read_text()


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.user = self.root / "home/Applications"
        self.other = self.root / "Applications"
        self.user.mkdir(parents=True)
        self.other.mkdir()
        self.source = bundle(self.root / "build" / installer.NAME, version="0.4.1", marker="new")
        self.destination = self.user / installer.NAME
        self.folders = [self.user, self.other]
        self.system = Mock(spec=installer.SystemCommands(enabled=False))
        self.system.agent_unloaded = False

    def install(self, **options):
        output, errors = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            installer.install(self.source, self.destination, self.folders, system=self.system, **options)
        return output.getvalue(), errors.getvalue()

    def assert_no_work(self):
        self.assertFalse(any(self.user.glob(".codex-usage-install-*")))

    def test_fresh_install(self):
        output, _ = self.install()
        self.assertEqual(marker(self.destination), "new")
        self.assertTrue((self.destination / "Contents/MacOS" / installer.EXECUTABLE).stat().st_mode & 0o111)
        self.assertIn("설치 완료", output)
        self.assertIn("0.4.1", output)
        self.assertTrue(self.source.exists())
        self.assert_no_work()

    def test_replace_removes_old_only_files_and_verifies_before_stop(self):
        bundle(self.destination)
        legacy = self.destination / "Contents/old-only.txt"
        legacy.write_text("old resource")

        def stop(apps):
            self.assertEqual(self.system.verify.call_count, 2)
            staged = self.system.verify.call_args.args[0]
            self.assertEqual(marker(staged), "new")
            self.assertEqual(marker(self.destination), "old")
            self.assertTrue(legacy.exists())
            self.assertIn(self.destination, apps)

        self.system.stop.side_effect = stop
        output, _ = self.install()
        self.assertEqual(marker(self.destination), "new")
        self.assertFalse(legacy.exists())
        self.assertIn("0.4.0 → 0.4.1", output)
        self.assert_no_work()

    def test_other_copies_and_backups_removed_after_unregister(self):
        copies = [bundle(self.other / installer.NAME),
                  bundle(self.user / (installer.NAME + ".bak-20261006")),
                  bundle(self.other / (installer.NAME + ".bak-old"))]

        def unregister(app):
            self.assertEqual(marker(self.destination), "new")
            self.assertTrue(app.is_dir())

        self.system.unregister.side_effect = unregister
        output, _ = self.install()
        for app in copies:
            self.assertFalse(app.exists())
            self.assertIn(str(app), output)
        self.assertEqual({call.args[0] for call in self.system.unregister.call_args_list}, set(copies))
        self.assertEqual(sorted(self.user.iterdir()), [self.destination])
        self.assertEqual(list(self.other.iterdir()), [])

    def test_foreign_products_files_and_symlinks_preserved(self):
        foreign_id = bundle(self.other / installer.NAME, identifier="com.example.other")
        foreign_executable = bundle(self.user / (installer.NAME + ".bak-other"), executable="Other")
        outside = bundle(self.root / "outside.app")
        linked = self.user / (installer.NAME + ".bak-link")
        linked.symlink_to(outside, target_is_directory=True)
        regular = self.other / (installer.NAME + ".bak-file")
        regular.write_text("keep")
        unrelated = bundle(self.other / "Unrelated.app")
        output, _ = self.install()
        self.assertEqual(marker(foreign_id), "old")
        self.assertTrue(foreign_executable.is_dir())
        self.assertTrue(linked.is_symlink())
        self.assertEqual(marker(outside), "old")
        self.assertEqual(regular.read_text(), "keep")
        self.assertEqual(marker(unrelated), "old")
        self.assertEqual(output.count("건드리지 않음"), 4)
        self.system.unregister.assert_not_called()

    def test_foreign_destination_aborts_without_modifying_anything(self):
        for kind in ("identifier", "executable", "file", "symlink"):
            with self.subTest(kind=kind):
                folder = self.root / kind
                folder.mkdir()
                destination = folder / installer.NAME
                peer = bundle(folder / (installer.NAME + ".bak-old"))
                if kind == "identifier":
                    bundle(destination, identifier="com.example.other")
                elif kind == "executable":
                    bundle(destination, executable="Other")
                elif kind == "file":
                    destination.write_text("foreign")
                else:
                    destination.symlink_to(self.source, target_is_directory=True)
                with self.assertRaisesRegex(RuntimeError, "건드리지"):
                    installer.install(self.source, destination, [folder], system=self.system)
                self.assertTrue(destination.exists())
                self.assertEqual(marker(peer), "old")
                self.assertEqual({path.name for path in folder.iterdir()}, {installer.NAME, peer.name})
        self.system.stop.assert_not_called()
        self.system.unregister.assert_not_called()

    def test_malformed_plist_copy_is_reported_and_preserved(self):
        other = self.other / installer.NAME
        (other / "Contents").mkdir(parents=True)
        contents = "<?xml version='1.0'?><plist><dict>"
        (other / "Contents/Info.plist").write_text(contents)
        output, _ = self.install()
        self.assertIn("건드리지 않음", output)
        self.assertEqual((other / "Contents/Info.plist").read_text(), contents)
        self.assertEqual(marker(self.destination), "new")
        self.system.unregister.assert_not_called()

    def test_source_and_staged_verification_failure_keep_old_install(self):
        bundle(self.destination)
        peer = bundle(self.other / installer.NAME)
        for results in ([RuntimeError("bad signature")], [None, RuntimeError("bad staged signature")]):
            with self.subTest(results=len(results)):
                self.system.verify.side_effect = results
                with self.assertRaisesRegex(RuntimeError, "signature"):
                    self.install()
                self.assertEqual(marker(self.destination), "old")
                self.assertEqual(marker(peer), "old")
                self.assert_no_work()
        self.system.stop.assert_not_called()
        self.system.unregister.assert_not_called()

    def test_non_executable_source_rejected(self):
        bundle(self.destination)
        (self.source / "Contents/MacOS" / installer.EXECUTABLE).chmod(0o644)
        with self.assertRaisesRegex(RuntimeError, "실행 가능한"):
            self.install()
        self.assertEqual(marker(self.destination), "old")
        self.system.stop.assert_not_called()

    def test_copy_failure_keeps_old_install(self):
        bundle(self.destination)
        with patch.object(installer.shutil, "copytree", side_effect=OSError("disk full")):
            with self.assertRaises(OSError):
                self.install()
        self.assertEqual(marker(self.destination), "old")
        self.system.stop.assert_not_called()
        self.assert_no_work()

    def test_process_stop_failure_keeps_old_install_and_copies(self):
        bundle(self.destination)
        peer = bundle(self.other / installer.NAME)
        self.system.stop.side_effect = RuntimeError("process still running")
        with self.assertRaisesRegex(RuntimeError, "running"):
            self.install()
        self.assertEqual(marker(self.destination), "old")
        self.assertEqual(marker(peer), "old")
        self.system.unregister.assert_not_called()
        self.assert_no_work()

    def test_failed_rename_restores_old_install(self):
        bundle(self.destination)
        peer = bundle(self.other / installer.NAME)
        rename = Path.rename

        def fail_swap(path, target):
            if path.name == installer.NAME and path.parent.name.startswith(".codex-usage-install-"):
                raise OSError("swap failed")
            return rename(path, target)

        with patch.object(Path, "rename", fail_swap), self.assertRaises(OSError):
            self.install()
        self.assertEqual(marker(self.destination), "old")
        self.assertEqual(marker(peer), "old")
        self.system.unregister.assert_not_called()
        self.assert_no_work()

    def test_failed_first_rename_leaves_old_install(self):
        bundle(self.destination)
        with patch.object(Path, "rename", side_effect=OSError("rename denied")), self.assertRaises(OSError):
            self.install()
        self.assertEqual(marker(self.destination), "old")
        self.assert_no_work()

    def test_failed_rollback_preserves_recoverable_previous_copy(self):
        bundle(self.destination)
        rename = Path.rename

        def fail_swap_and_rollback(path, target):
            if path.parent.name.startswith(".codex-usage-install-"):
                raise OSError("rename denied")
            return rename(path, target)

        with patch.object(Path, "rename", fail_swap_and_rollback), self.assertRaisesRegex(RuntimeError, "이전 사본을 보존"):
            self.install()
        previous = list(self.user.glob(".codex-usage-install-*/previous.app"))
        self.assertEqual(len(previous), 1)
        self.assertEqual(marker(previous[0]), "old")

    def test_cleanup_failure_continues_and_reports_failure(self):
        failed = bundle(self.user / (installer.NAME + ".bak-denied"))
        removed = bundle(self.other / installer.NAME)
        remove = installer.shutil.rmtree

        def deny_one(path, *args, **kwargs):
            if path == failed:
                raise PermissionError("permission denied")
            return remove(path, *args, **kwargs)

        errors = io.StringIO()
        with patch.object(installer.shutil, "rmtree", deny_one), contextlib.redirect_stderr(errors), \
             contextlib.redirect_stdout(io.StringIO()), self.assertRaisesRegex(installer.CleanupError, "정리가 끝나지"):
            installer.install(self.source, self.destination, self.folders, system=self.system)
        self.assertEqual(marker(self.destination), "new")
        self.assertTrue(failed.exists())
        self.assertFalse(removed.exists())
        self.assertIn(str(failed), errors.getvalue())
        self.assertIn("permission denied", errors.getvalue())

    def test_unregistered_copies_and_build_source_are_deleted(self):
        peer = bundle(self.other / installer.NAME)
        system = installer.SystemCommands()
        with patch.object(system, "verify"), patch.object(system, "stop"), \
             patch.object(installer, "BUILD_ROOT", self.source.parent), \
             patch.object(installer.subprocess, "run", return_value=subprocess.CompletedProcess(
                 [], 1, b"unregistered", b"not found")) as run, \
             contextlib.redirect_stdout(io.StringIO()):
            installer.install(self.source, self.destination, self.folders, system=system)
        self.assertEqual(marker(self.destination), "new")
        self.assertFalse(peer.exists())
        self.assertFalse(self.source.exists())
        self.assertEqual(run.call_count, 4)
        for call in run.call_args_list:
            self.assertTrue(call.kwargs["capture_output"])
            self.assertFalse(call.kwargs.get("check", False))

    def test_cli_cleanup_failure_returns_four_after_new_app_is_installed(self):
        failed = bundle(self.user / (installer.NAME + ".bak-denied"))
        remove = installer.shutil.rmtree

        def deny_one(path, *args, **kwargs):
            if path == failed:
                raise PermissionError("permission denied")
            return remove(path, *args, **kwargs)

        for unloaded in (False, True):
            self.system.agent_unloaded = unloaded
            with patch.object(sys, "argv", ["install_app.py", "--source", str(self.source),
                                           "--destination", str(self.destination), "--search-folder", str(self.user)]), \
                 patch.object(installer, "SystemCommands", return_value=self.system), \
                 patch.object(installer.shutil, "rmtree", deny_one), \
                 contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(installer.main(), installer.CLEANUP_ERROR)
            self.assertEqual(marker(self.destination), "new")
            self.assertTrue(failed.exists())

    def test_build_source_removed_but_build_cache_kept(self):
        cache = self.source.parent / "swift-build/keep.txt"
        cache.parent.mkdir()
        cache.write_text("cache")
        with patch.object(installer, "BUILD_ROOT", self.source.parent):
            self.install()
        self.assertEqual(marker(self.destination), "new")
        self.assertFalse(self.source.exists())
        self.assertEqual(cache.read_text(), "cache")
        self.system.unregister.assert_called_once_with(self.source)
        self.assertIn(self.source, self.system.stop.call_args.args[0])

    def test_keep_source_option(self):
        with patch.object(installer, "BUILD_ROOT", self.source.parent):
            self.install(cleanup_source=False)
        self.assertEqual(marker(self.destination), "new")
        self.assertTrue(self.source.exists())
        self.system.unregister.assert_not_called()

    def test_application_support_container_and_settings_are_untouched(self):
        kept = [self.root / "home/Library/Application Support/com.jino.codex-usage/usage-snapshot.json",
                self.root / "home/Library/Containers/com.jino.codex-usage.widget/Data/cache.json",
                self.root / "home/.claude/settings.json"]
        for path in kept:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("keep this data")
        bundle(self.destination)
        bundle(self.other / installer.NAME)
        self.install()
        for path in kept:
            self.assertEqual(path.read_text(), "keep this data")

    def test_cli_no_system_installs_and_replaces_in_temporary_folders(self):
        command = [sys.executable, str(Path(installer.__file__)), "--source", str(self.source),
                   "--destination", str(self.destination), "--search-folder", str(self.user),
                   "--search-folder", str(self.other), "--no-system", "--keep-source"]
        for replacing in (False, True):
            if replacing:
                (self.destination / "Contents/old-only.txt").write_text("old")
                peer = bundle(self.other / installer.NAME)
            result = subprocess.run(command, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(marker(self.destination), "new")
            if replacing:
                self.assertFalse(peer.exists())
                self.assertFalse((self.destination / "Contents/old-only.txt").exists())
        self.assertTrue(self.source.exists())

    def test_cli_failure_signals_unloaded_agent_for_shell_recovery(self):
        for unloaded, code in [(False, 1), (True, installer.AGENT_UNLOADED_ERROR)]:
            self.system.agent_unloaded = unloaded
            with patch.object(sys, "argv", ["install_app.py", "--source", str(self.source),
                                           "--destination", str(self.destination), "--search-folder", str(self.user)]), \
                 patch.object(installer, "SystemCommands", return_value=self.system), \
                 patch.object(installer, "install", side_effect=RuntimeError("installation failed")), \
                 contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(installer.main(), code)


class SystemCommandTests(unittest.TestCase):
    def test_no_system_never_runs_external_commands(self):
        system = installer.SystemCommands(enabled=False)
        with patch.object(installer.subprocess, "run") as run:
            system.verify(Path("/fixture/app"))
            system.stop([Path("/fixture/app")])
            system.unregister(Path("/fixture/app"))
        run.assert_not_called()

    def test_matching_pids_requires_exact_bundle_executable_path(self):
        app = Path("/fixture/Codex Usage.app")
        binary = str(app / "Contents/MacOS" / installer.EXECUTABLE)
        extension = str(app / installer.EXTENSION / "Contents/MacOS" / installer.EXTENSION_EXECUTABLE)
        commands = {101: binary + " --mode test", 102: "/other" + binary,
                    103: binary + "Other", 104: "/usr/bin/python3 --input " + binary,
                    201: extension, 202: extension + "Other", 203: "/other" + extension}

        def run(command, **kwargs):
            if command[0] == "/usr/bin/pgrep":
                stdout = "101 102 103 104" if command[-1] == installer.EXECUTABLE else "201 202 203"
            else:
                stdout = commands[int(command[2])]
            return subprocess.CompletedProcess(command, 0, stdout, "")

        with patch.object(installer.subprocess, "run", side_effect=run):
            self.assertEqual(installer.SystemCommands().matching_pids([app]), {101, 201})

    def test_bootout_precedes_term_and_wait(self):
        system = installer.SystemCommands()
        with patch.object(installer.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)) as run, \
             patch.object(system, "matching_pids", side_effect=[{101, 201}, {101}, set()]), \
             patch.object(installer.time, "sleep"):
            system.stop([Path("/fixture/app")])
        commands = [call.args[0] for call in run.call_args_list]
        self.assertEqual(commands[0][0:2], ["/bin/launchctl", "bootout"])
        self.assertEqual({tuple(command) for command in commands[1:]},
                         {("/bin/kill", "-TERM", "101"), ("/bin/kill", "-TERM", "201")})
        self.assertTrue(system.agent_unloaded)

    def test_timeout_aborts_without_force_kill(self):
        system = installer.SystemCommands()
        with patch.object(installer.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)) as run, \
             patch.object(system, "matching_pids", return_value={101}), patch.object(installer, "QUIT_WAIT", 0):
            with self.assertRaisesRegex(RuntimeError, "설치본을 그대로"):
                system.stop([Path("/fixture/app")])
        self.assertFalse(any("-KILL" in call.args[0] for call in run.call_args_list))

    def test_new_pid_during_wait_receives_term_once(self):
        system = installer.SystemCommands()
        with patch.object(installer.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)) as run, \
             patch.object(system, "matching_pids", side_effect=[{101}, {101, 201}, {201}, set()]), \
             patch.object(installer.time, "sleep"):
            system.stop([Path("/fixture/app")])
        self.assertEqual([call.args[0] for call in run.call_args_list if call.args[0][0] == "/bin/kill"], [
            ["/bin/kill", "-TERM", "101"], ["/bin/kill", "-TERM", "201"]])

    def test_loaded_agent_bootout_failure_aborts_before_processes(self):
        system = installer.SystemCommands()
        with patch.object(installer.subprocess, "run", side_effect=[subprocess.CompletedProcess([], 1),
                                                                  subprocess.CompletedProcess([], 0)]), \
             patch.object(system, "matching_pids") as pids:
            with self.assertRaisesRegex(RuntimeError, "자동 실행을 내리지"):
                system.stop([Path("/fixture/app")])
        pids.assert_not_called()

    def test_signature_and_unregistration_commands(self):
        with tempfile.TemporaryDirectory() as folder:
            app = bundle(Path(folder) / installer.NAME)
            with patch.object(installer.subprocess, "run") as run:
                system = installer.SystemCommands()
                system.verify(app)
                system.unregister(app)
        self.assertEqual([call.args[0] for call in run.call_args_list], [
            ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)],
            ["/usr/bin/pluginkit", "-r", str(app / installer.EXTENSION)],
            [installer.LSREGISTER, "-u", str(app)]])
        self.assertTrue(run.call_args_list[0].kwargs["check"])
        for call in run.call_args_list[1:]:
            self.assertEqual(call.kwargs, dict(capture_output=True))

    def test_unregister_returncode_one_and_oserror_do_not_raise(self):
        with tempfile.TemporaryDirectory() as folder:
            app = bundle(Path(folder) / installer.NAME)
            for error in (None, FileNotFoundError("command unavailable")):
                with self.subTest(error=error), patch.object(installer.subprocess, "run",
                         side_effect=error, return_value=subprocess.CompletedProcess([], 1, b"not registered", b"no plugin")) as run:
                    installer.SystemCommands().unregister(app)
                self.assertEqual(run.call_count, 2)
                for call in run.call_args_list:
                    self.assertTrue(call.kwargs["capture_output"])
                    self.assertFalse(call.kwargs.get("check", False))


class InstallShellTests(unittest.TestCase):
    def test_exit_code_branches_under_set_e_with_temporary_command_standins(self):
        original = (Path(__file__).parents[1] / "install.sh").read_text()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for result_code in (0, 4, 3, 1):
                with self.subTest(code=result_code):
                    case = root / str(result_code)
                    tools = case / "tools"
                    tools.mkdir(parents=True)
                    log = case / "commands.log"
                    log.write_text("")
                    for name in ("python3", "ditto", "lsregister", "pluginkit", "launchctl"):
                        path = tools / name
                        content = ("#!/bin/zsh\n"
                                   f"print -r -- '{name} '" + '"$*" >> "$INSTALL_TEST_LOG"\n')
                        if name == "python3":
                            content += 'exit "$INSTALL_TEST_RESULT"\n'
                        elif name == "ditto":
                            content += '/bin/cp "$1" "$2"\n'
                        path.write_text(content)
                        path.chmod(0o755)
                    (case / "build-widget-app.sh").write_text(
                        '#!/bin/zsh\nprint -r -- build >> "$INSTALL_TEST_LOG"\n')
                    agent_source = case / "LaunchAgent/com.jino.codex-usage.desktop.plist"
                    agent_source.parent.mkdir()
                    agent_source.write_text("new plist")
                    test_home = case / "home"
                    agent_destination = test_home / "Library/LaunchAgents" / agent_source.name
                    if result_code in (3, 1):
                        agent_destination.parent.mkdir(parents=True)
                        agent_destination.write_text("old plist")
                        executable = test_home / "Applications" / installer.NAME / "Contents/MacOS" / installer.EXECUTABLE
                        executable.parent.mkdir(parents=True)
                        executable.write_text("old binary")
                        executable.chmod(0o755)
                    # Only this temporary copy changes paths; production script structure is identical.
                    script = original.replace("$HOME/", "$INSTALL_TEST_HOME/")
                    script = script.replace("/private/tmp/codex-usage-widget-build/Codex Usage.app",
                                            "$INSTALL_TEST_HOME/build/Codex Usage.app")
                    for command, standin in [("/usr/bin/python3", "python3"), ("/usr/bin/ditto", "ditto"),
                                             (installer.LSREGISTER, "lsregister"), ("/usr/bin/pluginkit", "pluginkit"),
                                             ("launchctl", "launchctl")]:
                        self.assertIn(command, script)
                        script = script.replace(command, shlex.quote(str(tools / standin)))
                    path = case / "install.sh"
                    path.write_text(script)
                    env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ.get("PATH", ""),
                               INSTALL_TEST_LOG=str(log), INSTALL_TEST_HOME=str(test_home),
                               INSTALL_TEST_RESULT=str(result_code))
                    completed = subprocess.run(["/bin/zsh", "-f", str(path)], cwd=case, env=env,
                                               capture_output=True, text=True, timeout=10)
                    self.assertEqual(completed.returncode, result_code, completed.stderr)
                    calls = log.read_text().splitlines()
                    self.assertEqual(calls[0], "build")
                    if result_code in (0, 4):
                        self.assertEqual([line.split()[0] for line in calls],
                                         ["build", "python3", "ditto", "lsregister", "pluginkit", "launchctl", "launchctl"])
                        self.assertEqual(agent_destination.read_text(), "new plist")
                        self.assertTrue(calls[3].startswith("lsregister -f "))
                        self.assertTrue(calls[4].startswith("pluginkit -a "))
                        self.assertTrue(calls[5].startswith("launchctl bootstrap "))
                        self.assertTrue(calls[6].startswith("launchctl kickstart -k "))
                    elif result_code == 3:
                        self.assertEqual([line.split()[0] for line in calls], ["build", "python3", "launchctl", "launchctl"])
                        self.assertEqual(agent_destination.read_text(), "old plist")
                    else:
                        self.assertEqual([line.split()[0] for line in calls], ["build", "python3"])
                        self.assertEqual(agent_destination.read_text(), "old plist")
                    if result_code == 4:
                        self.assertIn("정리가 끝나지 않았습니다", completed.stderr)
                        self.assertNotIn("설치 및 자동 실행 등록 완료", completed.stdout)
                    elif result_code == 0:
                        self.assertIn("설치 및 자동 실행 등록 완료", completed.stdout)


if __name__ == "__main__":
    unittest.main()

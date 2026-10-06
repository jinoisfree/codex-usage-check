#!/usr/bin/env python3
"""검증한 새 앱을 설치하고 같은 제품의 이전 사본을 정리합니다."""
import argparse
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
from xml.parsers.expat import ExpatError

NAME = "Codex Usage.app"
BUNDLE_ID = "com.jino.codex-usage"
EXECUTABLE = "CodexUsageMenuBar"
EXTENSION = Path("Contents/PlugIns/CodexUsageWidgetExtension.appex")
EXTENSION_EXECUTABLE = "CodexUsageWidgetExtension"
AGENT_LABEL = "com.jino.codex-usage.desktop"
BUILD_ROOT = Path("/private/tmp/codex-usage-widget-build")
LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
QUIT_WAIT = 3
# install.sh restores the unloaded agent when the helper exits with this code.
AGENT_UNLOADED_ERROR = 3
CLEANUP_ERROR = 4


class CleanupError(RuntimeError):
    """새 앱 설치 후 이전 사본을 삭제하지 못한 경우입니다."""


def normalized(path):
    path = Path(path).expanduser().absolute()
    # Resolve parent aliases (such as /tmp), without following a bundle symlink.
    return path.parent.resolve() / path.name


def info(app):
    try:
        with (app / "Contents/Info.plist").open("rb") as source:
            value = plistlib.load(source)
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError, plistlib.InvalidFileException, ExpatError):
        return {}


def is_app(app):
    if app.is_symlink() or not app.is_dir():
        return False
    value = info(app)
    return value.get("CFBundleIdentifier") == BUNDLE_ID and value.get("CFBundleExecutable") == EXECUTABLE


def version(app):
    return str(info(app).get("CFBundleShortVersionString", "버전 미제공"))


def scan(folders, destination):
    copies, others, seen = [], [], set()
    for folder in folders:
        try:
            entries = sorted(Path(folder).expanduser().iterdir())
        except FileNotFoundError:
            continue
        for entry in entries:
            if entry.name != NAME and not entry.name.startswith(NAME + ".bak-"):
                continue
            app = normalized(entry)
            if app == destination or app in seen:
                continue
            seen.add(app)
            (copies if is_app(app) else others).append(app)
    return copies, others


class SystemCommands:
    def __init__(self, enabled=True):
        self.enabled = enabled
        self.agent_unloaded = False

    def verify(self, app):
        if self.enabled:
            subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)

    def matching_pids(self, apps):
        allowed = set()
        for app in apps:
            allowed.add(str(app / "Contents/MacOS" / EXECUTABLE))
            allowed.add(str(app / EXTENSION / "Contents/MacOS" / EXTENSION_EXECUTABLE))
        pids = set()
        for name in (EXECUTABLE, EXTENSION_EXECUTABLE):
            result = subprocess.run(["/usr/bin/pgrep", "-f", re.escape(name)], capture_output=True, text=True)
            if result.returncode not in (0, 1):
                raise RuntimeError("실행 중인 앱을 확인하지 못해 설치를 중단합니다")
            for text in result.stdout.split():
                if not text.isdigit():
                    continue
                pid = int(text)
                command = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "command="],
                                         capture_output=True, text=True)
                if command.returncode == 0 and any(
                        command.stdout.strip() == path or command.stdout.strip().startswith(path + " ")
                        for path in allowed):
                    pids.add(pid)
        return pids

    def stop(self, apps):
        if not self.enabled:
            return
        target = "gui/" + str(os.getuid()) + "/" + AGENT_LABEL
        result = subprocess.run(["/bin/launchctl", "bootout", target], capture_output=True)
        if result.returncode == 0:
            self.agent_unloaded = True
        elif subprocess.run(["/bin/launchctl", "print", target], capture_output=True).returncode == 0:
            raise RuntimeError("로그인 자동 실행을 내리지 못해 설치를 중단합니다")
        sent = self.matching_pids(apps)
        for pid in sent:
            subprocess.run(["/bin/kill", "-TERM", str(pid)], capture_output=True)
        deadline = time.monotonic() + QUIT_WAIT
        pending = self.matching_pids(apps)
        while pending:
            if time.monotonic() >= deadline:
                raise RuntimeError("이전 앱 또는 위젯 프로세스가 종료되지 않아 설치본을 그대로 둡니다")
            for pid in pending - sent:
                subprocess.run(["/bin/kill", "-TERM", str(pid)], capture_output=True)
            sent.update(pending)
            time.sleep(0.1)
            pending = self.matching_pids(apps)

    def unregister(self, app):
        if not self.enabled:
            return
        commands = []
        if (app / EXTENSION).is_dir():
            commands.append(["/usr/bin/pluginkit", "-r", str(app / EXTENSION)])
        commands.append([LSREGISTER, "-u", str(app)])
        # Unregistered copies may return an error; still remove the bundle.
        for command in commands:
            try:
                subprocess.run(command, capture_output=True)
            except OSError:
                pass


def verify(app, system):
    if not is_app(app):
        raise RuntimeError(f"설치할 앱의 번들 ID 또는 실행 파일이 일치하지 않습니다: {app}")
    system.verify(app)
    executable = app / "Contents/MacOS" / EXECUTABLE
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise RuntimeError(f"실행 가능한 앱 파일이 없습니다: {executable}")


def install(source, destination, folders, system=None, cleanup_source=True):
    system = system if system is not None else SystemCommands()
    source, destination = normalized(source), normalized(destination)
    if source == destination or source in destination.parents or destination in source.parents:
        raise RuntimeError("빌드 사본과 설치 경로는 서로 분리되어야 합니다")
    verify(source, system)
    replacing = destination.exists() or destination.is_symlink()
    if replacing and not is_app(destination):
        raise RuntimeError(f"다른 항목이 있어 건드리지 않고 중단합니다: {destination}")
    old, others = scan(folders, destination)
    for app in others:
        print(f"다른 항목으로 보고 건드리지 않음: {app}")
    if cleanup_source and BUILD_ROOT.resolve() in source.parents and source not in old:
        old.append(source)
    before = version(destination) if replacing else None
    after = version(source)
    destination.parent.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix=".codex-usage-install-", dir=destination.parent))
    staged, previous = work / NAME, work / "previous.app"
    preserve_work = False
    try:
        shutil.copytree(source, staged, symlinks=True)
        verify(staged, system)
        system.stop(([destination] if replacing else []) + old)
        if replacing:
            destination.rename(previous)
        staged.rename(destination)
    except BaseException as error:
        recovery_error = None
        if previous.exists():
            try:
                previous.rename(destination)
            except OSError as failure:
                preserve_work = True
                recovery_error = failure
        if not preserve_work:
            try:
                shutil.rmtree(work)
            except OSError as cleanup_error:
                print(f"임시 설치 폴더를 정리하지 못했습니다: {work} ({cleanup_error})", file=sys.stderr)
        if recovery_error is not None:
            raise RuntimeError(f"교체와 복구에 실패했습니다. 이전 사본을 보존합니다: {previous} ({recovery_error})") from error
        raise
    print(f"{'교체' if replacing else '설치'} 완료: {destination} ({before + ' → ' if before else ''}{after})")
    failed = []
    try:
        shutil.rmtree(work)
    except OSError as error:
        failed.append(str(work))
        print(f"이전 설치 사본을 삭제하지 못했습니다: {work} ({error})", file=sys.stderr)
    for app in old:
        if not is_app(app):
            print(f"다른 항목으로 바뀌어 건드리지 않음: {app}")
            continue
        system.unregister(app)
        try:
            shutil.rmtree(app)
            print(f"이전 버전 삭제: {app}")
        except OSError as error:
            failed.append(str(app))
            print(f"이전 버전을 삭제하지 못했습니다: {app} ({error})", file=sys.stderr)
    if failed:
        raise CleanupError("새 앱은 설치했지만 이전 사본 정리가 끝나지 않았습니다: " + ", ".join(failed))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=BUILD_ROOT / NAME)
    parser.add_argument("--destination", type=Path, default=Path.home() / "Applications" / NAME)
    parser.add_argument("--search-folder", type=Path, action="append",
                        help="이전 사본을 찾을 폴더 (반복 지정 가능)")
    parser.add_argument("--no-system", action="store_true", help="테스트용: 서명·프로세스·등록 명령을 실행하지 않음")
    parser.add_argument("--keep-source", action="store_true", help="테스트용: 빌드 폴더의 원본 사본을 보존")
    args = parser.parse_args()
    system = SystemCommands(enabled=not args.no_system)
    folders = args.search_folder if args.search_folder is not None else [Path.home() / "Applications", Path("/Applications")]
    try:
        install(args.source, args.destination, folders, system=system, cleanup_source=not args.keep_source)
    except CleanupError as error:
        print(f"설치 후 정리 실패: {error}", file=sys.stderr)
        return CLEANUP_ERROR
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"설치 실패: {error}", file=sys.stderr)
        return AGENT_UNLOADED_ERROR if system.agent_unloaded else 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

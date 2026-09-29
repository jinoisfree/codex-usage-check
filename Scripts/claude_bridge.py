#!/usr/bin/env python3
"""Local Claude usage bridge. Never stores auth output, prompts or transcripts."""
import argparse
import datetime as dt
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sqlite3
import sys
import tempfile
import time
import urllib.error


def direct_desktop_snapshot(args, directory, context):
    from claude_desktop import fetch
    identity = context[0] if context else None
    if not identity:
        return empty_snapshot("Claude 데스크톱 로그인 확인 필요")
    path = args.data_dir / "claude-direct-state.json"
    state = read_json(path, {})
    now = time.time()
    if state.get("identity") == identity and now < state.get("nextAttempt", 0):
        snapshot = state.get("snapshot", empty_snapshot("Claude 조회 대기", identity))
    else:
        delay = 120
        try:
            snapshot = fetch(directory, identity, now)
        except urllib.error.HTTPError as error:
            delay = 300 if error.code == 429 else 120
            message = "Claude 요청 제한 · 5분 후 재시도" if error.code == 429 else "Claude 인증 또는 서버 응답 확인 필요"
            snapshot = empty_snapshot(message, identity)
        except Exception:
            # Never expose credential data through exception messages.
            snapshot = empty_snapshot("Claude 직접 조회 실패 · Code 탭 로그인 확인", identity)
        if desktop_identity(directory) != context:
            return empty_snapshot("Claude 계정 변경 확인 중")
        atomic_json(path, dict(identity=identity, nextAttempt=now + delay, snapshot=snapshot))
    if desktop_identity(directory) != context:
        return empty_snapshot("Claude 계정 변경 확인 중")
    return snapshot


def timestamp():
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, name = tempfile.mkstemp(dir=path.parent, prefix=".usage-")
    try:
        with os.fdopen(fd, "w") as output:
            json.dump(value, output, ensure_ascii=False)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def read_json(path, default):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return default


def empty_snapshot(message, key=None):
    return dict(plan="Claude", updatedAt=timestamp(), windows=[], resetCredits=0,
                source="claude-statusline", accountKey=key, statusMessage=message)


def account_identity(executable):
    if not executable:
        return None, "Claude CLI 설치 필요"
    try:
        result = subprocess.run([executable, "auth", "status"], capture_output=True,
                                text=True, timeout=3)
        raw = json.loads(result.stdout)
        if not isinstance(raw, dict):
            return None, "Claude 인증 확인 실패"
        if result.returncode or raw.get("loggedIn") is not True:
            return None, "Claude 로그인 필요"
        if raw.get("authMethod") not in ("claude.ai", "oauth"):
            return None, "구독 한도 미지원 인증 방식"
        identity = raw.get("accountId") or raw.get("email")
        if not identity:
            return None, "Claude 계정 확인 필요"
        # Keep only a hash; never persist the email or full auth response.
        key = hashlib.sha256(json.dumps(
            [identity, raw.get("orgId"), raw.get("configDirectory")],
            sort_keys=True).encode()).hexdigest()
        return key, None
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None, "Claude 인증 확인 실패"


def parse_windows(payload, now):
    windows = []
    limits = payload.get("rate_limits")
    if not isinstance(limits, dict):
        return windows
    for identifier, label in (("five_hour", "5시간 한도"), ("seven_day", "주간 한도")):
        raw = limits.get(identifier)
        if not isinstance(raw, dict):
            continue
        used, reset = raw.get("used_percentage"), raw.get("resets_at")
        if any(isinstance(v, bool) or not isinstance(v, (float, int))
               or not math.isfinite(v) for v in (used, reset)):
            continue
        if not 0 <= used <= 100 or reset <= now:
            continue
        try:
            reset_string = dt.datetime.fromtimestamp(reset, dt.timezone.utc).isoformat(
                timespec="seconds").replace("+00:00", "Z")
        except (ValueError, OverflowError, OSError):
            continue
        windows.append(dict(id=identifier, label=label, usedPercent=math.ceil(used),
                            resetAt=reset_string))
    return windows


def update(state, mode, payload, key, error, now):
    if state.get("accountKey") != key or error:
        state = dict(accountKey=key, sessions={}, snapshot=empty_snapshot(
            error or "새 계정의 Claude 응답 대기", key))
    session = payload.get("session_id")
    sessions = state.setdefault("sessions", {})
    if mode == "session" and key and isinstance(session, str):
        # Only startup/resume can bind an identity; compact must not rebind an old session.
        source = payload.get("source")
        if source in ("startup", "resume"):
            sessions[session] = key
            while len(sessions) > 128:
                del sessions[next(iter(sessions))]
    if mode == "status" and key and sessions.get(session) == key:
        windows = parse_windows(payload, now)
        cost = payload.get("cost") or {}
        signal = hashlib.sha256(json.dumps(
            [windows, cost.get("total_api_duration_ms") if isinstance(cost, dict) else None],
            sort_keys=True).encode()).hexdigest()
        signals = state.setdefault("signals", {})
        if windows and signals.get(session) != signal:
            signals[session] = signal
            while len(signals) > 128:
                del signals[next(iter(signals))]
            state["snapshot"] = dict(plan="Claude", updatedAt=timestamp(),
                                     windows=windows, resetCredits=0,
                                     source="claude-statusline", accountKey=key)
        # Absence is not zero, and must not refresh the timestamp of an old observation.
    snapshot = state.setdefault("snapshot", empty_snapshot(error or "Claude 응답 대기", key))
    if snapshot.get("windows"):
        snapshot["windows"] = [w for w in snapshot["windows"]
                               if dt.datetime.fromisoformat(w["resetAt"].replace("Z", "+00:00")).timestamp() > now]
        if not snapshot["windows"]:
            snapshot["statusMessage"] = "한도 초기화 후 재확인 대기"
    return state


def configure(args):
    directory = Path(args.config_dir).expanduser().resolve()
    settings_path = directory / "settings.json"
    settings = json.loads(settings_path.read_text()) if settings_path.exists() else {}
    if not isinstance(settings, dict):
        raise ValueError("settings.json must be an object")
    original_settings = json.loads(json.dumps(settings))
    executable = shutil.which("claude")
    if not executable:
        for candidate in (Path.home()/".local/bin/claude", Path("/opt/homebrew/bin/claude"),
                          Path("/usr/local/bin/claude")):
            if os.access(candidate, os.X_OK):
                executable = str(candidate)
                break
    if not executable:
        raise ValueError("Claude CLI를 설치한 뒤 연결을 다시 실행하세요.")
    config_path = args.data_dir / "bridge-config.json"
    if config_path.exists():
        raise ValueError("이미 연결되어 있습니다. 기존 연결 해제 후 다시 연결하세요.")
    old_status = settings.get("statusLine")
    if old_status and (not isinstance(old_status, dict) or old_status.get("type") != "command"):
        raise ValueError("현재 상태 표시줄 형식을 보존할 수 없어 설정을 변경하지 않았습니다.")
    prefix = shlex.join([sys.executable, str(Path(__file__).resolve()),
                        "--data-dir", str(args.data_dir)])
    status = dict(old_status or {})
    status.update(type="command", command=prefix + " status")
    hook = dict(matcher="startup|resume|clear|fork|compact",
                hooks=[dict(type="command", command=prefix + " session", timeout=5)])
    # Validate the existing hook shape before writing anything.
    hooks = settings.setdefault("hooks", {})
    starts = hooks.setdefault("SessionStart", [])
    if not isinstance(starts, list):
        raise ValueError("SessionStart 설정 형식이 올바르지 않습니다.")
    backup = directory / ("settings.json.usage-backup-" + str(time.time_ns()))
    atomic_json(backup, original_settings)
    atomic_json(config_path, dict(executable=executable, configDirectory=str(directory),
                                 previousStatus=old_status, installedStatus=status,
                                 installedHook=hook, backup=str(backup)))
    starts.append(hook)
    settings["statusLine"] = status
    atomic_json(settings_path, settings)
    print("Claude 연결 완료. 새 Claude 세션을 시작하세요. 백업: " + str(backup))


def disconnect(args):
    path = args.data_dir / "bridge-config.json"
    config = read_json(path, None)
    if not config:
        return
    settings_path = Path(config["configDirectory"]) / "settings.json"
    settings = json.loads(settings_path.read_text())
    if settings.get("statusLine") == config["installedStatus"]:
        if config["previousStatus"] is None:
            settings.pop("statusLine", None)
        else:
            settings["statusLine"] = config["previousStatus"]
    starts = settings.get("hooks", {}).get("SessionStart", [])
    if config["installedHook"] in starts:
        starts.remove(config["installedHook"])
    atomic_json(settings_path, settings)
    path.unlink()
    atomic_json(args.data_dir / "claude-state.json", {})
    print("Claude 연결 해제 완료. 이후 변경한 다른 설정은 유지했습니다.")


def desktop_identity(directory):
    """Read account metadata and opaque org identity, never session-cookie contents."""
    config = read_json(directory / "config.json", {})
    account = config.get("lastKnownAccountUuid")
    if not isinstance(account, str) or not account:
        return None
    try:
        with sqlite3.connect((directory / "Cookies").as_uri() + "?mode=ro", uri=True,
                             timeout=1) as database:
            login = database.execute(
                "SELECT last_update_utc FROM cookies WHERE name='sessionKey' "
                "AND host_key IN ('.claude.ai','claude.ai') "
                "AND (expires_utc=0 OR expires_utc>?) ORDER BY last_update_utc DESC LIMIT 1",
                (int((time.time()+11644473600)*1000000),)).fetchone()
            org = database.execute(
                "SELECT value,encrypted_value,last_update_utc FROM cookies WHERE name='lastActiveOrg' "
                "AND host_key IN ('.claude.ai','claude.ai') ORDER BY last_update_utc DESC LIMIT 1"
            ).fetchone()
        if not login or not org:
            return None
        opaque_org = org[0].encode() if org[0] else org[1]
        if not opaque_org:
            return None
        since = max(login[0], org[2])/1000000-11644473600
        if not 0 < since <= time.time():
            return None
        key = hashlib.sha256(account.encode() + b":" + opaque_org +
                             str(login[0]).encode()).hexdigest()
        return key, since
    except (OSError, sqlite3.Error):
        return None


def desktop_snapshot(history, binding, identity, now, verified_since=None):
    if not identity:
        return {}, empty_snapshot("Claude 데스크톱 로그인 확인 필요")
    if binding.get("identity") != identity:
        # On first connection, a cookie's verified update time provides the boundary.
        # Subsequent account transitions always wait for a new observation.
        since = verified_since if not binding and verified_since is not None else now
        binding = dict(identity=identity, since=since, version=1)
    if history.get("version") != 2 or not isinstance(history.get("samples"), list):
        return binding, empty_snapshot("Claude 데스크톱 사용량 기록 미지원", identity)
    samples = [s for s in history["samples"] if isinstance(s, dict)
               and isinstance(s.get("t"), (int, float)) and not isinstance(s.get("t"), bool)
               and math.isfinite(s["t"]) and binding["since"] <= s["t"]/1000 <= now
               and isinstance(s.get("org"), str) and isinstance(s.get("u"), dict)]
    if not samples:
        return binding, empty_snapshot("Claude 앱에서 사용량을 열어 새 기록을 확인하세요", identity)
    latest = max(samples, key=lambda s: s["t"])
    if now-latest["t"]/1000 > 1800:
        return binding, empty_snapshot("Claude 사용량 재확인 필요 (30분 경과)", identity)
    windows = []
    for key, label in (("fh", "5시간 한도"), ("sd", "주간 한도")):
        used = latest["u"].get(key)
        if isinstance(used, (int, float)) and not isinstance(used, bool) and math.isfinite(used) and 0 <= used <= 100:
            windows.append(dict(id=key, label=label, usedPercent=math.ceil(used), resetAt=None))
    observed = dt.datetime.fromtimestamp(latest["t"]/1000, dt.timezone.utc).isoformat(
        timespec="seconds").replace("+00:00", "Z")
    snapshot = dict(plan="Desktop", updatedAt=observed, windows=windows, resetCredits=0,
                    source="claude-desktop-history", accountKey=identity)
    if not windows:
        snapshot["statusMessage"] = "Claude 구독 한도 미제공"
    return binding, snapshot


def read_desktop(args):
    directory = Path.home() / "Library/Application Support/Claude"
    args.data_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (args.data_dir / "claude-desktop.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        path = args.data_dir / "claude-desktop-binding.json"
        context = desktop_identity(directory)
        if read_json(args.data_dir / "claude-direct-consent.json", {}).get("enabled") is True:
            print(json.dumps(direct_desktop_snapshot(args, directory, context), ensure_ascii=False))
            return
        identity, since = context if context else (None, None)
        binding = read_json(path, {})
        if binding.get("version") != 1:
            binding = {}
        binding, snapshot = desktop_snapshot(
            read_json(directory / "plan-usage-history.json", {}),
            binding, identity, time.time(), verified_since=since)
        if desktop_identity(directory) != context:
            binding, snapshot = {}, empty_snapshot("Claude 계정 변경 확인 중")
        atomic_json(path, binding)
    print(json.dumps(snapshot, ensure_ascii=False))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--data-dir", type=Path, default=Path.home() /
                        "Library/Application Support/com.jino.codex-usage")
    parser.add_argument("--config-dir", default=os.environ.get("CLAUDE_CONFIG_DIR",
                                                             str(Path.home()/".claude")))
    parser.add_argument("mode", choices=["connect", "disconnect", "session", "status", "read",
                                        "enable-desktop-direct", "disable-desktop-direct"])
    args = parser.parse_args()
    if args.mode in ("enable-desktop-direct", "disable-desktop-direct"):
        atomic_json(args.data_dir / "claude-direct-consent.json",
                    dict(enabled=args.mode == "enable-desktop-direct"))
        print("Claude 직접 조회 설정 저장 완료")
        return
    if args.mode == "connect":
        configure(args)
        return
    if args.mode == "disconnect":
        disconnect(args)
        return
    config = read_json(args.data_dir / "bridge-config.json", {})
    if args.mode == "read" and not config:
        read_desktop(args)
        return
    raw = sys.stdin.buffer.read(1024 * 1024) if args.mode in ("session", "status") else b"{}"
    try:
        payload = json.loads(raw)
        if not isinstance(payload, dict):
            payload = {}
    except ValueError:
        payload = {}
    if not config:
        if args.mode == "read":
            print(json.dumps(empty_snapshot("Claude 연결 필요"), ensure_ascii=False))
        return
    os.environ["CLAUDE_CONFIG_DIR"] = config["configDirectory"]
    args.data_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    # Serialize auth checks and state writes so slow old sessions cannot overwrite new ones.
    with (args.data_dir / "claude-state.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        key, error = account_identity(config.get("executable"))
        state_path = args.data_dir / "claude-state.json"
        state = update(read_json(state_path, {}), args.mode, payload, key, error, time.time())
        atomic_json(state_path, state)
    if args.mode == "read":
        print(json.dumps(state["snapshot"], ensure_ascii=False))
    elif args.mode == "status":
        old = config.get("previousStatus")
        if old and old.get("command"):
            # Run only the user's original configured command, with the original stdin.
            subprocess.run(old["command"], shell=True, executable="/bin/sh",
                           input=raw, timeout=5)
        else:
            windows = state["snapshot"].get("windows", [])
            print(" · ".join(w["label"] + " " + str(100-w["usedPercent"]) + "% 남음"
                             for w in windows) or "Claude 사용량 확인 대기")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired):
        # Do not leak captured credentials or interrupt Claude's work.
        if "connect" in sys.argv or "disconnect" in sys.argv:
            print("연결 설정 실패. Claude 설치 및 설정 파일 형식을 확인하세요.", file=sys.stderr)
            sys.exit(1)

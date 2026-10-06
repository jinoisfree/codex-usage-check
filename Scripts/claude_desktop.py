"""Opt-in desktop quota reader. Secrets stay in memory; no credential refresh/write."""
import base64
import ctypes
import hashlib
import json
import math
import sqlite3
import subprocess
import time
import datetime as dt
import urllib.request
import urllib.error

ENDPOINT = "https://api.anthropic.com/api/oauth/usage"


class UsageReadError(ValueError):
    """A classified failure containing no credentials or response text."""
    def __init__(self, code):
        self.code = code
        super().__init__(code)


def failure_code(error):
    if isinstance(error, UsageReadError):
        return error.code
    if isinstance(error, urllib.error.HTTPError):
        if error.code == 429:
            return "limited"
        if error.code in (401, 403):
            return "authentication"
        return "http_" + str(error.code)
    if isinstance(error, (urllib.error.URLError, TimeoutError)):
        return "network"
    return "format"


def decrypt(encrypted, password):
    if not encrypted.startswith(b"v10"):
        raise ValueError("unsupported encryption")
    key = hashlib.pbkdf2_hmac("sha1", password, b"saltysalt", 1003, 16)
    library = ctypes.CDLL("/usr/lib/system/libcommonCrypto.dylib")
    crypt = library.CCCrypt
    crypt.argtypes = [ctypes.c_uint, ctypes.c_uint, ctypes.c_uint, ctypes.c_void_p,
                      ctypes.c_size_t, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t,
                      ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)]
    crypt.restype = ctypes.c_int
    data = encrypted[3:]
    output = ctypes.create_string_buffer(len(data) + 16)
    count = ctypes.c_size_t()
    if crypt(1, 0, 1, key, len(key), b" " * 16, data, len(data),
             output, len(output), ctypes.byref(count)):
        raise ValueError("decryption failed")
    return output.raw[:count.value]


def select_token(entries, account, org, now):
    candidates = []
    for key, value in entries.items():
        if not isinstance(value, dict) or not key.startswith("acct:" + account + "|"):
            continue
        suffix = key.split("|", 1)[1]
        if ":" + org + ":https://api.anthropic.com:" not in suffix:
            continue
        if "user:inference" not in suffix.split(":https://api.anthropic.com:", 1)[-1].split():
            continue
        token, expiry = value.get("token"), value.get("expiresAt")
        if (isinstance(token, str) and token and isinstance(expiry, (int, float))
                and not isinstance(expiry, bool) and math.isfinite(expiry) and expiry / 1000 > now + 15):
            candidates.append((expiry, token))
    if not candidates:
        raise UsageReadError("token_missing")
    return max(candidates)[1]


def credentials(directory):
    try:
        config = json.loads((directory / "config.json").read_text())
    except (OSError, ValueError):
        raise UsageReadError("login_missing") from None
    if not isinstance(config, dict):
        raise UsageReadError("login_missing")
    account = config.get("lastKnownAccountUuid")
    encoded = config.get("oauth:tokenCacheV2")
    if not isinstance(account, str) or not account or not isinstance(encoded, str) or not encoded:
        raise UsageReadError("login_missing")
    try:
        encrypted = base64.b64decode(encoded, validate=True)
    except ValueError:
        raise UsageReadError("login_missing") from None
    try:
        result = subprocess.run(["/usr/bin/security", "find-generic-password", "-s",
                                 "Claude Safe Storage", "-w"], capture_output=True, timeout=15)
    except (OSError, subprocess.TimeoutExpired):
        raise UsageReadError("keychain_unavailable") from None
    if result.returncode:
        raise UsageReadError("keychain_unavailable")
    password = result.stdout.rstrip(b"\n")
    try:
        entries = json.loads(decrypt(encrypted, password))
    except (OSError, ValueError, TypeError):
        raise UsageReadError("login_missing") from None
    if not isinstance(entries, dict):
        raise UsageReadError("login_missing")
    try:
        with sqlite3.connect((directory / "Cookies").as_uri() + "?mode=ro", uri=True, timeout=1) as database:
            row = database.execute("SELECT host_key,value,encrypted_value FROM cookies "
                "WHERE name='lastActiveOrg' AND host_key IN ('.claude.ai','claude.ai') "
                "ORDER BY last_update_utc DESC LIMIT 1").fetchone()
    except (OSError, sqlite3.Error):
        raise UsageReadError("token_missing") from None
    if not row:
        raise UsageReadError("token_missing")
    if row[1]:
        org = row[1]
    else:
        try:
            raw = decrypt(row[2], password)
            digest = hashlib.sha256(row[0].encode()).digest()
            if raw.startswith(digest):
                raw = raw[32:]
            org = raw.decode()
        except (OSError, ValueError, TypeError):
            raise UsageReadError("token_missing") from None
    if not org:
        raise UsageReadError("token_missing")
    return select_token(entries, account, org, time.time())


def parse_usage(raw, identity, now):
    if not isinstance(raw, dict):
        raise UsageReadError("format")
    windows = []
    for key, label in (("five_hour", "5시간 한도"), ("seven_day", "주간 한도")):
        value = raw.get(key)
        if not isinstance(value, dict):
            continue
        used, reset = value.get("utilization"), value.get("resets_at")
        if isinstance(used, bool) or not isinstance(used, (int, float)) or not math.isfinite(used) or not 0 <= used <= 100:
            raise UsageReadError("format")
        if not isinstance(reset, str):
            raise UsageReadError("format")
        try:
            date = dt.datetime.fromisoformat(reset.replace("Z", "+00:00"))
        except ValueError:
            raise UsageReadError("format") from None
        if date.tzinfo is None:
            raise UsageReadError("format")
        if date.timestamp() <= now:
            continue
        windows.append(dict(id=key, label=label, usedPercent=math.ceil(used),
                            resetAt=date.astimezone(dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")))
    result = dict(plan="Claude", updatedAt=dt.datetime.fromtimestamp(now, dt.timezone.utc).isoformat(
        timespec="seconds").replace("+00:00", "Z"), windows=windows, resetCredits=0,
        source="claude-desktop-direct", accountKey=identity)
    if not windows:
        result["statusMessage"] = "Claude 유효한 한도 없음"
    return result


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def fetch(directory, identity, now):
    token = credentials(directory)
    request = urllib.request.Request(ENDPOINT, headers={
        "Authorization": "Bearer " + token, "anthropic-beta": "oauth-2025-04-20",
        "Accept": "application/json"})
    # Never forward the bearer to redirects or another destination.
    try:
        with urllib.request.build_opener(NoRedirect).open(request, timeout=5) as response:
            raw = json.loads(response.read(1024 * 1024))
        return parse_usage(raw, identity, now)
    except (urllib.error.URLError, TimeoutError, ValueError, TypeError) as error:
        raise UsageReadError(failure_code(error)) from None

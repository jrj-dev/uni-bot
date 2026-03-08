#!/usr/bin/env python3
"""Guarded SSH log retrieval for UniFi devices with explicit approval token."""

from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import os
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path


ALLOWED_COMMANDS = {
    "logread_tail": "logread | tail -n 200",
    "messages_tail": "tail -n 200 /var/log/messages",
    "dmesg_tail": "dmesg | tail -n 200",
    "kernel_tail": "tail -n 200 /var/log/kern.log",
}
TOKEN_TTL_SECONDS = 300


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run guarded, read-only SSH log commands on UniFi devices."
    )
    parser.add_argument("--host", required=True, help="UniFi device host/IP.")
    parser.add_argument("--command-id", required=True, choices=sorted(ALLOWED_COMMANDS), help="Allowed command id.")
    parser.add_argument("--timeout", type=int, default=15, help="SSH timeout seconds. Default: 15.")
    parser.add_argument("--apply", action="store_true", help="Execute command. Without this, prints dry-run token.")
    parser.add_argument("--confirm-token", help="Token returned by dry-run.")
    parser.add_argument(
        "--reason",
        default="Collect UniFi device logs for troubleshooting",
        help="Reason for command execution shown in output.",
    )
    return parser.parse_args()


def require_env(name: str) -> str:
    value = (os.environ.get(name) or "").strip()
    if not value:
        raise SystemExit(f"missing required env var: {name}")
    return value


def approval_secret() -> str:
    secret = (os.environ.get("UNIFI_SSH_APPROVAL_SECRET") or "").strip()
    if secret:
        return secret
    # Fall back to API key-derived secret so token flow still works if explicit secret is omitted.
    api_key = require_env("UNIFI_API_KEY")
    return hashlib.sha256(api_key.encode("utf-8")).hexdigest()


def make_token(host: str, command_id: str, expires_at: int) -> str:
    secret = approval_secret().encode("utf-8")
    payload = f"{host}|{command_id}|{expires_at}".encode("utf-8")
    sig = hmac.new(secret, payload, hashlib.sha256).hexdigest()[:20]
    return f"{expires_at}:{sig}"


def verify_token(token: str, host: str, command_id: str) -> bool:
    try:
        expires_raw, sig = token.split(":", 1)
        expires_at = int(expires_raw)
    except ValueError:
        return False
    if expires_at < int(time.time()):
        return False
    expected = make_token(host, command_id, expires_at)
    return hmac.compare_digest(expected, token)


def resolve_private_key_path() -> Path:
    key_path = (os.environ.get("UNIFI_SSH_PRIVATE_KEY_PATH") or "").strip()
    key_content = os.environ.get("UNIFI_SSH_PRIVATE_KEY") or ""
    if key_path:
        path = Path(key_path).expanduser()
        if not path.exists():
            raise SystemExit(f"UNIFI_SSH_PRIVATE_KEY_PATH not found: {path}")
        return path
    if key_content.strip():
        fd, temp_path = tempfile.mkstemp(prefix="unifi_ssh_", suffix=".key")
        os.close(fd)
        path = Path(temp_path)
        path.write_text(key_content, encoding="utf-8")
        os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)
        return path
    raise SystemExit("set UNIFI_SSH_PRIVATE_KEY_PATH or UNIFI_SSH_PRIVATE_KEY")


def resolve_password() -> str:
    return (os.environ.get("UNIFI_SSH_PASSWORD") or "").strip()


def main() -> int:
    args = parse_args()
    host = args.host.strip()
    command_id = args.command_id.strip().lower()
    timeout = max(5, min(args.timeout, 60))
    command = ALLOWED_COMMANDS[command_id]

    if not args.apply:
        expires_at = int(time.time()) + TOKEN_TTL_SECONDS
        token = make_token(host, command_id, expires_at)
        payload = {
            "mode": "dry-run",
            "host": host,
            "command_id": command_id,
            "command": command,
            "reason": args.reason,
            "confirm_token": token,
            "expires_at_unix": expires_at,
            "expires_in_seconds": TOKEN_TTL_SECONDS,
            "next_step": "re-run with --apply --confirm-token <token>",
        }
        json.dump(payload, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
        return 0

    token = (args.confirm_token or "").strip()
    if not token:
        raise SystemExit("--apply requires --confirm-token")
    if not verify_token(token, host, command_id):
        raise SystemExit("invalid or expired confirm token; rerun dry-run")

    username = require_env("UNIFI_SSH_USERNAME")
    key_path: Path | None = None
    key_is_temp = False
    password = resolve_password()
    sshpass = ""
    key_configured = bool(
        (os.environ.get("UNIFI_SSH_PRIVATE_KEY_PATH") or "").strip()
        or (os.environ.get("UNIFI_SSH_PRIVATE_KEY") or "").strip()
    )
    if key_configured:
        key_path = resolve_private_key_path()
        key_is_temp = not (os.environ.get("UNIFI_SSH_PRIVATE_KEY_PATH") or "").strip()
    if password:
        sshpass = subprocess.run(["which", "sshpass"], capture_output=True, text=True, check=False).stdout.strip()
        if not sshpass:
            raise SystemExit("UNIFI_SSH_PASSWORD is set but sshpass is not installed")

    if not key_configured and not password:
        raise SystemExit("set UNIFI_SSH_PRIVATE_KEY_PATH / UNIFI_SSH_PRIVATE_KEY or UNIFI_SSH_PASSWORD")

    started = time.time()
    result: subprocess.CompletedProcess[str] | None = None
    used_method = ""

    if key_configured and key_path is not None:
        ssh_cmd = [
            "ssh",
            "-i",
            str(key_path),
            "-o",
            "BatchMode=yes",
            "-o",
            "StrictHostKeyChecking=accept-new",
            "-o",
            f"ConnectTimeout={timeout}",
            f"{username}@{host}",
            command,
        ]
        result = subprocess.run(ssh_cmd, capture_output=True, text=True, check=False)
        used_method = "key"

    # Fallback to password if key auth failed and password is available.
    if password and (result is None or result.returncode != 0):
        ssh_cmd = [
            sshpass,
            "-p",
            password,
            "ssh",
            "-o",
            "StrictHostKeyChecking=accept-new",
            "-o",
            f"ConnectTimeout={timeout}",
            f"{username}@{host}",
            command,
        ]
        result = subprocess.run(ssh_cmd, capture_output=True, text=True, check=False)
        used_method = "password"

    assert result is not None
    elapsed_ms = int((time.time() - started) * 1000)
    payload = {
        "mode": "apply",
        "host": host,
        "command_id": command_id,
        "auth_method": used_method,
        "reason": args.reason,
        "elapsed_ms": elapsed_ms,
        "exit_code": result.returncode,
        "stdout": result.stdout.strip(),
        "stderr": result.stderr.strip(),
    }
    json.dump(payload, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")

    if key_is_temp and key_path is not None:
        try:
            key_path.unlink(missing_ok=True)
        except Exception:
            pass
    return 0 if result.returncode == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())

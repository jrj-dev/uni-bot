#!/usr/bin/env python3
"""Safely toggle pre-approved UniFi policy/rule objects by ID.

This intentionally supports only narrow write operations:
- existing object IDs only (no create/delete)
- enabled flag toggle only
- explicit allowlist from environment
- dry-run by default
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from dataclasses import dataclass

from _paths import SCRIPT_DIR


REQUEST_SCRIPT = SCRIPT_DIR / "unifi_request.py"

RULE_TYPES = {
    "acl-rule": (
        "/proxy/network/integration/v1/sites/{site_id}/acl-rules/{rule_id}",
        "UNIFI_GUARD_ALLOWED_ACL_RULE_IDS",
    ),
    "firewall-policy": (
        "/proxy/network/integration/v1/sites/{site_id}/firewall/policies/{rule_id}",
        "UNIFI_GUARD_ALLOWED_FIREWALL_POLICY_IDS",
    ),
    "dns-policy": (
        "/proxy/network/integration/v1/sites/{site_id}/dns/policies/{rule_id}",
        "UNIFI_GUARD_ALLOWED_DNS_POLICY_IDS",
    ),
}


@dataclass
class RequestResult:
    returncode: int
    stdout: str
    stderr: str


# Parses CLI arguments for guarded policy enable and disable requests.
def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Guarded policy toggle for UniFi local integration."
    )
    parser.add_argument(
        "--rule-type",
        choices=sorted(RULE_TYPES),
        required=True,
        help="Kind of object to update.",
    )
    parser.add_argument("--rule-id", required=True, help="Existing policy/rule ID.")
    parser.add_argument("--site-id", help="Site UUID.")
    parser.add_argument(
        "--site-ref",
        default="default",
        help="Site internal reference to resolve when --site-id is not provided. Default: default.",
    )
    parser.add_argument(
        "--enabled",
        choices=("true", "false"),
        required=True,
        help="Target enabled state.",
    )
    parser.add_argument(
        "--reason",
        required=True,
        help="Short change reason for audit traceability.",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Execute the write. Without this flag, command is dry-run.",
    )
    parser.add_argument(
        "--confirm-token",
        help="Required with --apply. Must match the printed confirmation token.",
    )
    parser.add_argument(
        "--insecure",
        action="store_true",
        help="Pass through for self-signed TLS certs.",
    )
    return parser.parse_args()


# Runs one authenticated UniFi API request for the guarded policy flow.
def run_request(
    method: str,
    path: str,
    *,
    query: list[tuple[str, str]] | None = None,
    body: dict | None = None,
    insecure: bool = False,
) -> RequestResult:
    cmd = [sys.executable, str(REQUEST_SCRIPT), method, path]
    for key, value in query or []:
        cmd.extend(["--query", f"{key}={value}"])
    if body is not None:
        cmd.extend(["--json", json.dumps(body, separators=(",", ":"))])
    if insecure:
        cmd.append("--insecure")
    if method.upper() not in {"GET", "HEAD", "OPTIONS"}:
        cmd.append("--allow-write")

    result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    return RequestResult(
        returncode=result.returncode,
        stdout=result.stdout,
        stderr=result.stderr,
    )


# Parses JSON text or exits with a contextual error message.
def parse_json_or_exit(text: str, *, context: str) -> dict:
    try:
        payload = json.loads(text)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"{context}: non-JSON response: {exc}") from exc
    if not isinstance(payload, dict):
        raise SystemExit(f"{context}: expected JSON object response")
    return payload


# Resolves a site reference into the UUID site ID used by the API.
def resolve_site_id(site_id: str | None, site_ref: str, insecure: bool) -> str:
    if site_id:
        return site_id
    result = run_request("GET", "/proxy/network/integration/v1/sites", insecure=insecure)
    if result.returncode != 0:
        sys.stderr.write(result.stderr)
        raise SystemExit(result.returncode)
    payload = parse_json_or_exit(result.stdout, context="site lookup")
    sites = payload.get("data", [])
    if not isinstance(sites, list):
        raise SystemExit("site lookup: malformed response data")
    for item in sites:
        if isinstance(item, dict) and item.get("internalReference") == site_ref:
            resolved = item.get("id")
            if isinstance(resolved, str) and resolved:
                return resolved
    raise SystemExit(f"site reference not found: {site_ref}")


# Parses the environment-configured policy allowlist into a set of IDs.
def parse_allowlist(env_name: str) -> set[str]:
    raw = os.environ.get(env_name, "")
    items = [item.strip() for item in raw.split(",")]
    return {item for item in items if item}


# Builds the confirmation token required before toggling a policy.
def confirmation_token(rule_type: str, rule_id: str, enabled: bool) -> str:
    state = "enable" if enabled else "disable"
    return f"APPLY-{rule_type}-{rule_id[:8]}-{state}".upper()


# Dispatches the guarded policy toggle flow.
def main() -> int:
    args = parse_args()
    enabled = args.enabled == "true"

    template, allowlist_env = RULE_TYPES[args.rule_type]
    allowlist = parse_allowlist(allowlist_env)
    if not allowlist:
        raise SystemExit(
            f"guardrail config missing: set {allowlist_env} to a comma-separated list of allowed IDs"
        )
    if args.rule_id not in allowlist:
        raise SystemExit(
            f"blocked by guardrail: rule_id not allowlisted for {args.rule_type} ({allowlist_env})"
        )

    site_id = resolve_site_id(args.site_id, args.site_ref, args.insecure)
    path = template.format(site_id=site_id, rule_id=args.rule_id)

    # Read current object first for safety and traceability.
    current = run_request("GET", path, insecure=args.insecure)
    if current.returncode != 0:
        sys.stderr.write(current.stderr)
        return current.returncode
    current_payload = parse_json_or_exit(current.stdout, context="read current object")
    current_enabled = current_payload.get("enabled")

    token = confirmation_token(args.rule_type, args.rule_id, enabled)
    patch_body = {"enabled": enabled}
    summary = {
        "rule_type": args.rule_type,
        "site_id": site_id,
        "rule_id": args.rule_id,
        "reason": args.reason,
        "current_enabled": current_enabled,
        "target_enabled": enabled,
        "request": {"method": "PATCH", "path": path, "json": patch_body},
    }

    print(json.dumps(summary, indent=2, sort_keys=True))
    if not args.apply:
        print(
            f"DRY-RUN ONLY. Re-run with --apply --confirm-token {token} to execute this guarded write."
        )
        return 0

    if args.confirm_token != token:
        raise SystemExit(
            f"missing/invalid --confirm-token. expected: {token} (dry-run first to inspect)."
        )

    write_result = run_request(
        "PATCH",
        path,
        body=patch_body,
        insecure=args.insecure,
    )
    if write_result.returncode != 0:
        sys.stderr.write(write_result.stderr)
        return write_result.returncode

    print(write_result.stdout.rstrip())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

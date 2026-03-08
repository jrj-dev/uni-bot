#!/usr/bin/env python3
"""Read-only Loki queries scoped to UniFi Alarm Manager events."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import subprocess
import sys

from _paths import REPO_ROOT


REQUEST_SCRIPT = REPO_ROOT / "skills/unifi-network-local/scripts/loki_request.py"
ACTION_NAMES = ("query-range", "query-instant", "index-stats", "labels", "label-values")
ERROR_REGEX = r"(?i)error|failed|critical|deny|drop|offline|timeout|unauthorized"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run Loki queries for job=unifi_alarm_manager with optional narrowing."
    )
    parser.add_argument("action", choices=ACTION_NAMES, help="Action to run.")
    parser.add_argument(
        "--minutes",
        type=int,
        default=60,
        help="Window in minutes for range/index-stats. Default: 60.",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=100,
        help="Result limit for query actions. Default: 100.",
    )
    parser.add_argument(
        "--direction",
        choices=("backward", "forward"),
        default="backward",
        help="Direction for query-range. Default: backward.",
    )
    parser.add_argument("--label", help="Label key for label-values.")
    parser.add_argument(
        "--client-name",
        help="Filter logs containing this client name.",
    )
    parser.add_argument(
        "--client-ip",
        help="Filter logs containing this client IP.",
    )
    parser.add_argument(
        "--device-name",
        help="Filter logs containing this device name.",
    )
    parser.add_argument(
        "--contains",
        action="append",
        default=[],
        help="Additional plain-text contains filter. Repeat as needed.",
    )
    parser.add_argument(
        "--errors",
        action="store_true",
        help="Apply broad error-focused regex filter.",
    )
    parser.add_argument(
        "--raw-logql",
        help='Override full LogQL expression. If set, skips generated filters.',
    )
    parser.add_argument(
        "--insecure",
        action="store_true",
        help="Pass through for self-signed TLS certificates.",
    )
    return parser.parse_args()


def unix_nanos(timestamp: dt.datetime) -> str:
    return str(int(timestamp.timestamp() * 1_000_000_000))


def shell_quote(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"')


def build_logql(args: argparse.Namespace) -> str:
    if args.raw_logql:
        return args.raw_logql

    query = '{job="unifi_alarm_manager"}'
    terms: list[str] = []
    if args.client_name:
        terms.append(args.client_name)
    if args.client_ip:
        terms.append(args.client_ip)
    if args.device_name:
        terms.append(args.device_name)
    terms.extend(args.contains)

    for term in terms:
        if term.strip():
            query += f' |= "{shell_quote(term.strip())}"'
    if args.errors:
        query += f' |~ "{ERROR_REGEX}"'
    return query


def path_for_action(args: argparse.Namespace) -> str:
    if args.action == "query-range":
        return "/loki/api/v1/query_range"
    if args.action == "query-instant":
        return "/loki/api/v1/query"
    if args.action == "index-stats":
        return "/loki/api/v1/index/stats"
    if args.action == "labels":
        return "/loki/api/v1/labels"
    if args.action == "label-values":
        if not args.label:
            raise SystemExit("label-values requires --label")
        return f"/loki/api/v1/label/{args.label}/values"
    raise SystemExit(f"unsupported action: {args.action}")


def query_items_for_action(args: argparse.Namespace, logql: str) -> list[tuple[str, str]]:
    if args.action in {"labels", "label-values"}:
        return []
    if args.action == "query-instant":
        return [("query", logql), ("limit", str(max(1, args.limit)))]

    now = dt.datetime.now(tz=dt.timezone.utc)
    start = now - dt.timedelta(minutes=max(1, args.minutes))
    base = [
        ("query", logql),
        ("start", unix_nanos(start)),
        ("end", unix_nanos(now)),
    ]
    if args.action == "query-range":
        base.extend([
            ("limit", str(max(1, args.limit))),
            ("direction", args.direction),
        ])
    return base


def run_loki_request(path: str, query_items: list[tuple[str, str]], insecure: bool) -> int:
    cmd = [sys.executable, str(REQUEST_SCRIPT), "GET", path]
    for key, value in query_items:
        cmd.extend(["--query", f"{key}={value}"])
    if insecure:
        cmd.append("--insecure")

    result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if result.stderr:
        sys.stderr.write(result.stderr)
    if result.stdout:
        try:
            parsed = json.loads(result.stdout)
            json.dump(parsed, sys.stdout, indent=2, sort_keys=True)
            sys.stdout.write("\n")
        except json.JSONDecodeError:
            sys.stdout.write(result.stdout)
    return result.returncode


def main() -> int:
    args = parse_args()
    logql = build_logql(args)
    path = path_for_action(args)
    query_items = query_items_for_action(args, logql)

    if args.action in {"query-range", "query-instant", "index-stats"}:
        sys.stderr.write(f"[alarm-loki] logql={logql}\n")

    return run_loki_request(path, query_items, args.insecure)


if __name__ == "__main__":
    raise SystemExit(main())

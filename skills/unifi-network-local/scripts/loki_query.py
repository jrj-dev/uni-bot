#!/usr/bin/env python3
"""Named read-only Grafana Loki queries for common troubleshooting tasks."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import subprocess
import sys

from _paths import SCRIPT_DIR


REQUEST_SCRIPT = SCRIPT_DIR / "loki_request.py"
QUERY_NAMES = ("query-range", "query-instant", "labels", "label-values")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run a named read-only Grafana Loki query."
    )
    parser.add_argument("query", choices=QUERY_NAMES, help="Named Loki query to execute.")
    parser.add_argument(
        "--logql",
        default='{job="unifi"}',
        help='LogQL expression. Default: {job="unifi"}.',
    )
    parser.add_argument(
        "--minutes",
        type=int,
        default=60,
        help="Range window in minutes for query-range. Default: 60.",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=100,
        help="Maximum rows to return. Default: 100.",
    )
    parser.add_argument(
        "--direction",
        choices=("backward", "forward"),
        default="backward",
        help="Direction for query-range. Default: backward.",
    )
    parser.add_argument(
        "--label",
        help="Label key for label-values, for example host.",
    )
    parser.add_argument(
        "--insecure",
        action="store_true",
        help="Pass through for self-signed TLS certificates.",
    )
    return parser.parse_args()


def unix_nanos(timestamp: dt.datetime) -> str:
    return str(int(timestamp.timestamp() * 1_000_000_000))


def build_query_items(args: argparse.Namespace) -> list[tuple[str, str]]:
    query = args.query
    if query == "query-range":
        now = dt.datetime.now(tz=dt.timezone.utc)
        start = now - dt.timedelta(minutes=max(1, args.minutes))
        return [
            ("query", args.logql),
            ("start", unix_nanos(start)),
            ("end", unix_nanos(now)),
            ("limit", str(max(1, args.limit))),
            ("direction", args.direction),
        ]
    if query == "query-instant":
        return [
            ("query", args.logql),
            ("limit", str(max(1, args.limit))),
        ]
    return []


def path_for_query(args: argparse.Namespace) -> str:
    if args.query == "query-range":
        return "/loki/api/v1/query_range"
    if args.query == "query-instant":
        return "/loki/api/v1/query"
    if args.query == "labels":
        return "/loki/api/v1/labels"
    if args.query == "label-values":
        if not args.label:
            raise SystemExit("label-values requires --label")
        return f"/loki/api/v1/label/{args.label}/values"
    raise SystemExit(f"unsupported query: {args.query}")


def run_query(path: str, query_items: list[tuple[str, str]], insecure: bool) -> int:
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
    path = path_for_query(args)
    query_items = build_query_items(args)
    return run_query(path, query_items, args.insecure)


if __name__ == "__main__":
    raise SystemExit(main())


#!/usr/bin/env python3
"""Capture a fresh snapshot and print a summary in one step."""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

from _paths import SCRIPT_DIR


CAPTURE_SCRIPT = SCRIPT_DIR / "capture_snapshot.py"
ANALYZE_SCRIPT = SCRIPT_DIR / "analyze_snapshot.py"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Capture and analyze a fresh UniFi snapshot."
    )
    parser.add_argument(
        "--site-id",
        default=os.environ.get("UNIFI_SITE_ID"),
        help="Site ID to capture. Defaults to UNIFI_SITE_ID.",
    )
    parser.add_argument(
        "--insecure",
        action="store_true",
        help="Pass through for self-signed TLS certificates.",
    )
    return parser.parse_args()


def run_command(args: list[str]) -> str:
    result = subprocess.run(args, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        sys.stderr.write(result.stderr)
        raise SystemExit(result.returncode)
    return result.stdout.strip()


def main() -> int:
    args = parse_args()
    if not args.site_id:
        raise SystemExit("missing site ID: set UNIFI_SITE_ID or pass --site-id")

    capture_cmd = [
        sys.executable,
        str(CAPTURE_SCRIPT),
        "--site-id",
        args.site_id,
    ]
    if args.insecure:
        capture_cmd.append("--insecure")
    snapshot_dir = run_command(capture_cmd)

    analyze_cmd = [
        sys.executable,
        str(ANALYZE_SCRIPT),
        snapshot_dir,
    ]
    summary = run_command(analyze_cmd)

    print(summary)
    print(f"\nSaved snapshot: {Path(snapshot_dir)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

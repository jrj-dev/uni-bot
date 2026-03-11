#!/usr/bin/env python3
"""Capture a small set of UniFi API responses for later analysis."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import pathlib
import subprocess
import sys
from typing import Iterable

from _paths import SCRIPT_DIR


GLOBAL_ENDPOINTS = (
    ("sites", "/proxy/network/integration/v1/sites"),
    ("pending_devices", "/proxy/network/integration/v1/pending-devices"),
    ("dpi_categories", "/proxy/network/integration/v1/dpi/categories"),
    ("dpi_applications", "/proxy/network/integration/v1/dpi/applications"),
    ("countries", "/proxy/network/integration/v1/countries"),
)
SITE_SCOPED_ENDPOINTS = (
    ("devices", "/proxy/network/integration/v1/sites/{site_id}/devices"),
    ("clients", "/proxy/network/integration/v1/sites/{site_id}/clients"),
    ("networks", "/proxy/network/integration/v1/sites/{site_id}/networks"),
    ("wifi_broadcasts", "/proxy/network/integration/v1/sites/{site_id}/wifi/broadcasts"),
    ("firewall_policies", "/proxy/network/integration/v1/sites/{site_id}/firewall/policies"),
    ("firewall_zones", "/proxy/network/integration/v1/sites/{site_id}/firewall/zones"),
    ("device_tags", "/proxy/network/integration/v1/sites/{site_id}/device-tags"),
    ("wan_profiles", "/proxy/network/integration/v1/sites/{site_id}/wans"),
    ("vpn_servers", "/proxy/network/integration/v1/sites/{site_id}/vpn/servers"),
    ("site_to_site_vpn", "/proxy/network/integration/v1/sites/{site_id}/vpn/site-to-site-tunnels"),
    ("radius_profiles", "/proxy/network/integration/v1/sites/{site_id}/radius/profiles"),
)


REQUEST_SCRIPT = SCRIPT_DIR / "unifi_request.py"
ALL_ENDPOINT_NAMES = [name for name, _ in (*GLOBAL_ENDPOINTS, *SITE_SCOPED_ENDPOINTS)]


# Parses CLI arguments for UniFi snapshot capture.
def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Capture a standard UniFi troubleshooting snapshot."
    )
    parser.add_argument(
        "--output-dir",
        default="data/unifi/snapshots",
        help="Directory for timestamped snapshot folders.",
    )
    parser.add_argument(
        "--insecure",
        action="store_true",
        help="Pass through to the request client for self-signed TLS certs.",
    )
    parser.add_argument(
        "--include",
        action="append",
        choices=ALL_ENDPOINT_NAMES,
        help="Limit capture to specific datasets. Repeat as needed.",
    )
    parser.add_argument(
        "--endpoint",
        action="append",
        default=[],
        metavar="NAME=PATH",
        help="Add a custom endpoint to capture. Repeat as needed.",
    )
    parser.add_argument(
        "--site-id",
        help="Add the standard site-scoped datasets for the given site ID.",
    )
    return parser.parse_args()


# Parses custom endpoint aliases supplied on the command line.
def parse_custom_endpoints(items: list[str]) -> list[tuple[str, str]]:
    parsed: list[tuple[str, str]] = []
    for item in items:
        if "=" not in item:
            raise SystemExit(f"invalid endpoint {item!r}; expected NAME=PATH")
        name, path = item.split("=", 1)
        if not name:
            raise SystemExit(f"invalid endpoint {item!r}; missing NAME")
        if not path.startswith("/"):
            raise SystemExit(f"invalid endpoint {item!r}; PATH must begin with '/'")
        parsed.append((name, path))
    return parsed


# Returns the endpoint list that should be included in the snapshot.
def selected_endpoints(
    include: list[str] | None, custom: list[tuple[str, str]], site_id: str | None
) -> Iterable[tuple[str, str]]:
    include_set = set(include or [])
    want_filtered = bool(include_set)
    chosen: list[tuple[str, str]] = []

    for name, path in GLOBAL_ENDPOINTS:
        if not want_filtered or name in include_set:
            chosen.append((name, path))

    requested_site_scoped = [name for name, _ in SITE_SCOPED_ENDPOINTS if name in include_set]
    if requested_site_scoped and not site_id:
        raise SystemExit(
            "site-scoped datasets require --site-id: "
            + ", ".join(sorted(requested_site_scoped))
        )

    if include:
        pass
    if site_id:
        for name, path in SITE_SCOPED_ENDPOINTS:
            if not want_filtered or name in include_set:
                chosen.append((name, path.format(site_id=site_id)))
    chosen.extend(custom)
    return chosen


# Runs one snapshot request and decodes the JSON response.
def run_request(path: str, insecure: bool) -> dict:
    cmd = [
        sys.executable,
        str(REQUEST_SCRIPT),
        "GET",
        path,
    ]
    if insecure:
        cmd.append("--insecure")
    result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or f"request failed for {path}")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"non-JSON response for {path}") from exc


# Checks that the required UniFi request environment variables are present.
def ensure_env() -> None:
    missing = [name for name in ("UNIFI_BASE_URL", "UNIFI_API_KEY") if not os.environ.get(name)]
    if missing:
        raise SystemExit(f"missing required environment: {', '.join(missing)}")


# Dispatches the snapshot capture flow.
def main() -> int:
    args = parse_args()
    ensure_env()

    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    target_dir = pathlib.Path(args.output_dir) / stamp
    target_dir.mkdir(parents=True, exist_ok=False)

    manifest: dict[str, str] = {}
    try:
        for name, path in selected_endpoints(
            args.include, parse_custom_endpoints(args.endpoint), args.site_id
        ):
            payload = run_request(path, insecure=args.insecure)
            out_path = target_dir / f"{name}.json"
            out_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
            manifest[name] = path
    except Exception:
        for child in target_dir.iterdir():
            child.unlink()
        target_dir.rmdir()
        raise

    (target_dir / "manifest.json").write_text(
        json.dumps(
            {
                "captured_at_utc": stamp,
                "endpoints": manifest,
            },
            indent=2,
            sort_keys=True,
        )
        + "\n"
    )

    print(target_dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

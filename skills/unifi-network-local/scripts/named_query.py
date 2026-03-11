#!/usr/bin/env python3
"""Named read-only UniFi API queries for common troubleshooting tasks."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys

from _paths import SCRIPT_DIR


REQUEST_SCRIPT = SCRIPT_DIR / "unifi_request.py"
SITE_ID_QUERIES = {
    "devices": "/proxy/network/integration/v1/sites/{site_id}/devices",
    "clients": "/proxy/network/integration/v1/sites/{site_id}/clients",
    "clients-all": "/proxy/network/integration/v1/sites/{site_id}/clients?includeInactive=true",
    "networks": "/proxy/network/integration/v1/sites/{site_id}/networks",
    "wifi-broadcasts": "/proxy/network/integration/v1/sites/{site_id}/wifi/broadcasts",
    "hotspot-vouchers": "/proxy/network/integration/v1/sites/{site_id}/hotspot/vouchers",
    "firewall-policies": "/proxy/network/integration/v1/sites/{site_id}/firewall/policies",
    "firewall-policies-ordering": "/proxy/network/integration/v1/sites/{site_id}/firewall/policies/ordering",
    "firewall-zones": "/proxy/network/integration/v1/sites/{site_id}/firewall/zones",
    "acl-rules": "/proxy/network/integration/v1/sites/{site_id}/acl-rules",
    "acl-rules-ordering": "/proxy/network/integration/v1/sites/{site_id}/acl-rules/ordering",
    "dns-policies": "/proxy/network/integration/v1/sites/{site_id}/dns/policies",
    "traffic-matching-lists": "/proxy/network/integration/v1/sites/{site_id}/traffic-matching-lists",
    "device-tags": "/proxy/network/integration/v1/sites/{site_id}/device-tags",
    "wan-profiles": "/proxy/network/integration/v1/sites/{site_id}/wans",
    "vpn-servers": "/proxy/network/integration/v1/sites/{site_id}/vpn/servers",
    "site-to-site-vpn": "/proxy/network/integration/v1/sites/{site_id}/vpn/site-to-site-tunnels",
    "radius-profiles": "/proxy/network/integration/v1/sites/{site_id}/radius/profiles",
}
SITE_REF_QUERIES = {
    "events": "/proxy/network/api/s/{site_ref}/stat/event",
    "wlanconf": "/proxy/network/api/s/{site_ref}/rest/wlanconf",
    "networkconf": "/proxy/network/api/s/{site_ref}/rest/networkconf",
}
RESOURCE_ID_QUERIES = {
    "device": (
        ("site_id", "device_id"),
        "/proxy/network/integration/v1/sites/{site_id}/devices/{device_id}",
    ),
    "device-stats": (
        ("site_id", "device_id"),
        "/proxy/network/integration/v1/sites/{site_id}/devices/{device_id}/statistics/latest",
    ),
    "client": (
        ("site_id", "client_id"),
        "/proxy/network/integration/v1/sites/{site_id}/clients/{client_id}",
    ),
    "network": (
        ("site_id", "network_id"),
        "/proxy/network/integration/v1/sites/{site_id}/networks/{network_id}",
    ),
    "network-references": (
        ("site_id", "network_id"),
        "/proxy/network/integration/v1/sites/{site_id}/networks/{network_id}/references",
    ),
    "wifi-broadcast": (
        ("site_id", "wifi_broadcast_id"),
        "/proxy/network/integration/v1/sites/{site_id}/wifi/broadcasts/{wifi_broadcast_id}",
    ),
    "hotspot-voucher": (
        ("site_id", "voucher_id"),
        "/proxy/network/integration/v1/sites/{site_id}/hotspot/vouchers/{voucher_id}",
    ),
    "firewall-policy": (
        ("site_id", "firewall_policy_id"),
        "/proxy/network/integration/v1/sites/{site_id}/firewall/policies/{firewall_policy_id}",
    ),
    "firewall-zone": (
        ("site_id", "firewall_zone_id"),
        "/proxy/network/integration/v1/sites/{site_id}/firewall/zones/{firewall_zone_id}",
    ),
    "acl-rule": (
        ("site_id", "acl_rule_id"),
        "/proxy/network/integration/v1/sites/{site_id}/acl-rules/{acl_rule_id}",
    ),
    "dns-policy": (
        ("site_id", "dns_policy_id"),
        "/proxy/network/integration/v1/sites/{site_id}/dns/policies/{dns_policy_id}",
    ),
    "traffic-matching-list": (
        ("site_id", "traffic_matching_list_id"),
        "/proxy/network/integration/v1/sites/{site_id}/traffic-matching-lists/{traffic_matching_list_id}",
    ),
}
GLOBAL_QUERIES = {
    "sites": "/proxy/network/integration/v1/sites",
    "pending-devices": "/proxy/network/integration/v1/pending-devices",
    "dpi-categories": "/proxy/network/integration/v1/dpi/categories",
    "dpi-applications": "/proxy/network/integration/v1/dpi/applications",
    "countries": "/proxy/network/integration/v1/countries",
}
QUERY_NAMES = tuple(
    list(GLOBAL_QUERIES) + list(SITE_ID_QUERIES) + list(SITE_REF_QUERIES) + list(RESOURCE_ID_QUERIES)
)
NON_PAGINATED_QUERIES = {
    "firewall-policies-ordering",
    "acl-rules-ordering",
    *RESOURCE_ID_QUERIES.keys(),
}
SANITIZED_QUERIES = {"events", "wlanconf", "networkconf"}
REDACTED_VALUE = "<redacted>"
SENSITIVE_KEY_FRAGMENTS = (
    "passphrase",
    "password",
    "token",
    "secret",
    "private_key",
    "privatekey",
    "ssh_key",
    "certificate",
    "cert",
    "fingerprint",
    "hash",
    "sha",
    "api_key",
    "apikey",
    "psk",
    "sae_psk",
    "auth_key",
    "encryption_key",
    "x_ssh_password",
    "x_iapp_key",
)


# Parses CLI arguments for named UniFi API queries.
def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run a named read-only UniFi Network integration query."
    )
    parser.add_argument("query", choices=QUERY_NAMES, help="Named query to execute.")
    parser.add_argument("--site-id", help="Site ID for site-scoped queries.")
    parser.add_argument(
        "--site-ref",
        help="Site internal reference (for example 'default') to resolve into a site ID.",
    )
    parser.add_argument(
        "--query",
        dest="query_params",
        action="append",
        default=[],
        metavar="KEY=VALUE",
        help="Pass query parameters through to the request client. Repeat as needed.",
    )
    parser.add_argument("--device-id", help="Device ID for device-specific queries.")
    parser.add_argument("--client-id", help="Client ID for client-specific queries.")
    parser.add_argument("--network-id", help="Network ID for network-specific queries.")
    parser.add_argument(
        "--wifi-broadcast-id",
        help="WiFi broadcast ID for WiFi-specific queries.",
    )
    parser.add_argument("--voucher-id", help="Hotspot voucher ID for voucher queries.")
    parser.add_argument(
        "--firewall-policy-id",
        help="Firewall policy ID for firewall policy queries.",
    )
    parser.add_argument(
        "--firewall-zone-id",
        help="Firewall zone ID for firewall zone queries.",
    )
    parser.add_argument("--acl-rule-id", help="ACL rule ID for ACL rule queries.")
    parser.add_argument("--dns-policy-id", help="DNS policy ID for DNS policy queries.")
    parser.add_argument(
        "--traffic-matching-list-id",
        help="Traffic matching list ID for traffic matching list queries.",
    )
    parser.add_argument(
        "--all-pages",
        action="store_true",
        help="Follow paginated responses until all pages are fetched.",
    )
    parser.add_argument(
        "--page-size",
        type=int,
        default=100,
        help="Page size to request when using --all-pages. Default: 100.",
    )
    parser.add_argument(
        "--insecure",
        action="store_true",
        help="Pass through for self-signed TLS certificates.",
    )
    return parser.parse_args()


# Returns true when a named query requires a site-scoped path.
def uses_site_scope(query_name: str) -> bool:
    if query_name in SITE_ID_QUERIES:
        return True
    if query_name in SITE_REF_QUERIES:
        return True
    if query_name in RESOURCE_ID_QUERIES:
        return "site_id" in RESOURCE_ID_QUERIES[query_name][0]
    return False


# Loads the full UniFi site list used for site-ref resolution.
def load_sites(insecure: bool) -> list[dict]:
    payload = run_json_query(GLOBAL_QUERIES["sites"], [], insecure)
    data = payload.get("data", [])
    if isinstance(data, list):
        return [item for item in data if isinstance(item, dict)]
    return []


# Resolves a human-friendly site reference into the UUID site ID the API expects.
def resolve_site_id(args: argparse.Namespace) -> str | None:
    if not uses_site_scope(args.query):
        return None
    site_id = getattr(args, "site_id", None)
    if site_id:
        return site_id
    site_ref = getattr(args, "site_ref", None)
    if not site_ref:
        raise SystemExit(f"{args.query} requires --site-id or --site-ref")

    # Site references like "default" are stable enough for day-to-day use, but the
    # API itself still expects the UUID site ID in the final request path.
    sites = load_sites(args.insecure)
    for site in sites:
        if site.get("internalReference") == site_ref:
            resolved_site_id = site.get("id")
            if isinstance(resolved_site_id, str) and resolved_site_id:
                return resolved_site_id
            break
    raise SystemExit(f"site reference not found: {site_ref}")


# Resolves a UUID site ID or human-friendly site-ref into the legacy site path reference.
def resolve_site_ref(args: argparse.Namespace) -> str | None:
    if args.query not in SITE_REF_QUERIES:
        return None
    site_ref = getattr(args, "site_ref", None)
    if site_ref:
        return site_ref

    site_id = getattr(args, "site_id", None)
    if not site_id:
        raise SystemExit(f"{args.query} requires --site-id or --site-ref")

    sites = load_sites(args.insecure)
    for site in sites:
        if site.get("id") == site_id:
            resolved_site_ref = site.get("internalReference")
            if isinstance(resolved_site_ref, str) and resolved_site_ref:
                return resolved_site_ref
            break
    raise SystemExit(f"site id not found or missing internalReference: {site_id}")


# Maps a named query onto the concrete UniFi API path it should call.
def resolve_path(args: argparse.Namespace) -> str:
    if args.query in GLOBAL_QUERIES:
        return GLOBAL_QUERIES[args.query]

    if args.query in SITE_ID_QUERIES:
        site_id = resolve_site_id(args)
        return SITE_ID_QUERIES[args.query].format(site_id=site_id)

    if args.query in SITE_REF_QUERIES:
        site_ref = resolve_site_ref(args)
        return SITE_REF_QUERIES[args.query].format(site_ref=site_ref)

    required_fields, template = RESOURCE_ID_QUERIES[args.query]
    values: dict[str, str] = {}
    for field in required_fields:
        if field == "site_id":
            value = resolve_site_id(args)
        else:
            value = getattr(args, field)
        if not value:
            raise SystemExit(f"{args.query} requires --{field.replace('_', '-')}")
        values[field] = value
    return template.format(**values)


# Parses repeated key=value CLI arguments into query tuples.
def parse_query_items(items: list[str]) -> list[tuple[str, str]]:
    parsed: list[tuple[str, str]] = []
    for item in items:
        if "=" not in item:
            raise SystemExit(f"invalid query parameter {item!r}; expected KEY=VALUE")
        key, value = item.split("=", 1)
        parsed.append((key, value))
    return parsed


# Builds the `unifi_request.py` command used to execute the named query.
def build_command(
    path: str,
    query_items: list[tuple[str, str]],
    insecure: bool,
) -> list[str]:
    cmd = [sys.executable, str(REQUEST_SCRIPT), "GET", path]
    for key, value in query_items:
        cmd.extend(["--query", f"{key}={value}"])
    if insecure:
        cmd.append("--insecure")
    return cmd


# Runs the low-level UniFi request helper and decodes the JSON response.
def run_json_query(
    path: str,
    query_items: list[tuple[str, str]],
    insecure: bool,
) -> dict:
    cmd = build_command(path, query_items, insecure)
    result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        if result.stderr:
            sys.stderr.write(result.stderr)
        raise SystemExit(result.returncode)
    if result.stderr:
        sys.stderr.write(result.stderr)
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        sys.stdout.write(result.stdout)
        raise SystemExit(0)


# Returns true when the response matches UniFi's standard pagination envelope.
def is_paginated_payload(payload: dict) -> bool:
    return (
        isinstance(payload, dict)
        and isinstance(payload.get("data"), list)
        and isinstance(payload.get("offset"), int)
        and isinstance(payload.get("limit"), int)
        and isinstance(payload.get("count"), int)
        and isinstance(payload.get("totalCount"), int)
    )


# Merges multiple paginated UniFi responses into one payload.
def merge_paginated_pages(pages: list[dict]) -> dict:
    merged = dict(pages[0])
    data: list[object] = []
    for page in pages:
        page_data = page.get("data", [])
        if isinstance(page_data, list):
            data.extend(page_data)
    merged["data"] = data
    merged["offset"] = 0
    merged["count"] = len(data)
    merged["totalCount"] = max((page.get("totalCount", len(data)) for page in pages), default=len(data))
    if pages:
        merged["limit"] = pages[0].get("limit", len(data))
    return merged


# Walks a paginated UniFi endpoint until the reported total is exhausted.
def fetch_all_pages(
    query_name: str,
    path: str,
    query_items: list[tuple[str, str]],
    insecure: bool,
    page_size: int,
) -> dict:
    if query_name in NON_PAGINATED_QUERIES:
        return run_json_query(path, query_items, insecure)

    # When the endpoint follows the standard UniFi pagination envelope, walk pages
    # until the reported total is exhausted and return one merged payload.
    filtered_items = [(key, value) for key, value in query_items if key not in {"offset", "limit"}]
    pages: list[dict] = []
    offset = 0

    while True:
        page = run_json_query(
            path,
            [*filtered_items, ("offset", str(offset)), ("limit", str(page_size))],
            insecure,
        )
        if not is_paginated_payload(page):
            return page if not pages else merge_paginated_pages([*pages, page])
        pages.append(page)
        count = page.get("count", 0)
        total_count = page.get("totalCount", 0)
        offset += count
        if count == 0 or offset >= total_count:
            break

    return merge_paginated_pages(pages)


# Returns true when a payload key likely contains credential-bearing data.
def is_sensitive_key(key: str) -> bool:
    normalized = key.strip().lower()
    return any(fragment in normalized for fragment in SENSITIVE_KEY_FRAGMENTS)


# Recursively redacts credential-bearing values from UniFi payloads.
def sanitize_payload(value: object) -> object:
    if isinstance(value, dict):
        sanitized: dict[object, object] = {}
        for key, item in value.items():
            if isinstance(key, str) and is_sensitive_key(key):
                sanitized[key] = REDACTED_VALUE
            else:
                sanitized[key] = sanitize_payload(item)
        return sanitized
    if isinstance(value, list):
        return [sanitize_payload(item) for item in value]
    return value


# Dispatches the selected named query command.
def main() -> int:
    args = parse_args()
    path = resolve_path(args)
    query_items = parse_query_items(args.query_params)
    if args.all_pages:
        payload = fetch_all_pages(args.query, path, query_items, args.insecure, args.page_size)
    else:
        payload = run_json_query(path, query_items, args.insecure)
    if args.query in SANITIZED_QUERIES:
        payload = sanitize_payload(payload)
    json.dump(payload, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

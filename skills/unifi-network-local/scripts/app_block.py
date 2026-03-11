#!/usr/bin/env python3
"""Plan or apply UniFi simple app-block rules from clients, DPI apps, and schedules."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from datetime import datetime
from functools import lru_cache
from typing import Any

from _paths import SCRIPT_DIR


NAMED_QUERY_SCRIPT = SCRIPT_DIR / "named_query.py"
REQUEST_SCRIPT = SCRIPT_DIR / "unifi_request.py"
DAY_NAMES = ("mon", "tue", "wed", "thu", "fri", "sat", "sun")
DAY_VALUES = {
    "sun": 0,
    "mon": 1,
    "tue": 2,
    "wed": 3,
    "thu": 4,
    "fri": 5,
    "sat": 6,
}
SIMPLE_APP_BLOCK_PATH = "/proxy/network/v2/api/site/{site_ref}/firewall-app-blocks"


# Parses CLI arguments for resolving, planning, applying, listing, and removing UniFi simple app blocks.
def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Resolve or apply UniFi CyberSecure simple app-block rules by mapping "
            "clients, DPI apps, DPI categories, and schedule inputs onto the live UI model."
        )
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    list_apps = subparsers.add_parser(
        "list-apps",
        help="List or search the DPI application catalog exposed by UniFi.",
    )
    list_apps.add_argument(
        "--search",
        help="Case-insensitive substring search against application names.",
    )
    list_apps.add_argument(
        "--limit",
        type=int,
        default=50,
        help="Maximum apps to print. Default: 50.",
    )
    list_apps.add_argument(
        "--insecure",
        action="store_true",
        help="Pass through for self-signed TLS certificates.",
    )

    list_categories = subparsers.add_parser(
        "list-categories",
        help="List or search the DPI category catalog exposed by UniFi.",
    )
    list_categories.add_argument(
        "--search",
        help="Case-insensitive substring search against category names.",
    )
    list_categories.add_argument(
        "--limit",
        type=int,
        default=50,
        help="Maximum categories to print. Default: 50.",
    )
    list_categories.add_argument(
        "--insecure",
        action="store_true",
        help="Pass through for self-signed TLS certificates.",
    )

    resolve_client = subparsers.add_parser(
        "resolve-client",
        help="Resolve one client by fuzzy match (name/hostname/IP/MAC/id).",
    )
    resolve_client.add_argument(
        "--query",
        required=True,
        help="Client selector fragment.",
    )
    resolve_client.add_argument("--site-id", help="Site ID for site-scoped queries.")
    resolve_client.add_argument(
        "--site-ref",
        help="Site internal reference (for example 'default') to resolve into a site ID.",
    )
    resolve_client.add_argument(
        "--insecure",
        action="store_true",
        help="Pass through for self-signed TLS certificates.",
    )

    resolve_app = subparsers.add_parser(
        "resolve-app",
        help="Resolve one DPI application by fuzzy name or ID.",
    )
    resolve_app.add_argument(
        "--query",
        required=True,
        help="Application name or ID fragment.",
    )
    resolve_app.add_argument(
        "--insecure",
        action="store_true",
        help="Pass through for self-signed TLS certificates.",
    )

    resolve_category = subparsers.add_parser(
        "resolve-category",
        help="Resolve one DPI category by fuzzy name or ID.",
    )
    resolve_category.add_argument(
        "--query",
        required=True,
        help="Category name or ID fragment.",
    )
    resolve_category.add_argument(
        "--insecure",
        action="store_true",
        help="Pass through for self-signed TLS certificates.",
    )

    plan = subparsers.add_parser(
        "plan-block",
        help="Resolve a client and list of apps/categories into a simple app-block plan.",
    )

    apply_block = subparsers.add_parser(
        "apply-block",
        help="Create one or more simple app-block rules through the private firewall-app-blocks API.",
    )
    remove_block = subparsers.add_parser(
        "remove-block",
        help="Remove app-block rules for a client, or remove selected apps/categories from existing rules.",
    )
    list_block = subparsers.add_parser(
        "list-block",
        help="List app-block rules that currently target a specific client.",
    )

    for subparser in (plan, apply_block, remove_block):
        subparser.add_argument(
        "--client",
        required=True,
        help="Client selector. Matches client name, hostname, MAC, IP, or ID.",
    )
        subparser.add_argument(
        "--app",
        dest="apps",
        action="append",
        help="Application name or ID to block. Repeat for multiple apps.",
    )
        subparser.add_argument(
        "--category",
        dest="categories",
        action="append",
        help="Application category name or ID to block. Repeat for multiple categories.",
    )
        subparser.add_argument("--site-id", help="Site ID for site-scoped queries.")
        subparser.add_argument(
        "--site-ref",
        help="Site internal reference (for example 'default') to resolve into a site ID.",
    )
        subparser.add_argument(
        "--policy-name",
        help="Optional friendly policy name. Defaults to an auto-generated name.",
    )
        subparser.add_argument(
        "--schedule-mode",
        choices=("always", "once", "daily", "weekly", "custom"),
        default="always",
        help="Schedule type for the block. Default: always.",
    )
        subparser.add_argument(
        "--start",
        help="Start timestamp for schedule_mode=once, in ISO-8601 local form.",
    )
        subparser.add_argument(
        "--end",
        help="End timestamp for schedule_mode=once, in ISO-8601 local form.",
    )
        subparser.add_argument(
        "--start-time",
        help="Daily/weekly start time in HH:MM.",
    )
        subparser.add_argument(
        "--end-time",
        help="Daily/weekly end time in HH:MM.",
    )
        subparser.add_argument(
        "--days",
        help="Comma-separated days for schedule_mode=weekly. Example: mon,tue,wed.",
    )
        subparser.add_argument(
            "--all-day",
            action="store_true",
            help="For weekly/custom schedules, omit start/end times and block all day.",
        )
        subparser.add_argument(
        "--insecure",
        action="store_true",
        help="Pass through for self-signed TLS certificates.",
    )

    list_block.add_argument(
        "--client",
        required=True,
        help="Client selector. Matches client name, hostname, MAC, IP, or ID.",
    )
    list_block.add_argument("--site-id", help="Site ID for site-scoped queries.")
    list_block.add_argument(
        "--site-ref",
        help="Site internal reference (for example 'default') to resolve into a site ID.",
    )
    list_block.add_argument(
        "--insecure",
        action="store_true",
        help="Pass through for self-signed TLS certificates.",
    )

    apply_block.add_argument(
        "--rule-id",
        help="Existing rule ID to update instead of creating a new one. Only valid when producing one payload.",
    )

    return parser.parse_args()


# Runs the named-query helper and returns its decoded JSON output.
def run_named_query(
    query: str,
    *,
    site_id: str | None = None,
    site_ref: str | None = None,
    insecure: bool = False,
    all_pages: bool = False,
) -> Any:
    cmd = [sys.executable, str(NAMED_QUERY_SCRIPT), query]
    if site_id:
        cmd.extend(["--site-id", site_id])
    if site_ref:
        cmd.extend(["--site-ref", site_ref])
    if all_pages:
        cmd.append("--all-pages")
    if insecure:
        cmd.append("--insecure")

    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or f"query failed: {query}")

    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"non-JSON response for query {query}") from exc


# Extracts row dictionaries from the standard UniFi response envelope.
def rows(payload: Any) -> list[dict[str, Any]]:
    if isinstance(payload, list):
        return [item for item in payload if isinstance(item, dict)]
    if isinstance(payload, dict):
        data = payload.get("data")
        if isinstance(data, list):
            return [item for item in data if isinstance(item, dict)]
        return [payload]
    return []


# Loads the client inventory used to resolve simple app-block targets.
def load_clients_for_app_block(args: argparse.Namespace) -> list[dict[str, Any]]:
    candidates: list[list[dict[str, Any]]] = []

    try:
        payload = run_named_query(
            "clients-all",
            site_id=args.site_id,
            site_ref=args.site_ref,
            insecure=args.insecure,
            all_pages=True,
        )
        candidates.append(rows(payload))
    except Exception:
        pass

    try:
        payload = run_named_query(
            "clients",
            site_id=args.site_id,
            site_ref=args.site_ref,
            insecure=args.insecure,
            all_pages=True,
        )
        candidates.append(rows(payload))
    except Exception:
        pass

    try:
        site_ref = resolve_site_ref(args)
        payload = run_unifi_request(
            "GET",
            f"/proxy/network/api/s/{site_ref}/stat/alluser",
            insecure=args.insecure,
        )
        candidates.append(rows(payload))
    except Exception:
        pass

    if not candidates:
        raise SystemExit("unable to load clients for app block planning")
    return max(candidates, key=len)


# Runs the low-level UniFi request helper and returns its decoded JSON response.
def run_unifi_request(
    method: str,
    path: str,
    *,
    body: dict[str, Any] | None = None,
    insecure: bool = False,
) -> Any:
    cmd = [sys.executable, str(REQUEST_SCRIPT), method.upper(), path]
    if body is not None:
        cmd.extend(["--json", json.dumps(body)])
    if insecure:
        cmd.append("--insecure")
    if method.upper() not in {"GET", "HEAD", "OPTIONS"}:
        cmd.append("--allow-write")

    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or f"request failed: {method} {path}")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"non-JSON response for request {method} {path}") from exc


# Normalizes a value into lowercase text for case-insensitive comparisons.
def normalized(value: Any) -> str:
    return str(value or "").strip().lower()


# Normalizes a MAC address into lowercase colon-delimited form.
def canonical_mac(value: Any) -> str:
    text = str(value or "").strip().lower()
    if not text:
        return ""
    hex_only = text.replace(":", "").replace("-", "")
    if len(hex_only) != 12:
        return ""
    if any(ch not in "0123456789abcdef" for ch in hex_only):
        return ""
    return ":".join(hex_only[i:i + 2] for i in range(0, 12, 2))


# Normalizes a mixed input value into a deduplicated list of MAC addresses.
def normalize_mac_list(values: Any) -> list[str]:
    if not isinstance(values, list):
        return []
    out: list[str] = []
    for item in values:
        mac = canonical_mac(item)
        if mac:
            out.append(mac)
    return out


# Collects the non-empty string fields that should participate in matching.
def candidate_fields(item: dict[str, Any], keys: tuple[str, ...]) -> list[str]:
    return [normalized(item.get(key)) for key in keys if normalized(item.get(key))]


# Builds the human-readable client label used in CLI output.
def display_client(client: dict[str, Any]) -> str:
    for key in ("name", "displayName", "clientName", "hostname", "hostName", "dhcpHostname", "mac", "macAddress", "ip", "ipAddress", "id"):
        value = str(client.get(key) or "").strip()
        if value:
            return value
    return "unknown-client"


# Builds the human-readable DPI application label used in CLI output.
def display_app(app: dict[str, Any]) -> str:
    for key in ("name", "id"):
        value = str(app.get(key) or "").strip()
        if value:
            return value
    return "unknown-app"


# Returns exactly one fuzzy match or raises an error when the selector is ambiguous.
def resolve_single_match(
    selector: str,
    items: list[dict[str, Any]],
    *,
    keys: tuple[str, ...],
    label: str,
    display,
) -> dict[str, Any]:
    query = normalized(selector)
    if not query:
        raise SystemExit(f"missing {label} selector")

    exact_matches = [
        item for item in items
        if query in candidate_fields(item, keys) and query
    ]
    if len(exact_matches) == 1:
        return exact_matches[0]
    if len(exact_matches) > 1:
        raise SystemExit(
            f"ambiguous {label} selector {selector!r}; exact matches: "
            + ", ".join(display(item) for item in exact_matches[:8])
        )

    contains_matches = [
        item for item in items
        if any(query in field for field in candidate_fields(item, keys))
    ]
    if len(contains_matches) == 1:
        return contains_matches[0]
    if len(contains_matches) > 1:
        raise SystemExit(
            f"ambiguous {label} selector {selector!r}; candidates: "
            + ", ".join(display(item) for item in contains_matches[:8])
        )

    sample = ", ".join(display(item) for item in items[:8])
    raise SystemExit(f"{label} not found for selector {selector!r}. Sample values: {sample}")


# Normalizes text before fuzzy matching by stripping case and punctuation noise.
def normalize_match_text(value: str) -> str:
    text = str(value or "").strip().lower()
    if text.endswith(".local"):
        text = text[:-6]
    normalized_chars = [ch if ch.isalnum() else " " for ch in text]
    return " ".join("".join(normalized_chars).split())


@lru_cache(maxsize=2048)
# Computes Levenshtein edit distance for fuzzy selector matching.
def edit_distance(lhs: str, rhs: str) -> int:
    if lhs == rhs:
        return 0
    if not lhs:
        return len(rhs)
    if not rhs:
        return len(lhs)
    prev = list(range(len(rhs) + 1))
    for i, lhs_char in enumerate(lhs, start=1):
        cur = [i] + [0] * len(rhs)
        for j, rhs_char in enumerate(rhs, start=1):
            cost = 0 if lhs_char == rhs_char else 1
            cur[j] = min(
                prev[j] + 1,
                cur[j - 1] + 1,
                prev[j - 1] + cost,
            )
        prev = cur
    return prev[-1]


# Scores how well a candidate string matches the requested selector.
def fuzzy_score(query: str, candidate: str) -> int:
    if candidate == query:
        return 120
    if candidate.startswith(query) or query.startswith(candidate):
        return 95
    if query in candidate:
        return 85
    if candidate in query and len(candidate) >= 4:
        return 70
    dist = edit_distance(query, candidate)
    if dist <= 1:
        return 72
    if dist <= 2:
        return 62
    if dist <= 3 and min(len(query), len(candidate)) >= 6:
        return 48
    return 0


# Returns the highest-scoring fuzzy match from a candidate list.
def resolve_fuzzy_best(
    selector: str,
    items: list[dict[str, Any]],
    *,
    keys: tuple[str, ...],
    label: str,
    minimum_score: int = 35,
) -> tuple[dict[str, Any], int]:
    query = normalize_match_text(selector)
    if not query:
        raise SystemExit(f"missing {label} selector")

    best_item: dict[str, Any] | None = None
    best_score = -1
    for item in items:
        fields = [normalize_match_text(field) for field in candidate_fields(item, keys)]
        fields = [field for field in fields if field]
        if not fields:
            continue
        score = max((fuzzy_score(query, field) for field in fields), default=0)
        if score > best_score:
            best_score = score
            best_item = item

    if best_item is None or best_score < minimum_score:
        raise SystemExit(f"{label} not found for selector {selector!r}")
    return best_item, best_score


# Resolves one client selector against the fetched UniFi client inventory.
def resolve_client(selector: str, clients: list[dict[str, Any]]) -> dict[str, Any]:
    return resolve_single_match(
        selector,
        clients,
        keys=(
            "id",
            "name",
            "displayName",
            "clientName",
            "hostname",
            "hostName",
            "dhcpHostname",
            "mac",
            "macAddress",
            "ip",
            "ipAddress",
            "last_ip",
            "lastIp",
            "fixed_ip",
            "fixedIp",
        ),
        label="client",
        display=display_client,
    )


# Resolves one or more DPI application selectors against the application catalog.
def resolve_apps(selectors: list[str], applications: list[dict[str, Any]]) -> list[dict[str, Any]]:
    resolved: list[dict[str, Any]] = []
    seen_ids: set[str] = set()
    for selector in selectors:
        app = resolve_single_match(
            selector,
            applications,
            keys=("id", "name"),
            label="application",
            display=display_app,
        )
        app_id = normalized(app.get("id"))
        if app_id and app_id not in seen_ids:
            resolved.append(app)
            seen_ids.add(app_id)
    return resolved


# Resolves one or more DPI category selectors against the category catalog.
def resolve_categories(selectors: list[str], categories: list[dict[str, Any]]) -> list[dict[str, Any]]:
    resolved: list[dict[str, Any]] = []
    seen_ids: set[str] = set()
    for selector in selectors:
        category = resolve_single_match(
            selector,
            categories,
            keys=("id", "name"),
            label="application category",
            display=display_app,
        )
        category_id = normalized(category.get("id"))
        if category_id and category_id not in seen_ids:
            resolved.append(category)
            seen_ids.add(category_id)
    return resolved


# Parses weekly schedule day names into the ordered list expected by UniFi.
def parse_days(raw_days: str | None) -> list[str]:
    if raw_days is None:
        return []
    days = [normalized(part) for part in raw_days.split(",") if normalized(part)]
    invalid = [day for day in days if day not in DAY_NAMES]
    if invalid:
        raise SystemExit(
            f"invalid day names: {', '.join(invalid)}; expected subset of {', '.join(DAY_NAMES)}"
        )
    return days


# Parses a local ISO-8601 timestamp used in once-only schedules.
def parse_local_timestamp(value: str) -> datetime:
    try:
        return datetime.fromisoformat(value)
    except ValueError as exc:
        raise SystemExit(
            f"invalid timestamp {value!r}; expected ISO-8601 local form such as 2026-03-09T20:00"
        ) from exc


# Formats a datetime as the HH:MM value used by UniFi schedules.
def format_time(value: datetime) -> str:
    return value.strftime("%H:%M")


# Builds the schedule object for the requested block window.
def build_schedule(args: argparse.Namespace) -> dict[str, Any]:
    mode_map = {
        "always": "ALWAYS",
        "once": "ONE_TIME_ONLY",
        "daily": "EVERY_DAY",
        "weekly": "EVERY_WEEK",
        "custom": "CUSTOM",
    }
    schedule: dict[str, Any] = {"mode": mode_map[args.schedule_mode]}

    if args.schedule_mode == "always":
        return schedule

    if args.schedule_mode == "once":
        if not args.start or not args.end:
            raise SystemExit("--start and --end are required for --schedule-mode once")
        start = parse_local_timestamp(args.start)
        end = parse_local_timestamp(args.end)
        if start.date() != end.date():
            raise SystemExit("--start and --end must fall on the same date for --schedule-mode once")
        schedule["date"] = start.date().isoformat()
        schedule["time_range_start"] = format_time(start)
        schedule["time_range_end"] = format_time(end)
        return schedule

    if args.schedule_mode == "weekly":
        days = parse_days(args.days)
        if not days:
            raise SystemExit("--days is required for --schedule-mode weekly")
        schedule["repeat_on_days"] = [DAY_VALUES[day] for day in days]

    if args.schedule_mode == "custom":
        if not args.start or not args.end:
            raise SystemExit("--start and --end are required for --schedule-mode custom")
        start = parse_local_timestamp(args.start)
        end = parse_local_timestamp(args.end)
        if end.date() < start.date():
            raise SystemExit("--end must not be earlier than --start for --schedule-mode custom")
        schedule["date_start"] = start.date().isoformat()
        schedule["date_end"] = end.date().isoformat()
        if args.days:
            schedule["repeat_on_days"] = [DAY_VALUES[day] for day in parse_days(args.days)]
        if args.all_day:
            schedule["time_all_day"] = True
            return schedule
        schedule["time_range_start"] = args.start_time or format_time(start)
        schedule["time_range_end"] = args.end_time or format_time(end)
        return schedule

    if args.schedule_mode in {"daily", "weekly"} and args.all_day:
        if args.schedule_mode == "weekly":
            schedule["time_all_day"] = True
        else:
            raise SystemExit("--all-day is only supported for weekly/custom schedules")
        return schedule

    if not args.start_time or not args.end_time:
        raise SystemExit("--start-time and --end-time are required for daily/weekly schedules")

    schedule["time_range_start"] = args.start_time
    schedule["time_range_end"] = args.end_time

    return schedule


# Builds one normalized simple app-block payload for the firewall-app-blocks API.
def build_simple_app_block_payload(
    *,
    client: dict[str, Any],
    schedule: dict[str, Any],
    policy_name: str,
    target_type: str,
    ids: list[Any],
) -> dict[str, Any]:
    # Match the compact rule shape the UniFi Simple App Blocking collection API stores.
    client_mac = (
        canonical_mac(client.get("mac"))
        or canonical_mac(client.get("macAddress"))
        or canonical_mac(client.get("id"))
    )
    if not client_mac:
        raise SystemExit("could not resolve client MAC for app-block payload")
    payload: dict[str, Any] = {
        "name": policy_name,
        "type": "DEVICE",
        "target_type": target_type,
        "client_macs": [client_mac],
        "network_ids": [],
        "schedule": schedule,
    }
    if target_type == "APP_ID":
        payload["app_ids"] = ids
        payload["app_category_ids"] = []
    elif target_type == "APP_CATEGORY":
        payload["app_ids"] = []
        payload["app_category_ids"] = ids
    else:
        raise SystemExit(f"unsupported simple app block target_type: {target_type}")
    return payload


# Builds one or more simple app-block payloads from the resolved plan inputs.
def build_simple_app_block_payloads(
    *,
    client: dict[str, Any],
    resolved_apps: list[dict[str, Any]],
    resolved_categories: list[dict[str, Any]],
    schedule: dict[str, Any],
    policy_name: str,
) -> list[dict[str, Any]]:
    payloads: list[dict[str, Any]] = []
    app_ids = [app.get("id") for app in resolved_apps if app.get("id") is not None]
    category_ids = [category.get("id") for category in resolved_categories if category.get("id") is not None]

    if app_ids:
        payloads.append(
            build_simple_app_block_payload(
                client=client,
                schedule=schedule,
                policy_name=policy_name,
                target_type="APP_ID",
                ids=app_ids,
            )
        )
    if category_ids:
        category_name = f"{policy_name} (Categories)" if app_ids else policy_name
        payloads.append(
            build_simple_app_block_payload(
                client=client,
                schedule=schedule,
                policy_name=category_name,
                target_type="APP_CATEGORY",
                ids=category_ids,
            )
        )
    return payloads


# Builds the older trafficrules payload shape kept for comparison and debugging.
def build_legacy_private_api_payload(
    *,
    resolved_apps: list[dict[str, Any]],
    resolved_categories: list[dict[str, Any]],
) -> dict[str, Any]:
    rules: dict[str, Any] = {}
    index = 1

    for app in resolved_apps:
        app_name = str(app.get("name") or "").strip()
        if not app_name:
            continue
        rules[str(index)] = {
            "action": "drop",
            "application": app_name,
            "description": f"Block {app_name}",
        }
        index += 1

    for category in resolved_categories:
        category_id = str(category.get("id") or "").strip()
        category_name = str(category.get("name") or "").strip()
        if not category_id:
            continue
        rules[str(index)] = {
            "action": "drop",
            "application": {
                "category": category_id,
            },
            "description": f"Block {category_name or category_id}",
        }
        index += 1

    return {
        "service": {
            "dpi": {
                "disable": "false",
            },
            "firewall": {
                "name": {
                    "DPI_LOCAL": {
                        "default-action": "accept",
                        "description": "DPI Rules",
                        "rule": rules,
                    }
                }
            },
        }
    }


# Resolves the requested client, apps, and categories into a staged block plan.
def build_plan(args: argparse.Namespace) -> dict[str, Any]:
    if not args.apps and not args.categories:
        raise SystemExit("at least one --app or --category is required")

    clients_payload = load_clients_for_app_block(args)
    applications_payload = run_named_query(
        "dpi-applications",
        insecure=args.insecure,
    )
    categories_payload = run_named_query(
        "dpi-categories",
        insecure=args.insecure,
    )

    clients = rows(clients_payload) if not isinstance(clients_payload, list) else clients_payload
    applications = rows(applications_payload)
    categories = rows(categories_payload)

    client = resolve_client(args.client, clients)
    resolved_apps = resolve_apps(args.apps or [], applications)
    resolved_categories = resolve_categories(args.categories or [], categories)
    schedule = build_schedule(args)

    selected_labels = [display_app(app) for app in resolved_apps] + [
        display_app(category) for category in resolved_categories
    ]
    policy_name = args.policy_name or (
        f"Block {', '.join(selected_labels)} for {display_client(client)}"
    )
    client_mac = (
        canonical_mac(client.get("mac"))
        or canonical_mac(client.get("macAddress"))
        or canonical_mac(client.get("id"))
    )
    if not client_mac:
        raise SystemExit(f"could not resolve client MAC for {display_client(client)!r}")

    site_scope = args.site_id or args.site_ref or "resolved-by-controller"
    payloads = build_simple_app_block_payloads(
        client=client,
        resolved_apps=resolved_apps,
        resolved_categories=resolved_categories,
        schedule=schedule,
        policy_name=policy_name,
    )

    return {
        "kind": "unifi_app_block_plan",
        "policy_name": policy_name,
        "site_scope": site_scope,
        "resolved_client": {
            "id": client.get("id"),
            "name": client.get("name"),
            "hostname": client.get("hostname"),
            "mac": client_mac,
            "ip": client.get("ip"),
        },
        "resolved_applications": [
            {
                "id": app.get("id"),
                "name": app.get("name"),
            }
            for app in resolved_apps
        ],
        "resolved_categories": [
            {
                "id": category.get("id"),
                "name": category.get("name"),
            }
            for category in resolved_categories
        ],
        "schedule": schedule,
        "policy_intent": {
            "action": "BLOCK",
            "target_type": "CLIENT",
            "target_selector": {
                "client_id": client.get("id"),
                "mac": client_mac,
                "name": client.get("name"),
            },
            "application_ids": [app.get("id") for app in resolved_apps if app.get("id")],
            "application_names": [app.get("name") for app in resolved_apps if app.get("name")],
            "category_ids": [category.get("id") for category in resolved_categories if category.get("id")],
            "category_names": [category.get("name") for category in resolved_categories if category.get("name")],
            "schedule": schedule,
        },
        "api_notes": {
            "controller_docs_required": False,
            "confirmed_write_endpoint": SIMPLE_APP_BLOCK_PATH,
            "catalog_sources": [
                "/proxy/network/integration/v1/dpi/applications",
                "/proxy/network/integration/v1/dpi/categories",
            ],
            "confirmed_simple_app_block_shape": True,
            "confirmed_private_api": {
                "path_template": SIMPLE_APP_BLOCK_PATH,
                "create_method": "POST",
                "update_method": "PUT",
                "delete_method": "DELETE",
                "id_field": "_id",
                "bundle_source": "window.webpackChunkunifiNetworkUi module 410490",
            },
            "simple_app_block_notes": (
                "The live UniFi bundle exposes APP_ID and APP_CATEGORY target types for "
                "simple app blocking. When both specific apps and categories are requested, "
                "this helper emits two rules because the UI enum does not expose a combined type."
            ),
            "schedule_notes": (
                "Schedule fields come from the live bundle: mode, date, date_start, date_end, "
                "time_range_start, time_range_end, repeat_on_days, and time_all_day."
            ),
        },
        "simple_app_block_payloads": payloads,
        "legacy_private_api_payload_candidate": build_legacy_private_api_payload(
            resolved_apps=resolved_apps,
            resolved_categories=resolved_categories,
        ),
    }


# Returns the site reference used for simple app-block collection requests.
def resolve_site_ref(args: argparse.Namespace) -> str:
    if args.site_ref:
        return args.site_ref

    sites_payload = run_named_query("sites", insecure=args.insecure)
    sites = rows(sites_payload)

    if args.site_id:
        for site in sites:
            if normalized(site.get("id")) == normalized(args.site_id):
                site_ref = str(site.get("internalReference") or "").strip()
                if site_ref:
                    return site_ref
        raise SystemExit(f"could not resolve site reference for site ID {args.site_id!r}")

    if len(sites) == 1:
        site_ref = str(sites[0].get("internalReference") or "").strip()
        if site_ref:
            return site_ref

    raise SystemExit("simple app block requires --site-ref or a resolvable --site-id")


# Prints a filtered view of the DPI application catalog.
def command_list_apps(args: argparse.Namespace) -> int:
    payload = run_named_query("dpi-applications", insecure=args.insecure)
    applications = rows(payload)
    if args.search:
        query = normalized(args.search)
        applications = [
            item for item in applications
            if query in normalized(item.get("name")) or query in normalized(item.get("id"))
        ]

    applications = sorted(applications, key=lambda item: normalized(item.get("name")))
    for app in applications[: max(1, args.limit)]:
        name = str(app.get("name") or "").strip()
        app_id = str(app.get("id") or "").strip()
        print(f"{name}\t{app_id}")
    return 0


# Prints a resolved simple app-block plan without writing anything to UniFi.
def command_plan_block(args: argparse.Namespace) -> int:
    plan = build_plan(args)
    json.dump(plan, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


# Prints the single client row selected by the provided client query.
def command_resolve_client(args: argparse.Namespace) -> int:
    clients = load_clients_for_app_block(args)
    client, score = resolve_fuzzy_best(
        args.query,
        clients,
        keys=(
            "id",
            "name",
            "displayName",
            "clientName",
            "hostname",
            "hostName",
            "dhcpHostname",
            "mac",
            "macAddress",
            "ip",
            "ipAddress",
            "last_ip",
            "lastIp",
            "fixed_ip",
            "fixedIp",
        ),
        label="client",
    )
    output = {
        "kind": "unifi_client_resolution",
        "query": args.query,
        "score": score,
        "resolved_client": {
            "id": client.get("id") or client.get("_id") or client.get("clientId"),
            "name": client.get("name") or client.get("displayName") or client.get("hostname"),
            "hostname": client.get("hostname") or client.get("dhcpHostname"),
            "mac": client.get("mac") or client.get("macAddress"),
            "ip": client.get("ip") or client.get("ipAddress") or client.get("last_ip"),
        },
    }
    json.dump(output, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


# Prints the single DPI application selected by the provided query.
def command_resolve_app(args: argparse.Namespace) -> int:
    applications = rows(run_named_query("dpi-applications", insecure=args.insecure))
    app, score = resolve_fuzzy_best(
        args.query,
        applications,
        keys=("id", "name"),
        label="application",
    )
    output = {
        "kind": "unifi_dpi_application_resolution",
        "query": args.query,
        "score": score,
        "resolved_application": {
            "id": app.get("id"),
            "name": app.get("name"),
        },
    }
    json.dump(output, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


# Prints the single DPI category selected by the provided query.
def command_resolve_category(args: argparse.Namespace) -> int:
    categories = rows(run_named_query("dpi-categories", insecure=args.insecure))
    category, score = resolve_fuzzy_best(
        args.query,
        categories,
        keys=("id", "name"),
        label="category",
    )
    output = {
        "kind": "unifi_dpi_category_resolution",
        "query": args.query,
        "score": score,
        "resolved_category": {
            "id": category.get("id"),
            "name": category.get("name"),
        },
    }
    json.dump(output, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


# Prints a filtered view of the DPI category catalog.
def command_list_categories(args: argparse.Namespace) -> int:
    payload = run_named_query("dpi-categories", insecure=args.insecure)
    categories = rows(payload)
    if args.search:
        query = normalized(args.search)
        categories = [
            item for item in categories
            if query in normalized(item.get("name")) or query in normalized(item.get("id"))
        ]

    categories = sorted(categories, key=lambda item: normalized(item.get("name")))
    for category in categories[: max(1, args.limit)]:
        name = str(category.get("name") or "").strip()
        category_id = str(category.get("id") or "").strip()
        print(f"{name}\t{category_id}")
    return 0


# Merges planned blocks into the current simple app-block collection and posts the full replacement set to UniFi.
def command_apply_block(args: argparse.Namespace) -> int:
    plan = build_plan(args)
    payloads = list(plan["simple_app_block_payloads"])
    if args.rule_id and len(payloads) != 1:
        raise SystemExit("--rule-id can only be used when exactly one payload will be submitted")

    site_ref = resolve_site_ref(args)
    path = SIMPLE_APP_BLOCK_PATH.format(site_ref=site_ref)
    existing_rules = rows(run_unifi_request("GET", path, insecure=args.insecure))
    responses: list[dict[str, Any]] = []

    # UniFi saves Simple App Blocking by replacing the full collection in one POST,
    # so we merge each planned change into the fetched list before submitting it.
    for payload in payloads:
        if args.rule_id:
            replacement = dict(payload)
            replacement["_id"] = args.rule_id
            existing_rules = [
                replacement if str(rule.get("_id") or rule.get("id") or "").strip() == args.rule_id else rule
                for rule in existing_rules
            ]
            continue

        match = find_matching_rule(payload, existing_rules)
        if match:
            rule_id = str(match.get("_id") or match.get("id") or "").strip()
            if rule_id:
                merged = merge_rule(match, payload)
                existing_rules = [
                    merged if str(rule.get("_id") or rule.get("id") or "").strip() == rule_id else rule
                    for rule in existing_rules
                ]
                continue

        existing_rules.append(payload)

    response = run_unifi_request("POST", path, body=existing_rules, insecure=args.insecure)
    responses.append({"method": "POST", "path": path, "response": response})

    output = {
        "kind": "unifi_app_block_apply_result",
        "site_ref": site_ref,
        "submitted_payloads": payloads,
        "results": responses,
    }
    json.dump(output, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


# Normalizes an arbitrary value into a list of comparable strings.
def normalize_list(values: Any) -> list[str]:
    if not isinstance(values, list):
        return []
    return [str(item).strip().lower() for item in values if str(item).strip()]


# Builds a stable signature string for comparing UniFi schedule objects.
def schedule_signature(value: Any) -> str:
    if not isinstance(value, dict):
        return "{}"
    return json.dumps(value, sort_keys=True)


# Checks whether a stored rule belongs to the simple app-block collection.
def is_simple_app_rule(rule: dict[str, Any]) -> bool:
    target_type = str(rule.get("target_type") or rule.get("targetType") or "").strip().lower()
    return str(rule.get("type") or "").strip().lower() == "device" and target_type in {"app_id", "app_category"}


# Finds an existing simple app-block rule that targets the same client, target type, and schedule.
def find_matching_rule(payload: dict[str, Any], rules: list[dict[str, Any]]) -> dict[str, Any] | None:
    # Simple app blocks are matched by target kind, client, and schedule so app IDs
    # can be merged into an existing rule instead of creating duplicates.
    payload_target = str(payload.get("target_type") or "").strip().lower()
    payload_macs = set(normalize_mac_list(payload.get("client_macs")))
    payload_schedule = schedule_signature(payload.get("schedule"))
    for rule in rules:
        if not is_simple_app_rule(rule):
            continue
        rule_target = str(rule.get("target_type") or rule.get("targetType") or "").strip().lower()
        if rule_target != payload_target:
            continue
        if set(normalize_mac_list(rule.get("client_macs"))) != payload_macs:
            continue
        if schedule_signature(rule.get("schedule")) != payload_schedule:
            continue
        return rule
    return None


# Merges new app or category targets into an existing simple app-block rule.
def merge_rule(existing: dict[str, Any], incoming: dict[str, Any]) -> dict[str, Any]:
    # Preserve the existing rule identity while expanding its app/category target set.
    merged = dict(existing)
    for key in (
        "name",
        "type",
        "target_type",
        "client_macs",
        "network_ids",
        "schedule",
    ):
        if key in incoming:
            merged[key] = incoming[key]
    target = str(incoming.get("target_type") or "").strip().lower()
    if target == "app_id":
        merged["app_ids"] = sorted(set(normalize_list(existing.get("app_ids")) + normalize_list(incoming.get("app_ids"))))
        merged["app_category_ids"] = []
    elif target == "app_category":
        merged["app_category_ids"] = sorted(set(normalize_list(existing.get("app_category_ids")) + normalize_list(incoming.get("app_category_ids"))))
        merged["app_ids"] = []
    return merged


# Removes matching apps or categories from a client's simple app-block rules and writes the updated collection back to UniFi.
def command_remove_block(args: argparse.Namespace) -> int:
    site_ref = resolve_site_ref(args)
    clients = load_clients_for_app_block(args)
    client = resolve_client(args.client, clients)
    client_mac = canonical_mac(client.get("mac")) or canonical_mac(client.get("macAddress"))
    if not client_mac:
        raise SystemExit("could not resolve client MAC for removal")

    app_ids: set[str] = set()
    category_ids: set[str] = set()
    if args.apps:
        app_ids = {
            str(item.get("id") or "").strip().lower()
            for item in resolve_apps(args.apps, rows(run_named_query("dpi-applications", insecure=args.insecure)))
            if str(item.get("id") or "").strip()
        }
    if args.categories:
        category_ids = {
            str(item.get("id") or "").strip().lower()
            for item in resolve_categories(args.categories, rows(run_named_query("dpi-categories", insecure=args.insecure)))
            if str(item.get("id") or "").strip()
        }

    path = SIMPLE_APP_BLOCK_PATH.format(site_ref=site_ref)
    rules = rows(run_unifi_request("GET", path, insecure=args.insecure))
    deleted = 0
    updated = 0

    # Removals also use collection replacement: edit the local rule list, then POST
    # the resulting full set back to UniFi once.
    for rule in rules:
        if not is_simple_app_rule(rule):
            continue
        rule_id = str(rule.get("_id") or rule.get("id") or "").strip()
        if not rule_id:
            continue
        if client_mac not in set(normalize_mac_list(rule.get("client_macs"))):
            continue

        target = str(rule.get("target_type") or rule.get("targetType") or "").strip().lower()
        if not app_ids and not category_ids:
            rules = [item for item in rules if str(item.get("_id") or item.get("id") or "").strip() != rule_id]
            deleted += 1
            continue

        next_rule = dict(rule)
        if target == "app_id" and app_ids:
            kept = [v for v in normalize_list(rule.get("app_ids")) if v not in app_ids]
            if not kept:
                rules = [item for item in rules if str(item.get("_id") or item.get("id") or "").strip() != rule_id]
                deleted += 1
                continue
            next_rule["app_ids"] = kept
        elif target == "app_category" and category_ids:
            kept = [v for v in normalize_list(rule.get("app_category_ids")) if v not in category_ids]
            if not kept:
                rules = [item for item in rules if str(item.get("_id") or item.get("id") or "").strip() != rule_id]
                deleted += 1
                continue
            next_rule["app_category_ids"] = kept
        else:
            continue

        rules = [
            next_rule if str(item.get("_id") or item.get("id") or "").strip() == rule_id else item
            for item in rules
        ]
        updated += 1

    response = run_unifi_request("POST", path, body=rules, insecure=args.insecure)

    output = {
        "kind": "unifi_app_block_remove_result",
        "site_ref": site_ref,
        "resolved_client": {
            "name": client.get("name") or client.get("displayName") or client.get("hostname"),
            "mac": client.get("mac") or client.get("macAddress"),
            "ip": client.get("ip") or client.get("ipAddress"),
        },
        "rules_deleted": deleted,
        "rules_updated": updated,
        "response": response,
    }
    json.dump(output, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


# Prints the current simple app-block rules that target a resolved client.
def command_list_block(args: argparse.Namespace) -> int:
    site_ref = resolve_site_ref(args)
    clients = load_clients_for_app_block(args)
    client = resolve_client(args.client, clients)
    client_mac = canonical_mac(client.get("mac")) or canonical_mac(client.get("macAddress"))
    if not client_mac:
        raise SystemExit("could not resolve client MAC for listing")

    applications = rows(run_named_query("dpi-applications", insecure=args.insecure))
    categories = rows(run_named_query("dpi-categories", insecure=args.insecure))
    app_name_by_id = {
        normalized(item.get("id")): str(item.get("name") or "").strip()
        for item in applications
        if normalized(item.get("id")) and str(item.get("name") or "").strip()
    }
    category_name_by_id = {
        normalized(item.get("id")): str(item.get("name") or "").strip()
        for item in categories
        if normalized(item.get("id")) and str(item.get("name") or "").strip()
    }

    path = SIMPLE_APP_BLOCK_PATH.format(site_ref=site_ref)
    rules = rows(run_unifi_request("GET", path, insecure=args.insecure))

    matched_rules: list[dict[str, Any]] = []
    for rule in rules:
        if not is_simple_app_rule(rule):
            continue
        rule_macs = set(normalize_mac_list(rule.get("client_macs")))
        if client_mac not in rule_macs:
            continue
        target_type = str(rule.get("target_type") or rule.get("targetType") or "").strip().upper()
        app_ids = sorted(
            set(
                normalize_list(rule.get("app_ids"))
                + normalize_list(rule.get("appIds"))
            )
        )
        category_ids = sorted(
            set(
                normalize_list(rule.get("app_category_ids"))
                + normalize_list(rule.get("appCategoryIds"))
            )
        )
        matched_rules.append(
            {
                "rule_id": str(rule.get("_id") or rule.get("id") or "").strip(),
                "name": str(rule.get("name") or "").strip(),
                "target_type": target_type,
                "action": str(rule.get("action") or "").strip().upper() or "BLOCK",
                "schedule": rule.get("schedule") if isinstance(rule.get("schedule"), dict) else {},
                "app_ids": app_ids,
                "app_names": [app_name_by_id[item_id] for item_id in app_ids if item_id in app_name_by_id],
                "category_ids": category_ids,
                "category_names": [
                    category_name_by_id[item_id]
                    for item_id in category_ids
                    if item_id in category_name_by_id
                ],
            }
        )

    output = {
        "kind": "unifi_app_block_list_result",
        "site_ref": site_ref,
        "resolved_client": {
            "name": client.get("name") or client.get("displayName") or client.get("hostname"),
            "mac": client.get("mac") or client.get("macAddress"),
            "ip": client.get("ip") or client.get("ipAddress"),
        },
        "rule_count": len(matched_rules),
        "rules": matched_rules,
    }
    json.dump(output, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


# Dispatches the selected simple app-block subcommand.
def main() -> int:
    args = parse_args()
    if args.command == "resolve-client":
        return command_resolve_client(args)
    if args.command == "resolve-app":
        return command_resolve_app(args)
    if args.command == "resolve-category":
        return command_resolve_category(args)
    if args.command == "list-apps":
        return command_list_apps(args)
    if args.command == "list-categories":
        return command_list_categories(args)
    if args.command == "plan-block":
        return command_plan_block(args)
    if args.command == "apply-block":
        return command_apply_block(args)
    if args.command == "remove-block":
        return command_remove_block(args)
    if args.command == "list-block":
        return command_list_block(args)
    raise SystemExit(f"unknown command: {args.command}")


if __name__ == "__main__":
    raise SystemExit(main())

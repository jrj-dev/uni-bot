#!/usr/bin/env python3
"""Plan or apply UniFi simple app-block rules from clients, DPI apps, and schedules."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from datetime import datetime
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
SIMPLE_APP_BLOCK_PATH = "/proxy/network/v2/api/site/{site_ref}/trafficrules"


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

    plan = subparsers.add_parser(
        "plan-block",
        help="Resolve a client and list of apps/categories into a simple app-block plan.",
    )

    apply_block = subparsers.add_parser(
        "apply-block",
        help="Create one or more simple app-block rules through the private trafficrules API.",
    )

    for subparser in (plan, apply_block):
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

    apply_block.add_argument(
        "--rule-id",
        help="Existing rule ID to update instead of creating a new one. Only valid when producing one payload.",
    )

    return parser.parse_args()


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


def rows(payload: Any) -> list[dict[str, Any]]:
    if isinstance(payload, list):
        return [item for item in payload if isinstance(item, dict)]
    if isinstance(payload, dict):
        data = payload.get("data")
        if isinstance(data, list):
            return [item for item in data if isinstance(item, dict)]
        return [payload]
    return []


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


def normalized(value: Any) -> str:
    return str(value or "").strip().lower()


def candidate_fields(item: dict[str, Any], keys: tuple[str, ...]) -> list[str]:
    return [normalized(item.get(key)) for key in keys if normalized(item.get(key))]


def display_client(client: dict[str, Any]) -> str:
    for key in ("name", "hostname", "mac", "ip", "id"):
        value = str(client.get(key) or "").strip()
        if value:
            return value
    return "unknown-client"


def display_app(app: dict[str, Any]) -> str:
    for key in ("name", "id"):
        value = str(app.get(key) or "").strip()
        if value:
            return value
    return "unknown-app"


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


def resolve_client(selector: str, clients: list[dict[str, Any]]) -> dict[str, Any]:
    return resolve_single_match(
        selector,
        clients,
        keys=("id", "name", "hostname", "mac", "ip"),
        label="client",
        display=display_client,
    )


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


def parse_local_timestamp(value: str) -> datetime:
    try:
        return datetime.fromisoformat(value)
    except ValueError as exc:
        raise SystemExit(
            f"invalid timestamp {value!r}; expected ISO-8601 local form such as 2026-03-09T20:00"
        ) from exc


def format_time(value: datetime) -> str:
    return value.strftime("%H:%M")


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


def build_simple_app_block_payload(
    *,
    client: dict[str, Any],
    schedule: dict[str, Any],
    policy_name: str,
    target_type: str,
    ids: list[Any],
) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "name": policy_name,
        "type": "DEVICE",
        "target_type": target_type,
        "client_macs": [client.get("mac") or client.get("id")],
        "network_ids": [],
        "schedule": schedule,
        "source_devices": [],
        "source_networks": [],
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


def build_plan(args: argparse.Namespace) -> dict[str, Any]:
    if not args.apps and not args.categories:
        raise SystemExit("at least one --app or --category is required")

    clients_payload = run_named_query(
        "clients",
        site_id=args.site_id,
        site_ref=args.site_ref,
        insecure=args.insecure,
        all_pages=True,
    )
    applications_payload = run_named_query(
        "dpi-applications",
        insecure=args.insecure,
    )
    categories_payload = run_named_query(
        "dpi-categories",
        insecure=args.insecure,
    )

    clients = rows(clients_payload)
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
            "mac": client.get("mac"),
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
                "mac": client.get("mac"),
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


def command_plan_block(args: argparse.Namespace) -> int:
    plan = build_plan(args)
    json.dump(plan, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


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


def command_apply_block(args: argparse.Namespace) -> int:
    plan = build_plan(args)
    payloads = list(plan["simple_app_block_payloads"])
    if args.rule_id and len(payloads) != 1:
        raise SystemExit("--rule-id can only be used when exactly one payload will be submitted")

    site_ref = resolve_site_ref(args)
    path = SIMPLE_APP_BLOCK_PATH.format(site_ref=site_ref)
    responses: list[dict[str, Any]] = []

    for payload in payloads:
        if args.rule_id:
            payload = dict(payload)
            payload["_id"] = args.rule_id
            response = run_unifi_request(
                "PUT",
                f"{path}/{args.rule_id}",
                body=payload,
                insecure=args.insecure,
            )
            responses.append({"method": "PUT", "path": f"{path}/{args.rule_id}", "response": response})
            continue

        response = run_unifi_request("POST", path, body=payload, insecure=args.insecure)
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


def main() -> int:
    args = parse_args()
    if args.command == "list-apps":
        return command_list_apps(args)
    if args.command == "list-categories":
        return command_list_categories(args)
    if args.command == "plan-block":
        return command_plan_block(args)
    if args.command == "apply-block":
        return command_apply_block(args)
    raise SystemExit(f"unknown command: {args.command}")


if __name__ == "__main__":
    raise SystemExit(main())

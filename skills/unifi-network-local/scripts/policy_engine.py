#!/usr/bin/env python3
"""Read-only helpers for UniFi's newer Policy Engine rule model."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from collections import Counter
from typing import Any

from _paths import SCRIPT_DIR


NAMED_QUERY_SCRIPT = SCRIPT_DIR / "named_query.py"
REQUEST_SCRIPT = SCRIPT_DIR / "unifi_request.py"
GROUP_COLLECTION_PATH = "/proxy/network/v2/api/site/{site_ref}/network-members-groups"
GROUP_ITEM_PATH = "/proxy/network/v2/api/site/{site_ref}/network-members-group"
OBJECT_COLLECTION_PATH = "/proxy/network/v2/api/site/{site_ref}/object-oriented-network-configs"
OBJECT_ITEM_PATH = "/proxy/network/v2/api/site/{site_ref}/object-oriented-network-config"
CLIENTS_QUERY = "clients-all"


class RequestResult:
    # Stores the raw subprocess result for one UniFi API helper call.
    def __init__(self, returncode: int, stdout: str, stderr: str) -> None:
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr


# Parses CLI arguments for Policy Engine inspection commands.
def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Inspect UniFi's newer Policy Engine traffic-rule collection while it "
            "coexists with the older firewall-app-blocks API."
        )
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    list_rules = subparsers.add_parser(
        "list-rules",
        help="List Policy Engine traffic rules from /trafficrules.",
    )
    list_rules.add_argument(
        "--limit",
        type=int,
        default=50,
        help="Maximum rules to print. Default: 50.",
    )

    summarize_rules = subparsers.add_parser(
        "summarize-rules",
        help="Print a compact summary of the current Policy Engine traffic-rule collection.",
    )
    summarize_rules.add_argument(
        "--limit",
        type=int,
        default=10,
        help="Maximum top groupings to print. Default: 10.",
    )

    compare_paths = subparsers.add_parser(
        "compare-paths",
        help="Compare Policy Engine trafficrules with the older firewall-app-blocks collection.",
    )
    compare_paths.add_argument(
        "--limit",
        type=int,
        default=10,
        help="Maximum example entries to print from each path. Default: 10.",
    )

    list_groups = subparsers.add_parser(
        "list-groups",
        help="List Policy Engine client groups from /network-members-groups.",
    )
    list_groups.add_argument(
        "--limit",
        type=int,
        default=50,
        help="Maximum groups to print. Default: 50.",
    )

    create_group = subparsers.add_parser(
        "create-group",
        help="Create a Policy Engine client group. Dry-run by default.",
    )
    create_group.add_argument("--name", required=True, help="Group name.")
    create_group.add_argument(
        "--member-mac",
        action="append",
        default=[],
        help="Client MAC to include. Repeat as needed.",
    )
    create_group.add_argument(
        "--apply",
        action="store_true",
        help="Execute the write. Without this flag, command is dry-run.",
    )

    update_group = subparsers.add_parser(
        "update-group",
        help="Update a Policy Engine client group. Dry-run by default.",
    )
    update_group.add_argument("--group-id", required=True, help="Existing group ID.")
    update_group.add_argument("--name", required=True, help="Updated group name.")
    update_group.add_argument(
        "--member-mac",
        action="append",
        default=[],
        help="Client MAC to include. Repeat as needed.",
    )
    update_group.add_argument(
        "--apply",
        action="store_true",
        help="Execute the write. Without this flag, command is dry-run.",
    )

    delete_group = subparsers.add_parser(
        "delete-group",
        help="Delete a Policy Engine client group. Dry-run by default.",
    )
    delete_group.add_argument("--group-id", required=True, help="Existing group ID.")
    delete_group.add_argument(
        "--apply",
        action="store_true",
        help="Execute the delete. Without this flag, command is dry-run.",
    )

    list_objects = subparsers.add_parser(
        "list-objects",
        help="List Object Manager objects from /object-oriented-network-configs.",
    )
    list_objects.add_argument(
        "--limit",
        type=int,
        default=50,
        help="Maximum objects to print. Default: 50.",
    )

    create_object = subparsers.add_parser(
        "create-object",
        help="Create an Object Manager object from raw JSON. Dry-run by default.",
    )
    create_object.add_argument(
        "--json",
        dest="json_body",
        required=True,
        help="Normalized object payload JSON for /object-oriented-network-config.",
    )
    create_object.add_argument(
        "--apply",
        action="store_true",
        help="Execute the write. Without this flag, command is dry-run.",
    )

    update_object = subparsers.add_parser(
        "update-object",
        help="Update an Object Manager object from raw JSON. Dry-run by default.",
    )
    update_object.add_argument("--object-id", required=True, help="Existing object ID.")
    update_object.add_argument(
        "--json",
        dest="json_body",
        required=True,
        help="Normalized object payload JSON for /object-oriented-network-config/{id}.",
    )
    update_object.add_argument(
        "--apply",
        action="store_true",
        help="Execute the write. Without this flag, command is dry-run.",
    )

    delete_object = subparsers.add_parser(
        "delete-object",
        help="Delete an Object Manager object. Dry-run by default.",
    )
    delete_object.add_argument("--object-id", required=True, help="Existing object ID.")
    delete_object.add_argument(
        "--apply",
        action="store_true",
        help="Execute the delete. Without this flag, command is dry-run.",
    )

    create_secure_blocklist_object = subparsers.add_parser(
        "create-secure-blocklist-object",
        help="Create a Secure internet blocklist object using the live captured Object Manager shape. Dry-run by default.",
    )
    create_secure_blocklist_object.add_argument("--name", required=True, help="Object name.")
    create_secure_blocklist_object.add_argument(
        "--target-type",
        choices=("CLIENTS", "GROUPS", "NETWORKS"),
        required=True,
        help="Object target type.",
    )
    create_secure_blocklist_object.add_argument(
        "--target-id",
        action="append",
        default=[],
        required=True,
        help="Target ID or MAC. Repeat as needed.",
    )
    create_secure_blocklist_object.add_argument(
        "--apply",
        action="store_true",
        help="Execute the write. Without this flag, command is dry-run.",
    )

    create_quarantine_object = subparsers.add_parser(
        "create-quarantine-object",
        help="Create a Secure local quarantine object using the live captured Object Manager shape. Dry-run by default.",
    )
    create_quarantine_object.add_argument("--name", required=True, help="Object name.")
    create_quarantine_object.add_argument(
        "--target-type",
        choices=("CLIENTS", "GROUPS", "NETWORKS"),
        required=True,
        help="Object target type.",
    )
    create_quarantine_object.add_argument(
        "--target-id",
        action="append",
        default=[],
        required=True,
        help="Target ID or MAC. Repeat as needed.",
    )
    create_quarantine_object.add_argument(
        "--apply",
        action="store_true",
        help="Execute the write. Without this flag, command is dry-run.",
    )

    create_allowlist_object = subparsers.add_parser(
        "create-secure-allowlist-object",
        help="Create a Secure internet allowlist object using the live captured Object Manager shape. Dry-run by default.",
    )
    create_allowlist_object.add_argument("--name", required=True, help="Object name.")
    create_allowlist_object.add_argument(
        "--target-type",
        choices=("CLIENTS", "GROUPS", "NETWORKS"),
        required=True,
        help="Object target type.",
    )
    create_allowlist_object.add_argument(
        "--target-id",
        action="append",
        default=[],
        required=True,
        help="Target ID or MAC. Repeat as needed.",
    )
    create_allowlist_object.add_argument(
        "--apply",
        action="store_true",
        help="Execute the write. Without this flag, command is dry-run.",
    )

    create_no_internet_object = subparsers.add_parser(
        "create-no-internet-object",
        help="Create a Secure no-internet object using the live captured Object Manager shape. Dry-run by default.",
    )
    create_no_internet_object.add_argument("--name", required=True, help="Object name.")
    create_no_internet_object.add_argument(
        "--target-type",
        choices=("CLIENTS", "GROUPS", "NETWORKS"),
        required=True,
        help="Object target type.",
    )
    create_no_internet_object.add_argument(
        "--target-id",
        action="append",
        default=[],
        required=True,
        help="Target ID or MAC. Repeat as needed.",
    )
    create_no_internet_object.add_argument(
        "--apply",
        action="store_true",
        help="Execute the write. Without this flag, command is dry-run.",
    )

    create_route_object = subparsers.add_parser(
        "create-route-object",
        help="Create a Route object using the live captured Object Manager shape. Dry-run by default.",
    )
    create_route_object.add_argument("--name", required=True, help="Object name.")
    create_route_object.add_argument(
        "--target-type",
        choices=("CLIENTS", "GROUPS", "NETWORKS"),
        required=True,
        help="Object target type.",
    )
    create_route_object.add_argument(
        "--target-id",
        action="append",
        default=[],
        required=True,
        help="Target ID or MAC. Repeat as needed.",
    )
    create_route_object.add_argument(
        "--network-id",
        required=True,
        help="WAN profile or VPN network ID to route through.",
    )
    create_route_object.add_argument(
        "--apply",
        action="store_true",
        help="Execute the write. Without this flag, command is dry-run.",
    )

    create_route_domain_object = subparsers.add_parser(
        "create-route-domain-object",
        help="Create a Route domain-selector object using the live captured Object Manager shape. Dry-run by default.",
    )
    create_route_domain_object.add_argument("--name", required=True, help="Object name.")
    create_route_domain_object.add_argument(
        "--target-type",
        choices=("CLIENTS", "GROUPS", "NETWORKS"),
        required=True,
        help="Object target type.",
    )
    create_route_domain_object.add_argument(
        "--target-id",
        action="append",
        default=[],
        required=True,
        help="Target ID or MAC. Repeat as needed.",
    )
    create_route_domain_object.add_argument(
        "--network-id",
        default="5b4549d03961821e8f96f5f8",
        help="WAN profile or VPN network ID used by the captured Route selector object.",
    )
    create_route_domain_object.add_argument(
        "--domain",
        action="append",
        default=[],
        required=True,
        help="Domain to route. Repeat as needed.",
    )
    create_route_domain_object.add_argument(
        "--apply",
        action="store_true",
        help="Execute the write. Without this flag, command is dry-run.",
    )

    create_route_ip_object = subparsers.add_parser(
        "create-route-ip-object",
        help="Create a Route IP-selector object using the live captured Object Manager shape. Dry-run by default.",
    )
    create_route_ip_object.add_argument("--name", required=True, help="Object name.")
    create_route_ip_object.add_argument(
        "--target-type",
        choices=("CLIENTS", "GROUPS", "NETWORKS"),
        required=True,
        help="Object target type.",
    )
    create_route_ip_object.add_argument(
        "--target-id",
        action="append",
        default=[],
        required=True,
        help="Target ID or MAC. Repeat as needed.",
    )
    create_route_ip_object.add_argument(
        "--network-id",
        default="5b4549d03961821e8f96f5f8",
        help="WAN profile or VPN network ID used by the captured Route selector object.",
    )
    create_route_ip_object.add_argument(
        "--ip-address",
        action="append",
        default=[],
        required=True,
        help="IP address to route. Repeat as needed.",
    )
    create_route_ip_object.add_argument(
        "--apply",
        action="store_true",
        help="Execute the write. Without this flag, command is dry-run.",
    )

    create_qos_object = subparsers.add_parser(
        "create-qos-object",
        help="Create a QoS object using the live captured Object Manager shape. Dry-run by default.",
    )
    create_qos_object.add_argument("--name", required=True, help="Object name.")
    create_qos_object.add_argument(
        "--target-type",
        choices=("CLIENTS", "GROUPS", "NETWORKS"),
        required=True,
        help="Object target type.",
    )
    create_qos_object.add_argument(
        "--target-id",
        action="append",
        default=[],
        required=True,
        help="Target ID or MAC. Repeat as needed.",
    )
    create_qos_object.add_argument(
        "--apply",
        action="store_true",
        help="Execute the write. Without this flag, command is dry-run.",
    )

    create_qos_prioritize_object = subparsers.add_parser(
        "create-qos-prioritize-object",
        help="Create a QoS prioritize object using the live captured Object Manager shape. Dry-run by default.",
    )
    create_qos_prioritize_object.add_argument("--name", required=True, help="Object name.")
    create_qos_prioritize_object.add_argument(
        "--target-type",
        choices=("CLIENTS", "GROUPS", "NETWORKS"),
        required=True,
        help="Object target type.",
    )
    create_qos_prioritize_object.add_argument(
        "--target-id",
        action="append",
        default=[],
        required=True,
        help="Target ID or MAC. Repeat as needed.",
    )
    create_qos_prioritize_object.add_argument(
        "--apply",
        action="store_true",
        help="Execute the write. Without this flag, command is dry-run.",
    )

    create_qos_limits_object = subparsers.add_parser(
        "create-qos-limits-object",
        help="Create a QoS object with download/upload limits using the live captured Object Manager shape. Dry-run by default.",
    )
    create_qos_limits_object.add_argument("--name", required=True, help="Object name.")
    create_qos_limits_object.add_argument(
        "--target-type",
        choices=("CLIENTS", "GROUPS", "NETWORKS"),
        required=True,
        help="Object target type.",
    )
    create_qos_limits_object.add_argument(
        "--target-id",
        action="append",
        default=[],
        required=True,
        help="Target ID or MAC. Repeat as needed.",
    )
    create_qos_limits_object.add_argument(
        "--network-id",
        required=True,
        help="WAN profile or VPN network ID used by the saved QoS object.",
    )
    create_qos_limits_object.add_argument(
        "--download-limit",
        type=int,
        default=10000,
        help="Download limit value captured in the saved QoS object. Default: 10000.",
    )
    create_qos_limits_object.add_argument(
        "--upload-limit",
        type=int,
        default=10000,
        help="Upload limit value captured in the saved QoS object. Default: 10000.",
    )
    create_qos_limits_object.add_argument(
        "--apply",
        action="store_true",
        help="Execute the write. Without this flag, command is dry-run.",
    )

    create_qos_prioritize_limits_object = subparsers.add_parser(
        "create-qos-prioritize-limits-object",
        help="Create a QoS prioritize-and-limit object using the live captured Object Manager shape. Dry-run by default.",
    )
    create_qos_prioritize_limits_object.add_argument("--name", required=True, help="Object name.")
    create_qos_prioritize_limits_object.add_argument(
        "--target-type",
        choices=("CLIENTS", "GROUPS", "NETWORKS"),
        required=True,
        help="Object target type.",
    )
    create_qos_prioritize_limits_object.add_argument(
        "--target-id",
        action="append",
        default=[],
        required=True,
        help="Target ID or MAC. Repeat as needed.",
    )
    create_qos_prioritize_limits_object.add_argument(
        "--download-limit",
        type=int,
        default=10000,
        help="Download limit value captured in the saved QoS prioritize-and-limit object. Default: 10000.",
    )
    create_qos_prioritize_limits_object.add_argument(
        "--upload-limit",
        type=int,
        default=10000,
        help="Upload limit value captured in the saved QoS prioritize-and-limit object. Default: 10000.",
    )
    create_qos_prioritize_limits_object.add_argument(
        "--apply",
        action="store_true",
        help="Execute the write. Without this flag, command is dry-run.",
    )

    create_secure_domain_blocklist_object = subparsers.add_parser(
        "create-secure-domain-blocklist-object",
        help="Create a Secure domain blocklist object using the live captured Object Manager shape. Dry-run by default.",
    )
    create_secure_domain_blocklist_object.add_argument("--name", required=True, help="Object name.")
    create_secure_domain_blocklist_object.add_argument(
        "--target-type",
        choices=("CLIENTS", "GROUPS", "NETWORKS"),
        required=True,
        help="Object target type.",
    )
    create_secure_domain_blocklist_object.add_argument(
        "--target-id",
        action="append",
        default=[],
        required=True,
        help="Target ID or MAC. Repeat as needed.",
    )
    create_secure_domain_blocklist_object.add_argument(
        "--domain",
        action="append",
        default=[],
        required=True,
        help="Domain to block. Repeat as needed.",
    )
    create_secure_domain_blocklist_object.add_argument(
        "--apply",
        action="store_true",
        help="Execute the write. Without this flag, command is dry-run.",
    )

    create_secure_app_blocklist_object = subparsers.add_parser(
        "create-secure-app-blocklist-object",
        help="Create a Secure app blocklist object using the live captured Object Manager shape. Dry-run by default.",
    )
    create_secure_app_blocklist_object.add_argument("--name", required=True, help="Object name.")
    create_secure_app_blocklist_object.add_argument(
        "--target-type",
        choices=("CLIENTS", "GROUPS", "NETWORKS"),
        required=True,
        help="Object target type.",
    )
    create_secure_app_blocklist_object.add_argument(
        "--target-id",
        action="append",
        default=[],
        required=True,
        help="Target ID or MAC. Repeat as needed.",
    )
    create_secure_app_blocklist_object.add_argument(
        "--app-id",
        action="append",
        default=[],
        required=True,
        type=int,
        help="DPI application ID to block. Repeat as needed.",
    )
    create_secure_app_blocklist_object.add_argument(
        "--apply",
        action="store_true",
        help="Execute the write. Without this flag, command is dry-run.",
    )

    create_secure_ip_blocklist_object = subparsers.add_parser(
        "create-secure-ip-blocklist-object",
        help="Create a Secure IP-address blocklist object using the live captured Object Manager shape. Dry-run by default.",
    )
    create_secure_ip_blocklist_object.add_argument("--name", required=True, help="Object name.")
    create_secure_ip_blocklist_object.add_argument(
        "--target-type",
        choices=("CLIENTS", "GROUPS", "NETWORKS"),
        required=True,
        help="Object target type.",
    )
    create_secure_ip_blocklist_object.add_argument(
        "--target-id",
        action="append",
        default=[],
        required=True,
        help="Target ID or MAC. Repeat as needed.",
    )
    create_secure_ip_blocklist_object.add_argument(
        "--ip-address",
        action="append",
        default=[],
        required=True,
        help="IP address to block. Repeat as needed.",
    )
    create_secure_ip_blocklist_object.add_argument(
        "--apply",
        action="store_true",
        help="Execute the write. Without this flag, command is dry-run.",
    )

    for subparser in (
        list_rules,
        summarize_rules,
        compare_paths,
        list_groups,
        create_group,
        update_group,
        delete_group,
        list_objects,
        create_object,
        update_object,
        delete_object,
        create_secure_blocklist_object,
        create_quarantine_object,
        create_allowlist_object,
        create_no_internet_object,
        create_route_object,
        create_route_domain_object,
        create_route_ip_object,
        create_qos_object,
        create_qos_prioritize_object,
        create_qos_limits_object,
        create_qos_prioritize_limits_object,
        create_secure_domain_blocklist_object,
        create_secure_app_blocklist_object,
        create_secure_ip_blocklist_object,
    ):
        subparser.add_argument(
            "--site-ref",
            default="default",
            help="Site internal reference. Default: default.",
        )
        subparser.add_argument(
            "--insecure",
            action="store_true",
            help="Pass through for self-signed TLS certificates.",
        )

    return parser.parse_args()


# Loads one named query through the shared authenticated UniFi wrapper.
def load_named_query(query: str, *, site_ref: str, insecure: bool) -> dict[str, Any]:
    cmd = [sys.executable, str(NAMED_QUERY_SCRIPT), query, "--site-ref", site_ref]
    if insecure:
        cmd.append("--insecure")
    result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        if result.stderr:
            sys.stderr.write(result.stderr)
        raise SystemExit(result.returncode)
    return json.loads(result.stdout)


# Runs one raw UniFi request through the shared request helper.
def run_request(
    method: str,
    path: str,
    *,
    body: dict[str, Any] | None = None,
    insecure: bool,
) -> RequestResult:
    cmd = [sys.executable, str(REQUEST_SCRIPT), method, path]
    if body is not None:
        cmd.extend(["--json", json.dumps(body, separators=(",", ":"))])
    if insecure:
        cmd.append("--insecure")
    if method.upper() not in {"GET", "HEAD", "OPTIONS"}:
        cmd.append("--allow-write")
    result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    return RequestResult(result.returncode, result.stdout, result.stderr)


# Extracts row dictionaries from the standard response envelope or raw list shape.
def rows(payload: dict[str, Any] | list[Any]) -> list[dict[str, Any]]:
    if isinstance(payload, list):
        return [item for item in payload if isinstance(item, dict)]
    data = payload.get("data", [])
    if isinstance(data, list):
        return [item for item in data if isinstance(item, dict)]
    return []


# Returns the best display label available for a Policy Engine rule.
def rule_label(rule: dict[str, Any]) -> str:
    label = rule.get("name") or rule.get("description") or rule.get("_id") or rule.get("id")
    return str(label or "unnamed-rule")


# Returns a stable string identifier for a rule row.
def rule_id(rule: dict[str, Any]) -> str:
    return str(rule.get("_id") or rule.get("id") or "unknown")


# Returns the best available matching target label for a traffic rule.
def matching_target(rule: dict[str, Any]) -> str:
    value = rule.get("matching_target") or rule.get("matchingTarget") or rule.get("target_type")
    return str(value or "UNKNOWN")


# Returns the best available schedule mode label for a traffic rule.
def schedule_mode(rule: dict[str, Any]) -> str:
    schedule = rule.get("schedule")
    if isinstance(schedule, dict):
        return str(schedule.get("mode") or "CUSTOM")
    return "UNKNOWN"


# Returns the list of target device descriptors from a traffic rule.
def target_devices(rule: dict[str, Any]) -> list[dict[str, Any]]:
    items = rule.get("target_devices") or rule.get("targetDevices") or []
    if isinstance(items, list):
        return [item for item in items if isinstance(item, dict)]
    return []


# Returns a short category for the rule's target device scope.
def target_scope(rule: dict[str, Any]) -> str:
    devices = target_devices(rule)
    if not devices:
        return "UNKNOWN"
    types = {str(item.get("type") or "UNKNOWN") for item in devices}
    return ",".join(sorted(types))


# Returns which high-level Policy Engine property families appear enabled on a rule.
def property_families(rule: dict[str, Any]) -> list[str]:
    families: list[str] = []
    for key in ("secure", "route", "qos"):
        value = rule.get(key)
        if isinstance(value, dict):
            if value.get("enabled") is False:
                continue
            families.append(key)
    return families


# Returns a normalized client-group label for display.
def group_label(group: dict[str, Any]) -> str:
    return str(group.get("name") or group.get("id") or "unnamed-group")


# Returns a normalized client-group identifier.
def group_id(group: dict[str, Any]) -> str:
    return str(group.get("id") or group.get("_id") or "unknown")


# Returns the normalized list of member MACs from a client group row.
def group_members(group: dict[str, Any]) -> list[str]:
    members = group.get("members") or []
    if not isinstance(members, list):
        return []
    return [str(member) for member in members if isinstance(member, str) and member]


# Returns a stable create/update payload for Policy Engine client groups.
def build_group_payload(*, name: str, member_macs: list[str], group_id_value: str | None = None) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "name": name,
        "members": member_macs,
        "type": "CLIENTS",
    }
    if group_id_value:
        payload["id"] = group_id_value
    return payload


# Parses a JSON object payload for raw Object Manager CRUD commands.
def parse_json_object(json_body: str) -> dict[str, Any]:
    parsed = json.loads(json_body)
    if not isinstance(parsed, dict):
        raise SystemExit("expected JSON object payload")
    return parsed


# Returns the disabled Route block captured from the live Object Manager UI.
def default_disabled_route() -> dict[str, Any]:
    return {
        "enabled": False,
        "apps": {"enabled": False, "values": []},
        "domains": {"enabled": False, "values": []},
        "ip_addresses": {"enabled": False, "values": []},
        "regions": {"enabled": False, "values": []},
    }


# Returns the disabled QoS block captured from the live Object Manager UI.
def default_disabled_qos() -> dict[str, Any]:
    return {
        "enabled": False,
        "all_traffic": True,
        "apps": {"enabled": False, "values": []},
        "domains": {"enabled": False, "values": []},
        "ip_addresses": {"enabled": False, "values": []},
        "regions": {"enabled": False, "values": []},
        "mode": "LIMIT",
        "download_limit": {"enabled": False, "limit": 10000, "burst": "DISABLED"},
        "upload_limit": {"enabled": False, "limit": 10000, "burst": "DISABLED"},
    }


# Builds the first narrow convenience payload confirmed from the live Object Manager UI.
def build_secure_blocklist_object(
    *,
    name: str,
    target_type: str,
    target_ids: list[str],
) -> dict[str, Any]:
    return {
        "enabled": True,
        "name": name,
        "target_type": target_type,
        "targets": target_ids,
        "secure": {
            "enabled": True,
            "internet": {
                "mode": "BLOCKLIST",
                "everything": True,
                "apps": {"enabled": False, "values": []},
                "domains": {"enabled": False, "values": []},
                "ip_addresses": {"enabled": False, "values": []},
                "regions": {"enabled": False, "values": []},
                "schedule": {"mode": "ALWAYS"},
            },
        },
        "route": default_disabled_route(),
        "qos": default_disabled_qos(),
    }


# Builds the captured Secure internet allowlist object shape.
def build_secure_allowlist_object(
    *,
    name: str,
    target_type: str,
    target_ids: list[str],
) -> dict[str, Any]:
    payload = build_secure_blocklist_object(
        name=name,
        target_type=target_type,
        target_ids=target_ids,
    )
    payload["secure"]["internet"]["mode"] = "ALLOWLIST"
    return payload


# Builds the captured Secure local quarantine object shape.
def build_quarantine_object(
    *,
    name: str,
    target_type: str,
    target_ids: list[str],
) -> dict[str, Any]:
    payload = build_secure_blocklist_object(
        name=name,
        target_type=target_type,
        target_ids=target_ids,
    )
    payload["secure"]["local"] = {"mode": "QUARANTINE"}
    return payload


# Builds the captured Secure no-internet object shape.
def build_no_internet_object(
    *,
    name: str,
    target_type: str,
    target_ids: list[str],
) -> dict[str, Any]:
    return {
        "enabled": True,
        "name": name,
        "target_type": target_type,
        "targets": target_ids,
        "secure": {
            "enabled": True,
            "internet": {
                "mode": "TURN_OFF_INTERNET",
                "schedule": {"mode": "ALWAYS"},
            },
        },
        "route": default_disabled_route(),
        "qos": default_disabled_qos(),
    }


# Builds the captured Route object shape.
def build_route_object(
    *,
    name: str,
    target_type: str,
    target_ids: list[str],
    network_id: str,
) -> dict[str, Any]:
    return {
        "enabled": True,
        "name": name,
        "target_type": target_type,
        "targets": target_ids,
        "secure": {
            "enabled": False,
            "internet": {
                "mode": "BLOCKLIST",
                "everything": True,
            },
        },
        "route": {
            "enabled": True,
            "all_traffic": True,
            "apps": {"enabled": False, "values": []},
            "domains": {"enabled": False, "values": []},
            "ip_addresses": {"enabled": False, "values": []},
            "kill_switch": True,
            "network_id": network_id,
            "regions": {"enabled": False, "values": []},
        },
        "qos": default_disabled_qos(),
    }


# Builds the captured Route domain-selector object shape.
def build_route_domain_object(
    *,
    name: str,
    target_type: str,
    target_ids: list[str],
    network_id: str,
    domains: list[str],
) -> dict[str, Any]:
    payload = build_route_object(
        name=name,
        target_type=target_type,
        target_ids=target_ids,
        network_id=network_id,
    )
    payload["route"]["all_traffic"] = False
    payload["route"]["domains"] = {
        "enabled": True,
        "values": domains,
    }
    return payload


# Builds the captured Route IP-selector object shape.
def build_route_ip_object(
    *,
    name: str,
    target_type: str,
    target_ids: list[str],
    network_id: str,
    ip_addresses: list[str],
) -> dict[str, Any]:
    payload = build_route_object(
        name=name,
        target_type=target_type,
        target_ids=target_ids,
        network_id=network_id,
    )
    payload["route"]["all_traffic"] = False
    payload["route"]["ip_addresses"] = {
        "enabled": True,
        "values": ip_addresses,
    }
    return payload


# Builds the captured QoS object shape.
def build_qos_object(
    *,
    name: str,
    target_type: str,
    target_ids: list[str],
) -> dict[str, Any]:
    return {
        "enabled": True,
        "name": name,
        "target_type": target_type,
        "targets": target_ids,
        "secure": {
            "enabled": False,
            "internet": {
                "mode": "BLOCKLIST",
                "everything": True,
            },
        },
        "route": default_disabled_route(),
        "qos": {
            "enabled": True,
            "all_traffic": True,
            "apps": {"enabled": False, "values": []},
            "domains": {"enabled": False, "values": []},
            "ip_addresses": {"enabled": False, "values": []},
            "regions": {"enabled": False, "values": []},
            "mode": "LIMIT",
            "download_limit": {"enabled": False, "limit": 10000, "burst": "DISABLED"},
            "upload_limit": {"enabled": False, "limit": 10000, "burst": "DISABLED"},
            "schedule": {"mode": "ALWAYS"},
        },
    }


# Builds the captured QoS prioritize object shape.
def build_qos_prioritize_object(
    *,
    name: str,
    target_type: str,
    target_ids: list[str],
) -> dict[str, Any]:
    payload = build_qos_object(
        name=name,
        target_type=target_type,
        target_ids=target_ids,
    )
    payload["qos"]["mode"] = "PRIORITIZE"
    return payload


# Builds the captured QoS object shape with enabled download and upload limits.
def build_qos_limits_object(
    *,
    name: str,
    target_type: str,
    target_ids: list[str],
    network_id: str,
    download_limit: int,
    upload_limit: int,
) -> dict[str, Any]:
    payload = build_qos_object(
        name=name,
        target_type=target_type,
        target_ids=target_ids,
    )
    payload["qos"]["network_id"] = network_id
    payload["qos"]["download_limit"]["enabled"] = True
    payload["qos"]["download_limit"]["limit"] = download_limit
    payload["qos"]["upload_limit"]["enabled"] = True
    payload["qos"]["upload_limit"]["limit"] = upload_limit
    return payload


# Builds the captured QoS prioritize-and-limit object shape.
def build_qos_prioritize_limits_object(
    *,
    name: str,
    target_type: str,
    target_ids: list[str],
    download_limit: int,
    upload_limit: int,
) -> dict[str, Any]:
    payload = build_qos_object(
        name=name,
        target_type=target_type,
        target_ids=target_ids,
    )
    payload["qos"]["mode"] = "LIMIT_AND_PRIORITIZE"
    payload["qos"]["download_limit"]["enabled"] = True
    payload["qos"]["download_limit"]["limit"] = download_limit
    payload["qos"]["upload_limit"]["enabled"] = True
    payload["qos"]["upload_limit"]["limit"] = upload_limit
    return payload


# Builds the captured Secure domain blocklist object shape.
def build_secure_domain_blocklist_object(
    *,
    name: str,
    target_type: str,
    target_ids: list[str],
    domains: list[str],
) -> dict[str, Any]:
    payload = build_secure_blocklist_object(
        name=name,
        target_type=target_type,
        target_ids=target_ids,
    )
    payload["secure"]["internet"]["everything"] = False
    payload["secure"]["internet"]["domains"] = {
        "enabled": True,
        "values": domains,
    }
    return payload


# Builds the captured Secure app blocklist object shape.
def build_secure_app_blocklist_object(
    *,
    name: str,
    target_type: str,
    target_ids: list[str],
    app_ids: list[int],
) -> dict[str, Any]:
    payload = build_secure_blocklist_object(
        name=name,
        target_type=target_type,
        target_ids=target_ids,
    )
    payload["secure"]["internet"]["everything"] = False
    payload["secure"]["internet"]["apps"] = {
        "enabled": True,
        "values": app_ids,
    }
    return payload


# Builds the captured Secure IP-address blocklist object shape.
def build_secure_ip_blocklist_object(
    *,
    name: str,
    target_type: str,
    target_ids: list[str],
    ip_addresses: list[str],
) -> dict[str, Any]:
    payload = build_secure_blocklist_object(
        name=name,
        target_type=target_type,
        target_ids=target_ids,
    )
    payload["secure"]["internet"]["everything"] = False
    payload["secure"]["internet"]["ip_addresses"] = {
        "enabled": True,
        "values": ip_addresses,
    }
    return payload


# Prints a dry-run summary or executes the requested group mutation.
def execute_group_write(
    *,
    method: str,
    path: str,
    payload: dict[str, Any] | None,
    apply: bool,
    insecure: bool,
) -> int:
    summary = {
        "request": {
            "method": method,
            "path": path,
            "json": payload,
        }
    }
    print(json.dumps(summary, indent=2, sort_keys=True))
    if not apply:
        print("DRY-RUN ONLY. Re-run with --apply to execute this Policy Engine group change.")
        return 0
    result = run_request(method, path, body=payload, insecure=insecure)
    if result.returncode != 0:
        if result.stderr:
            sys.stderr.write(result.stderr)
        return result.returncode
    if result.stdout.strip():
        print(result.stdout.rstrip())
    return 0


# Returns true when the rule looks currently enabled.
def is_enabled(rule: dict[str, Any]) -> bool:
    value = rule.get("enabled")
    if isinstance(value, bool):
        return value
    return True


# Prints a compact list of Policy Engine traffic rules.
def list_rules(site_ref: str, limit: int, insecure: bool) -> int:
    rules = rows(load_named_query("traffic-rules", site_ref=site_ref, insecure=insecure))
    print("Policy Engine traffic rules")
    print(f"- site_ref: {site_ref}")
    print(f"- rule_count: {len(rules)}")
    for index, rule in enumerate(rules[: max(1, limit)], start=1):
        families = property_families(rule)
        print(
            f"{index}. id={rule_id(rule)}, name={rule_label(rule)}, enabled={'yes' if is_enabled(rule) else 'no'}, "
            f"matching_target={matching_target(rule)}, target_scope={target_scope(rule)}, "
            f"schedule={schedule_mode(rule)}, families={','.join(families) if families else 'none'}"
        )
    return 0


# Prints grouped counts and top patterns from Policy Engine traffic rules.
def summarize_rules(site_ref: str, limit: int, insecure: bool) -> int:
    rules = rows(load_named_query("traffic-rules", site_ref=site_ref, insecure=insecure))
    by_matching_target = Counter(matching_target(rule) for rule in rules)
    by_scope = Counter(target_scope(rule) for rule in rules)
    by_schedule = Counter(schedule_mode(rule) for rule in rules)
    by_family = Counter(
        family
        for rule in rules
        for family in (property_families(rule) or ["none"])
    )

    print("Policy Engine traffic rule summary")
    print(f"- site_ref: {site_ref}")
    print(f"- rule_count: {len(rules)}")
    print("- by matching_target:")
    for label, count in by_matching_target.most_common(max(1, limit)):
        print(f"  {label}: {count}")
    print("- by target_scope:")
    for label, count in by_scope.most_common(max(1, limit)):
        print(f"  {label}: {count}")
    print("- by schedule:")
    for label, count in by_schedule.most_common(max(1, limit)):
        print(f"  {label}: {count}")
    print("- by property family:")
    for label, count in by_family.most_common(max(1, limit)):
        print(f"  {label}: {count}")
    return 0


# Compares the newer Policy Engine collection with the older simple app-block collection.
def compare_paths(site_ref: str, limit: int, insecure: bool) -> int:
    traffic_rules = rows(load_named_query("traffic-rules", site_ref=site_ref, insecure=insecure))
    app_blocks = rows(load_named_query("firewall-app-blocks", site_ref=site_ref, insecure=insecure))

    print("UniFi policy path comparison")
    print(f"- site_ref: {site_ref}")
    print(f"- trafficrules_count: {len(traffic_rules)}")
    print(f"- firewall_app_blocks_count: {len(app_blocks)}")
    print("- note: UniFi currently appears to expose these as parallel APIs during migration.")

    if traffic_rules:
        print("- trafficrules examples:")
        for rule in traffic_rules[: max(1, limit)]:
            print(
                f"  id={rule_id(rule)}, name={rule_label(rule)}, matching_target={matching_target(rule)}, "
                f"target_scope={target_scope(rule)}, schedule={schedule_mode(rule)}"
            )

    if app_blocks:
        print("- firewall-app-blocks examples:")
        for rule in app_blocks[: max(1, limit)]:
            app_ids = rule.get("app_ids") or []
            category_ids = rule.get("app_category_ids") or []
            print(
                f"  id={rule_id(rule)}, name={rule_label(rule)}, target_type={rule.get('target_type')}, "
                f"client_macs={len(rule.get('client_macs') or [])}, app_ids={len(app_ids)}, "
                f"app_category_ids={len(category_ids)}"
            )

    return 0


# Prints a compact list of Object Manager objects from the new Policy Engine path.
def list_objects(site_ref: str, limit: int, insecure: bool) -> int:
    objects = rows(load_named_query("policy-engine-objects", site_ref=site_ref, insecure=insecure))
    print("Policy Engine objects")
    print(f"- site_ref: {site_ref}")
    print(f"- object_count: {len(objects)}")
    for index, obj in enumerate(objects[: max(1, limit)], start=1):
        properties = [
            key
            for key in ("secure", "route", "qos")
            if isinstance(obj.get(key), dict) and obj.get(key, {}).get("enabled") is not False
        ]
        print(
            f"{index}. id={obj.get('id') or obj.get('_id') or 'unknown'}, "
            f"name={obj.get('name') or 'unnamed-object'}, enabled={'yes' if obj.get('enabled', True) else 'no'}, "
            f"target_type={obj.get('target_type') or 'UNKNOWN'}, targets={','.join(obj.get('targets') or []) or 'none'}, "
            f"properties={','.join(properties) if properties else 'none'}"
        )
    return 0


# Prints a compact list of Policy Engine client groups.
def list_groups(site_ref: str, limit: int, insecure: bool) -> int:
    groups = rows(load_named_query("network-members-groups", site_ref=site_ref, insecure=insecure))
    print("Policy Engine client groups")
    print(f"- site_ref: {site_ref}")
    print(f"- group_count: {len(groups)}")
    for index, group in enumerate(groups[: max(1, limit)], start=1):
        members = group_members(group)
        print(
            f"{index}. id={group_id(group)}, name={group_label(group)}, type={group.get('type') or 'UNKNOWN'}, "
            f"member_count={len(members)}, members={','.join(members[:5]) if members else 'none'}"
        )
    return 0


# Creates a Policy Engine client group using the controller's network-members-group path.
def create_group(site_ref: str, name: str, member_macs: list[str], apply: bool, insecure: bool) -> int:
    payload = build_group_payload(name=name, member_macs=member_macs)
    return execute_group_write(
        method="POST",
        path=GROUP_ITEM_PATH.format(site_ref=site_ref),
        payload=payload,
        apply=apply,
        insecure=insecure,
    )


# Updates an existing Policy Engine client group by ID.
def update_group(
    site_ref: str,
    group_id_value: str,
    name: str,
    member_macs: list[str],
    apply: bool,
    insecure: bool,
) -> int:
    payload = build_group_payload(name=name, member_macs=member_macs, group_id_value=group_id_value)
    return execute_group_write(
        method="PUT",
        path=f"{GROUP_ITEM_PATH.format(site_ref=site_ref)}/{group_id_value}",
        payload=payload,
        apply=apply,
        insecure=insecure,
    )


# Deletes an existing Policy Engine client group by ID.
def delete_group(site_ref: str, group_id_value: str, apply: bool, insecure: bool) -> int:
    return execute_group_write(
        method="DELETE",
        path=f"{GROUP_ITEM_PATH.format(site_ref=site_ref)}/{group_id_value}",
        payload=None,
        apply=apply,
        insecure=insecure,
    )


# Creates an Object Manager object using the normalized object-oriented endpoint.
def create_object(site_ref: str, json_body: str, apply: bool, insecure: bool) -> int:
    payload = parse_json_object(json_body)
    return execute_group_write(
        method="POST",
        path=OBJECT_ITEM_PATH.format(site_ref=site_ref),
        payload=payload,
        apply=apply,
        insecure=insecure,
    )


# Updates an Object Manager object by ID using the normalized object-oriented endpoint.
def update_object(
    site_ref: str,
    object_id: str,
    json_body: str,
    apply: bool,
    insecure: bool,
) -> int:
    payload = parse_json_object(json_body)
    if "id" not in payload:
        payload["id"] = object_id
    return execute_group_write(
        method="PUT",
        path=f"{OBJECT_ITEM_PATH.format(site_ref=site_ref)}/{object_id}",
        payload=payload,
        apply=apply,
        insecure=insecure,
    )


# Deletes an Object Manager object by ID.
def delete_object(site_ref: str, object_id: str, apply: bool, insecure: bool) -> int:
    return execute_group_write(
        method="DELETE",
        path=f"{OBJECT_ITEM_PATH.format(site_ref=site_ref)}/{object_id}",
        payload=None,
        apply=apply,
        insecure=insecure,
    )


# Creates the first fully captured Secure Object Manager payload variant.
def create_secure_blocklist_object(
    site_ref: str,
    name: str,
    target_type: str,
    target_ids: list[str],
    apply: bool,
    insecure: bool,
) -> int:
    payload = build_secure_blocklist_object(
        name=name,
        target_type=target_type,
        target_ids=target_ids,
    )
    return execute_group_write(
        method="POST",
        path=OBJECT_ITEM_PATH.format(site_ref=site_ref),
        payload=payload,
        apply=apply,
        insecure=insecure,
    )


# Creates the captured allowlist variant on the Object Manager API.
def create_secure_allowlist_object(
    site_ref: str,
    name: str,
    target_type: str,
    target_ids: list[str],
    apply: bool,
    insecure: bool,
) -> int:
    payload = build_secure_allowlist_object(
        name=name,
        target_type=target_type,
        target_ids=target_ids,
    )
    return execute_group_write(
        method="POST",
        path=OBJECT_ITEM_PATH.format(site_ref=site_ref),
        payload=payload,
        apply=apply,
        insecure=insecure,
    )


# Creates the captured quarantine variant on the Object Manager API.
def create_quarantine_object(
    site_ref: str,
    name: str,
    target_type: str,
    target_ids: list[str],
    apply: bool,
    insecure: bool,
) -> int:
    payload = build_quarantine_object(
        name=name,
        target_type=target_type,
        target_ids=target_ids,
    )
    return execute_group_write(
        method="POST",
        path=OBJECT_ITEM_PATH.format(site_ref=site_ref),
        payload=payload,
        apply=apply,
        insecure=insecure,
    )


# Creates the captured no-internet variant on the Object Manager API.
def create_no_internet_object(
    site_ref: str,
    name: str,
    target_type: str,
    target_ids: list[str],
    apply: bool,
    insecure: bool,
) -> int:
    payload = build_no_internet_object(
        name=name,
        target_type=target_type,
        target_ids=target_ids,
    )
    return execute_group_write(
        method="POST",
        path=OBJECT_ITEM_PATH.format(site_ref=site_ref),
        payload=payload,
        apply=apply,
        insecure=insecure,
    )


# Creates the captured Route variant on the Object Manager API.
def create_route_object(
    site_ref: str,
    name: str,
    target_type: str,
    target_ids: list[str],
    network_id: str,
    apply: bool,
    insecure: bool,
) -> int:
    payload = build_route_object(
        name=name,
        target_type=target_type,
        target_ids=target_ids,
        network_id=network_id,
    )
    return execute_group_write(
        method="POST",
        path=OBJECT_ITEM_PATH.format(site_ref=site_ref),
        payload=payload,
        apply=apply,
        insecure=insecure,
    )


# Creates the captured Route domain-selector variant on the Object Manager API.
def create_route_domain_object(
    site_ref: str,
    name: str,
    target_type: str,
    target_ids: list[str],
    network_id: str,
    domains: list[str],
    apply: bool,
    insecure: bool,
) -> int:
    payload = build_route_domain_object(
        name=name,
        target_type=target_type,
        target_ids=target_ids,
        network_id=network_id,
        domains=domains,
    )
    return execute_group_write(
        method="POST",
        path=OBJECT_ITEM_PATH.format(site_ref=site_ref),
        payload=payload,
        apply=apply,
        insecure=insecure,
    )


# Creates the captured Route IP-selector variant on the Object Manager API.
def create_route_ip_object(
    site_ref: str,
    name: str,
    target_type: str,
    target_ids: list[str],
    network_id: str,
    ip_addresses: list[str],
    apply: bool,
    insecure: bool,
) -> int:
    payload = build_route_ip_object(
        name=name,
        target_type=target_type,
        target_ids=target_ids,
        network_id=network_id,
        ip_addresses=ip_addresses,
    )
    return execute_group_write(
        method="POST",
        path=OBJECT_ITEM_PATH.format(site_ref=site_ref),
        payload=payload,
        apply=apply,
        insecure=insecure,
    )


# Creates the captured QoS variant on the Object Manager API.
def create_qos_object(
    site_ref: str,
    name: str,
    target_type: str,
    target_ids: list[str],
    apply: bool,
    insecure: bool,
) -> int:
    payload = build_qos_object(
        name=name,
        target_type=target_type,
        target_ids=target_ids,
    )
    return execute_group_write(
        method="POST",
        path=OBJECT_ITEM_PATH.format(site_ref=site_ref),
        payload=payload,
        apply=apply,
        insecure=insecure,
    )


# Creates the captured QoS prioritize variant on the Object Manager API.
def create_qos_prioritize_object(
    site_ref: str,
    name: str,
    target_type: str,
    target_ids: list[str],
    apply: bool,
    insecure: bool,
) -> int:
    payload = build_qos_prioritize_object(
        name=name,
        target_type=target_type,
        target_ids=target_ids,
    )
    return execute_group_write(
        method="POST",
        path=OBJECT_ITEM_PATH.format(site_ref=site_ref),
        payload=payload,
        apply=apply,
        insecure=insecure,
    )


# Creates the captured QoS-limits variant on the Object Manager API.
def create_qos_limits_object(
    site_ref: str,
    name: str,
    target_type: str,
    target_ids: list[str],
    network_id: str,
    download_limit: int,
    upload_limit: int,
    apply: bool,
    insecure: bool,
) -> int:
    payload = build_qos_limits_object(
        name=name,
        target_type=target_type,
        target_ids=target_ids,
        network_id=network_id,
        download_limit=download_limit,
        upload_limit=upload_limit,
    )
    return execute_group_write(
        method="POST",
        path=OBJECT_ITEM_PATH.format(site_ref=site_ref),
        payload=payload,
        apply=apply,
        insecure=insecure,
    )


# Creates the captured QoS prioritize-and-limit variant on the Object Manager API.
def create_qos_prioritize_limits_object(
    site_ref: str,
    name: str,
    target_type: str,
    target_ids: list[str],
    download_limit: int,
    upload_limit: int,
    apply: bool,
    insecure: bool,
) -> int:
    payload = build_qos_prioritize_limits_object(
        name=name,
        target_type=target_type,
        target_ids=target_ids,
        download_limit=download_limit,
        upload_limit=upload_limit,
    )
    return execute_group_write(
        method="POST",
        path=OBJECT_ITEM_PATH.format(site_ref=site_ref),
        payload=payload,
        apply=apply,
        insecure=insecure,
    )


# Creates the captured Secure domain blocklist variant on the Object Manager API.
def create_secure_domain_blocklist_object(
    site_ref: str,
    name: str,
    target_type: str,
    target_ids: list[str],
    domains: list[str],
    apply: bool,
    insecure: bool,
) -> int:
    payload = build_secure_domain_blocklist_object(
        name=name,
        target_type=target_type,
        target_ids=target_ids,
        domains=domains,
    )
    return execute_group_write(
        method="POST",
        path=OBJECT_ITEM_PATH.format(site_ref=site_ref),
        payload=payload,
        apply=apply,
        insecure=insecure,
    )


# Creates the captured Secure app blocklist variant on the Object Manager API.
def create_secure_app_blocklist_object(
    site_ref: str,
    name: str,
    target_type: str,
    target_ids: list[str],
    app_ids: list[int],
    apply: bool,
    insecure: bool,
) -> int:
    payload = build_secure_app_blocklist_object(
        name=name,
        target_type=target_type,
        target_ids=target_ids,
        app_ids=app_ids,
    )
    return execute_group_write(
        method="POST",
        path=OBJECT_ITEM_PATH.format(site_ref=site_ref),
        payload=payload,
        apply=apply,
        insecure=insecure,
    )


# Creates the captured Secure IP-address blocklist variant on the Object Manager API.
def create_secure_ip_blocklist_object(
    site_ref: str,
    name: str,
    target_type: str,
    target_ids: list[str],
    ip_addresses: list[str],
    apply: bool,
    insecure: bool,
) -> int:
    payload = build_secure_ip_blocklist_object(
        name=name,
        target_type=target_type,
        target_ids=target_ids,
        ip_addresses=ip_addresses,
    )
    return execute_group_write(
        method="POST",
        path=OBJECT_ITEM_PATH.format(site_ref=site_ref),
        payload=payload,
        apply=apply,
        insecure=insecure,
    )


# Dispatches the selected Policy Engine helper command.
def main() -> int:
    args = parse_args()
    if args.command == "list-rules":
        return list_rules(args.site_ref, args.limit, args.insecure)
    if args.command == "summarize-rules":
        return summarize_rules(args.site_ref, args.limit, args.insecure)
    if args.command == "compare-paths":
        return compare_paths(args.site_ref, args.limit, args.insecure)
    if args.command == "list-groups":
        return list_groups(args.site_ref, args.limit, args.insecure)
    if args.command == "create-group":
        return create_group(args.site_ref, args.name, args.member_mac, args.apply, args.insecure)
    if args.command == "update-group":
        return update_group(
            args.site_ref,
            args.group_id,
            args.name,
            args.member_mac,
            args.apply,
            args.insecure,
        )
    if args.command == "delete-group":
        return delete_group(args.site_ref, args.group_id, args.apply, args.insecure)
    if args.command == "list-objects":
        return list_objects(args.site_ref, args.limit, args.insecure)
    if args.command == "create-object":
        return create_object(args.site_ref, args.json_body, args.apply, args.insecure)
    if args.command == "update-object":
        return update_object(args.site_ref, args.object_id, args.json_body, args.apply, args.insecure)
    if args.command == "delete-object":
        return delete_object(args.site_ref, args.object_id, args.apply, args.insecure)
    if args.command == "create-secure-blocklist-object":
        return create_secure_blocklist_object(
            args.site_ref,
            args.name,
            args.target_type,
            args.target_id,
            args.apply,
            args.insecure,
        )
    if args.command == "create-secure-allowlist-object":
        return create_secure_allowlist_object(
            args.site_ref,
            args.name,
            args.target_type,
            args.target_id,
            args.apply,
            args.insecure,
        )
    if args.command == "create-quarantine-object":
        return create_quarantine_object(
            args.site_ref,
            args.name,
            args.target_type,
            args.target_id,
            args.apply,
            args.insecure,
        )
    if args.command == "create-no-internet-object":
        return create_no_internet_object(
            args.site_ref,
            args.name,
            args.target_type,
            args.target_id,
            args.apply,
            args.insecure,
        )
    if args.command == "create-route-object":
        return create_route_object(
            args.site_ref,
            args.name,
            args.target_type,
            args.target_id,
            args.network_id,
            args.apply,
            args.insecure,
        )
    if args.command == "create-route-domain-object":
        return create_route_domain_object(
            args.site_ref,
            args.name,
            args.target_type,
            args.target_id,
            args.network_id,
            args.domain,
            args.apply,
            args.insecure,
        )
    if args.command == "create-route-ip-object":
        return create_route_ip_object(
            args.site_ref,
            args.name,
            args.target_type,
            args.target_id,
            args.network_id,
            args.ip_address,
            args.apply,
            args.insecure,
        )
    if args.command == "create-qos-object":
        return create_qos_object(
            args.site_ref,
            args.name,
            args.target_type,
            args.target_id,
            args.apply,
            args.insecure,
        )
    if args.command == "create-qos-prioritize-object":
        return create_qos_prioritize_object(
            args.site_ref,
            args.name,
            args.target_type,
            args.target_id,
            args.apply,
            args.insecure,
        )
    if args.command == "create-qos-limits-object":
        return create_qos_limits_object(
            args.site_ref,
            args.name,
            args.target_type,
            args.target_id,
            args.network_id,
            args.download_limit,
            args.upload_limit,
            args.apply,
            args.insecure,
        )
    if args.command == "create-qos-prioritize-limits-object":
        return create_qos_prioritize_limits_object(
            args.site_ref,
            args.name,
            args.target_type,
            args.target_id,
            args.download_limit,
            args.upload_limit,
            args.apply,
            args.insecure,
        )
    if args.command == "create-secure-domain-blocklist-object":
        return create_secure_domain_blocklist_object(
            args.site_ref,
            args.name,
            args.target_type,
            args.target_id,
            args.domain,
            args.apply,
            args.insecure,
        )
    if args.command == "create-secure-app-blocklist-object":
        return create_secure_app_blocklist_object(
            args.site_ref,
            args.name,
            args.target_type,
            args.target_id,
            args.app_id,
            args.apply,
            args.insecure,
        )
    if args.command == "create-secure-ip-blocklist-object":
        return create_secure_ip_blocklist_object(
            args.site_ref,
            args.name,
            args.target_type,
            args.target_id,
            args.ip_address,
            args.apply,
            args.insecure,
        )
    raise SystemExit(f"unsupported command: {args.command}")


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Bottom-up UniFi rankings that avoid dumping full inventories to the caller."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from datetime import datetime
from typing import Any

from _paths import SCRIPT_DIR


NAMED_QUERY_SCRIPT = SCRIPT_DIR / "named_query.py"
UNIFI_REQUEST_SCRIPT = SCRIPT_DIR / "unifi_request.py"


# Parses CLI arguments for bottom-up UniFi rankings.
def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Compute compact bottom-up UniFi rankings without returning full raw client or "
            "device inventories."
        )
    )
    parser.add_argument(
        "entity_type",
        choices=(
            "client",
            "access_point",
            "wifi_broadcast",
            "network",
            "switch_port",
            "firewall_rule",
            "acl_rule",
            "vpn_tunnel",
            "wan_profile",
            "dns_policy",
            "app_block",
        ),
        help="Entity family to rank.",
    )
    parser.add_argument(
        "metric",
        choices=(
            "highest_bandwidth",
            "reconnect_churn",
            "most_retransmits",
            "offline_recent",
            "recent_ip_changes",
            "slowest_speed",
            "weakest_signal",
            "highest_latency",
            "client_count",
            "weakest_average_signal",
            "strongest_average_signal",
            "roam_churn",
            "disconnect_churn",
            "reference_count",
            "shadow_risk",
            "ordering_risk",
            "down",
            "up",
            "stale",
            "healthy",
            "unhealthy",
            "errors",
            "disconnected_client_count",
            "flapping",
            "hits",
            "target_count",
        ),
        help="Metric to rank by.",
    )
    parser.add_argument("--limit", type=int, default=5, help="How many results to print. Default: 5.")
    parser.add_argument("--site-id", help="Site ID for site-scoped queries.")
    parser.add_argument("--site-ref", help="Site internal reference (for example 'default').")
    parser.add_argument(
        "--include-inactive",
        action="store_true",
        help="Include inactive clients for client-based rankings when supported.",
    )
    parser.add_argument(
        "--insecure",
        action="store_true",
        help="Pass through for self-signed TLS certificates.",
    )
    return parser.parse_args()


# Runs the named-query helper and returns its decoded JSON output.
def run_named_query(
    query: str,
    *,
    site_id: str | None = None,
    site_ref: str | None = None,
    insecure: bool = False,
) -> Any:
    cmd = [sys.executable, str(NAMED_QUERY_SCRIPT), query, "--all-pages"]
    if site_id:
        cmd.extend(["--site-id", site_id])
    if site_ref:
        cmd.extend(["--site-ref", site_ref])
    if insecure:
        cmd.append("--insecure")
    result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        if result.stderr:
            sys.stderr.write(result.stderr)
        raise SystemExit(result.returncode)
    return json.loads(result.stdout)


# Runs the raw UniFi request helper and returns its decoded JSON output.
def run_unifi_request(method: str, path: str, *, insecure: bool = False) -> Any:
    cmd = [sys.executable, str(UNIFI_REQUEST_SCRIPT), method, path]
    if insecure:
        cmd.append("--insecure")
    result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        if result.stderr:
            sys.stderr.write(result.stderr)
        raise SystemExit(result.returncode)
    return json.loads(result.stdout)


# Extracts row dictionaries from the standard UniFi response envelope.
def rows(payload: Any) -> list[dict[str, Any]]:
    if isinstance(payload, list):
        return [item for item in payload if isinstance(item, dict)]
    if isinstance(payload, dict):
        data = payload.get("data", [])
        if isinstance(data, list):
            return [item for item in data if isinstance(item, dict)]
    return []


# Resolves the UUID site ID required for site-scoped queries.
def require_site_id(args: argparse.Namespace) -> str:
    if args.site_id:
        return args.site_id
    if not args.site_ref:
        raise SystemExit(f"{args.entity_type}/{args.metric} requires --site-id or --site-ref")
    sites = rows(run_named_query("sites", insecure=args.insecure))
    for site in sites:
        if site.get("internalReference") == args.site_ref:
            site_id = site.get("id")
            if isinstance(site_id, str) and site_id:
                return site_id
    raise SystemExit(f"site reference not found: {args.site_ref}")


# Returns the normalized site reference, defaulting to `default`.
def normalized_site_ref(args: argparse.Namespace) -> str:
    if args.site_ref:
        return args.site_ref
    return "default"


# Loads the client rows used by the ranking commands.
def load_clients(args: argparse.Namespace, *, include_inactive: bool) -> list[dict[str, Any]]:
    site_id = require_site_id(args)
    sources: list[list[dict[str, Any]]] = []
    if include_inactive:
        for query in ("clients-all", "clients"):
            try:
                sources.append(rows(run_named_query(query, site_id=site_id, insecure=args.insecure)))
            except SystemExit:
                continue
        try:
            legacy = run_unifi_request(
                "GET",
                f"/proxy/network/api/s/{normalized_site_ref(args)}/stat/alluser",
                insecure=args.insecure,
            )
            sources.append(rows(legacy))
        except SystemExit:
            pass
    else:
        sources.append(rows(run_named_query("clients", site_id=site_id, insecure=args.insecure)))

    merged: dict[str, dict[str, Any]] = {}
    for group in sources:
        for client in group:
            key = client_merge_key(client)
            if key in merged:
                merged[key] = merge_rows(merged[key], client)
            else:
                merged[key] = client
    return list(merged.values())


# Builds the deduplication key used when merging client rows.
def client_merge_key(row: dict[str, Any]) -> str:
    for key in ("mac", "macAddress", "clientMac", "staMac", "ip", "ipAddress", "last_ip", "id", "_id", "clientId"):
        value = string_value(row.get(key))
        if value:
            return value.lower()
    return f"row:{id(row)}"


# Merges two rows while preferring the richer set of fields.
def merge_rows(existing: dict[str, Any], incoming: dict[str, Any]) -> dict[str, Any]:
    merged = dict(existing)
    for key, value in incoming.items():
        current = merged.get(key)
        if isinstance(current, str) and current.strip():
            continue
        merged[key] = value
    return merged


# Returns a compact display name for a client row.
def client_label(client: dict[str, Any]) -> str:
    name = (
        string_value(client.get("name"))
        or string_value(client.get("displayName"))
        or string_value(client.get("clientName"))
        or string_value(client.get("hostname"))
        or string_value(client.get("ip"))
        or string_value(client.get("ipAddress"))
        or "unknown-client"
    )
    ip = string_value(client.get("ip")) or string_value(client.get("ipAddress"))
    return f"{name} ({ip})" if ip and ip != name else name


# Returns a compact identity suffix for a client result.
def client_detail(client: dict[str, Any]) -> str:
    medium = "wired" if is_wired_client(client) else "wifi"
    ip = string_value(client.get("ip")) or string_value(client.get("ipAddress")) or "unknown"
    mac = (
        string_value(client.get("mac"))
        or string_value(client.get("macAddress"))
        or string_value(client.get("clientMac"))
        or "unknown"
    )
    uplink = (
        string_value(client.get("uplinkDeviceName"))
        or string_value(client.get("uplinkDeviceId"))
        or string_value(client.get("ap_name"))
        or "unknown"
    )
    return f"medium={medium}, ip={ip}, mac={mac}, uplink={uplink}"


# Returns true when a client row appears to be wired.
def is_wired_client(client: dict[str, Any]) -> bool:
    for key in ("is_wired", "isWired"):
        value = bool_value(client.get(key))
        if value is not None:
            return value
    medium = (
        string_value(client.get("medium"))
        or string_value(client.get("connectionType"))
        or string_value(client.get("radio"))
        or ""
    ).lower()
    return "wired" in medium or "ethernet" in medium


# Returns true when a client row appears to be active.
def is_active_client(client: dict[str, Any]) -> bool:
    for key in ("active", "isActive", "is_online", "isOnline"):
        value = bool_value(client.get(key))
        if value is not None:
            return value
    state = (
        string_value(client.get("state"))
        or string_value(client.get("status"))
        or string_value(client.get("connectionState"))
        or ""
    ).lower()
    if any(word in state for word in ("offline", "disconnected", "inactive")):
        return False
    if any(word in state for word in ("online", "connected", "active")):
        return True
    return True


# Returns true when a device row appears online and available for current-state rankings.
def is_online_device(device: dict[str, Any]) -> bool:
    for key in ("active", "isActive", "is_online", "isOnline"):
        value = bool_value(device.get(key))
        if value is not None:
            return value
    state = (
        string_value(device.get("state"))
        or string_value(device.get("status"))
        or string_value(device.get("connectionState"))
        or string_value(device.get("uplink_status"))
        or ""
    ).lower()
    if any(word in state for word in ("offline", "disconnected", "inactive", "down")):
        return False
    if any(word in state for word in ("online", "connected", "active", "up")):
        return True
    return True


# Converts a flexible JSON value into a boolean when possible.
def bool_value(value: Any) -> bool | None:
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return bool(value)
    if isinstance(value, str):
        normalized = value.strip().lower()
        if normalized in {"1", "true", "yes", "y", "on"}:
            return True
        if normalized in {"0", "false", "no", "n", "off"}:
            return False
    return None


# Returns a trimmed string representation when possible.
def string_value(value: Any) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    return text or None


# Converts a JSON field into a numeric value when possible.
def numeric_value(value: Any) -> float | None:
    if isinstance(value, bool):
        return float(value)
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return float(value.strip())
        except ValueError:
            return None
    if isinstance(value, dict):
        for key in ("value", "current", "avg", "mean"):
            if key in value:
                parsed = numeric_value(value[key])
                if parsed is not None:
                    return parsed
    return None


# Extracts numeric values from a row for the provided key list.
def numeric_values(row: dict[str, Any], keys: list[str]) -> list[float]:
    values: list[float] = []
    for key in keys:
        if key not in row:
            continue
        parsed = numeric_value(row[key])
        if parsed is not None:
            values.append(parsed)
            continue
        nested = row[key]
        if isinstance(nested, dict):
            values.extend(
                item for item in (numeric_value(candidate) for candidate in nested.values()) if item is not None
            )
    return values


# Sums numeric values across a set of likely field names.
def sum_numeric_values(row: dict[str, Any], keys: list[str]) -> float:
    return sum(numeric_value(row.get(key)) or 0 for key in keys)


# Parses the most recent timestamp from a row.
def latest_date(row: dict[str, Any], keys: list[str]) -> datetime | None:
    dates = [date_value(row.get(key)) for key in keys]
    valid = [item for item in dates if item is not None]
    return max(valid) if valid else None


# Converts a timestamp-like JSON value into a datetime when possible.
def date_value(value: Any) -> datetime | None:
    if isinstance(value, (int, float)):
        seconds = float(value)
        if seconds > 10_000_000_000:
            seconds /= 1000
        return datetime.fromtimestamp(seconds)
    if isinstance(value, str):
        text = value.strip()
        if not text:
            return None
        try:
            return date_value(float(text))
        except ValueError:
            try:
                return datetime.fromisoformat(text.replace("Z", "+00:00"))
            except ValueError:
                return None
    return None


# Returns distinct non-empty string values in their original order.
def unique_strings(values: list[str]) -> list[str]:
    seen: set[str] = set()
    output: list[str] = []
    for value in values:
        trimmed = value.strip()
        if not trimmed:
            continue
        key = trimmed.lower()
        if key in seen:
            continue
        seen.add(key)
        output.append(trimmed)
    return output


# Counts explicit targets attached to a rule or policy payload.
def target_count(row: dict[str, Any]) -> int:
    count = 0
    for key in (
        "client_macs",
        "client_ids",
        "clientIds",
        "devices",
        "deviceIds",
        "targetDevices",
        "target_devices",
        "source_devices",
        "network_ids",
        "networks",
    ):
        value = row.get(key)
        if isinstance(value, list):
            count += len(value)
    target = row.get("target")
    if count == 0 and isinstance(target, dict):
        return target_count(target)
    return count


# Resolves the WiFi broadcast name a client most likely belongs to.
def wifi_broadcast_name(client: dict[str, Any], broadcasts: list[dict[str, Any]]) -> str | None:
    for key in ("essid", "ssid", "wifiName", "network", "networkName", "wlan", "radioName"):
        value = string_value(client.get(key))
        if value:
            return value
    broadcast_id = (
        string_value(client.get("wifiBroadcastId"))
        or string_value(client.get("wifi_broadcast_id"))
        or string_value(client.get("wlanconfId"))
        or string_value(client.get("wlanconf_id"))
    )
    network_id = (
        string_value(client.get("networkId"))
        or string_value(client.get("network_id"))
        or string_value(client.get("last_connection_network_id"))
        or string_value(client.get("lastConnectionNetworkId"))
    )
    for broadcast in broadcasts:
        identifier = string_value(broadcast.get("id")) or string_value(broadcast.get("_id"))
        attached_network = string_value(broadcast.get("networkId")) or string_value(broadcast.get("network_id"))
        if identifier and identifier == broadcast_id:
            return string_value(broadcast.get("name")) or string_value(broadcast.get("ssid")) or identifier
        if attached_network and attached_network == network_id:
            return string_value(broadcast.get("name")) or string_value(broadcast.get("ssid")) or attached_network
    return None


# Counts how often a token appears anywhere inside a nested policy-like row.
def row_contains_token(value: Any, token: str) -> bool:
    normalized = token.lower()
    if isinstance(value, str):
        return normalized in value.lower()
    if isinstance(value, list):
        return any(row_contains_token(item, token) for item in value)
    if isinstance(value, dict):
        return any(row_contains_token(item, token) for item in value.values())
    return False


# Builds a compact scope signature for a nested source or destination object.
def rule_scope_signature(value: Any) -> str:
    if not isinstance(value, dict):
        return "any"
    zone = string_value(value.get("zoneId")) or string_value(value.get("zone_id")) or string_value(value.get("id")) or "any"
    network = string_value(value.get("networkId")) or string_value(value.get("network_id")) or "any"
    country = string_value(value.get("countryCode")) or string_value(value.get("country_code")) or "any"
    return f"{zone}:{network}:{country}"


# Returns a compact comparison signature for a policy row.
def rule_signature(row: dict[str, Any]) -> str:
    action_row = row.get("action")
    action = ""
    if isinstance(action_row, dict):
        action = (
            string_value(action_row.get("type"))
            or string_value(action_row.get("name"))
            or string_value(action_row.get("state"))
            or ""
        )
    if not action:
        action = (
            string_value(row.get("state"))
            or string_value(row.get("status"))
            or string_value(row.get("connectionState"))
            or ""
        )
    traffic = unique_strings(
        [
            item
            for item in (
                string_value(row.get("protocol")),
                string_value(row.get("ipVersion")),
                string_value(row.get("ip_version")),
                string_value(row.get("trafficMatchingListId")),
                string_value(row.get("traffic_matching_list_id")),
                string_value(row.get("port")),
                string_value(row.get("ports")),
            )
            if item
        ]
    )
    return "||".join(
        (
            rule_scope_signature(row.get("source")),
            rule_scope_signature(row.get("destination")),
            action.lower(),
            "|".join(traffic).lower(),
        )
    )


# Returns true when a state string appears healthy or connected.
def state_looks_healthy(state: str | None) -> bool:
    normalized = (state or "").lower()
    if any(word in normalized for word in ("down", "fail", "disconnected", "offline")):
        return False
    return any(word in normalized for word in ("up", "connected", "online", "active", "established"))


# Returns a compact state string for VPN and WAN rows.
def state_text(row: dict[str, Any]) -> str:
    return (
        string_value(row.get("state"))
        or string_value(row.get("status"))
        or string_value(row.get("connectionState"))
        or string_value(row.get("tunnelState"))
        or string_value(row.get("health"))
        or ""
    )


# Builds a stable switch-port key from a client row.
def switch_port_key(client: dict[str, Any]) -> str | None:
    device_id = (
        string_value(client.get("uplinkDeviceId"))
        or string_value(client.get("uplink_device_id"))
        or string_value(client.get("sw_mac"))
        or string_value(client.get("switchId"))
        or string_value(client.get("switch_id"))
    )
    port = (
        string_value(client.get("uplinkPort"))
        or string_value(client.get("uplink_port"))
        or string_value(client.get("uplinkPortIdx"))
        or string_value(client.get("switchPort"))
        or string_value(client.get("switch_port"))
        or string_value(client.get("swPort"))
        or string_value(client.get("port"))
        or string_value(client.get("last_connection_port"))
    )
    if device_id and port:
        return f"{device_id}|{port}"
    return None


# Splits an internal switch-port key back into device and port labels.
def split_switch_port_key(key: str) -> tuple[str, str]:
    if "|" not in key:
        return key, "unknown-port"
    device_id, port = key.split("|", 1)
    return device_id, port


# Extracts candidate switch-port rows from a device payload.
def extract_port_rows(device: dict[str, Any]) -> list[dict[str, Any]]:
    for key in ("ports", "port_table", "portTable", "interfaces", "ethernet_table", "ethernetPorts"):
        value = device.get(key)
        if isinstance(value, list):
            rows = [item for item in value if isinstance(item, dict)]
            if rows:
                return rows
    return []


# Builds one ranked output row.
def rank_result(label: str, value: float, value_text: str, detail: str) -> dict[str, Any]:
    return {"label": label, "value": value, "value_text": value_text, "detail": detail}


# Returns the ranked results for the requested entity and metric.
def compute_rankings(args: argparse.Namespace) -> list[dict[str, Any]]:
    if args.entity_type == "client" and args.metric == "highest_bandwidth":
        clients = load_clients(args, include_inactive=args.include_inactive)
        ranked = []
        for client in clients:
            total = sum_numeric_values(
                client,
                [
                    "txRate", "rxRate", "tx_rate", "rx_rate", "tx_rate_kbps", "rx_rate_kbps",
                    "downloadKbps", "uploadKbps", "downloadRate", "uploadRate", "throughput",
                ],
            )
            if total <= 0:
                continue
            ranked.append(rank_result(f"client={client_label(client)}", total, f"{total:.0f} Mbps", client_detail(client)))
        return sorted(ranked, key=lambda item: (-item["value"], item["label"]))

    if args.entity_type == "client" and args.metric == "reconnect_churn":
        clients = load_clients(args, include_inactive=True)
        ranked = []
        for client in clients:
            total = sum_numeric_values(
                client,
                [
                    "disconnectCount", "disconnect_count", "disconnects", "reconnectCount", "reconnect_count",
                    "reconnects", "reassocCount", "reassoc_count", "associationFailures", "authFailures",
                ],
            )
            if total <= 0:
                continue
            ranked.append(rank_result(f"client={client_label(client)}", total, f"{total:.0f}", client_detail(client)))
        return sorted(ranked, key=lambda item: (-item["value"], item["label"]))

    if args.entity_type == "client" and args.metric == "most_retransmits":
        clients = load_clients(args, include_inactive=args.include_inactive)
        ranked = []
        for client in clients:
            total = sum_numeric_values(
                client,
                [
                    "retries", "retryCount", "retry_count", "txRetries", "rxRetries",
                    "tx_retries", "rx_retries", "txRetry", "rxRetry", "txRetryPct", "tx_retry_pct",
                ],
            )
            if total <= 0:
                continue
            ranked.append(rank_result(f"client={client_label(client)}", total, f"{total:.0f}", client_detail(client)))
        return sorted(ranked, key=lambda item: (-item["value"], item["label"]))

    if args.entity_type == "client" and args.metric == "offline_recent":
        clients = load_clients(args, include_inactive=True)
        ranked = []
        for client in clients:
            if is_active_client(client):
                continue
            date = latest_date(client, ["lastSeen", "last_seen", "lastConnected", "disconnect_timestamp", "connectedAt"])
            if date is None:
                continue
            ranked.append(
                rank_result(
                    f"client={client_label(client)}",
                    date.timestamp(),
                    date.isoformat(),
                    client_detail(client),
                )
            )
        return sorted(ranked, key=lambda item: (-item["value"], item["label"]))

    if args.entity_type == "client" and args.metric == "recent_ip_changes":
        clients = load_clients(args, include_inactive=True)
        ranked = []
        for client in clients:
            ips = unique_strings(
                [
                    item
                    for item in (
                        string_value(client.get("ip")),
                        string_value(client.get("ipAddress")),
                        string_value(client.get("last_ip")),
                        string_value(client.get("lastIp")),
                        string_value(client.get("fixed_ip")),
                        string_value(client.get("fixedIp")),
                        string_value(client.get("previous_ip")),
                        string_value(client.get("previousIp")),
                    )
                    if item
                ]
            )
            if len(ips) <= 1:
                continue
            ranked.append(
                rank_result(
                    f"client={client_label(client)}",
                    float(len(ips) - 1),
                    str(len(ips) - 1),
                    f"ips={' -> '.join(ips)}, {client_detail(client)}",
                )
            )
        return sorted(ranked, key=lambda item: (-item["value"], item["label"]))

    if args.entity_type == "client" and args.metric in {"slowest_speed", "weakest_signal", "highest_latency"}:
        clients = load_clients(args, include_inactive=args.include_inactive)
        ranked = []
        metric_keys = {
            "slowest_speed": ["txRate", "rxRate", "tx_rate", "rx_rate", "linkSpeed", "link_speed", "speed"],
            "weakest_signal": ["signal", "signalStrength", "wifiSignal", "rssi"],
            "highest_latency": ["latency", "avgLatency", "latencyMs", "latency_ms", "ping", "pingMs", "ping_ms"],
        }[args.metric]
        for client in clients:
            if args.metric == "weakest_signal" and is_wired_client(client):
                continue
            candidates = [item for item in numeric_values(client, metric_keys)]
            if args.metric == "slowest_speed":
                candidates = [item for item in candidates if item > 0]
                value = min(candidates) if candidates else None
                value_text = f"{value:.0f} Mbps" if value is not None else ""
            elif args.metric == "weakest_signal":
                value = max((item for item in candidates if item < 0), default=None)
                if value is None and candidates:
                    value = min(candidates)
                value_text = f"{value:.0f} dBm" if value is not None else ""
            else:
                candidates = [item for item in candidates if item >= 0]
                value = max(candidates) if candidates else None
                value_text = f"{value:.1f} ms" if value is not None else ""
            if value is None:
                continue
            ranked.append(rank_result(f"client={client_label(client)}", value, value_text, client_detail(client)))
        reverse = args.metric == "highest_latency"
        return sorted(ranked, key=lambda item: ((-item["value"]) if reverse else item["value"], item["label"]))

    if args.entity_type == "access_point" and args.metric == "client_count":
        site_id = require_site_id(args)
        devices = rows(run_named_query("devices", site_id=site_id, insecure=args.insecure))
        online_device_ids = {
            string_value(device.get("id"))
            for device in devices
            if string_value(device.get("id")) and is_online_device(device)
        }
        device_map = {
            string_value(device.get("id")): string_value(device.get("name")) or string_value(device.get("model")) or "unknown"
            for device in devices
            if string_value(device.get("id"))
        }
        clients = load_clients(args, include_inactive=args.include_inactive)
        counts: dict[str, int] = {}
        for client in clients:
            uplink = (
                string_value(client.get("uplinkDeviceId"))
                or string_value(client.get("uplink_device_id"))
                or string_value(client.get("apId"))
                or string_value(client.get("ap_id"))
            )
            if uplink:
                if not is_active_client(client):
                    continue
                if uplink not in online_device_ids:
                    continue
                counts[uplink] = counts.get(uplink, 0) + 1
        ranked = [
            rank_result(
                f"access_point={device_map.get(uplink, uplink)}",
                float(count),
                str(count),
                f"device_id={uplink}",
            )
            for uplink, count in counts.items()
        ]
        return sorted(ranked, key=lambda item: (-item["value"], item["label"]))

    if args.entity_type == "access_point" and args.metric == "weakest_average_signal":
        site_id = require_site_id(args)
        devices = rows(run_named_query("devices", site_id=site_id, insecure=args.insecure))
        online_device_ids = {
            string_value(device.get("id"))
            for device in devices
            if string_value(device.get("id")) and is_online_device(device)
        }
        device_map = {
            string_value(device.get("id")): string_value(device.get("name")) or string_value(device.get("model")) or "unknown"
            for device in devices
            if string_value(device.get("id"))
        }
        clients = [client for client in load_clients(args, include_inactive=args.include_inactive) if not is_wired_client(client)]
        grouped: dict[str, list[float]] = {}
        counts: dict[str, int] = {}
        for client in clients:
            uplink = string_value(client.get("uplinkDeviceId")) or string_value(client.get("apId"))
            if not is_active_client(client):
                continue
            if not uplink or uplink not in online_device_ids:
                continue
            signals = numeric_values(client, ["signal", "signalStrength", "wifiSignal", "rssi"])
            if not signals:
                continue
            value = max((item for item in signals if item < 0), default=min(signals))
            grouped.setdefault(uplink, []).append(value)
            counts[uplink] = counts.get(uplink, 0) + 1
        ranked = []
        for uplink, signals in grouped.items():
            average = sum(signals) / len(signals)
            ranked.append(
                rank_result(
                    f"access_point={device_map.get(uplink, uplink)}",
                    average,
                    f"{average:.1f} dBm",
                    f"clients={counts[uplink]}, device_id={uplink}",
                )
            )
        return sorted(ranked, key=lambda item: (item["value"], item["label"]))

    if args.entity_type == "access_point" and args.metric in {"roam_churn", "disconnect_churn"}:
        site_id = require_site_id(args)
        devices = rows(run_named_query("devices", site_id=site_id, insecure=args.insecure))
        device_map = {
            string_value(device.get("id")): string_value(device.get("name")) or string_value(device.get("model")) or "unknown"
            for device in devices
            if string_value(device.get("id"))
        }
        clients = load_clients(args, include_inactive=True)
        metric_keys = {
            "roam_churn": ["roamCount", "roam_count", "roams", "roamEvents", "roam_events"],
            "disconnect_churn": ["disconnectCount", "disconnect_count", "disconnects", "reconnectCount", "reconnect_count", "reconnects"],
        }[args.metric]
        totals: dict[str, float] = {}
        counts: dict[str, int] = {}
        for client in clients:
            uplink = (
                string_value(client.get("uplinkDeviceId"))
                or string_value(client.get("uplink_device_id"))
                or string_value(client.get("apId"))
                or string_value(client.get("ap_id"))
            )
            if not uplink:
                continue
            total = sum_numeric_values(client, metric_keys)
            if total <= 0:
                continue
            totals[uplink] = totals.get(uplink, 0) + total
            counts[uplink] = counts.get(uplink, 0) + 1
        ranked = [
            rank_result(
                f"access_point={device_map.get(uplink, uplink)}",
                value,
                f"{value:.0f}",
                f"clients={counts.get(uplink, 0)}, device_id={uplink}",
            )
            for uplink, value in totals.items()
        ]
        return sorted(ranked, key=lambda item: (-item["value"], item["label"]))

    if args.entity_type == "wifi_broadcast" and args.metric == "client_count":
        site_id = require_site_id(args)
        broadcasts = rows(run_named_query("wifi-broadcasts", site_id=site_id, insecure=args.insecure))
        clients = [
            client
            for client in load_clients(args, include_inactive=args.include_inactive)
            if not is_wired_client(client) and is_active_client(client)
        ]
        counts: dict[str, int] = {}
        for client in clients:
            name = wifi_broadcast_name(client, broadcasts)
            if name:
                counts[name] = counts.get(name, 0) + 1
        ranked = [rank_result(f"wifi_broadcast={name}", float(count), str(count), "") for name, count in counts.items()]
        return sorted(ranked, key=lambda item: (-item["value"], item["label"]))

    if args.entity_type == "wifi_broadcast" and args.metric in {"weakest_average_signal", "strongest_average_signal"}:
        site_id = require_site_id(args)
        broadcasts = rows(run_named_query("wifi-broadcasts", site_id=site_id, insecure=args.insecure))
        clients = [
            client
            for client in load_clients(args, include_inactive=args.include_inactive)
            if not is_wired_client(client) and is_active_client(client)
        ]
        grouped: dict[str, list[float]] = {}
        for client in clients:
            name = wifi_broadcast_name(client, broadcasts)
            if not name:
                continue
            signals = numeric_values(client, ["signal", "signalStrength", "wifiSignal", "rssi"])
            if not signals:
                continue
            signal = max((item for item in signals if item < 0), default=min(signals))
            grouped.setdefault(name, []).append(signal)
        ranked = []
        for name, values in grouped.items():
            average = sum(values) / len(values)
            ranked.append(rank_result(f"wifi_broadcast={name}", average, f"{average:.1f} dBm", f"clients={len(values)}"))
        if args.metric == "strongest_average_signal":
            return sorted(ranked, key=lambda item: (-item["value"], item["label"]))
        return sorted(ranked, key=lambda item: (item["value"], item["label"]))

    if args.entity_type == "network" and args.metric == "client_count":
        site_id = require_site_id(args)
        networks = rows(run_named_query("networks", site_id=site_id, insecure=args.insecure))
        network_map = {
            string_value(network.get("id")): string_value(network.get("name")) or "unknown-network"
            for network in networks
            if string_value(network.get("id"))
        }
        clients = [client for client in load_clients(args, include_inactive=args.include_inactive) if is_active_client(client)]
        counts: dict[str, int] = {}
        for client in clients:
            network_id = (
                string_value(client.get("networkId"))
                or string_value(client.get("network_id"))
                or string_value(client.get("last_connection_network_id"))
                or string_value(client.get("lastConnectionNetworkId"))
            )
            if network_id:
                counts[network_id] = counts.get(network_id, 0) + 1
        ranked = [
            rank_result(
                f"network={network_map.get(network_id, network_id)}",
                float(count),
                str(count),
                f"network_id={network_id}",
            )
            for network_id, count in counts.items()
        ]
        return sorted(ranked, key=lambda item: (-item["value"], item["label"]))

    if args.entity_type == "network" and args.metric == "reference_count":
        site_id = require_site_id(args)
        networks = rows(run_named_query("networks", site_id=site_id, insecure=args.insecure))
        wifi = rows(run_named_query("wifi-broadcasts", site_id=site_id, insecure=args.insecure))
        dns = rows(run_named_query("dns-policies", site_id=site_id, insecure=args.insecure))
        firewall = rows(run_named_query("firewall-policies", site_id=site_id, insecure=args.insecure))
        acl = rows(run_named_query("acl-rules", site_id=site_id, insecure=args.insecure))
        ranked = []
        for network in networks:
            network_id = string_value(network.get("id")) or string_value(network.get("_id"))
            if not network_id:
                continue
            count = sum(
                1
                for collection in (wifi, dns, firewall, acl)
                for row in collection
                if row_contains_token(row, network_id)
            )
            if count <= 0:
                continue
            ranked.append(
                rank_result(
                    f"network={string_value(network.get('name')) or network_id}",
                    float(count),
                    str(count),
                    f"network_id={network_id}",
                )
            )
        return sorted(ranked, key=lambda item: (-item["value"], item["label"]))

    if args.entity_type == "switch_port" and args.metric == "errors":
        site_id = require_site_id(args)
        devices = rows(run_named_query("devices", site_id=site_id, insecure=args.insecure))
        ranked = []
        for device in devices:
            device_label = string_value(device.get("name")) or string_value(device.get("model")) or "unknown-device"
            for port in extract_port_rows(device):
                errors = sum_numeric_values(
                    port,
                    ["errors", "errorCount", "rxErrors", "txErrors", "crcErrors", "drops", "dropped", "discarded"],
                )
                if errors <= 0:
                    continue
                port_label = (
                    string_value(port.get("name"))
                    or string_value(port.get("portName"))
                    or string_value(port.get("port"))
                    or string_value(port.get("portIdx"))
                    or "unknown-port"
                )
                ranked.append(
                    rank_result(
                        f"switch_port={device_label} port {port_label}",
                        errors,
                        f"{errors:.0f}",
                        f"device={device_label}",
                    )
                )
        return sorted(ranked, key=lambda item: (-item["value"], item["label"]))

    if args.entity_type == "switch_port" and args.metric == "disconnected_client_count":
        site_id = require_site_id(args)
        devices = rows(run_named_query("devices", site_id=site_id, insecure=args.insecure))
        device_map = {
            string_value(device.get("id")): string_value(device.get("name")) or string_value(device.get("model")) or "unknown"
            for device in devices
            if string_value(device.get("id"))
        }
        clients = load_clients(args, include_inactive=True)
        counts: dict[str, int] = {}
        for client in clients:
            if is_active_client(client):
                continue
            key = switch_port_key(client)
            if key:
                counts[key] = counts.get(key, 0) + 1
        ranked = []
        for key, count in counts.items():
            device_id, port = split_switch_port_key(key)
            device_label = device_map.get(device_id, device_id)
            ranked.append(
                rank_result(
                    f"switch_port={device_label} port {port}",
                    float(count),
                    str(count),
                    f"device={device_label}",
                )
            )
        return sorted(ranked, key=lambda item: (-item["value"], item["label"]))

    if args.entity_type == "switch_port" and args.metric == "flapping":
        site_id = require_site_id(args)
        devices = rows(run_named_query("devices", site_id=site_id, insecure=args.insecure))
        ranked = []
        for device in devices:
            device_label = string_value(device.get("name")) or string_value(device.get("model")) or "unknown-device"
            for port in extract_port_rows(device):
                flaps = sum_numeric_values(
                    port,
                    ["linkFlaps", "link_flaps", "flaps", "upDownCount", "up_down_count", "linkDownCount", "linkUpCount", "stpTransitions", "stateChanges"],
                )
                if flaps <= 0:
                    continue
                port_label = (
                    string_value(port.get("name"))
                    or string_value(port.get("portName"))
                    or string_value(port.get("port"))
                    or string_value(port.get("portIdx"))
                    or "unknown-port"
                )
                ranked.append(rank_result(f"switch_port={device_label} port {port_label}", flaps, f"{flaps:.0f}", f"device={device_label}"))
        return sorted(ranked, key=lambda item: (-item["value"], item["label"]))

    if args.entity_type == "firewall_rule" and args.metric == "hits":
        site_id = require_site_id(args)
        policies = rows(run_named_query("firewall-policies", site_id=site_id, insecure=args.insecure))
        ranked = []
        for policy in policies:
            hits = None
            for key in ("hitCount", "hit_count", "hits", "packetCount", "matchCount", "matchedPackets"):
                hits = numeric_value(policy.get(key))
                if hits is not None and hits > 0:
                    break
            if hits is None and isinstance(policy.get("statistics"), dict):
                stats = policy["statistics"]
                for key in ("hitCount", "hit_count", "hits", "packetCount", "matchCount", "matchedPackets"):
                    hits = numeric_value(stats.get(key))
                    if hits is not None and hits > 0:
                        break
            if hits is None or hits <= 0:
                continue
            label = string_value(policy.get("name")) or string_value(policy.get("id")) or "unknown-rule"
            ranked.append(
                rank_result(
                    f"firewall_rule={label}",
                    hits,
                    f"{hits:.0f}",
                    f"rule_id={string_value(policy.get('id')) or 'unknown'}",
                )
            )
        return sorted(ranked, key=lambda item: (-item["value"], item["label"]))

    if args.entity_type == "firewall_rule" and args.metric == "shadow_risk":
        site_id = require_site_id(args)
        policies = rows(run_named_query("firewall-policies", site_id=site_id, insecure=args.insecure))
        seen: dict[str, int] = {}
        ranked = []
        for index, policy in enumerate(policies, start=1):
            if bool_value(policy.get("enabled")) is False:
                continue
            signature = rule_signature(policy)
            duplicates = seen.get(signature, 0)
            if duplicates > 0:
                label = string_value(policy.get("name")) or string_value(policy.get("id")) or "unknown-rule"
                ranked.append(
                    rank_result(
                        f"firewall_rule={label}",
                        float(duplicates * 100 + index),
                        str(duplicates),
                        f"rule_id={string_value(policy.get('id')) or 'unknown'}, order={index}",
                    )
                )
            seen[signature] = duplicates + 1
        return sorted(ranked, key=lambda item: (-item["value"], item["label"]))

    if args.entity_type == "acl_rule" and args.metric == "ordering_risk":
        site_id = require_site_id(args)
        rules = rows(run_named_query("acl-rules", site_id=site_id, insecure=args.insecure))
        seen: dict[str, int] = {}
        ranked = []
        for index, rule in enumerate(rules, start=1):
            if bool_value(rule.get("enabled")) is False:
                continue
            signature = rule_signature(rule)
            duplicates = seen.get(signature, 0)
            if duplicates > 0:
                label = string_value(rule.get("name")) or string_value(rule.get("id")) or "unknown-rule"
                ranked.append(
                    rank_result(
                        f"acl_rule={label}",
                        float(duplicates * 100 + index),
                        str(duplicates),
                        f"rule_id={string_value(rule.get('id')) or 'unknown'}, order={index}",
                    )
                )
            seen[signature] = duplicates + 1
        return sorted(ranked, key=lambda item: (-item["value"], item["label"]))

    if args.entity_type == "vpn_tunnel" and args.metric in {"down", "up", "stale"}:
        site_id = require_site_id(args)
        tunnels = rows(run_named_query("site-to-site-vpn", site_id=site_id, insecure=args.insecure))
        ranked = []
        for tunnel in tunnels:
            name = (
                string_value(tunnel.get("name"))
                or string_value(tunnel.get("displayName"))
                or string_value(tunnel.get("remoteSiteName"))
                or string_value(tunnel.get("peerName"))
                or "unknown-tunnel"
            )
            state = state_text(tunnel)
            is_up = state_looks_healthy(state)
            last_seen = latest_date(tunnel, ["lastSeen", "last_seen", "lastConnected", "connectedAt", "updatedAt", "lastHandshake", "last_handshake"])
            age_seconds = max(0.0, (datetime.now(last_seen.tzinfo) - last_seen).total_seconds()) if last_seen else 0.0
            if args.metric == "down" and not is_up:
                ranked.append(rank_result(f"vpn_tunnel={name}", age_seconds or 1.0, state or "down", f"last_seen={last_seen.isoformat() if last_seen else 'unknown'}"))
            elif args.metric == "up" and is_up:
                ranked.append(rank_result(f"vpn_tunnel={name}", last_seen.timestamp() if last_seen else 1.0, state or "up", f"last_seen={last_seen.isoformat() if last_seen else 'unknown'}"))
            elif args.metric == "stale" and age_seconds > 0:
                ranked.append(rank_result(f"vpn_tunnel={name}", age_seconds, f"{age_seconds / 60:.0f} min", f"state={state or 'unknown'}"))
        return sorted(ranked, key=lambda item: (-item["value"], item["label"]))

    if args.entity_type == "wan_profile" and args.metric in {"healthy", "unhealthy"}:
        site_id = require_site_id(args)
        profiles = rows(run_named_query("wan-profiles", site_id=site_id, insecure=args.insecure))
        ranked = []
        for profile in profiles:
            name = (
                string_value(profile.get("name"))
                or string_value(profile.get("displayName"))
                or string_value(profile.get("ispName"))
                or "unknown-wan"
            )
            state = state_text(profile)
            packet_loss = 0.0
            latency = 0.0
            jitter = 0.0
            for source in (profile, profile.get("health"), profile.get("statistics"), profile.get("stats")):
                if not isinstance(source, dict):
                    continue
                packet_loss = packet_loss or numeric_value(source.get("packetLoss")) or numeric_value(source.get("packet_loss")) or numeric_value(source.get("lossPct")) or 0.0
                latency = latency or numeric_value(source.get("latency")) or numeric_value(source.get("avgLatency")) or numeric_value(source.get("latencyMs")) or 0.0
                jitter = jitter or numeric_value(source.get("jitter")) or numeric_value(source.get("jitterMs")) or 0.0
            penalty = (0 if state_looks_healthy(state) else 100) + packet_loss * 5 + latency / 10 + jitter / 5
            healthy_score = max(0.0, 100 - penalty)
            value = healthy_score if args.metric == "healthy" else penalty
            if value <= 0:
                continue
            ranked.append(
                rank_result(
                    f"wan_profile={name}",
                    value,
                    f"{value:.0f}",
                    f"state={state or 'unknown'}, loss={packet_loss:.0f}%, latency={latency:.0f}ms, jitter={jitter:.0f}ms",
                )
            )
        return sorted(ranked, key=lambda item: (-item["value"], item["label"]))

    if args.entity_type == "dns_policy" and args.metric == "client_count":
        site_id = require_site_id(args)
        policies = rows(run_named_query("dns-policies", site_id=site_id, insecure=args.insecure))
        ranked = []
        for policy in policies:
            count = target_count(policy)
            if count <= 0:
                continue
            label = string_value(policy.get("name")) or string_value(policy.get("id")) or "unknown-policy"
            ranked.append(
                rank_result(
                    f"dns_policy={label}",
                    float(count),
                    str(count),
                    f"policy_id={string_value(policy.get('id')) or 'unknown'}",
                )
            )
        return sorted(ranked, key=lambda item: (-item["value"], item["label"]))

    if args.entity_type == "app_block" and args.metric == "target_count":
        site_ref = normalized_site_ref(args)
        payload = run_unifi_request(
            "GET",
            f"/proxy/network/v2/api/site/{site_ref}/firewall-app-blocks",
            insecure=args.insecure,
        )
        ranked = []
        for rule in rows(payload):
            count = max(target_count(rule), len(rule.get("client_macs", [])) if isinstance(rule.get("client_macs"), list) else 0)
            if count <= 0:
                continue
            label = string_value(rule.get("name")) or string_value(rule.get("_id")) or "unknown-app-block"
            ranked.append(rank_result(f"app_block={label}", float(count), str(count), f"site_ref={site_ref}"))
        return sorted(ranked, key=lambda item: (-item["value"], item["label"]))

    raise SystemExit(f"unsupported entity_type/metric combination: {args.entity_type}/{args.metric}")


# Dispatches the selected bottom-up ranking.
def main() -> int:
    args = parse_args()
    ranked = compute_rankings(args)
    payload = {
        "kind": "unifi_network_rankings",
        "entity_type": args.entity_type,
        "metric": args.metric,
        "result_count": min(len(ranked), max(1, min(args.limit, 20))),
        "results": ranked[: max(1, min(args.limit, 20))],
    }
    json.dump(payload, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

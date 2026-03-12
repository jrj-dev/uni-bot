#!/usr/bin/env python3
"""Higher-level read-only UniFi summaries built on named queries."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from collections import Counter

from _paths import SCRIPT_DIR


NAMED_QUERY_SCRIPT = SCRIPT_DIR / "named_query.py"
SITE_SUMMARIES = {"overview", "clients", "networks", "wifi", "firewall", "security"}
SITE_SUMMARIES = SITE_SUMMARIES | {"devices", "pending-devices", "guest-access"}


# Parses CLI arguments for higher-level UniFi summary commands.
def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run a higher-level UniFi summary using read-only named queries."
    )
    parser.add_argument(
        "summary",
        choices=sorted(SITE_SUMMARIES),
        help="Summary to generate.",
    )
    parser.add_argument("--site-id", help="Site ID for site-scoped summaries.")
    parser.add_argument(
        "--site-ref",
        help="Site internal reference (for example 'default') to resolve into a site ID.",
    )
    parser.add_argument(
        "--insecure",
        action="store_true",
        help="Pass through for self-signed TLS certificates.",
    )
    return parser.parse_args()


# Returns the UUID site ID required for summary queries.
def require_site_id(args: argparse.Namespace) -> str:
    if args.site_id:
        return args.site_id
    if not args.site_ref:
        raise SystemExit(f"{args.summary} requires --site-id or --site-ref")
    # Summary mode shares the same convenience as named queries: resolve a human
    # friendly site reference once, then use the UUID for all downstream calls.
    sites = rows(load_named_query("sites", insecure=args.insecure))
    for site in sites:
        if site.get("internalReference") == args.site_ref:
            site_id = site.get("id")
            if isinstance(site_id, str) and site_id:
                return site_id
            break
    raise SystemExit(f"site reference not found: {args.site_ref}")


# Loads a named UniFi query through the existing CLI wrapper.
def load_named_query(query: str, *, site_id: str | None = None, insecure: bool) -> dict:
    # Higher-level summaries deliberately build on the existing CLI wrapper so the
    # request rules, pagination behavior, and auth handling stay in one place.
    cmd = [sys.executable, str(NAMED_QUERY_SCRIPT), query, "--all-pages"]
    if site_id:
        cmd.extend(["--site-id", site_id])
    if insecure:
        cmd.append("--insecure")
    result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        if result.stderr:
            sys.stderr.write(result.stderr)
        raise SystemExit(result.returncode)
    return json.loads(result.stdout)


# Extracts row dictionaries from the standard UniFi response envelope.
def rows(payload: dict) -> list[dict]:
    data = payload.get("data", [])
    if isinstance(data, list):
        return [item for item in data if isinstance(item, dict)]
    return []


# Returns the best display name available for a UniFi row.
def safe_name(item: dict, fallback: str) -> str:
    return item.get("name") or item.get("model") or fallback


# Returns true when a client row looks currently active.
def is_active_client(item: dict) -> bool:
    for key in ("active", "isActive", "is_online", "isOnline"):
        value = item.get(key)
        if isinstance(value, bool):
            return value
    state = str(item.get("state") or item.get("status") or item.get("connectionState") or "").lower()
    if any(word in state for word in ("offline", "disconnected", "inactive")):
        return False
    return True


# Returns true when a device row looks currently online.
def is_online_device(item: dict) -> bool:
    state = str(item.get("state") or item.get("status") or item.get("connectionState") or "").lower()
    if not state:
        return True
    return not any(word in state for word in ("offline", "disconnected", "inactive"))


# Prints a compact overall network summary.
def summarize_overview(site_id: str, insecure: bool) -> int:
    sites = rows(load_named_query("sites", insecure=insecure))
    devices = rows(load_named_query("devices", site_id=site_id, insecure=insecure))
    clients = rows(load_named_query("clients", site_id=site_id, insecure=insecure))
    networks = rows(load_named_query("networks", site_id=site_id, insecure=insecure))
    wifi = rows(load_named_query("wifi-broadcasts", site_id=site_id, insecure=insecure))
    pending = rows(load_named_query("pending-devices", insecure=insecure))

    device_map = {item.get("id"): item for item in devices if item.get("id")}
    uplinks = Counter(
        client.get("uplinkDeviceId")
        for client in clients
        if client.get("uplinkDeviceId")
        and is_active_client(client)
        and is_online_device(device_map.get(client.get("uplinkDeviceId"), {}))
    )

    print("Overview")
    print(f"- sites: {len(sites)}")
    print(f"- devices: {len(devices)}")
    print(f"- clients: {len(clients)}")
    print(f"- networks: {len(networks)}")
    print(f"- wifi broadcasts: {len(wifi)}")
    print(f"- pending devices: {len(pending)}")
    if uplinks:
        print("- busiest uplinks:")
        for device_id, count in uplinks.most_common(5):
            device = device_map.get(device_id, {})
            print(f"  {safe_name(device, device_id)}: {count}")
    return 0


# Prints a compact client inventory summary.
def summarize_clients(site_id: str, insecure: bool) -> int:
    devices = rows(load_named_query("devices", site_id=site_id, insecure=insecure))
    clients = rows(load_named_query("clients", site_id=site_id, insecure=insecure))
    device_map = {item.get("id"): item for item in devices if item.get("id")}
    active_clients = [item for item in clients if is_active_client(item)]
    by_type = Counter(item.get("type", "UNKNOWN") for item in active_clients)
    by_access = Counter(item.get("access", {}).get("type", "UNKNOWN") for item in active_clients)
    by_uplink = Counter(
        item.get("uplinkDeviceId")
        for item in active_clients
        if item.get("uplinkDeviceId")
        and is_online_device(device_map.get(item.get("uplinkDeviceId"), {}))
    )

    print("Clients")
    print(f"- total: {len(active_clients)}")
    print("- by type:")
    for label, count in by_type.most_common():
        print(f"  {label}: {count}")
    print("- by access:")
    for label, count in by_access.most_common():
        print(f"  {label}: {count}")
    print("- by uplink:")
    for device_id, count in by_uplink.most_common(10):
        device = device_map.get(device_id, {})
        print(f"  {safe_name(device, device_id)}: {count}")
    return 0


# Prints a compact network and VLAN summary.
def summarize_networks(site_id: str, insecure: bool) -> int:
    networks = rows(load_named_query("networks", site_id=site_id, insecure=insecure))
    print("Networks")
    for network in networks:
        default = " default" if network.get("default") else ""
        enabled = "enabled" if network.get("enabled", True) else "disabled"
        vlan = network.get("vlanId", "n/a")
        print(f"- {safe_name(network, 'unnamed network')}: vlan={vlan}, {enabled}{default}")
    return 0


# Prints a compact WiFi summary.
def summarize_wifi(site_id: str, insecure: bool) -> int:
    networks = rows(load_named_query("networks", site_id=site_id, insecure=insecure))
    wifi = rows(load_named_query("wifi-broadcasts", site_id=site_id, insecure=insecure))
    network_map = {item.get("id"): safe_name(item, "unknown network") for item in networks if item.get("id")}

    print("WiFi")
    for broadcast in wifi:
        network_ref = broadcast.get("network", {})
        network_name = "native"
        if network_ref.get("type") == "SPECIFIC":
            network_name = network_map.get(network_ref.get("networkId"), "unknown network")
        security = broadcast.get("securityConfiguration", {}).get("type", "UNKNOWN")
        freqs = broadcast.get("broadcastingFrequenciesGHz", [])
        freq_label = ",".join(str(item) for item in freqs) if freqs else "default"
        state = "enabled" if broadcast.get("enabled", True) else "disabled"
        print(
            f"- {safe_name(broadcast, 'unnamed wifi')}: {state}, security={security}, "
            f"network={network_name}, ghz={freq_label}"
        )
    return 0


# Prints a compact firewall summary.
def summarize_firewall(site_id: str, insecure: bool) -> int:
    policies = rows(load_named_query("firewall-policies", site_id=site_id, insecure=insecure))
    zones = rows(load_named_query("firewall-zones", site_id=site_id, insecure=insecure))
    zone_map = {item.get("id"): safe_name(item, "unknown zone") for item in zones if item.get("id")}
    actions = Counter()
    zone_pairs = Counter()

    for policy in policies:
        # UniFi nests the action verb in an object, so flatten it here before counting.
        action = policy.get("action", {})
        action_name = action.get("type", "UNKNOWN") if isinstance(action, dict) else str(action)
        actions[action_name] += 1
        source = zone_map.get(policy.get("source", {}).get("zoneId"), "unknown")
        dest = zone_map.get(policy.get("destination", {}).get("zoneId"), "unknown")
        zone_pairs[(source, dest)] += 1

    print("Firewall")
    print("- actions:")
    for action, count in actions.most_common():
        print(f"  {action}: {count}")
    print("- top zone pairs:")
    for (source, dest), count in zone_pairs.most_common(10):
        print(f"  {source} -> {dest}: {count}")
    return 0


# Prints a compact security summary.
def summarize_security(site_id: str, insecure: bool) -> int:
    acl_rules = rows(load_named_query("acl-rules", site_id=site_id, insecure=insecure))
    dns_policies = rows(load_named_query("dns-policies", site_id=site_id, insecure=insecure))
    vpn_servers = rows(load_named_query("vpn-servers", site_id=site_id, insecure=insecure))
    site_to_site = rows(load_named_query("site-to-site-vpn", site_id=site_id, insecure=insecure))
    vouchers = rows(load_named_query("hotspot-vouchers", site_id=site_id, insecure=insecure))
    radius_profiles = rows(load_named_query("radius-profiles", site_id=site_id, insecure=insecure))

    print("Security")
    print(f"- acl rules: {len(acl_rules)}")
    print(f"- dns policies: {len(dns_policies)}")
    print(f"- vpn servers: {len(vpn_servers)}")
    print(f"- site-to-site tunnels: {len(site_to_site)}")
    print(f"- hotspot vouchers: {len(vouchers)}")
    print(f"- radius profiles: {len(radius_profiles)}")
    return 0


# Prints a compact UniFi device inventory summary.
def summarize_devices(site_id: str, insecure: bool) -> int:
    devices = rows(load_named_query("devices", site_id=site_id, insecure=insecure))
    by_state = Counter(item.get("state", "UNKNOWN") for item in devices)
    by_model = Counter(item.get("model", "unknown") for item in devices)
    by_firmware = Counter(item.get("firmwareVersion", "unknown") for item in devices)

    print("Devices")
    print(f"- total: {len(devices)}")
    print("- by state:")
    for label, count in sorted(by_state.items()):
        print(f"  {label}: {count}")
    print("- by model:")
    for label, count in by_model.most_common():
        print(f"  {label}: {count}")
    print("- by firmware:")
    for label, count in by_firmware.most_common():
        print(f"  {label}: {count}")
    return 0


# Prints a compact summary of pending UniFi devices.
def summarize_pending_devices(site_id: str, insecure: bool) -> int:
    del site_id
    pending = rows(load_named_query("pending-devices", insecure=insecure))
    print("Pending Devices")
    print(f"- total: {len(pending)}")
    for device in pending:
        print(f"  {safe_name(device, 'unnamed device')}: {device.get('model', 'unknown')}")
    return 0


# Prints a compact guest access summary.
def summarize_guest_access(site_id: str, insecure: bool) -> int:
    clients = rows(load_named_query("clients", site_id=site_id, insecure=insecure))
    wifi = rows(load_named_query("wifi-broadcasts", site_id=site_id, insecure=insecure))
    guest_clients = [
        item
        for item in clients
        if item.get("access", {}).get("type") == "GUEST"
    ]
    guest_ssids = [
        item for item in wifi
        if "guest" in safe_name(item, "").lower()
    ]

    print("Guest Access")
    print(f"- guest clients: {len(guest_clients)}")
    print(f"- guest-like ssids: {len(guest_ssids)}")
    if guest_ssids:
        print("- ssids:")
        for item in guest_ssids:
            print(f"  {safe_name(item, 'unnamed wifi')}")
    return 0


# Dispatches the selected summary mode.
def main() -> int:
    args = parse_args()
    site_id = require_site_id(args)
    if args.summary == "overview":
        return summarize_overview(site_id, args.insecure)
    if args.summary == "clients":
        return summarize_clients(site_id, args.insecure)
    if args.summary == "networks":
        return summarize_networks(site_id, args.insecure)
    if args.summary == "wifi":
        return summarize_wifi(site_id, args.insecure)
    if args.summary == "firewall":
        return summarize_firewall(site_id, args.insecure)
    if args.summary == "devices":
        return summarize_devices(site_id, args.insecure)
    if args.summary == "pending-devices":
        return summarize_pending_devices(site_id, args.insecure)
    if args.summary == "guest-access":
        return summarize_guest_access(site_id, args.insecure)
    return summarize_security(site_id, args.insecure)


if __name__ == "__main__":
    raise SystemExit(main())

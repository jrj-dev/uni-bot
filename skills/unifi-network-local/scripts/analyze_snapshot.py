#!/usr/bin/env python3
"""Summarize a captured UniFi snapshot for troubleshooting."""

from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path


# Parses CLI arguments for snapshot analysis.
def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Analyze a saved UniFi snapshot directory."
    )
    parser.add_argument(
        "snapshot_dir",
        help="Path to a snapshot directory created by capture_snapshot.py",
    )
    return parser.parse_args()


# Loads a JSON file from disk.
def load_json(path: Path) -> dict:
    if not path.exists():
        return {}
    return json.loads(path.read_text())


# Extracts row dictionaries from a UniFi snapshot payload.
def extract_rows(payload: dict) -> list[dict]:
    data = payload.get("data", [])
    if isinstance(data, list):
        return [item for item in data if isinstance(item, dict)]
    return []


# Returns the best display name available for a snapshot row.
def safe_name(item: dict, fallback: str) -> str:
    return item.get("name") or item.get("model") or fallback


# Returns the normalized action name for a policy row.
def policy_action_name(policy: dict) -> str:
    action = policy.get("action", "UNKNOWN")
    if isinstance(action, dict):
        return str(action.get("type", "UNKNOWN"))
    return str(action)


# Dispatches the snapshot analysis flow.
def main() -> int:
    args = parse_args()
    snap = Path(args.snapshot_dir)
    devices = extract_rows(load_json(snap / "devices.json"))
    clients = extract_rows(load_json(snap / "clients.json"))
    sites = extract_rows(load_json(snap / "sites.json"))
    networks = extract_rows(load_json(snap / "networks.json"))
    wifi_broadcasts = extract_rows(load_json(snap / "wifi_broadcasts.json"))
    firewall_policies = extract_rows(load_json(snap / "firewall_policies.json"))
    firewall_zones = extract_rows(load_json(snap / "firewall_zones.json"))
    device_tags = extract_rows(load_json(snap / "device_tags.json"))
    wan_profiles = extract_rows(load_json(snap / "wan_profiles.json"))
    vpn_servers = extract_rows(load_json(snap / "vpn_servers.json"))
    site_to_site_vpn = extract_rows(load_json(snap / "site_to_site_vpn.json"))
    radius_profiles = extract_rows(load_json(snap / "radius_profiles.json"))
    pending_devices = extract_rows(load_json(snap / "pending_devices.json"))
    dpi_categories = extract_rows(load_json(snap / "dpi_categories.json"))
    dpi_applications = extract_rows(load_json(snap / "dpi_applications.json"))
    countries = extract_rows(load_json(snap / "countries.json"))

    device_map = {device.get("id"): device for device in devices if device.get("id")}
    state_counts = Counter(device.get("state", "UNKNOWN") for device in devices)
    firmware_counts = Counter(
        device.get("firmwareVersion", "unknown") for device in devices
    )
    model_counts = Counter(device.get("model", "unknown") for device in devices)

    client_counts = Counter()
    client_types = Counter(client.get("type", "UNKNOWN") for client in clients)
    for client in clients:
        uplink = client.get("uplinkDeviceId")
        if uplink:
            client_counts[uplink] += 1

    print(f"Snapshot: {snap}")
    print(f"Sites: {len(sites)}")
    print(f"Devices: {len(devices)}")
    print(f"Clients in page: {len(clients)}")
    if networks:
        print(f"Networks: {len(networks)}")
    if wifi_broadcasts:
        print(f"WiFi broadcasts: {len(wifi_broadcasts)}")
    if firewall_policies:
        print(f"Firewall policies: {len(firewall_policies)}")
    if firewall_zones:
        print(f"Firewall zones: {len(firewall_zones)}")
    if pending_devices:
        print(f"Pending devices: {len(pending_devices)}")

    if state_counts:
        print("\nDevice states:")
        for state, count in sorted(state_counts.items()):
            print(f"- {state}: {count}")

    offline = [d for d in devices if d.get("state") != "ONLINE"]
    if offline:
        print("\nNon-online devices:")
        for device in offline:
            print(
                f"- {safe_name(device, 'unnamed device')} ({device.get('model', 'unknown')}): "
                f"{device.get('state', 'UNKNOWN')}"
            )

    if model_counts:
        print("\nDevice models:")
        for model, count in model_counts.most_common():
            print(f"- {model}: {count}")

    if firmware_counts:
        print("\nFirmware versions:")
        for version, count in firmware_counts.most_common():
            print(f"- {version}: {count}")

    if client_types:
        print("\nClient types:")
        for client_type, count in client_types.most_common():
            print(f"- {client_type}: {count}")

    if client_counts:
        print("\nTop uplink devices by connected clients:")
        for device_id, count in client_counts.most_common(5):
            device = device_map.get(device_id, {})
            print(
                f"- {safe_name(device, device_id)} ({device.get('model', 'unknown')}): {count}"
            )

    if networks:
        network_types = Counter(network.get("type", "UNKNOWN") for network in networks)
        print("\nNetwork types:")
        for network_type, count in network_types.most_common():
            print(f"- {network_type}: {count}")

    if wifi_broadcasts:
        enabled_broadcasts = sum(1 for item in wifi_broadcasts if item.get("enabled", True))
        print("\nWiFi broadcasts:")
        print(f"- enabled: {enabled_broadcasts}")
        print(f"- disabled: {len(wifi_broadcasts) - enabled_broadcasts}")

    if firewall_policies:
        policy_actions = Counter(
            policy_action_name(policy) for policy in firewall_policies
        )
        print("\nFirewall policy actions:")
        for action, count in policy_actions.most_common():
            print(f"- {action}: {count}")

    if firewall_zones:
        print("\nFirewall zones:")
        for zone in firewall_zones[:10]:
            print(f"- {safe_name(zone, 'unnamed zone')}")

    if device_tags:
        print("\nDevice tags:")
        for tag in device_tags[:10]:
            device_ids = tag.get("deviceIds", [])
            attached = len(device_ids) if isinstance(device_ids, list) else 0
            print(f"- {safe_name(tag, 'unnamed tag')}: {attached} devices")

    if wan_profiles:
        print("\nWAN profiles:")
        for profile in wan_profiles[:10]:
            print(f"- {safe_name(profile, 'unnamed wan profile')}")

    if vpn_servers:
        print("\nVPN servers:")
        for server in vpn_servers[:10]:
            print(f"- {safe_name(server, 'unnamed vpn server')}")

    if site_to_site_vpn:
        print(f"\nSite-to-site VPN tunnels: {len(site_to_site_vpn)}")

    if radius_profiles:
        print("\nRADIUS profiles:")
        for profile in radius_profiles[:10]:
            print(f"- {safe_name(profile, 'unnamed radius profile')}")

    if pending_devices:
        print("\nPending devices:")
        for device in pending_devices[:10]:
            print(f"- {safe_name(device, 'unnamed device')} ({device.get('model', 'unknown')})")

    if dpi_categories:
        print(f"\nDPI categories: {len(dpi_categories)}")

    if dpi_applications:
        print(f"DPI applications: {len(dpi_applications)}")

    if countries:
        print(f"Countries reference entries: {len(countries)}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

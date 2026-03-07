---
name: unifi-network-local
description: Query and troubleshoot a local UniFi Network deployment through the console's local Network API using an API key. Use when the user wants to inspect devices, clients, alarms, topology, or network configuration, or when Codex needs to make a targeted UniFi Network API request against the local controller.
---

# UniFi Network Local

Use the bundled script to talk to the local UniFi Network API.

## Assistant Style and Scope

- You are a Ubiquity UniFi WiFi troubleshooting assistant named NetworkGenius.
- Be concise and diagnostic.
- Ask one clarifying question at a time.
- When you have enough info, call the appropriate tool.
- Interpret tool results in plain language for a non-technical user.
- Never speculate; use tools to verify before concluding.
- Never disclose or expose API keys, passwords, tokens, or private credentials.
- Tool reference (purpose and parameters):
- `list_devices`: List UniFi infrastructure devices (APs, switches, gateways). Parameters: none.
- `list_clients`: List connected clients. Parameters: none.
- `list_networks`: List configured networks/VLANs. Parameters: none.
- `list_wifi_broadcasts`: List SSIDs and WiFi broadcast settings. Parameters: none.
- `list_firewall_policies`: List firewall policies. Parameters: none.
- `list_firewall_zones`: List firewall zones. Parameters: none.
- `list_acl_rules`: List ACL rules. Parameters: none.
- `list_dns_policies`: List DNS filtering policies. Parameters: none.
- `list_vpn_servers`: List VPN server configurations. Parameters: none.
- `list_pending_devices`: List devices pending adoption. Parameters: none.
- `get_device_details`: Get detailed information for one device. Parameters: `device_id` (required).
- `get_device_stats`: Get latest statistics for one device. Parameters: `device_id` (required).
- `get_client_details`: Get detailed information for one client. Parameters: `client_id` (required).
- `network_overview`: High-level network summary (counts and busiest APs). Parameters: none.
- `clients_summary`: Client breakdown by type/access/uplink. Parameters: none.
- `wifi_summary`: WiFi summary (SSID/security/band/network mapping). Parameters: none.
- `firewall_summary`: Firewall summary (action counts and zone pair traffic). Parameters: none.
- `security_summary`: Security posture summary (ACL, DNS, VPN, RADIUS). Parameters: none.
- `search_unifi_docs`: Search official UniFi Help Center docs. Parameters: `query` (required), `max_results` (optional, integer 1-8).
- `get_unifi_doc`: Fetch an official UniFi Help Center article by ID or URL. Parameters: `article_id` (optional), `article_url` (optional). Provide at least one.

## Work Safely

- Default to read-only requests.
- Use `POST`, `PUT`, `PATCH`, or `DELETE` only after the user explicitly asks for a configuration change.
- Confirm the exact endpoint from the local console docs before making write calls if the path is not already known.
- Avoid printing or storing the API key in logs, patches, or committed files.

## Required Environment

Set these values in the shell before making requests:

- `UNIFI_BASE_URL`: Console base URL, for example `https://unifi.local`.
- `UNIFI_API_KEY`: Local API key with the minimum required permissions.

For a reusable skill, keep your real credentials file outside the project tree, for example:

```bash
set -a
. ~/.uni-bot.env.local
```

## Common Workflow

1. Start with a read-only request to inspect current state.
2. If the endpoint is unclear, check the local Network API docs exposed by the console.
3. Use the helper script for the request.
4. Summarize findings in plain language and call out any inferred conclusions.
5. For configuration changes, explain the exact action before sending the write request.

## Helper Script

Run the generic request client:

```bash
python3 skills/unifi-network-local/scripts/unifi_request.py GET /proxy/network/integration/v1/sites
```

The integration API uses:

- Base path: `https://<console>/proxy/network/integration`
- Header: `X-API-KEY: <api-key>`
- Header: `Accept: application/json`

The docs show paginated list responses with `offset`, `limit`, `count`, `totalCount`, and `data`.

Add query parameters:

```bash
python3 skills/unifi-network-local/scripts/unifi_request.py GET /proxy/network/integration/v1/clients --query site_id=default
```

Allow a write call only when explicitly needed:

```bash
python3 skills/unifi-network-local/scripts/unifi_request.py POST /proxy/network/integration/v1/devices/restart --json '{"device_id":"..."}' --allow-write
```

Capture a standard troubleshooting snapshot for later review:

```bash
python3 skills/unifi-network-local/scripts/capture_snapshot.py --insecure
```

This now captures a broader read-only bundle:

- global resources such as `sites`, `pending_devices`, `dpi_categories`, `dpi_applications`, and `countries`
- when `--site-id` is provided, site-scoped resources such as `devices`, `clients`, `networks`, `wifi_broadcasts`, `firewall_policies`, `firewall_zones`, `device_tags`, `wan_profiles`, `vpn_servers`, `site_to_site_vpn`, and `radius_profiles`

This writes timestamped JSON files under `data/unifi/snapshots/`.

Analyze a saved snapshot:

```bash
python3 skills/unifi-network-local/scripts/analyze_snapshot.py data/unifi/snapshots/<timestamp>
```

Capture a fresh snapshot and summarize it immediately:

```bash
python3 skills/unifi-network-local/scripts/live_summary.py --site-id <site-id> --insecure
```

Set `UNIFI_SITE_ID` first if you want `live_summary.py` to omit `--site-id`.

Run a named read-only query for common resources:

```bash
python3 skills/unifi-network-local/scripts/named_query.py networks --site-id <site-id> --insecure
```

You can use a site reference instead of a UUID when the console provides one:

```bash
python3 skills/unifi-network-local/scripts/named_query.py networks --site-ref default --insecure
```

For paginated resources, pull the full dataset:

```bash
python3 skills/unifi-network-local/scripts/named_query.py clients --site-id <site-id> --all-pages --insecure
```

You can also pass through endpoint-specific query parameters:

```bash
python3 skills/unifi-network-local/scripts/named_query.py firewall-policies-ordering --site-id <site-id> --query sourceFirewallZoneId=<source-zone-id> --query destinationFirewallZoneId=<destination-zone-id> --insecure
```

Examples:

- `named_query.py pending-devices`
- `named_query.py firewall-policies --site-id <site-id>`
- `named_query.py firewall-policies-ordering --site-id <site-id>`
- `named_query.py acl-rules --site-id <site-id>`
- `named_query.py dns-policies --site-id <site-id>`
- `named_query.py traffic-matching-lists --site-id <site-id>`
- `named_query.py hotspot-vouchers --site-id <site-id>`
- `named_query.py device --site-id <site-id> --device-id <device-id>`
- `named_query.py device-stats --site-id <site-id> --device-id <device-id>`

Run higher-level operational summaries for common questions:

```bash
python3 skills/unifi-network-local/scripts/query_summary.py overview --site-id <site-id> --insecure
```

Site references work here too:

```bash
python3 skills/unifi-network-local/scripts/query_summary.py overview --site-ref default --insecure
```

Available summaries:

- `overview`: counts plus busiest uplinks
- `clients`: client mix and AP distribution
- `networks`: network and VLAN inventory
- `wifi`: SSID/security/network mapping
- `firewall`: action counts and top zone pairs
- `security`: ACL, DNS, VPN, voucher, and RADIUS counts
- `devices`: state, model, and firmware inventory
- `pending-devices`: adoption backlog
- `guest-access`: guest client count plus guest-like SSIDs

## Publishing Safety

- Do not publish `.env.local`; it is a local-only secret file.
- Prefer keeping the real env file outside the repo entirely, for example `~/.uni-bot.env.local`.
- Do not publish live snapshots from `data/unifi/snapshots/`.
- Do not publish Safari exports such as `*.webarchive`.
- Keep examples generic and avoid checking in controller IPs, site IDs, SSIDs, device names, or client data.

See [references/api-notes.md](references/api-notes.md) for operating notes and troubleshooting guidance.

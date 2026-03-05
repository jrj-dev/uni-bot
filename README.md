# uni-bot

`uni-bot` is a local UniFi Network troubleshooting assistant and script bundle.

It is designed to inspect and summarize UniFi Network state through the local integration API, using an API key and read-only queries by default.

## What It Is

This repository currently centers on the `unifi-network-local` skill and helper scripts under:

- `skills/unifi-network-local/scripts`

The tooling is built for:

- pulling inventory and operational data from UniFi Network
- running named queries for common resources
- capturing snapshot bundles for offline analysis
- generating concise, higher-level summaries from raw API responses

## Current Access Mode

Current default behavior is **read-only**.

- `GET`, `HEAD`, and `OPTIONS` are allowed by default.
- Write methods (`POST`, `PUT`, `PATCH`, `DELETE`) are blocked unless you explicitly pass `--allow-write` to `unifi_request.py`.
- Operational guidance in this project is to only perform write operations with explicit user approval.

## API Access and Endpoint Coverage

Base URL shape:

- `https://<console>/proxy/network/integration`

Primary auth headers:

- `X-API-Key: <api-key>`
- `Accept: application/json`

### Global read endpoints

- `/proxy/network/integration/v1/sites`
- `/proxy/network/integration/v1/pending-devices`
- `/proxy/network/integration/v1/dpi/categories`
- `/proxy/network/integration/v1/dpi/applications`
- `/proxy/network/integration/v1/countries`

### Site-scoped read endpoints

- `/proxy/network/integration/v1/sites/{site_id}/devices`
- `/proxy/network/integration/v1/sites/{site_id}/clients`
- `/proxy/network/integration/v1/sites/{site_id}/networks`
- `/proxy/network/integration/v1/sites/{site_id}/wifi/broadcasts`
- `/proxy/network/integration/v1/sites/{site_id}/hotspot/vouchers`
- `/proxy/network/integration/v1/sites/{site_id}/firewall/policies`
- `/proxy/network/integration/v1/sites/{site_id}/firewall/policies/ordering`
- `/proxy/network/integration/v1/sites/{site_id}/firewall/zones`
- `/proxy/network/integration/v1/sites/{site_id}/acl-rules`
- `/proxy/network/integration/v1/sites/{site_id}/acl-rules/ordering`
- `/proxy/network/integration/v1/sites/{site_id}/dns/policies`
- `/proxy/network/integration/v1/sites/{site_id}/traffic-matching-lists`
- `/proxy/network/integration/v1/sites/{site_id}/device-tags`
- `/proxy/network/integration/v1/sites/{site_id}/wans`
- `/proxy/network/integration/v1/sites/{site_id}/vpn/servers`
- `/proxy/network/integration/v1/sites/{site_id}/vpn/site-to-site-tunnels`
- `/proxy/network/integration/v1/sites/{site_id}/radius/profiles`

### Resource-by-ID read endpoints

- `/proxy/network/integration/v1/sites/{site_id}/devices/{device_id}`
- `/proxy/network/integration/v1/sites/{site_id}/devices/{device_id}/statistics/latest`
- `/proxy/network/integration/v1/sites/{site_id}/clients/{client_id}`
- `/proxy/network/integration/v1/sites/{site_id}/networks/{network_id}`
- `/proxy/network/integration/v1/sites/{site_id}/networks/{network_id}/references`
- `/proxy/network/integration/v1/sites/{site_id}/wifi/broadcasts/{wifi_broadcast_id}`
- `/proxy/network/integration/v1/sites/{site_id}/hotspot/vouchers/{voucher_id}`
- `/proxy/network/integration/v1/sites/{site_id}/firewall/policies/{firewall_policy_id}`
- `/proxy/network/integration/v1/sites/{site_id}/firewall/zones/{firewall_zone_id}`
- `/proxy/network/integration/v1/sites/{site_id}/acl-rules/{acl_rule_id}`
- `/proxy/network/integration/v1/sites/{site_id}/dns/policies/{dns_policy_id}`
- `/proxy/network/integration/v1/sites/{site_id}/traffic-matching-lists/{traffic_matching_list_id}`

## Environment Setup (`.env.local`)

Create a local environment file from the provided example:

```bash
cp .env.local.example .env.local
```

Then edit `.env.local` and set real values:

```dotenv
UNIFI_BASE_URL=https://your-console-hostname-or-ip
UNIFI_API_KEY=your-local-api-key
```

Optional variable used by `live_summary.py`:

```dotenv
UNIFI_SITE_ID=your-site-uuid
```

Load values into your shell:

```bash
set -a
. ./.env.local
set +a
```

Notes:

- `.env.local` is for local use only and should not be committed.
- `.env.local.example` is the template to distribute with the project.

## Quick Start

List sites:

```bash
python3 skills/unifi-network-local/scripts/unifi_request.py GET /proxy/network/integration/v1/sites
```

Run a named query:

```bash
python3 skills/unifi-network-local/scripts/named_query.py networks --site-ref default
```

Capture a troubleshooting snapshot:

```bash
python3 skills/unifi-network-local/scripts/capture_snapshot.py --site-id <site-id>
```

Generate an overview summary:

```bash
python3 skills/unifi-network-local/scripts/query_summary.py overview --site-ref default
```

## Safety for Distribution

When distributing this repository:

- keep `.env.local` out of version control
- never publish real API keys
- avoid publishing live snapshot data from `data/unifi/snapshots/`
- avoid publishing controller-specific identifiers (site IDs, device names, SSIDs, client info)

## Testing

Run tests:

```bash
python3 -m unittest -v tests/test_unifi_network_local.py
```

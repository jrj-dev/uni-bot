# uni-bot

`uni-bot` is a local UniFi Network troubleshooting assistant that lets you chat with an AI about your real network data.

It includes Python scripts for querying the UniFi local integration API and a native iOS app (**Network Genius**) that wraps those capabilities into a conversational interface powered by Claude or ChatGPT.

## What It Is

### Network Genius (iOS App)

A SwiftUI chat app in `NetworkGenius/` that connects to your UniFi console over your local network and feeds real data to an LLM so you can ask natural-language questions about your network.

- On your home WiFi: queries the console directly, LLM answers with real data
- Off-network: LLM provides general networking advice
- Supports both Claude (Anthropic) and OpenAI as LLM providers
- All API keys stored in iOS Keychain, never in plaintext
- Read-only access to the UniFi console
- Sensitive values are redacted from in-app/Xcode debug logs

**To build:** Open `NetworkGenius/NetworkGenius.xcodeproj` in Xcode 15.4+, set your development team, and run on a device or simulator (iOS 17.0+).

### Python Scripts

The `unifi-network-local` skill and helper scripts under `skills/unifi-network-local/scripts/` provide the original CLI tooling:

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

## Network Genius iOS App

### First Launch

1. Open the app and enter your UniFi console URL (e.g. `https://192.168.1.1`)
2. Enter your UniFi API key (created in UniFi Console under Settings > API)
3. Optionally enter your site ID (if omitted, the app auto-selects `default` or the first returned site)
4. Choose Claude or OpenAI and enter the corresponding API key
5. Start chatting about your network

### Privacy and Security Notes (iOS)

- UniFi, Claude, and OpenAI API keys are stored in iOS Keychain only.
- The app never intentionally logs raw API keys; debug log output is sanitized to redact key-like values.
- `Share Device Context With AI` is **off by default**.
- When enabled, the app sends masked context (for example masked local IPs and masked console host) to improve responses about the current device/network.
- Site ID values are not sent verbatim in device context; only whether a site ID is configured.

### What You Can Ask

- "How many devices are on my network?"
- "Give me a network overview"
- "Which AP has the most clients?"
- "Show me my firewall policies"
- "What WiFi networks are configured?"
- "Are there any security concerns?"

### Project Structure

```
NetworkGenius/
├── NetworkGenius.xcodeproj
├── NetworkGenius/
│   ├── App/              -- @main entry point, global state
│   ├── Models/           -- ChatMessage, UniFi types, LLM types, tool schemas
│   ├── Services/
│   │   ├── UniFi/        -- API client, query service, summary service
│   │   ├── LLM/          -- Claude + OpenAI services, tool executor
│   │   ├── KeychainHelper.swift
│   │   └── NetworkMonitor.swift
│   ├── ViewModels/       -- Chat and settings view models
│   ├── Views/            -- Chat, settings, onboarding, components
│   └── Resources/        -- Assets, system prompt
└── NetworkGeniusTests/
```

### Requirements

- Xcode 15.4+
- iOS 17.0+ deployment target
- A UniFi Network console with a local API key
- A Claude or OpenAI API key

## Safety for Distribution

When distributing this repository:

- keep `.env.local` out of version control
- never publish real API keys
- avoid publishing live snapshot data from `data/unifi/snapshots/`
- avoid publishing controller-specific identifiers (site IDs, device names, SSIDs, client info)
- the iOS app stores all keys in the device Keychain, never in files

## Testing

Python tests:

```bash
python3 -m unittest -v tests/test_unifi_network_local.py
```

iOS tests (requires Xcode):

```bash
xcodebuild test -project NetworkGenius/NetworkGenius.xcodeproj -scheme NetworkGenius -destination 'platform=iOS Simulator,name=iPhone 16'
```

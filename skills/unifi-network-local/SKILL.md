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
- LM Studio meta-llama-3-8b-instruct access is local-only; use it only when the device is on local Wi-Fi or VPN.
- Interpret tool results in plain language for a non-technical user.
- Never speculate; use tools to verify before concluding.
- Never disclose or expose API keys, passwords, tokens, or private credentials.
- If the user asks about a specific client/device, first resolve identity with `list_clients` and/or `lookup_client_identity` (name/hostname/IP/MAC) before deeper checks.
- For app-block workflows, prefer `app_block.py resolve-client` first to keep context small and return exactly one client.
- Do not assume "the current phone/device" unless the user explicitly asks about their current phone/device.
- Tool reference (purpose and parameters):
- `list_devices`: List UniFi infrastructure devices (APs, switches, gateways). Parameters: none.
- `list_clients`: List clients. Default is active clients; include inactive/known clients when specifically requested (for example inactive-history questions) and during app-block targeting.
- `list_networks`: List configured networks/VLANs. Parameters: none.
- `list_wifi_broadcasts`: List SSIDs and WiFi broadcast settings. Parameters: none.
- `list_network_events`: List recent legacy UniFi controller events from the site event feed. Parameters: none.
- `list_wlan_configs`: List legacy UniFi WLAN config objects, including lower-level SSID settings. Parameters: none.
- `list_network_configs`: List legacy UniFi network config objects, including lower-level LAN/VLAN/WAN details. Parameters: none.
- `named_query.py traffic-rules`: List the newer Policy Engine traffic-rule collection from `/proxy/network/v2/api/site/{site_ref}/trafficrules`.
- `named_query.py firewall-app-blocks`: Inspect the older Simple App Blocking collection from `/proxy/network/v2/api/site/{site_ref}/firewall-app-blocks`.
- `named_query.py network-members-groups`: List Policy Engine client groups from `/proxy/network/v2/api/site/{site_ref}/network-members-groups`.
- `named_query.py policy-engine-objects`: List Object Manager objects from `/proxy/network/v2/api/site/{site_ref}/object-oriented-network-configs`.
- `policy_engine.py list-rules`: Print a compact read-only view of Policy Engine traffic rules.
- `policy_engine.py summarize-rules`: Summarize Policy Engine rules by matching target, scope, schedule, and property family.
- `policy_engine.py compare-paths`: Compare the newer `trafficrules` collection with the older `firewall-app-blocks` collection.
- `policy_engine.py list-groups`: Print a compact read-only view of Policy Engine client groups.
- `policy_engine.py create-group`: Dry-run or create a Policy Engine client group through `network-members-group`.
- `policy_engine.py update-group`: Dry-run or update a Policy Engine client group through `network-members-group/{id}`.
- `policy_engine.py delete-group`: Dry-run or delete a Policy Engine client group through `network-members-group/{id}`.
- `policy_engine.py list-objects`: Print a compact read-only view of Object Manager objects.
- `policy_engine.py create-object`: Dry-run or create an Object Manager object through `object-oriented-network-config`.
- `policy_engine.py update-object`: Dry-run or update an Object Manager object through `object-oriented-network-config/{id}`.
- `policy_engine.py delete-object`: Dry-run or delete an Object Manager object through `object-oriented-network-config/{id}`.
- `policy_engine.py create-secure-blocklist-object`: Dry-run or create the first fully captured Secure internet blocklist object shape on the new Object Manager API.
- `policy_engine.py create-secure-allowlist-object`: Dry-run or create the captured Secure internet allowlist object shape on the new Object Manager API.
- `policy_engine.py create-quarantine-object`: Dry-run or create the captured Secure local quarantine object shape on the new Object Manager API.
- `policy_engine.py create-no-internet-object`: Dry-run or create the captured Secure no-internet object shape on the new Object Manager API.
- `policy_engine.py create-route-object`: Dry-run or create the captured Route object shape on the new Object Manager API.
- `policy_engine.py create-route-domain-object`: Dry-run or create the captured Route domain-selector object shape on the new Object Manager API.
- `policy_engine.py create-route-ip-object`: Dry-run or create the captured Route IP-selector object shape on the new Object Manager API.
- `policy_engine.py create-qos-object`: Dry-run or create the captured QoS object shape on the new Object Manager API.
- `policy_engine.py create-qos-prioritize-object`: Dry-run or create the captured QoS prioritize object shape on the new Object Manager API.
- `policy_engine.py create-qos-limits-object`: Dry-run or create the captured QoS object shape with enabled download/upload limits on the new Object Manager API.
- `policy_engine.py create-qos-prioritize-limits-object`: Dry-run or create the captured QoS prioritize-and-limit object shape on the new Object Manager API.
- `policy_engine.py create-secure-domain-blocklist-object`: Dry-run or create the captured Secure domain blocklist object shape on the new Object Manager API.
- `policy_engine.py create-secure-app-blocklist-object`: Dry-run or create the captured Secure app blocklist object shape on the new Object Manager API.
- `policy_engine.py create-secure-ip-blocklist-object`: Dry-run or create the captured Secure IP-address blocklist object shape on the new Object Manager API.
- `list_firewall_policies`: List firewall policies. Parameters: none.
- `list_firewall_zones`: List firewall zones. Parameters: none.
- `list_acl_rules`: List ACL rules. Parameters: none.
- `list_dns_policies`: List DNS filtering policies. Parameters: none.
- `list_vpn_servers`: List VPN server configurations. Parameters: none.
- `list_pending_devices`: List devices pending adoption. Parameters: none.
- `get_device_details`: Get detailed information for one device. Parameters: `device_id` (required).
- `get_device_stats`: Get latest statistics for one device. Parameters: `device_id` (required).
- `get_client_details`: Get detailed information for one client. Parameters: `client_id` (required).
- `lookup_client_identity`: Resolve a client by GUID/IP/MAC/name fragment and return friendly identity fields.
- `app_block.py resolve-client`: Resolve one app-block client by fuzzy query (name/hostname/IP/MAC/id), including inactive-capable sources.
- `app_block.py resolve-app`: Resolve one DPI application by fuzzy name/id.
- `app_block.py resolve-category`: Resolve one DPI category by fuzzy name/id.
- `ping_client`: Probe reachability for a client host/IP. Parameters: `target` (required), `timeout_seconds` (optional).
- `resolve_client_dns`: Resolve DNS (forward/reverse) for a client host/IP. Parameters: `target` (required).
- `network_traceroute`: Run traceroute to inspect path hops/latency. Parameters: `target` (required), `max_hops` (optional), `timeout_seconds` (optional).
- `ssh_collect_unifi_logs`: Run an approved read-only SSH log command on a UniFi device. Parameters: `host` (required), `command_id` (required), `approve_token` (optional, required to execute), `timeout_seconds` (optional).
- `network_overview`: High-level network summary (counts and busiest APs). Parameters: none.
- `clients_summary`: Client breakdown by type/access/uplink. Parameters: none.
- `wifi_summary`: WiFi summary (SSID/security/band/network mapping). Parameters: none.
- `firewall_summary`: Firewall summary (action counts and zone pair traffic). Parameters: none.
- `security_summary`: Security posture summary (ACL, DNS, VPN, RADIUS). Parameters: none.
- `wan_gateway_health`: Gateway/WAN health snapshot plus recent WAN-related SIEM logs. Parameters: `minutes` (optional).
- `config_diff_from_logs`: Summarize recent config/admin/security log changes. Parameters: `minutes` (optional), `limit` (optional), `contains` (optional).
- `search_unifi_docs`: Search official UniFi Help Center docs. Parameters: `query` (required), `max_results` (optional, integer 1-8).
- `get_unifi_doc`: Fetch an official UniFi Help Center article by ID or URL. Parameters: `article_id` (optional), `article_url` (optional). Provide at least one.
- `query_unifi_logs`: Query Grafana Loki logs over a recent time range. Parameters: `query` (optional), `minutes` (optional), `limit` (optional), `direction` (optional).
- `query_unifi_logs_instant`: Run an instant Grafana Loki query. Parameters: `query` (required), `limit` (optional).
- `list_unifi_log_labels`: List available Loki labels. Parameters: none.
- `list_unifi_log_label_values`: List values for one Loki label. Parameters: `label` (required).
- Use Loki log tools to answer event-history questions across security detections, critical incidents, admin logins, device issues, triggers/alerts, VPN behavior, firewall policy effects, UniFi OS updates, backup activity, and user access.
- Loki query scope is UniFi-only: selectors are constrained to `job="unifi_siem"`.
- For current-state questions, start with latest logs (usually 5-30 minutes, `direction=backward`).
- For historical/trend questions, use explicit duration (`minutes`) before querying.

## Work Safely

- Default to read-only requests.
- Use `POST`, `PUT`, `PATCH`, or `DELETE` only after the user explicitly asks for a configuration change.
- Confirm the exact endpoint from the local console docs before making write calls if the path is not already known.
- Avoid printing or storing the API key in logs, patches, or committed files.
- For app/service suspension work, use `guarded_policy_toggle.py` instead of raw write calls.
- Guarded writes are limited to existing allowlisted IDs and only toggle `enabled`; no create/delete/replace flows.
- UniFi is currently in a mixed migration state:
  - use `traffic-rules` to inspect the newer Policy Engine-backed rule model
  - use `firewall-app-blocks` / `app_block.py` for the still-separate Simple App Blocking flow
  - do not assume one path fully replaces the other unless the live controller proves it

## Required Environment

Set these values in the shell before making requests:

- `UNIFI_BASE_URL`: Console base URL, for example `https://unifi.local`.
- `UNIFI_API_KEY`: Local API key with the minimum required permissions.
- `LOKI_BASE_URL`: Loki base URL, for example `http://loki.local:3100` (required for Loki queries).
- `LOKI_API_KEY`: Optional Loki bearer token.
- `LM_STUDIO_BASE_URL`: LM Studio API base URL, for example `http://lmstudio.local:1234`.
- `LM_STUDIO_API_KEY`: LM Studio API key.
- `LM_STUDIO_MODEL`: Optional model alias. If unset, pass `--model` when querying chat.
- `UNIFI_GUARD_ALLOWED_ACL_RULE_IDS`: Comma-separated ACL rule IDs that guarded writes may toggle.
- `UNIFI_GUARD_ALLOWED_FIREWALL_POLICY_IDS`: Comma-separated firewall policy IDs that guarded writes may toggle.
- `UNIFI_GUARD_ALLOWED_DNS_POLICY_IDS`: Comma-separated DNS policy IDs that guarded writes may toggle.
- `UNIFI_ALARM_WEBHOOK_BIND`: Bind address for webhook receiver. Default `0.0.0.0`.
- `UNIFI_ALARM_WEBHOOK_PORT`: Webhook receiver port. Default `8787`.
- `UNIFI_ALARM_WEBHOOK_PATH`: Webhook path. Default `/webhook/unifi/alarm`.
- `UNIFI_ALARM_WEBHOOK_SECRET`: Optional shared secret required on inbound webhook requests.
- `UNIFI_ALARM_LOKI_JOB`: Loki `job` label for alarm events. Default `unifi_siem`.
- `UNIFI_SSH_USERNAME`: SSH username for UniFi device access (required for SSH log collection).
- `UNIFI_SSH_PRIVATE_KEY_PATH`: Path to SSH private key file.
- `UNIFI_SSH_PRIVATE_KEY`: SSH private key content (used when key path is not provided).
- `UNIFI_SSH_PASSWORD`: Optional SSH password fallback when key is unavailable (requires `sshpass` on host).
- `UNIFI_SSH_APPROVAL_SECRET`: Secret used to mint/verify guarded SSH approval tokens.

For a reusable skill, keep your real credentials file outside the project tree, for example:

```bash
set -a
. ~/.env.local
```

## Common Workflow

1. If a specific client/device is mentioned, resolve it first with `list_clients` or `lookup_client_identity` and carry friendly name + IP + MAC through the rest of the workflow. For app-block planning, use `app_block.py resolve-client` first to resolve exactly one client with fuzzy match and inactive-capable inventory.
2. Start with a read-only request to inspect current state.
3. If the endpoint is unclear, check the local Network API docs exposed by the console.
4. Use the helper script for the request.
5. Summarize findings in plain language and call out any inferred conclusions.
6. For configuration changes, explain the exact action before sending the write request.
7. Prefer a dry-run first; require explicit confirmation token before apply.

## Helper Script

Run the generic request client:

```bash
python3 skills/unifi-network-local/scripts/unifi_request.py GET /proxy/network/integration/v1/sites
```

Plan app blocking for a specific client from the DPI application catalog with narrow resolvers first:

```bash
python3 skills/unifi-network-local/scripts/app_block.py resolve-client --query "Kid iPad" --site-ref default --insecure
python3 skills/unifi-network-local/scripts/app_block.py resolve-app --query youtube --insecure
python3 skills/unifi-network-local/scripts/app_block.py resolve-category --query streaming --insecure
python3 skills/unifi-network-local/scripts/app_block.py plan-block \
  --site-ref default \
  --client "Kid iPad" \
  --app YouTube \
  --app Roblox \
  --category "Streaming Media" \
  --schedule-mode weekly \
  --days mon,tue,wed,thu,fri \
  --start-time 20:00 \
  --end-time 22:00 \
  --timezone America/Chicago \
  --insecure

python3 skills/unifi-network-local/scripts/app_block.py apply-block \
  --site-ref default \
  --client "Kid iPad" \
  --app YouTube \
  --category "Streaming Media" \
  --schedule-mode weekly \
  --days mon,tue,wed,thu,fri \
  --start-time 20:00 \
  --end-time 22:00 \
  --insecure

python3 skills/unifi-network-local/scripts/app_block.py remove-block \
  --site-ref default \
  --client "Kid iPad" \
  --app YouTube \
  --insecure
```

The helper resolves:

- the client by name, hostname, MAC, IP, or client ID
- the app list from `/proxy/network/integration/v1/dpi/applications`
- the category list from `/proxy/network/integration/v1/dpi/categories`
- schedule intent for `always`, `once`, `daily`, or `weekly`

It emits a policy plan and can now apply the private CyberSecure simple-app-block API used by the live UniFi UI.
It emits `simple_app_block_payloads` matching the live CyberSecure UI object model:

- `type: DEVICE`
- `target_type: APP_ID` or `APP_CATEGORY`
- `app_ids` or `app_category_ids`
- `client_macs`
- `schedule.mode`, `date`, `date_start`, `date_end`, `time_range_start`, `time_range_end`, `repeat_on_days`, `time_all_day`

The live UniFi frontend bundle confirms that Simple App Blocking is saved through the collection endpoint:

- `GET /proxy/network/v2/api/site/{site_ref}/firewall-app-blocks`
- `POST /proxy/network/v2/api/site/{site_ref}/firewall-app-blocks`

The current Policy Engine UI also references the newer rule collection:

- `GET /proxy/network/v2/api/site/{site_ref}/trafficrules`

Treat these as parallel APIs for now:

- `firewall-app-blocks` is the working Simple App Blocking path in this repo
- `trafficrules` appears to back the newer object-oriented Policy Engine model
- device groups and richer Secure / Route / QoS workflows should be traced and implemented against Policy Engine separately rather than forced through the simple app-block flow

Apply and remove both use collection replacement semantics:

- fetch the current simple-app-block list
- merge or prune rules in memory
- `POST` the full resulting collection back to UniFi

The live UI enum exposes separate target types for apps and categories, so when both `--app` and `--category` are supplied the helper emits or applies two rules instead of fabricating a combined target type.
Apply uses smart upsert behavior:
- it updates an existing rule only when `client + target_type + schedule` match
- otherwise it creates a new rule
- it never merges APP_ID and APP_CATEGORY rules together.
`remove-block` can either delete all client app-block rules or remove selected app/category IDs from existing rules.

The integration API uses:

- Base path: `https://<console>/proxy/network/integration`
- Header: `X-API-KEY: <api-key>`
- Header: `Accept: application/json`

For Loki queries use:

- Base path: `http://<loki>/loki/api/v1`
- Optional header: `Authorization: Bearer <loki-api-key>`

The docs show paginated list responses with `offset`, `limit`, `count`, `totalCount`, and `data`.

Add query parameters:

```bash
python3 skills/unifi-network-local/scripts/unifi_request.py GET /proxy/network/integration/v1/clients --query site_id=default
```

Allow a write call only when explicitly needed:

```bash
python3 skills/unifi-network-local/scripts/unifi_request.py POST /proxy/network/integration/v1/devices/restart --json '{"device_id":"..."}' --allow-write
```

Guarded service/app suspension toggles (recommended write path):

```bash
# Dry-run (safe): inspect exact change and capture confirmation token
python3 skills/unifi-network-local/scripts/guarded_policy_toggle.py --rule-type acl-rule --rule-id <allowlisted-rule-id> --site-ref default --enabled false --reason "Suspend selected services for approved client scope" --insecure

# Apply (only with explicit token from dry-run output)
python3 skills/unifi-network-local/scripts/guarded_policy_toggle.py --rule-type acl-rule --rule-id <allowlisted-rule-id> --site-ref default --enabled false --reason "Suspend selected services for approved client scope" --apply --confirm-token <TOKEN_FROM_DRY_RUN> --insecure
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
- `named_query.py events --site-ref <site-ref>`
- `named_query.py wlanconf --site-ref <site-ref>`
- `named_query.py networkconf --site-ref <site-ref>`
- `named_query.py firewall-policies --site-id <site-id>`
- `named_query.py firewall-policies-ordering --site-id <site-id>`
- `named_query.py acl-rules --site-id <site-id>`
- `named_query.py dns-policies --site-id <site-id>`
- `named_query.py traffic-rules --site-ref <site-ref>`
- `named_query.py firewall-app-blocks --site-ref <site-ref>`
- `named_query.py network-members-groups --site-ref <site-ref>`
- `named_query.py policy-engine-objects --site-ref <site-ref>`
- `named_query.py traffic-matching-lists --site-id <site-id>`
- `named_query.py hotspot-vouchers --site-id <site-id>`
- `named_query.py device --site-id <site-id> --device-id <device-id>`
- `named_query.py device-stats --site-id <site-id> --device-id <device-id>`
- `policy_engine.py list-rules --site-ref <site-ref> --insecure`
- `policy_engine.py summarize-rules --site-ref <site-ref> --insecure`
- `policy_engine.py compare-paths --site-ref <site-ref> --insecure`
- `policy_engine.py list-groups --site-ref <site-ref> --insecure`
- `policy_engine.py create-group --site-ref <site-ref> --name <group-name> --member-mac <mac> --insecure`
- `policy_engine.py update-group --site-ref <site-ref> --group-id <group-id> --name <group-name> --member-mac <mac> --insecure`
- `policy_engine.py delete-group --site-ref <site-ref> --group-id <group-id> --insecure`
- `policy_engine.py list-objects --site-ref <site-ref> --insecure`
- `policy_engine.py create-object --site-ref <site-ref> --json '{"name":"Example","enabled":true,"target_type":"GROUPS","targets":["group-id"],"secure":{"enabled":true},"route":{"enabled":false},"qos":{"enabled":false}}' --insecure`
- `policy_engine.py update-object --site-ref <site-ref> --object-id <object-id> --json '{"id":"<object-id>","name":"Example","enabled":true,"target_type":"GROUPS","targets":["group-id"],"secure":{"enabled":true},"route":{"enabled":false},"qos":{"enabled":false}}' --insecure`
- `policy_engine.py delete-object --site-ref <site-ref> --object-id <object-id> --insecure`
- `policy_engine.py create-secure-blocklist-object --site-ref <site-ref> --name <object-name> --target-type GROUPS --target-id <group-id> --insecure`
- `policy_engine.py create-secure-allowlist-object --site-ref <site-ref> --name <object-name> --target-type GROUPS --target-id <group-id> --insecure`
- `policy_engine.py create-quarantine-object --site-ref <site-ref> --name <object-name> --target-type GROUPS --target-id <group-id> --insecure`
- `policy_engine.py create-no-internet-object --site-ref <site-ref> --name <object-name> --target-type GROUPS --target-id <group-id> --insecure`
- `policy_engine.py create-route-object --site-ref <site-ref> --name <object-name> --target-type GROUPS --target-id <group-id> --network-id <network-id> --insecure`
- `policy_engine.py create-route-domain-object --site-ref <site-ref> --name <object-name> --target-type GROUPS --target-id <group-id> --domain example.com --insecure`
- `policy_engine.py create-route-ip-object --site-ref <site-ref> --name <object-name> --target-type GROUPS --target-id <group-id> --ip-address 1.1.1.1 --insecure`
- `policy_engine.py create-qos-object --site-ref <site-ref> --name <object-name> --target-type GROUPS --target-id <group-id> --insecure`
- `policy_engine.py create-qos-prioritize-object --site-ref <site-ref> --name <object-name> --target-type GROUPS --target-id <group-id> --insecure`
- `policy_engine.py create-qos-limits-object --site-ref <site-ref> --name <object-name> --target-type GROUPS --target-id <group-id> --network-id <network-id> --download-limit 10000 --upload-limit 10000 --insecure`
- `policy_engine.py create-qos-prioritize-limits-object --site-ref <site-ref> --name <object-name> --target-type GROUPS --target-id <group-id> --download-limit 10000 --upload-limit 10000 --insecure`
- `policy_engine.py create-secure-domain-blocklist-object --site-ref <site-ref> --name <object-name> --target-type GROUPS --target-id <group-id> --domain example.com --insecure`
- `policy_engine.py create-secure-app-blocklist-object --site-ref <site-ref> --name <object-name> --target-type GROUPS --target-id <group-id> --app-id 262392 --insecure`
- `policy_engine.py create-secure-ip-blocklist-object --site-ref <site-ref> --name <object-name> --target-type GROUPS --target-id <group-id> --ip-address 1.1.1.1 --insecure`

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

Run named Loki queries:

```bash
python3 skills/unifi-network-local/scripts/loki_query.py query-range --logql '{job="unifi_siem"}' --minutes 60 --limit 100 --direction backward
python3 skills/unifi-network-local/scripts/loki_query.py query-instant --logql '{job="unifi_siem"} |= "DROP"' --limit 50
python3 skills/unifi-network-local/scripts/loki_query.py labels
python3 skills/unifi-network-local/scripts/loki_query.py label-values --label host
```

Run UniFi Help Center documentation helpers:

```bash
python3 skills/unifi-network-local/scripts/unifi_docs.py search "firewall rules"
python3 skills/unifi-network-local/scripts/unifi_docs.py article --article-id 32065480092951
```

Run a local LM Studio model (local network / VPN only):

```bash
python3 skills/unifi-network-local/scripts/lmstudio_chat.py --list-models
python3 skills/unifi-network-local/scripts/lmstudio_chat.py --test
python3 skills/unifi-network-local/scripts/lmstudio_chat.py "Summarize top network risks from these events: <paste logs>"
python3 skills/unifi-network-local/scripts/lmstudio_chat.py --model meta-llama-3-8b-instruct "Summarize top network risks from these events: <paste logs>"
```

Run UniFi Alarm Manager webhook receiver and forward to Loki:

```bash
python3 skills/unifi-network-local/scripts/unifi_alarm_webhook_receiver.py
```

Deploy webhook receiver to local Docker stack:

```bash
docker build -t local/unifi-alarm-webhook:latest -f skills/unifi-network-local/deploy/unifi-alarm-webhook/Dockerfile .
docker stack deploy -c skills/unifi-network-local/deploy/unifi-alarm-webhook/stack.yml unifi-tools
```

Run client diagnostics:

```bash
python3 skills/unifi-network-local/scripts/network_client_diagnostics.py ping 192.168.1.50 --count 3 --timeout 2
python3 skills/unifi-network-local/scripts/network_client_diagnostics.py dns 192.168.1.50
python3 skills/unifi-network-local/scripts/network_client_diagnostics.py dns laptop.local
python3 skills/unifi-network-local/scripts/network_client_diagnostics.py http 192.168.1.50 --scheme https --path /
python3 skills/unifi-network-local/scripts/network_client_diagnostics.py ports 192.168.1.50 --ports 22,53,80,443 --timeout 2
```

Run guarded UniFi SSH log collection (approval required):

```bash
# Dry-run: prints confirm token (required for apply)
python3 skills/unifi-network-local/scripts/guarded_unifi_ssh_logs.py --host 192.168.1.1 --command-id logread_tail --reason "Investigate WAN drops"

# Apply: must include exact token from dry-run
python3 skills/unifi-network-local/scripts/guarded_unifi_ssh_logs.py --host 192.168.1.1 --command-id logread_tail --apply --confirm-token <TOKEN>
```

## Publishing Safety

- Do not publish `.env.local`; it is a local-only secret file.
- Prefer keeping the real env file outside the repo entirely, for example `~/.env.local`.
- Do not publish live snapshots from `data/unifi/snapshots/`.
- Do not publish Safari exports such as `*.webarchive`.
- Keep examples generic and avoid checking in controller IPs, site IDs, SSIDs, device names, or client data.

See [references/api-notes.md](references/api-notes.md) for operating notes and troubleshooting guidance.

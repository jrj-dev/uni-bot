# Device Group Policy Plan

Goal: support UniFi-native device groups for traffic and app-block policies without storing group state in the app.

## Decision

- UniFi should be the source of truth for device groups.
- The app and local scripts should read and target UniFi device groups, not persist their own grouping database.
- Existing single-device app blocking remains the fallback path until native device-group policy support is traced and implemented.
- During UniFi's current API migration, the repo should treat Policy Engine and `firewall-app-blocks` as parallel systems rather than forcing them into one abstraction too early.

## Why

- Avoids dual-write and drift between app-managed groups and UniFi-managed groups.
- Aligns with UniFi's move toward policy-engine-backed traffic management.
- Keeps operational behavior legible: if a group exists, it exists in UniFi.

## Phase 1: Trace UniFi At Home

Use the UniFi web UI on a home controller and capture the requests involved in:

- listing device groups
- creating a device group
- updating group membership
- deleting a device group
- listing policy / traffic-rule objects
- creating an app-block or traffic policy against a device group
- updating that policy
- deleting that policy

For each request, record:

- controller version
- Network application version
- UI action taken
- HTTP method
- path
- request body
- response body
- identifiers referenced by later requests
- whether the endpoint is site-scoped, console-scoped, or policy-engine-scoped

## Validate During Trace

Confirm these details before implementation:

- whether device groups are modeled as policy-engine objects or as a Network-specific collection
- whether policy targets reference `device_group_id`, object references, or embedded membership
- whether the app/category catalog matches the existing DPI IDs used by `firewall-app-blocks`
- whether schedules use the same shape as the current simple app-block schedule model
- whether rules are created as full-collection replace, partial update, or standard CRUD

## Implementation Shape

Add abstractions, not local persistence:

- `GroupCatalogProvider`
  - list device groups from UniFi
  - resolve one group by name or ID
  - inspect group membership
- `TrafficPolicyProvider`
  - plan/apply/remove group-targeted app policies through UniFi's newer API path
- keep the existing simple per-device app-block provider for single-device fallback

Suggested target model:

- `PolicyTarget.device(mac)`
- `PolicyTarget.deviceGroup(id or name)`

This model should stay in-memory only unless UniFi itself is being updated.

## Implementation Order

1. Read-only group discovery
2. Group resolution in prompts and tool planning
3. Dry-run planning for group-targeted app blocks
4. Guarded apply/remove for group-targeted policies
5. UX and docs refinement

## Guardrails

- Keep read-only by default.
- Preserve dry-run planning before apply.
- Preserve approval-token requirements for writes.
- Show resolved group members in plan output before policy apply.
- Use MAC addresses as the stable per-device fallback identifier where direct device targeting is still needed.

## Current Repo Reality

- Current app-block flow uses `POST /proxy/network/v2/api/site/{site_ref}/firewall-app-blocks`.
- That flow already works well for single-device targeting through `client_macs`.
- The current Policy Engine frontend also references `/proxy/network/v2/api/site/{site_ref}/trafficrules`.
- Live frontend bundle capture also confirms Policy Engine client-group paths:
  - `GET /proxy/network/v2/api/site/{site_ref}/network-members-groups`
  - `POST /proxy/network/v2/api/site/{site_ref}/network-members-group`
  - `PUT /proxy/network/v2/api/site/{site_ref}/network-members-group/{id}`
  - `DELETE /proxy/network/v2/api/site/{site_ref}/network-members-group/{id}`
- Live frontend bundle capture also confirms Object Manager object paths:
  - `GET /proxy/network/v2/api/site/{site_ref}/object-oriented-network-configs`
  - `POST /proxy/network/v2/api/site/{site_ref}/object-oriented-network-config`
  - `PUT /proxy/network/v2/api/site/{site_ref}/object-oriented-network-config/{id}`
  - `DELETE /proxy/network/v2/api/site/{site_ref}/object-oriented-network-config/{id}`
- Captured Object Manager Secure variants now include:
  - internet blocklist
  - internet allowlist
  - local quarantine
  - no internet via `secure.internet.mode = TURN_OFF_INTERNET`
- Captured non-Secure variants now include:
  - route via `route.network_id` plus `kill_switch`
  - route domain selectors via `route.all_traffic = false` plus `route.domains.enabled = true`
  - route IP selectors via `route.all_traffic = false` plus `route.ip_addresses.enabled = true`
  - qos via `qos.mode = LIMIT` plus `schedule`
  - qos prioritize via `qos.mode = PRIORITIZE`
  - qos with enabled download/upload limits plus `qos.network_id`
  - qos prioritize-and-limit via `qos.mode = LIMIT_AND_PRIORITIZE`
- Captured selector-specific Secure variants now include:
  - domain blocklist via `secure.internet.domains.enabled = true`
  - app blocklist via `secure.internet.apps.enabled = true`
  - IP blocklist via `secure.internet.ip_addresses.enabled = true`
- Device groups and richer Secure / Route / QoS behavior likely belong to Policy Engine, not the simple app-block collection.
- The repo does not currently manage a local device-group store and should not add one for this feature.

## Open Questions

- Which exact UniFi endpoints back Device Groups in the current UI?
- Does the new policy path fully replace `firewall-app-blocks` or coexist with it?
- Are group-targeted app blocks supported uniformly across controller versions?
- Are there policy-engine permissions or feature gates that need to be surfaced in setup/docs?

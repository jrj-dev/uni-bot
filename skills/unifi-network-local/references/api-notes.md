# UniFi API Notes

## Authentication

- Send the API key in the `X-API-Key` header.
- Keep `Accept: application/json` on all requests.
- Use `Content-Type: application/json` for requests with a body.
- The integration API is served from `https://<console>/proxy/network/integration`.

## Response Shape

- Most list endpoints in the rendered docs return a paginated envelope with `offset`, `limit`, `count`, `totalCount`, and `data`.

## Common Resource Groups

- Global resources: sites, pending devices, DPI categories, DPI applications, countries.
- Site-scoped inventory: devices, clients, networks, WiFi broadcasts, device tags.
- Policy/configuration resources: firewall zones, firewall policies, ACL rules, DNS policies, traffic matching lists.
- Uplink and access services: WAN profiles, VPN servers, site-to-site VPN tunnels, RADIUS profiles.

## Practical Usage

- Prefer GET requests first to inspect sites, devices, clients, alarms, and current configuration.
- Confirm endpoint paths against the console-hosted docs because local API versions and routes can vary by UniFi OS and Network application version.
- If the console uses a self-signed certificate, pass `--insecure` to the helper script.
- Use `--all-pages` with `named_query.py` when you need the full dataset rather than the first page.
- Use `query_summary.py` for recurring operational questions where raw JSON is too low-level.
- Prefer `--site-ref default` when a stable internal reference is good enough; it avoids copying UUIDs in routine commands.

## Troubleshooting Flow

1. Identify the site or network segment in scope.
2. Gather current state for affected devices, clients, and recent alarms.
3. Check whether the issue is likely client-specific, AP-specific, uplink-related, or configuration-driven.
4. Propose the least disruptive change first.
5. Make write calls only with explicit user approval.

## Example Questions

- "Which AP has the most connected clients right now?"
- "Show me offline devices."
- "Pull recent alarms for the default site."
- "Compare client counts across sites."
- "Restart this AP after we confirm its device ID."
- "List networks for this site."
- "Show WiFi broadcasts and firewall policies for this site."
- "Check pending devices before adoption."
- "List ACL rules, DNS policies, or traffic matching lists for this site."
- "Show hotspot vouchers or firewall rule ordering for this site."
- "Which APs have the most clients right now?"
- "Summarize my firewall by zone pair."
- "Show me the full WiFi and VLAN inventory."
- "What devices and firmware versions are currently online?"
- "Are there any pending devices to adopt?"
- "How much guest access is active right now?"

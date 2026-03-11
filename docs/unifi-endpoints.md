# UniFi Endpoint Notes

This repo uses a narrow subset of UniFi Network endpoints. Keep this file focused on the paths and behaviors the app and local scripts actually depend on.

## Base Patterns

- Integration API base: `/proxy/network/integration/v1`
- Legacy/private read paths: `/proxy/network/api/s/{site_ref}`
- Private app-block path: `/proxy/network/v2/api/site/{site_ref}/firewall-app-blocks`

## Common Discovery

- List sites: `GET /proxy/network/integration/v1/sites`
- List pending devices: `GET /proxy/network/integration/v1/pending-devices`
- List DPI categories: `GET /proxy/network/integration/v1/dpi/categories`
- List DPI applications: `GET /proxy/network/integration/v1/dpi/applications`
- List countries: `GET /proxy/network/integration/v1/countries`

## Site-Scoped Read Endpoints

- Devices: `GET /proxy/network/integration/v1/sites/{site_id}/devices`
- Device detail: `GET /proxy/network/integration/v1/sites/{site_id}/devices/{device_id}`
- Device stats: `GET /proxy/network/integration/v1/sites/{site_id}/devices/{device_id}/statistics/latest`
- Clients: `GET /proxy/network/integration/v1/sites/{site_id}/clients`
- Clients including inactive: `GET /proxy/network/integration/v1/sites/{site_id}/clients?includeInactive=true`
- Client detail: `GET /proxy/network/integration/v1/sites/{site_id}/clients/{client_id}`
- Networks: `GET /proxy/network/integration/v1/sites/{site_id}/networks`
- Wi-Fi broadcasts: `GET /proxy/network/integration/v1/sites/{site_id}/wifi/broadcasts`
- Hotspot vouchers: `GET /proxy/network/integration/v1/sites/{site_id}/hotspot/vouchers`
- Firewall policies: `GET /proxy/network/integration/v1/sites/{site_id}/firewall/policies`
- Firewall policy ordering: `GET /proxy/network/integration/v1/sites/{site_id}/firewall/policies/ordering`
- Firewall zones: `GET /proxy/network/integration/v1/sites/{site_id}/firewall/zones`
- ACL rules: `GET /proxy/network/integration/v1/sites/{site_id}/acl-rules`
- ACL rule ordering: `GET /proxy/network/integration/v1/sites/{site_id}/acl-rules/ordering`
- DNS policies: `GET /proxy/network/integration/v1/sites/{site_id}/dns/policies`
- Traffic matching lists: `GET /proxy/network/integration/v1/sites/{site_id}/traffic-matching-lists`
- Device tags: `GET /proxy/network/integration/v1/sites/{site_id}/device-tags`
- WAN profiles: `GET /proxy/network/integration/v1/sites/{site_id}/wans`
- VPN servers: `GET /proxy/network/integration/v1/sites/{site_id}/vpn/servers`
- Site-to-site VPN: `GET /proxy/network/integration/v1/sites/{site_id}/vpn/site-to-site-tunnels`
- RADIUS profiles: `GET /proxy/network/integration/v1/sites/{site_id}/radius/profiles`

## Legacy / Private Read Endpoints

- Event feed: `GET /proxy/network/api/s/{site_ref}/stat/event`
- WLAN config: `GET /proxy/network/api/s/{site_ref}/rest/wlanconf`
- Network config: `GET /proxy/network/api/s/{site_ref}/rest/networkconf`
- Legacy client inventory fallback: `GET /proxy/network/api/s/{site_ref}/stat/alluser`

## Private Write / Guarded Endpoints

- Restart device: `POST /proxy/network/integration/v1/devices/restart`
- App block collection read: `GET /proxy/network/v2/api/site/{site_ref}/firewall-app-blocks`
- App block collection write: `POST /proxy/network/v2/api/site/{site_ref}/firewall-app-blocks`
- Guarded policy toggle targets:
  - `PATCH /proxy/network/integration/v1/sites/{site_id}/acl-rules/{rule_id}`
  - `PATCH /proxy/network/integration/v1/sites/{site_id}/firewall/policies/{rule_id}`
  - `PATCH /proxy/network/integration/v1/sites/{site_id}/dns/policies/{rule_id}`

## Notes

- Most flows should stay read-only by default.
- `site_id` and `site_ref` are both used in the repo because UniFi exposes different path shapes across integration and legacy/private APIs.
- App blocking uses the private `firewall-app-blocks` collection API and must keep the current guarded apply/remove flow.
- If event polling returns `404`, the validated fallback path in this repo is `/proxy/network/api/s/default/stat/event`.

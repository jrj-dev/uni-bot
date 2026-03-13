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

## Policy Engine Findings

These notes come from the live UniFi Policy Engine UI on Network `10.1.85` plus frontend bundle inspection. Where a request was not captured directly on the wire, it is called out as an inference from the current controller JavaScript.

### Confirmed UI Surface

- Settings route:
  - `https://unifi.ui.com/.../network/default/settings/objects`
- Object create route:
  - `https://unifi.ui.com/.../network/default/settings/objects/new`
- Related Policy Engine sections:
  - `policy-table`
  - `zones`
  - `objects`

### Confirmed Current Rule Route

- Traffic rules route constant in the current frontend bundle:
  - `/v2/api/site/{site}/trafficrules`

This route still exists in the Policy Engine code path even though the UI now presents an object-oriented workflow.

### Policy Engine Object Shape

The objects list page renders rows using this normalized shape in the current frontend bundle:

```json
{
  "id": "object-id",
  "enabled": true,
  "name": "Family iPads",
  "target_type": "CLIENTS | NETWORKS | GROUPS",
  "targets": ["id-or-mac"],
  "secure": { "enabled": true },
  "route": { "enabled": false },
  "qos": { "enabled": false }
}
```

Observed semantics:
- `target_type=CLIENTS` uses MAC addresses in `targets`
- `target_type=NETWORKS` uses network IDs in `targets`
- `target_type=GROUPS` points at a separate group object, and client groups expand to member MACs in the renderer

Captured from the live 10.1.85 frontend bundle:
- collection read path: `GET /proxy/network/v2/api/site/{site_ref}/object-oriented-network-configs`
- create path: `POST /proxy/network/v2/api/site/{site_ref}/object-oriented-network-config`
- update path: `PUT /proxy/network/v2/api/site/{site_ref}/object-oriented-network-config/{id}`
- delete path: `DELETE /proxy/network/v2/api/site/{site_ref}/object-oriented-network-config/{id}`
- store key: `object`
- object key field: `id`

Important limitation:
- the exact Secure / Route / QoS property subfields for convenience builders still need narrower capture
- the normalized object shape and CRUD endpoint family above are confirmed from the current frontend bundle and live UI behavior

### Captured Secure Blocklist Object

I created one temporary Object Manager item through the live UI, queried the saved collection, and then removed the probe object. The persisted object shape for:
- target type: `GROUPS`
- Secure enabled
- Internet mode: `Blocklist`
- Internet scope: `Everything`
- Schedule: `Always`
- Local mode: `Inherit`

was:

```json
{
  "enabled": true,
  "name": "codex-secure-probe",
  "target_type": "GROUPS",
  "targets": ["69b3500d203564b3e98f4410"],
  "secure": {
    "enabled": true,
    "internet": {
      "mode": "BLOCKLIST",
      "everything": true,
      "apps": { "enabled": false, "values": [] },
      "domains": { "enabled": false, "values": [] },
      "ip_addresses": { "enabled": false, "values": [] },
      "regions": { "enabled": false, "values": [] },
      "schedule": { "mode": "ALWAYS" }
    }
  },
  "route": {
    "enabled": false,
    "apps": { "enabled": false, "values": [] },
    "domains": { "enabled": false, "values": [] },
    "ip_addresses": { "enabled": false, "values": [] },
    "regions": { "enabled": false, "values": [] }
  },
  "qos": {
    "enabled": false,
    "all_traffic": true,
    "apps": { "enabled": false, "values": [] },
    "domains": { "enabled": false, "values": [] },
    "ip_addresses": { "enabled": false, "values": [] },
    "regions": { "enabled": false, "values": [] },
    "mode": "LIMIT",
    "download_limit": { "enabled": false, "limit": 10000, "burst": "DISABLED" },
    "upload_limit": { "enabled": false, "limit": 10000, "burst": "DISABLED" }
  }
}
```

This is now sufficient for a first narrow convenience writer on the new Object Manager path.

### Captured Secure Allowlist Object

I created one temporary Object Manager item through the live UI with:
- target type: `GROUPS`
- Secure enabled
- Internet mode: `Allowlist`
- Internet scope: `Everything`
- Schedule: `Always`

and read back the persisted object. The saved shape matched the blocklist variant except for:

```json
{
  "secure": {
    "enabled": true,
    "internet": {
      "mode": "ALLOWLIST",
      "everything": true,
      "apps": { "enabled": false, "values": [] },
      "domains": { "enabled": false, "values": [] },
      "ip_addresses": { "enabled": false, "values": [] },
      "regions": { "enabled": false, "values": [] },
      "schedule": { "mode": "ALWAYS" }
    }
  }
}
```

This confirms that allowlist uses the full selector-bearing internet object shape and differs from blocklist primarily by `secure.internet.mode = "ALLOWLIST"`.

### Captured Quarantine Object

I created one temporary Object Manager item through the live UI with:
- target type: `GROUPS`
- Secure enabled
- Local mode: `Quarantine`

and read back the persisted object. The saved shape was the Secure blocklist object above plus:

```json
{
  "secure": {
    "enabled": true,
    "internet": {
      "mode": "BLOCKLIST",
      "everything": true,
      "apps": { "enabled": false, "values": [] },
      "domains": { "enabled": false, "values": [] },
      "ip_addresses": { "enabled": false, "values": [] },
      "regions": { "enabled": false, "values": [] },
      "schedule": { "mode": "ALWAYS" }
    },
    "local": {
      "mode": "QUARANTINE"
    }
  }
}
```

This confirms that local quarantine is persisted as `secure.local.mode = "QUARANTINE"` on the Object Manager API.

### Captured No Internet Object

I created one temporary Object Manager item through the live UI with:
- target type: `GROUPS`
- Secure enabled
- Internet mode: `No Internet`

and read back the persisted object. The saved shape was:

```json
{
  "enabled": true,
  "name": "codex-no-internet-probe",
  "target_type": "GROUPS",
  "targets": ["69b3500d203564b3e98f4410"],
  "secure": {
    "enabled": true,
    "internet": {
      "mode": "TURN_OFF_INTERNET",
      "schedule": { "mode": "ALWAYS" }
    }
  },
  "route": {
    "enabled": false,
    "apps": { "enabled": false, "values": [] },
    "domains": { "enabled": false, "values": [] },
    "ip_addresses": { "enabled": false, "values": [] },
    "regions": { "enabled": false, "values": [] }
  },
  "qos": {
    "enabled": false,
    "all_traffic": true,
    "apps": { "enabled": false, "values": [] },
    "domains": { "enabled": false, "values": [] },
    "ip_addresses": { "enabled": false, "values": [] },
    "regions": { "enabled": false, "values": [] },
    "mode": "LIMIT",
    "download_limit": { "enabled": false, "limit": 10000, "burst": "DISABLED" },
    "upload_limit": { "enabled": false, "limit": 10000, "burst": "DISABLED" }
  }
}
```

This confirms that the `No Internet` branch is not stored as a blocklist variant. UniFi persists it as `secure.internet.mode = "TURN_OFF_INTERNET"` with only the schedule block under `internet`.

### Captured Route Object

I created one temporary Object Manager item through the live UI with:
- target type: `GROUPS`
- Route enabled
- target scope: `All Traffic`
- interface: `Internet 1`
- `Kill Switch` enabled

and read back the persisted object. The saved shape was:

```json
{
  "enabled": true,
  "name": "codex-route-probe",
  "target_type": "GROUPS",
  "targets": ["69b3500d203564b3e98f4410"],
  "secure": {
    "enabled": false,
    "internet": {
      "everything": true,
      "mode": "BLOCKLIST"
    }
  },
  "route": {
    "enabled": true,
    "all_traffic": true,
    "apps": { "enabled": false, "values": [] },
    "domains": { "enabled": false, "values": [] },
    "ip_addresses": { "enabled": false, "values": [] },
    "kill_switch": true,
    "network_id": "5b4549d03961821e8f96f5f8",
    "regions": { "enabled": false, "values": [] }
  },
  "qos": {
    "enabled": false,
    "all_traffic": true,
    "apps": { "enabled": false, "values": [] },
    "domains": { "enabled": false, "values": [] },
    "ip_addresses": { "enabled": false, "values": [] },
    "regions": { "enabled": false, "values": [] },
    "mode": "LIMIT",
    "download_limit": { "enabled": false, "limit": 10000, "burst": "DISABLED" },
    "upload_limit": { "enabled": false, "limit": 10000, "burst": "DISABLED" }
  }
}
```

This confirms that Route persists the selected interface or tunnel as `route.network_id` and defaults `kill_switch` to `true` in the saved object.

### Captured Route Domain Selector Object

I created one temporary Object Manager item through the live UI with:
- target type: `GROUPS`
- Route enabled
- target scope: `Domain`
- one domain value: `example.com`
- interface: `Internet 1`

and read back the persisted object. The saved shape differed from the Route all-traffic object by:

```json
{
  "route": {
    "enabled": true,
    "all_traffic": false,
    "domains": {
      "enabled": true,
      "values": ["example.com"]
    },
    "ip_addresses": { "enabled": false, "values": [] },
    "network_id": "5b4549d03961821e8f96f5f8",
    "kill_switch": true
  }
}
```

This confirms that selector-based Route rules stay in the same `route` object family, toggle `all_traffic` to `false`, and persist the selector-specific block under `route.domains`.

### Captured Route IP Selector Object

I created one temporary Object Manager item through the live UI with:
- target type: `GROUPS`
- Route enabled
- target scope: `IP Address`
- one value: `1.1.1.1`
- interface: `Internet 1`

and read back the persisted object. The saved shape differed from the Route all-traffic object by:

```json
{
  "route": {
    "enabled": true,
    "all_traffic": false,
    "domains": { "enabled": false, "values": [] },
    "ip_addresses": {
      "enabled": true,
      "values": ["1.1.1.1"]
    },
    "network_id": "5b4549d03961821e8f96f5f8",
    "kill_switch": true
  }
}
```

This confirms that Route IP selectors follow the same pattern as domain selectors and persist under `route.ip_addresses`.

### Captured QoS Object

I created one temporary Object Manager item through the live UI with:
- target type: `GROUPS`
- QoS enabled
- target scope: `All Traffic`
- interface scope shown as `All WANs`
- mode: `Limit`
- schedule: `Always`

and read back the persisted object. The saved shape was:

```json
{
  "enabled": true,
  "name": "codex-qos-probe",
  "target_type": "GROUPS",
  "targets": ["69b3500d203564b3e98f4410"],
  "secure": {
    "enabled": false,
    "internet": {
      "everything": true,
      "mode": "BLOCKLIST"
    }
  },
  "route": {
    "apps": { "enabled": false, "values": [] },
    "domains": { "enabled": false, "values": [] },
    "enabled": false,
    "ip_addresses": { "enabled": false, "values": [] },
    "regions": { "enabled": false, "values": [] }
  },
  "qos": {
    "enabled": true,
    "all_traffic": true,
    "apps": { "enabled": false, "values": [] },
    "domains": { "enabled": false, "values": [] },
    "ip_addresses": { "enabled": false, "values": [] },
    "regions": { "enabled": false, "values": [] },
    "mode": "LIMIT",
    "download_limit": { "enabled": false, "limit": 10000, "burst": "DISABLED" },
    "upload_limit": { "enabled": false, "limit": 10000, "burst": "DISABLED" },
    "schedule": { "mode": "ALWAYS" }
  }
}
```

This confirms that the minimal QoS save keeps the standard disabled limit blocks, enables `qos`, and persists a schedule, but the `All WANs` selection did not materialize as a dedicated `network_id` field in the saved object.

### Captured QoS Object With Limits Enabled

I created one temporary Object Manager item through the live UI with:
- target type: `GROUPS`
- QoS enabled
- target scope: `All Traffic`
- both `Download Limit` and `Upload Limit` enabled
- both limits left at the default visible value `10000`

and read back the persisted object. The saved shape differed from the minimal QoS object by:

```json
{
  "qos": {
    "enabled": true,
    "all_traffic": true,
    "mode": "LIMIT",
    "network_id": "655c75b55c1d6b28bb6315e5",
    "download_limit": {
      "enabled": true,
      "limit": 10000,
      "burst": "DISABLED"
    },
    "upload_limit": {
      "enabled": true,
      "limit": 10000,
      "burst": "DISABLED"
    },
    "schedule": {
      "mode": "ALWAYS"
    }
  }
}
```

This confirms that once concrete QoS limits are enabled, UniFi persists a `qos.network_id` alongside the enabled download/upload limit blocks.

### Captured QoS Prioritize Object

I created one temporary Object Manager item through the live UI with:
- target type: `GROUPS`
- QoS enabled
- target scope: `All Traffic`
- mode: `Prioritize`
- interface scope shown as `All WANs`

and read back the persisted object. The saved shape differed from the minimal QoS object by:

```json
{
  "qos": {
    "enabled": true,
    "all_traffic": true,
    "mode": "PRIORITIZE",
    "download_limit": { "enabled": false, "limit": 10000, "burst": "DISABLED" },
    "upload_limit": { "enabled": false, "limit": 10000, "burst": "DISABLED" },
    "schedule": { "mode": "ALWAYS" }
  }
}
```

This confirms that the prioritize-only variant is primarily a `qos.mode` change and does not require enabled limit blocks.

### Captured QoS Prioritize-And-Limit Object

I created one temporary Object Manager item through the live UI with:
- target type: `GROUPS`
- QoS enabled
- target scope: `All Traffic`
- mode: `Prioritize and Limit`
- both `Download Limit` and `Upload Limit` enabled

and read back the persisted object. The saved shape differed from the minimal QoS object by:

```json
{
  "qos": {
    "enabled": true,
    "all_traffic": true,
    "mode": "LIMIT_AND_PRIORITIZE",
    "download_limit": {
      "enabled": true,
      "limit": 10000,
      "burst": "DISABLED"
    },
    "upload_limit": {
      "enabled": true,
      "limit": 10000,
      "burst": "DISABLED"
    },
    "schedule": { "mode": "ALWAYS" }
  }
}
```

This confirms that UniFi persists the combined mode as `LIMIT_AND_PRIORITIZE` and does not require a `qos.network_id` when the UI stays on `All WANs`.

### Captured Secure Domain Blocklist Object

I created one temporary Object Manager item through the live UI with:
- target type: `GROUPS`
- Secure enabled
- Internet mode: `Blocklist`
- `Domain` selector enabled
- one domain value: `example.com`

and read back the persisted object. The saved shape was:

```json
{
  "secure": {
    "enabled": true,
    "internet": {
      "mode": "BLOCKLIST",
      "everything": false,
      "apps": { "enabled": false, "values": [] },
      "domains": {
        "enabled": true,
        "values": ["example.com"]
      },
      "ip_addresses": { "enabled": false, "values": [] },
      "regions": { "enabled": false, "values": [] },
      "schedule": { "mode": "ALWAYS" }
    }
  }
}
```

This confirms that selector-based Secure rules stay in the same `secure.internet` object family, with `everything = false` and the specific selector block toggled to `enabled = true`.

### Captured Secure App Blocklist Object

I created one temporary Object Manager item through the live UI with:
- target type: `GROUPS`
- Secure enabled
- Internet mode: `Blocklist`
- `App` selector enabled
- one app value: TikTok (`262392`)

and read back the persisted object. The saved shape differed from the Secure blocklist object by:

```json
{
  "secure": {
    "enabled": true,
    "internet": {
      "mode": "BLOCKLIST",
      "everything": false,
      "apps": {
        "enabled": true,
        "values": [262392]
      },
      "domains": { "enabled": false, "values": [] },
      "ip_addresses": { "enabled": false, "values": [] },
      "regions": { "enabled": false, "values": [] },
      "schedule": { "mode": "ALWAYS" }
    }
  }
}
```

This confirms that app-selector Secure rules persist numeric DPI application IDs under `secure.internet.apps.values`.

### Captured Secure IP Blocklist Object

I created one temporary Object Manager item through the live UI with:
- target type: `GROUPS`
- Secure enabled
- Internet mode: `Blocklist`
- `IP Address` selector enabled
- one value: `1.1.1.1`

and read back the persisted object. The saved shape differed from the Secure blocklist object by:

```json
{
  "secure": {
    "enabled": true,
    "internet": {
      "mode": "BLOCKLIST",
      "everything": false,
      "apps": { "enabled": false, "values": [] },
      "domains": { "enabled": false, "values": [] },
      "ip_addresses": {
        "enabled": true,
        "values": ["1.1.1.1"]
      },
      "regions": { "enabled": false, "values": [] },
      "schedule": { "mode": "ALWAYS" }
    }
  }
}
```

This confirms that IP-selector Secure rules persist string values under `secure.internet.ip_addresses.values`.

### Client Group Shape

The client-group editor form in the bundle submits this payload into the group action creator:

```json
{
  "id": "optional-existing-id",
  "name": "Kids Devices",
  "members": ["aa:bb:cc:dd:ee:ff"],
  "type": "CLIENTS"
}
```

High-confidence behavior from the live UI:
- `Create Group` stages a client group in the Object Manager immediately
- groups can then be selected as the target for Secure / Route / QoS settings

Captured from the live 10.1.85 frontend bundle:
- collection read path: `GET /proxy/network/v2/api/site/{site_ref}/network-members-groups`
- create path: `POST /proxy/network/v2/api/site/{site_ref}/network-members-group`
- update path: `PUT /proxy/network/v2/api/site/{site_ref}/network-members-group/{id}`
- delete path: `DELETE /proxy/network/v2/api/site/{site_ref}/network-members-group/{id}`
- store key: `networkMembersGroup`
- object key field: `id`

Important limitation:
- the devtools bridge still did not expose the controller request body directly from the network panel
- the payload and endpoint family above are confirmed from the current frontend bundle and live UI behavior

### Secure / Route / QoS Rule Shape

The Policy Engine object editor exposes three major property blocks:
- `secure`
- `route`
- `qos`

The bundle and live form controls show these enum families:

- object properties:
  - `secure`
  - `routing`
  - `qos`
- source type:
  - `DEVICE`
  - `NETWORK`
- app target type:
  - `APP_ID`
  - `APP_CATEGORY`
- route / traffic match target:
  - `INTERNET`
  - `DOMAIN`
  - `IP`
  - `REGION`
  - `LOCAL_NETWORK`
- schedule mode:
  - `ALWAYS`
  - `CUSTOM`
  - `EVERY_DAY`
  - `EVERY_WEEK`
  - `ONE_TIME_ONLY`

The current rule renderers also confirm these fields are part of the rule objects:

```json
{
  "enabled": true,
  "matching_target": "INTERNET | DOMAIN | IP | REGION | LOCAL_NETWORK | APP_ID | APP_CATEGORY",
  "target_devices": [
    {
      "type": "ALL_CLIENTS | CLIENT | NETWORK",
      "client_mac": "aa:bb:cc:dd:ee:ff",
      "network_id": "network-id"
    }
  ],
  "schedule": {
    "mode": "ALWAYS | CUSTOM | EVERY_DAY | EVERY_WEEK | ONE_TIME_ONLY"
  }
}
```

### Simple App Blocking In Policy Engine

The current Simple App Blocking modal in the frontend still normalizes to this payload before submit:

```json
{
  "name": "Block TikTok on Kids Devices",
  "app_ids": [262392],
  "client_macs": ["aa:bb:cc:dd:ee:ff"],
  "network_ids": [],
  "type": "DEVICE",
  "target_type": "APP_ID",
  "app_category_ids": [],
  "schedule": {
    "mode": "ALWAYS"
  }
}
```

Field mappings confirmed by the current bundle:
- `type`
  - `DEVICE`
  - `NETWORK`
- `target_type`
  - `APP_ID`
  - `APP_CATEGORY`
- `client_macs` is used when source type is `DEVICE`
- `network_ids` is used when source type is `NETWORK`

### QoS-Specific Shape Hints

The current QoS policy bundle exposes these defaults and fields:

```json
{
  "qos_policies": [],
  "qos_profile_mode": "CUSTOM"
}
```

The current UI also exposes prioritization/marking enums for:
- DSCP
- IP precedence
- CoS

This strongly suggests Policy Engine QoS actions are still backed by the controller QoS profile model rather than a standalone brand-new route family.

## Notes

- Most flows should stay read-only by default.
- `site_id` and `site_ref` are both used in the repo because UniFi exposes different path shapes across integration and legacy/private APIs.
- App blocking uses the private `firewall-app-blocks` collection API and must keep the current guarded apply/remove flow.
- If event polling returns `404`, the validated fallback path in this repo is `/proxy/network/api/s/default/stat/event`.
- Policy Engine in the current UI is object-oriented, but the underlying controller model still references `trafficrules` and separate group objects.
- The most likely next implementation path for device groups, quarantine, blocklists, route, and shaping is through Policy Engine object/group CRUD plus the existing traffic-rule backing model.

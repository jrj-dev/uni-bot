---
name: unifi-alarm-manager-local
description: Query UniFi Alarm Manager events from Grafana Loki, scoped to job="unifi_alarm_manager". Use when the user wants alarm-specific event history and troubleshooting context narrowed by client, IP, device, or error patterns.
---

# UniFi Alarm Manager Local

Focused Loki skill for UniFi Alarm Manager event streams.

## Scope

- Read-only Loki access only.
- Always scoped to `job="unifi_alarm_manager"` unless the user explicitly provides a raw LogQL override.
- Prefer narrowing with known context:
  - client name
  - client IP
  - device name
  - targeted contains terms
- For broad issue hunting, use `--errors` and `index-stats` to scope quickly.

## Required Environment

- `LOKI_BASE_URL` (required)
- `LOKI_API_KEY` (optional)

## Main Script

`skills/unifi-alarm-manager-local/scripts/alarm_loki_query.py`

Actions:

- `query-range`
- `query-instant`
- `index-stats`
- `labels`
- `label-values`

## Examples

Recent alarms for one client:

```bash
python3 skills/unifi-alarm-manager-local/scripts/alarm_loki_query.py query-range --minutes 120 --client-name "Kid-iPad"
```

Narrow by client IP and device name:

```bash
python3 skills/unifi-alarm-manager-local/scripts/alarm_loki_query.py query-range --minutes 240 --client-ip 192.168.1.56 --device-name "U7-LR-Hallway"
```

Error-focused search:

```bash
python3 skills/unifi-alarm-manager-local/scripts/alarm_loki_query.py query-range --minutes 180 --errors
```

Index stats for scoped triage:

```bash
python3 skills/unifi-alarm-manager-local/scripts/alarm_loki_query.py index-stats --minutes 180 --errors --contains vpn
```

Inspect available labels:

```bash
python3 skills/unifi-alarm-manager-local/scripts/alarm_loki_query.py labels
python3 skills/unifi-alarm-manager-local/scripts/alarm_loki_query.py label-values --label host
```

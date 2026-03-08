---
name: unifi-siem-security-local
description: Query UniFi SIEM security events from Grafana Loki, scoped to job="unifi_siem" with security-focused filters. Use when the user asks about security detections, blocked traffic, auth failures, VPN/security incidents, suspicious activity, or recent security state.
---

# UniFi SIEM Security Local

Focused Loki skill for security-centric SIEM event investigation.

## Scope

- Read-only Loki access only.
- Always scoped to `job="unifi_siem"`.
- Defaults to current-state windows (last 30 minutes, backward/latest-first).
- Supports historical analysis by explicitly setting `--minutes`.
- Security-focused regex is applied by default (can be disabled with `--no-security-regex`).

## Required Environment

- `LOKI_BASE_URL` (required)
- `LOKI_API_KEY` (optional)

## Main Script

`skills/unifi-siem-security-local/scripts/siem_security_query.py`

Actions:

- `query-range`
- `query-instant`
- `index-stats`
- `labels`
- `label-values`

## Examples

Current security state (latest first):

```bash
python3 skills/unifi-siem-security-local/scripts/siem_security_query.py query-range --minutes 30
```

Security events for one client/device:

```bash
python3 skills/unifi-siem-security-local/scripts/siem_security_query.py query-range --minutes 120 --client-name "Kid-iPad" --device-name "U7-LR-Hallway"
```

Blocked/drop-focused investigation:

```bash
python3 skills/unifi-siem-security-local/scripts/siem_security_query.py query-range --minutes 180 --contains drop --contains blocked
```

Historical trend window:

```bash
python3 skills/unifi-siem-security-local/scripts/siem_security_query.py index-stats --minutes 1440
```

Inspect available labels:

```bash
python3 skills/unifi-siem-security-local/scripts/siem_security_query.py labels
python3 skills/unifi-siem-security-local/scripts/siem_security_query.py label-values --label host
```

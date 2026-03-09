# uni-bot

Local-first network assistant for UniFi environments.

This repo contains two parts:
- `NetworkGenius/`: iOS app (SwiftUI) for chat + voice network troubleshooting.
- `skills/unifi-network-local/`: CLI skill and scripts for direct UniFi/Loki/LM Studio workflows.

## Repository Capabilities

### iOS App (`NetworkGenius`)

- Chat assistant with tool use against local UniFi APIs.
- LLM providers:
  - OpenAI
  - Claude
  - LM Studio (local-only)
- Local network awareness:
  - Detects Wi-Fi/VPN state.
  - Restricts local-only providers/tools when off-network.
- Voice support:
  - Local iOS speech
  - OpenAI neural TTS
- Secure secret storage in iOS Keychain:
  - UniFi key
  - UniFi SSH username + private key
  - Loki key
  - LM Studio key
  - OpenAI key
  - Claude key
- Client diagnostics tools in app:
  - ping-style reachability probe
  - DNS forward/reverse resolution
  - traceroute path analysis
- WAN and change-analysis tools in app:
  - WAN/gateway health snapshot (`wan_gateway_health`)
  - SIEM config/admin/security diff summary (`config_diff_from_logs`)
- Guarded SSH log collection tool in app:
  - explicit approval token required before execution
  - strict read-only command allowlist
- Loki/Grafana tools for event logs and security/network event analysis.
- LM Studio model loading in Settings via `/v1/models` with model picker.
- Reasoning-output controls:
  - Prompt instruction to keep reasoning internal for LM Studio.
  - Optional `Hide Reasoning Output` filter for chat + TTS.
- Sanitized debug logs (redacts API-key-like values).

### Skill + CLI (`skills/unifi-network-local`)

- Query UniFi local integration APIs (read workflows).
- Named queries for common resources (clients/devices/firewall/VPN/etc).
- Snapshot capture and summary workflows for offline analysis.
- Loki query helpers:
  - `query_range`
  - instant query
  - labels
  - label values
- UniFi docs search/fetch helper.
- LM Studio chat helper (`lmstudio_chat.py`) with:
  - `--list-models`
  - explicit model selection
  - local/no-proxy request behavior
- Guarded UniFi mutation helper (`guarded_policy_toggle.py`) with:
  - allowlisted IDs only
  - `enabled` toggle only
  - dry-run default
  - explicit confirmation token for apply
- Client diagnostics helper (`network_client_diagnostics.py`) for ping-style probes and DNS checks.
- Guarded UniFi SSH log helper (`guarded_unifi_ssh_logs.py`) with dry-run token + explicit apply.
  - Supports key auth (`UNIFI_SSH_PRIVATE_KEY_PATH`/`UNIFI_SSH_PRIVATE_KEY`) or password auth (`UNIFI_SSH_PASSWORD`, requires `sshpass`).
- UniFi Alarm Manager webhook receiver (`unifi_alarm_webhook_receiver.py`) that forwards alarms to Loki.
  - Includes Docker module at `skills/unifi-network-local/deploy/unifi-alarm-webhook/` with `Dockerfile`, `stack.yml`, and `deploy.sh`.
- Dedicated alarm-analysis skill module (`skills/unifi-alarm-manager-local`) for Loki queries scoped to `job="unifi_siem"` with client/IP/device narrowing.
- Dedicated SIEM security-analysis skill module (`skills/unifi-siem-security-local`) for security-focused Loki queries scoped to `job="unifi_siem"`.
- UniFi event poller module (`skills/unifi-event-poller`) that polls UniFi events every 30s and forwards new events to Loki (supports endpoint auto-discovery plus explicit `UNIFI_EVENT_PATH` override).

## Project Layout

```text
NetworkGenius/                         iOS app project
skills/unifi-network-local/            skill docs + scripts
tests/                                 python tests and fixtures
.env.local.example                     local env template for scripts
```

## Configuration

Create local env file for scripts in your home directory:

```bash
cp .env.local.example ~/.env.local
```

Set values in `~/.env.local`:

```dotenv
UNIFI_BASE_URL=https://your-unifi-console
UNIFI_API_KEY=replace-me
UNIFI_SSH_USERNAME=
UNIFI_SSH_PRIVATE_KEY_PATH=
UNIFI_SSH_PRIVATE_KEY=
UNIFI_SSH_PASSWORD=
UNIFI_SSH_APPROVAL_SECRET=

LOKI_BASE_URL=http://your-loki-host:3100
LOKI_API_KEY=replace-me

LM_STUDIO_BASE_URL=http://your-lmstudio-host:1234
LM_STUDIO_API_KEY=replace-me
LM_STUDIO_MODEL=

UNIFI_GUARD_ALLOWED_ACL_RULE_IDS=
UNIFI_GUARD_ALLOWED_FIREWALL_POLICY_IDS=
UNIFI_GUARD_ALLOWED_DNS_POLICY_IDS=
UNIFI_ALARM_WEBHOOK_BIND=0.0.0.0
UNIFI_ALARM_WEBHOOK_PORT=8787
UNIFI_ALARM_WEBHOOK_PATH=/webhook/unifi/alarm
UNIFI_ALARM_WEBHOOK_SECRET=
UNIFI_ALARM_LOKI_JOB=unifi_siem
UNIFI_EVENT_PATH=/proxy/network/api/s/default/stat/event
UNIFI_EVENT_LIMIT=50
UNIFI_POLL_INTERVAL_SECONDS=30
UNIFI_EVENT_TIMEOUT_SECONDS=20
UNIFI_EVENT_LOKI_JOB=unifi_siem
UNIFI_INSECURE=true
LOKI_INSECURE=false
```

Load env vars:

```bash
set -a
. ~/.env.local
set +a
```

Notes:
- Keep `~/.env.local` out of git.
- `LM_STUDIO_MODEL` can be blank; select model from API/UI.
- Guard allowlists are required for any policy toggles. Empty allowlists block writes.
- If event polling returns `HTTP 404`, use `UNIFI_EVENT_PATH=/proxy/network/api/s/default/stat/event` (validated on this controller).

## iOS App Setup

1. Open `NetworkGenius/NetworkGenius.xcodeproj` in Xcode.
2. Set your signing team.
3. Build/run on simulator or device.
4. In app Settings:
   - Configure UniFi URL + key.
   - Configure preferred LLM provider + key.
   - For LM Studio: set base URL/key, then use `Load Models` and select one.

## Local-Network Constraints

These integrations are local-only by design unless reachable over VPN:
- UniFi local integration API
- Loki endpoint on your LAN
- LM Studio endpoint on your LAN

If LM Studio works on desktop but not mobile:
- Use LAN IP URL (for example `http://192.168.x.x:1234`).
- Ensure service binds beyond localhost (`0.0.0.0` or LAN interface).
- Allow inbound firewall rule for port `1234`.
- Verify iPhone can open `/v1/models` in Safari on same network.

## Common Script Commands

UniFi:

```bash
python3 skills/unifi-network-local/scripts/unifi_request.py GET /proxy/network/integration/v1/sites
python3 skills/unifi-network-local/scripts/named_query.py clients --site-ref default
python3 skills/unifi-network-local/scripts/query_summary.py overview --site-ref default
python3 skills/unifi-network-local/scripts/app_block.py list-apps --search zoom
python3 skills/unifi-network-local/scripts/app_block.py list-categories --search streaming
python3 skills/unifi-network-local/scripts/app_block.py plan-block --site-ref default --client "Kid iPad" --app YouTube --category "Streaming Media" --schedule-mode daily --start-time 20:00 --end-time 22:00
python3 skills/unifi-network-local/scripts/app_block.py apply-block --site-ref default --client "Kid iPad" --app YouTube --category "Streaming Media" --schedule-mode daily --start-time 20:00 --end-time 22:00
```

The app-block helper now targets UniFi's private CyberSecure `trafficrules` API and emits `simple_app_block_payloads` derived from the live UI model. It uses separate `APP_ID` and `APP_CATEGORY` rule types, so mixed app-plus-category requests are submitted as two rules.

Loki:

```bash
python3 skills/unifi-network-local/scripts/loki_query.py query-range --logql '{job="unifi_siem"}' --minutes 60 --limit 100
python3 skills/unifi-network-local/scripts/loki_query.py labels
python3 skills/unifi-network-local/scripts/loki_query.py label-values --label host
```

UniFi Alarm Manager Loki skill:

```bash
python3 skills/unifi-alarm-manager-local/scripts/alarm_loki_query.py query-range --minutes 120 --client-name "Kid-iPad"
python3 skills/unifi-alarm-manager-local/scripts/alarm_loki_query.py query-range --minutes 180 --errors --device-name "U7-LR-Hallway"
python3 skills/unifi-alarm-manager-local/scripts/alarm_loki_query.py index-stats --minutes 240 --errors --contains vpn
```

UniFi SIEM Security skill:

```bash
# Current security state (latest-first, short window)
python3 skills/unifi-siem-security-local/scripts/siem_security_query.py query-range --minutes 30

# Historical/security investigation with narrowing
python3 skills/unifi-siem-security-local/scripts/siem_security_query.py query-range --minutes 180 --contains blocked --contains vpn
python3 skills/unifi-siem-security-local/scripts/siem_security_query.py index-stats --minutes 1440
```

UniFi event poller (detached container, replaces old container automatically):

```bash
ENV_FILE="$HOME/.env.local" ~/projects/uni-bot/skills/unifi-event-poller/deploy/start.sh
# One-time startup backfill for last 24h, then normal polling
ENV_FILE="$HOME/.env.local" ~/projects/uni-bot/skills/unifi-event-poller/deploy/start.sh --backfill-24h
```

Watch poller logs:

```bash
docker logs -f unifi-event-poller
```

LM Studio:

```bash
python3 skills/unifi-network-local/scripts/lmstudio_chat.py --list-models
python3 skills/unifi-network-local/scripts/lmstudio_chat.py --test
python3 skills/unifi-network-local/scripts/lmstudio_chat.py --model <model-id> "Summarize top issues"
```

Client diagnostics:

```bash
python3 skills/unifi-network-local/scripts/network_client_diagnostics.py ping 192.168.1.50 --count 3 --timeout 2
python3 skills/unifi-network-local/scripts/network_client_diagnostics.py dns 192.168.1.50
python3 skills/unifi-network-local/scripts/network_client_diagnostics.py dns laptop.local
python3 skills/unifi-network-local/scripts/network_client_diagnostics.py http 192.168.1.50 --scheme https --path /
python3 skills/unifi-network-local/scripts/network_client_diagnostics.py ports 192.168.1.50 --ports 22,53,80,443 --timeout 2
```

Guarded UniFi SSH logs:

```bash
# Dry-run (returns confirm token)
python3 skills/unifi-network-local/scripts/guarded_unifi_ssh_logs.py --host 192.168.1.1 --command-id logread_tail --reason "Investigate packet drops"

# Apply (requires exact token from dry-run)
python3 skills/unifi-network-local/scripts/guarded_unifi_ssh_logs.py --host 192.168.1.1 --command-id logread_tail --apply --confirm-token <TOKEN>
```

Guarded policy toggle (safe write path):

```bash
# Dry-run first (prints summary + required confirm token)
python3 skills/unifi-network-local/scripts/guarded_policy_toggle.py \
  --rule-type acl-rule \
  --rule-id <allowlisted-rule-id> \
  --site-ref default \
  --enabled false \
  --reason "Temporarily suspend social-media apps for kid devices" \
  --insecure

# Apply using the exact token printed by dry-run
python3 skills/unifi-network-local/scripts/guarded_policy_toggle.py \
  --rule-type acl-rule \
  --rule-id <allowlisted-rule-id> \
  --site-ref default \
  --enabled false \
  --reason "Temporarily suspend social-media apps for kid devices" \
  --apply \
  --confirm-token <TOKEN_FROM_DRY_RUN> \
  --insecure
```

UniFi Alarm webhook receiver (host process):

```bash
python3 skills/unifi-network-local/scripts/unifi_alarm_webhook_receiver.py
```

It listens on `UNIFI_ALARM_WEBHOOK_BIND:UNIFI_ALARM_WEBHOOK_PORT` and forwards inbound JSON alarms to Loki at `LOKI_BASE_URL/loki/api/v1/push`.

Docker stack deployment (local machine):

```bash
# One-command build + deploy
skills/unifi-network-local/deploy/unifi-alarm-webhook/deploy.sh
```

By default, `deploy.sh` reads environment variables from `~/.env.local`.
Override with `--env-file <path>` when needed.
It defaults to compose mode (`docker compose up -d`).
Use `--mode swarm` if you want swarm stack deployment.

Watch logs (compose mode):

```bash
docker compose -f ~/projects/uni-bot/skills/unifi-network-local/deploy/unifi-alarm-webhook/compose.yml logs -f
```

Optional flags:

```bash
skills/unifi-network-local/deploy/unifi-alarm-webhook/deploy.sh --help
skills/unifi-network-local/deploy/unifi-alarm-webhook/deploy.sh --skip-build
skills/unifi-network-local/deploy/unifi-alarm-webhook/deploy.sh --mode compose
```

## Testing

Python:

```bash
python3 -m unittest -v tests/test_unifi_network_local.py
```

iOS build:

```bash
xcodebuild -project NetworkGenius/NetworkGenius.xcodeproj -scheme NetworkGenius -destination 'platform=iOS Simulator,name=iPhone 17' build
```

## Security

- Do not commit real secrets, snapshot exports, or local network identifiers.
- Use Keychain for app secrets and `.env.local` for script secrets.
- Keep local-only hostnames/IPs out of committed docs where possible.

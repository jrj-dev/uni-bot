# Repository Guidelines

## Project Overview
`uni-bot` is not a blank bootstrap repo. It is a local-first UniFi network assistant with two primary parts:

- `NetworkGenius/`: a SwiftUI iOS app for chat- and voice-driven network troubleshooting.
- `skills/`: local skill modules and Python scripts for UniFi, Loki, alarm, SIEM, and LM Studio workflows.

The app answers questions about a user's UniFi environment by combining LLM responses with tool calls against local UniFi and Loki endpoints. Some flows are read-only, and some guarded flows require explicit approval tokens before mutation or sensitive log access.

The current product direction serves two personas:

- Basic mode: a personal/home UniFi assistant for lower-technical-skill users who need plain-language answers and guided troubleshooting.
- Advanced mode: an operator-style assistant for more technical users performing deeper troubleshooting, event/security triage, and log-driven analysis.

Future work should be evaluated against those two modes. Features that only make sense for one mode should be clearly scoped rather than implicitly blended together.
Persona selection should be an explicit product control with a user-visible switch for basic/default mode versus advanced mode.

## Product Intent And Maturity
- Primary goal: a personal/home UniFi assistant.
- Secondary goal: a testbed for patterns that may later apply to telecom/operator tooling.
- Current maturity: between active prototype and fully functioning tool.

This means the repo should optimize for iteration speed, but changes should still improve clarity, guardrails, and operator discipline rather than adding ad hoc behavior.

## Source Of Truth
- Desired source of truth: `README.md`
- Current practical source of truth while docs are being brought up to date: user direction in chat plus observed code behavior

When behavior changes, update `README.md` and any relevant skill or agent docs so future work does not rely on tribal knowledge.

For external knowledge augmentation, prefer sources in this order:

1. Official UniFi documentation
2. Official documentation for any third-party product being integrated or discussed
3. UniFi or third-party support/community forums only as fallback

## Architecture And Key Flows
### iOS app
- Entry point: `NetworkGenius/NetworkGenius/App/NetworkGeniusApp.swift`
- App state/config: `NetworkGenius/NetworkGenius/App/AppState.swift`
- Chat orchestration: `NetworkGenius/NetworkGenius/ViewModels/ChatViewModel.swift`
- Tool execution: `NetworkGenius/NetworkGenius/Services/LLM/ToolExecutor.swift`
- UniFi access layer:
  - `NetworkGenius/NetworkGenius/Services/UniFi/UniFiAPIClient.swift`
  - `NetworkGenius/NetworkGenius/Services/UniFi/UniFiQueryService.swift`
  - `NetworkGenius/NetworkGenius/Services/UniFi/UniFiSummaryService.swift`
- LLM providers:
  - `NetworkGenius/NetworkGenius/Services/LLM/OpenAILLMService.swift`
  - `NetworkGenius/NetworkGenius/Services/LLM/ClaudeLLMService.swift`
  - `NetworkGenius/NetworkGenius/Services/LLM/LMStudioLLMService.swift`
- Prompting/instructions:
  - `NetworkGenius/NetworkGenius/Resources/SystemPrompt.txt`
  - `NetworkGenius/NetworkGenius/Resources/AgentInstructions.txt`

The app supports OpenAI, Claude, and LM Studio. LM Studio is intentionally treated as local-only and should only be assumed available on LAN or VPN.

The iOS app is the primary product surface for both personas. Python skills and local automation exist mainly to support advanced workflows, investigation, and operational depth.

### Skills and local automation
- Primary skill: `skills/unifi-network-local/`
- Related modules:
  - `skills/unifi-alarm-manager-local/`
  - `skills/unifi-siem-security-local/`
  - `skills/unifi-event-poller/`

These scripts support live UniFi queries, Loki log analysis, snapshot capture, app-block planning/apply/remove flows, guarded policy toggles, guarded UniFi SSH log collection, webhook ingestion, and event polling.

## Project Structure
- `NetworkGenius/`: Xcode project and Swift sources
- `tests/`: Python unit tests and fixtures for local scripts
- `docs/`: supporting notes and reference material
- `skills/`: skill docs, helper scripts, and deploy assets
- `.env.local.example`: example local environment file for Python/script tooling
- `README.md`: source of truth for setup, capabilities, and operator commands

## Build, Test, And Development Commands
Prefer these documented commands over inventing new entry points:

- Python tests: `python3 -m unittest -v tests/test_unifi_network_local.py`
- iOS build: `xcodebuild -project NetworkGenius/NetworkGenius.xcodeproj -scheme NetworkGenius -destination 'platform=iOS Simulator,name=iPhone 17' build`
- Open app in Xcode: `open NetworkGenius/NetworkGenius.xcodeproj`

Common script workflows:

- UniFi request: `python3 skills/unifi-network-local/scripts/unifi_request.py GET /proxy/network/integration/v1/sites`
- Named query: `python3 skills/unifi-network-local/scripts/named_query.py clients --site-ref default`
- Snapshot summary: `python3 skills/unifi-network-local/scripts/query_summary.py overview --site-ref default`
- LM Studio models: `python3 skills/unifi-network-local/scripts/lmstudio_chat.py --list-models`
- Loki query: `python3 skills/unifi-network-local/scripts/loki_query.py query-range --logql '{job="unifi_siem"}' --minutes 60 --limit 100`

If new commands become canonical, document them in `README.md` and keep `AGENTS.md` aligned.

## Configuration
Python and deploy scripts expect a local env file outside git:

1. `cp .env.local.example ~/.env.local`
2. Load it with:
   `set -a`
   `. ~/.env.local`
   `set +a`

Important environment groups:
- UniFi: `UNIFI_BASE_URL`, `UNIFI_API_KEY`, site and SSH-related values
- Loki: `LOKI_BASE_URL`, `LOKI_API_KEY`
- LM Studio: `LM_STUDIO_BASE_URL`, `LM_STUDIO_API_KEY`, `LM_STUDIO_MODEL`
- Guardrails: allowlist env vars for policy changes and approval secrets

Environment assumptions to preserve:
- Xcode is required for iOS app work
- Python 3.x is the baseline for script tooling
- Docker is part of the advanced setup for SIEM/log capture workflows

Never commit real secrets, local IPs/hostnames, exported snapshots, or private network identifiers.

## Operating Constraints
- Treat UniFi, Loki, and LM Studio integrations as local-first. If a flow depends on LAN or VPN reachability, preserve that behavior.
- Do not weaken guardrails around app-block changes, policy toggles, or SSH log collection. Dry-run and approval-token flows are intentional.
- The app stores secrets in iOS Keychain. Script-side secrets belong in `~/.env.local`, not repo files.
- Prefer using real tool data for network-specific behavior rather than hardcoding assumptions.
- Preserve sanitized logging and avoid exposing API keys, tokens, or credentials in logs, tests, or docs.
- Default to read-only behavior. Guarded writes should stay explicit, reversible where possible, and approval-based.
- Keep dependency footprint low unless there is a clear payoff.
- Changes should work on a real iPhone, not just the simulator.
- Build context bottom-up and keep it targeted. Prefer fetching the smallest relevant dataset that answers the question instead of broad dumps that waste context window.

## Personas And UX Expectations
### Basic mode
- Audience: lower-technical-skill home users
- Primary use cases:
  - troubleshooting a bad client experience
  - stepwise process-of-elimination with documentation/web augmentation when needed
  - general network performance and tuning advice
  - parental/app blocking
  - voice-driven support
- Response style:
  - plain language
  - minimal jargon
  - guided, incremental troubleshooting
  - answer the user's real-world question first, then add supporting detail only if needed
- UX boundary:
  - advanced/operator capabilities should be hidden in this mode, not merely shown and disabled

Example: "Why can't my printer connect?" should produce a layman-friendly explanation and the next best diagnostic step.

### Advanced mode
- Audience: technical users, closer to a network technician persona
- Primary use cases:
  - advanced troubleshooting with technical capabilities
  - process-of-elimination and triage with documentation/web augmentation when needed
  - answering "what changed?" from logs
  - security/event triage
  - offline snapshot analysis
- Response style:
  - technical but concise
  - evidence-based
  - explicit about uncertainty and observed data
  - optimized for fast triage
- UX boundary:
  - advanced/operator capabilities may be exposed here when appropriate

Example: "Are you seeing any dropped packets on client X?" should bias toward precise evidence, scoped queries, and concise interpretation.

## Coding And Editing Guidance
- Swift changes should follow the existing SwiftUI/service-oriented structure already in `NetworkGenius`.
- Python script changes should remain small, dependency-light, and compatible with the existing `unittest` coverage pattern in `tests/test_unifi_network_local.py`.
- When adding tests, mirror the existing area under test rather than creating parallel structures.
- Update `README.md` when adding or changing user-facing commands, environment variables, or operator workflows.
- Do not replace project-specific guidance with generic scaffold advice.
- Prefer direct implementation over extended discussion unless requirements are genuinely unclear.
- Be conservative with network and security-sensitive changes.
- Challenge assumptions before adding complexity.
- Consider both personas when creating features, prompts, tools, or UX. If something is only appropriate for one persona, make that explicit in the design and docs.
- When adding retrieval or augmentation behavior, prefer official docs first and use forum/community content only as fallback.
- UniFi private APIs are an accepted dependency for both personas. Use them pragmatically, but isolate that coupling where possible because UniFi platform behavior may change over time.

## Testing Expectations
Run targeted verification for the area you changed:

- Script or skill changes: run `python3 -m unittest -v tests/test_unifi_network_local.py`
- iOS app changes: run the documented `xcodebuild` command when feasible

If you cannot run a required verification step, say so explicitly in your handoff.

## Documentation Gaps To Improve
These areas are known to need ongoing cleanup and should be improved as related work happens:

- architecture documentation
- setup steps
- environment and configuration guidance
- skill usage and operator workflows

Bootstrap work should actively reduce these gaps rather than leaving new behavior implicit in code alone.

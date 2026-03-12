import Foundation

enum ToolAudience {
    case basic
    case advanced
}

struct ToolDefinition {
    let name: String
    let description: String
    let parameters: [ToolParameter]
    let audience: ToolAudience

    init(
        name: String,
        description: String,
        parameters: [ToolParameter],
        audience: ToolAudience = .basic
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.audience = audience
    }
}

struct ToolParameter {
    let name: String
    let type: String
    let description: String
    let required: Bool
}

enum ToolCatalog {
    static let all: [ToolDefinition] = [
        ToolDefinition(
            name: "list_devices",
            description: "List all UniFi network infrastructure devices (APs, switches, gateways).",
            parameters: []
        ),
        ToolDefinition(
            name: "list_clients",
            description: "List network clients. By default returns active clients; can include inactive/known clients. Prefer ranking tools for 'slowest', 'worst', 'most', or 'least' questions to avoid large responses.",
            parameters: [
                ToolParameter(name: "include_inactive", type: "boolean", description: "Set true to include inactive/known clients when supported.", required: false),
            ]
        ),
        ToolDefinition(
            name: "list_networks",
            description: "List all configured networks and VLANs.",
            parameters: []
        ),
        ToolDefinition(
            name: "list_wifi_broadcasts",
            description: "List all WiFi SSIDs and their broadcast settings.",
            parameters: []
        ),
        ToolDefinition(
            name: "list_network_events",
            description: "List recent legacy UniFi controller events from the site event feed.",
            parameters: []
        ),
        ToolDefinition(
            name: "list_wlan_configs",
            description: "List legacy UniFi WLAN configuration objects, including lower-level SSID settings not exposed by the documented integration API.",
            parameters: []
        ),
        ToolDefinition(
            name: "list_network_configs",
            description: "List legacy UniFi network configuration objects, including lower-level LAN/VLAN/WAN details not exposed by the documented integration API.",
            parameters: []
        ),
        ToolDefinition(
            name: "list_firewall_policies",
            description: "List all firewall policies.",
            parameters: [],
            audience: .advanced
        ),
        ToolDefinition(
            name: "list_firewall_zones",
            description: "List all firewall zones.",
            parameters: [],
            audience: .advanced
        ),
        ToolDefinition(
            name: "list_acl_rules",
            description: "List all access control rules.",
            parameters: [],
            audience: .advanced
        ),
        ToolDefinition(
            name: "list_dns_policies",
            description: "List all DNS filter policies.",
            parameters: [],
            audience: .advanced
        ),
        ToolDefinition(
            name: "list_vpn_servers",
            description: "List all VPN server configurations.",
            parameters: [],
            audience: .advanced
        ),
        ToolDefinition(
            name: "list_pending_devices",
            description: "List devices waiting to be adopted.",
            parameters: []
        ),
        ToolDefinition(
            name: "get_device_details",
            description: "Get detailed info for a specific network device.",
            parameters: [
                ToolParameter(name: "device_id", type: "string", description: "The device ID.", required: true),
            ]
        ),
        ToolDefinition(
            name: "get_device_stats",
            description: "Get latest statistics for a specific device.",
            parameters: [
                ToolParameter(name: "device_id", type: "string", description: "The device ID.", required: true),
            ],
            audience: .advanced
        ),
        ToolDefinition(
            name: "get_client_details",
            description: "Get detailed info for a specific connected client.",
            parameters: [
                ToolParameter(name: "client_id", type: "string", description: "The client ID.", required: true),
            ]
        ),
        ToolDefinition(
            name: "ping_client",
            description: "Probe reachability for a client IP/hostname using a local TCP-based ping-style check.",
            parameters: [
                ToolParameter(name: "target", type: "string", description: "Client IP or hostname.", required: true),
                ToolParameter(name: "timeout_seconds", type: "integer", description: "Probe timeout in seconds (1-10). Default: 3.", required: false),
            ]
        ),
        ToolDefinition(
            name: "resolve_client_dns",
            description: "Resolve DNS for a client hostname (forward) or IP (reverse lookup).",
            parameters: [
                ToolParameter(name: "target", type: "string", description: "Client IP or hostname.", required: true),
            ]
        ),
        ToolDefinition(
            name: "http_probe_client",
            description: "Probe HTTP/HTTPS response for a client host/IP and return status/latency.",
            parameters: [
                ToolParameter(name: "target", type: "string", description: "Client host or IP.", required: true),
                ToolParameter(name: "scheme", type: "string", description: "http or https. Default: http.", required: false),
                ToolParameter(name: "path", type: "string", description: "Optional request path. Default: /.", required: false),
                ToolParameter(name: "timeout_seconds", type: "integer", description: "Probe timeout seconds (1-20). Default: 5.", required: false),
            ]
        ),
        ToolDefinition(
            name: "port_check_client",
            description: "Check TCP connectivity to one or more ports on a client host/IP.",
            parameters: [
                ToolParameter(name: "target", type: "string", description: "Client host or IP.", required: true),
                ToolParameter(name: "ports", type: "string", description: "Comma-separated ports, e.g. 22,53,80,443.", required: true),
                ToolParameter(name: "timeout_seconds", type: "integer", description: "Per-port timeout seconds (1-10). Default: 2.", required: false),
            ],
            audience: .advanced
        ),
        ToolDefinition(
            name: "network_traceroute",
            description: "Run traceroute to a target host/IP to inspect path hops and latency.",
            parameters: [
                ToolParameter(name: "target", type: "string", description: "Target host or IP.", required: true),
                ToolParameter(name: "max_hops", type: "integer", description: "Maximum hops (5-64). Default: 20.", required: false),
                ToolParameter(name: "timeout_seconds", type: "integer", description: "Per-hop timeout seconds (1-5). Default: 2.", required: false),
            ],
            audience: .advanced
        ),
        ToolDefinition(
            name: "lookup_client_identity",
            description: "Resolve a UniFi client by GUID/IP/MAC/name and return friendly identity fields.",
            parameters: [
                ToolParameter(name: "query", type: "string", description: "Client id, IP, MAC, hostname, or display name fragment.", required: true),
            ]
        ),
        ToolDefinition(
            name: "find_slowest_client",
            description: "Find the active client with the lowest observed link speed metric without returning the full client list. Prefer this over list_clients for 'slowest device' questions.",
            parameters: [
                ToolParameter(name: "include_inactive", type: "boolean", description: "Set true to include inactive/known clients when supported. Default: false.", required: false),
            ]
        ),
        ToolDefinition(
            name: "top_slowest_clients",
            description: "Return the N slowest active clients by observed link speed metric without returning the full client list. Prefer this over list_clients for ranking questions.",
            parameters: [
                ToolParameter(name: "limit", type: "integer", description: "How many clients to return (1-20). Default: 5.", required: false),
                ToolParameter(name: "include_inactive", type: "boolean", description: "Set true to include inactive/known clients when supported. Default: false.", required: false),
            ]
        ),
        ToolDefinition(
            name: "find_weakest_wifi_client",
            description: "Find the WiFi client with the weakest signal without returning the full client list. Prefer this over list_clients for weak-signal questions.",
            parameters: [
                ToolParameter(name: "include_inactive", type: "boolean", description: "Set true to include inactive/known clients when supported. Default: false.", required: false),
            ]
        ),
        ToolDefinition(
            name: "top_weakest_wifi_clients",
            description: "Return the N WiFi clients with the weakest signal without returning the full client list.",
            parameters: [
                ToolParameter(name: "limit", type: "integer", description: "How many clients to return (1-20). Default: 5.", required: false),
                ToolParameter(name: "include_inactive", type: "boolean", description: "Set true to include inactive/known clients when supported. Default: false.", required: false),
            ]
        ),
        ToolDefinition(
            name: "find_highest_latency_client",
            description: "Find the client with the highest observed latency without returning the full client list. Prefer this over list_clients for latency ranking questions.",
            parameters: [
                ToolParameter(name: "include_inactive", type: "boolean", description: "Set true to include inactive/known clients when supported. Default: false.", required: false),
            ]
        ),
        ToolDefinition(
            name: "top_highest_latency_clients",
            description: "Return the N clients with the highest observed latency without returning the full client list.",
            parameters: [
                ToolParameter(name: "limit", type: "integer", description: "How many clients to return (1-20). Default: 5.", required: false),
                ToolParameter(name: "include_inactive", type: "boolean", description: "Set true to include inactive/known clients when supported. Default: false.", required: false),
            ]
        ),
        ToolDefinition(
            name: "rank_network_entities",
            description: "Compute compact bottom-up rankings without returning full raw lists. Supports questions like busiest SSID, weakest or strongest SSID signal, highest bandwidth client, reconnecting client, busiest AP, AP churn, busiest network, most-referenced network, shadowed firewall rules, misordered ACL rules, unhealthy WANs, stale VPN tunnels, switch ports with errors, flapping ports, disconnected clients behind a port, most-hit firewall rule, DNS policy affecting most clients, and app block targeting the most devices.",
            parameters: [
                ToolParameter(name: "entity_type", type: "string", description: "One of: client, access_point, wifi_broadcast, network, switch_port, firewall_rule, acl_rule, vpn_tunnel, wan_profile, dns_policy, app_block.", required: true),
                ToolParameter(name: "metric", type: "string", description: "Metric to rank by. Supported examples: highest_bandwidth, reconnect_churn, most_retransmits, offline_recent, recent_ip_changes, client_count, weakest_average_signal, strongest_average_signal, roam_churn, disconnect_churn, reference_count, shadow_risk, ordering_risk, down, up, stale, healthy, unhealthy, errors, disconnected_client_count, flapping, hits, target_count, slowest_speed, weakest_signal, highest_latency.", required: true),
                ToolParameter(name: "limit", type: "integer", description: "How many ranked results to return (1-20). Default: 5.", required: false),
                ToolParameter(name: "include_inactive", type: "boolean", description: "Set true when client-based metrics should include inactive/known clients. Default: false.", required: false),
                ToolParameter(name: "site_ref", type: "string", description: "Optional site reference for app-block ranking. Default: default.", required: false),
            ]
        ),
        ToolDefinition(
            name: "resolve_client_for_app_block",
            description: "Resolve one client for app-block changes using fuzzy matching (inactive clients included). Prefer this over list tools to avoid large responses.",
            parameters: [
                ToolParameter(name: "query", type: "string", description: "Client name/hostname/IP/MAC/id fragment.", required: true),
                ToolParameter(name: "site_ref", type: "string", description: "Optional site reference. Default: default.", required: false),
            ]
        ),
        ToolDefinition(
            name: "resolve_dpi_application",
            description: "Resolve one DPI application by fuzzy name/id for app-block planning. Prefer this over list tools to avoid large responses.",
            parameters: [
                ToolParameter(name: "query", type: "string", description: "Application name or id fragment.", required: true),
            ]
        ),
        ToolDefinition(
            name: "resolve_dpi_category",
            description: "Resolve one DPI category by fuzzy name/id for app-block planning. Prefer this over list tools to avoid large responses.",
            parameters: [
                ToolParameter(name: "query", type: "string", description: "Category name or id fragment.", required: true),
            ]
        ),
        ToolDefinition(
            name: "list_dpi_applications",
            description: "List/search UniFi DPI application catalog for app-block planning. Use only when resolve_dpi_application is insufficient.",
            parameters: [
                ToolParameter(name: "search", type: "string", description: "Optional case-insensitive name/id filter.", required: false),
                ToolParameter(name: "limit", type: "integer", description: "Max results (1-200). Default: 50.", required: false),
            ]
        ),
        ToolDefinition(
            name: "list_dpi_categories",
            description: "List/search UniFi DPI category catalog for app-block planning. Use only when resolve_dpi_category is insufficient.",
            parameters: [
                ToolParameter(name: "search", type: "string", description: "Optional case-insensitive name/id filter.", required: false),
                ToolParameter(name: "limit", type: "integer", description: "Max results (1-200). Default: 50.", required: false),
            ]
        ),
        ToolDefinition(
            name: "plan_client_app_block",
            description: "Create a guarded plan to block selected DPI apps/categories for one client. Prefer resolve_client_for_app_block, resolve_dpi_application, and resolve_dpi_category before calling this. Returns an approve_token for apply.",
            parameters: [
                ToolParameter(name: "client", type: "string", description: "Client selector (name/hostname/IP/MAC/id).", required: true),
                ToolParameter(name: "apps", type: "string", description: "Optional comma-separated DPI app names/ids.", required: false),
                ToolParameter(name: "categories", type: "string", description: "Optional comma-separated DPI category names/ids.", required: false),
                ToolParameter(name: "policy_name", type: "string", description: "Optional friendly rule name.", required: false),
                ToolParameter(name: "site_ref", type: "string", description: "Optional site reference for apply path. Default: default.", required: false),
            ]
        ),
        ToolDefinition(
            name: "apply_client_app_block",
            description: "Apply a previously planned client app-block rule using approve_token.",
            parameters: [
                ToolParameter(name: "approve_token", type: "string", description: "Token returned by plan_client_app_block.", required: true),
            ]
        ),
        ToolDefinition(
            name: "remove_client_app_block",
            description: "Remove app-block rule(s) for a client, or remove selected apps/categories from existing rules.",
            parameters: [
                ToolParameter(name: "client", type: "string", description: "Client selector (name/hostname/IP/MAC/id).", required: true),
                ToolParameter(name: "apps", type: "string", description: "Optional comma-separated DPI app names/ids to remove.", required: false),
                ToolParameter(name: "categories", type: "string", description: "Optional comma-separated DPI category names/ids to remove.", required: false),
                ToolParameter(name: "site_ref", type: "string", description: "Optional site reference for apply path. Default: default.", required: false),
            ]
        ),
        ToolDefinition(
            name: "list_client_app_block",
            description: "List current app-block rules affecting one client, including app/category IDs and names when resolvable.",
            parameters: [
                ToolParameter(name: "client", type: "string", description: "Client selector (name/hostname/IP/MAC/id).", required: true),
                ToolParameter(name: "site_ref", type: "string", description: "Optional site reference for lookup path. Default: default.", required: false),
            ]
        ),
        ToolDefinition(
            name: "list_clients_with_app_blocks",
            description: "Return a compact summary of clients that currently have simple app-block rules. Prefer this over broad client/rule listings for questions like 'what clients have blocks?'",
            parameters: [
                ToolParameter(name: "limit", type: "integer", description: "How many blocked clients to return (1-100). Default: 20.", required: false),
                ToolParameter(name: "site_ref", type: "string", description: "Optional site reference for lookup path. Default: default.", required: false),
            ]
        ),
        ToolDefinition(
            name: "ssh_collect_unifi_logs",
            description: "Run an approved, read-only SSH log command on a UniFi device. Requires explicit approval token before execution.",
            parameters: [
                ToolParameter(name: "host", type: "string", description: "UniFi device host or IP.", required: true),
                ToolParameter(name: "command_id", type: "string", description: "Read-only command id: logread_tail, messages_tail, dmesg_tail, kernel_tail.", required: true),
                ToolParameter(name: "approve_token", type: "string", description: "Approval token returned by prior dry-run call. Required to execute.", required: false),
                ToolParameter(name: "timeout_seconds", type: "integer", description: "SSH timeout in seconds (5-60). Default: 15.", required: false),
            ],
            audience: .advanced
        ),
        ToolDefinition(
            name: "network_overview",
            description: "High-level network overview with device, client, and network counts plus busiest APs.",
            parameters: []
        ),
        ToolDefinition(
            name: "clients_summary",
            description: "Client breakdown by type, access method, and uplink device.",
            parameters: []
        ),
        ToolDefinition(
            name: "wifi_summary",
            description: "WiFi SSID details including security, bands, and network mapping.",
            parameters: []
        ),
        ToolDefinition(
            name: "firewall_summary",
            description: "Firewall policy analysis with action counts and zone pair traffic.",
            parameters: [],
            audience: .advanced
        ),
        ToolDefinition(
            name: "security_summary",
            description: "Security posture summary: ACL rules, DNS policies, VPN, RADIUS profiles.",
            parameters: [],
            audience: .advanced
        ),
        ToolDefinition(
            name: "wan_gateway_health",
            description: "Summarize gateway/WAN health from UniFi device data plus recent WAN-related SIEM logs.",
            parameters: [
                ToolParameter(name: "minutes", type: "integer", description: "How far back to inspect logs (1-1440). Default: 120.", required: false),
            ],
            audience: .advanced
        ),
        ToolDefinition(
            name: "config_diff_from_logs",
            description: "Summarize recent config/admin/security changes from UniFi SIEM logs, with optional duration and filter.",
            parameters: [
                ToolParameter(name: "minutes", type: "integer", description: "How far back to inspect logs (1-10080). Default: 180.", required: false),
                ToolParameter(name: "limit", type: "integer", description: "Max matching events to include (1-200). Default: 80.", required: false),
                ToolParameter(name: "contains", type: "string", description: "Optional text filter, e.g. firewall, vpn, admin, backup.", required: false),
            ],
            audience: .advanced
        ),
        ToolDefinition(
            name: "search_unifi_docs",
            description: "Search official UniFi Help Center documentation for a topic.",
            parameters: [
                ToolParameter(name: "query", type: "string", description: "Search phrase, e.g. 'WiFi optimization' or 'firewall rules'.", required: true),
                ToolParameter(name: "max_results", type: "integer", description: "Maximum results to return (1-8). Default is 5.", required: false),
            ]
        ),
        ToolDefinition(
            name: "get_unifi_doc",
            description: "Fetch an official UniFi Help Center article by ID or article URL.",
            parameters: [
                ToolParameter(name: "article_id", type: "string", description: "Help Center article ID, e.g. '32065480092951'.", required: false),
                ToolParameter(name: "article_url", type: "string", description: "Help Center article URL containing /articles/<id>-...", required: false),
            ]
        ),
        ToolDefinition(
            name: "query_unifi_logs",
            description: "Query Grafana Loki logs over a recent time range, restricted to UniFi jobs only.",
            parameters: [
                ToolParameter(name: "query", type: "string", description: "Loki query pipeline or selector+pipeline. Selector is replaced with UniFi-only scope automatically.", required: false),
                ToolParameter(name: "minutes", type: "integer", description: "How far back to search in minutes (1-1440). Default: 60.", required: false),
                ToolParameter(name: "limit", type: "integer", description: "Maximum log lines to return (1-500). Default: 100.", required: false),
                ToolParameter(name: "direction", type: "string", description: "Result direction: backward or forward. Default: backward.", required: false),
            ],
            audience: .advanced
        ),
        ToolDefinition(
            name: "query_unifi_logs_instant",
            description: "Run an instant Loki query for recent matching UniFi logs, restricted to UniFi jobs only.",
            parameters: [
                ToolParameter(name: "query", type: "string", description: "Loki query pipeline or selector+pipeline. Selector is replaced with UniFi-only scope automatically.", required: true),
                ToolParameter(name: "limit", type: "integer", description: "Maximum log lines to return (1-500). Default: 50.", required: false),
            ],
            audience: .advanced
        ),
        ToolDefinition(
            name: "list_unifi_log_labels",
            description: "List all available label names in Loki.",
            parameters: [],
            audience: .advanced
        ),
        ToolDefinition(
            name: "list_unifi_log_label_values",
            description: "List values for a specific Loki label key.",
            parameters: [
                ToolParameter(name: "label", type: "string", description: "Label name, e.g. host, job, level.", required: true),
            ],
            audience: .advanced
        ),
        ToolDefinition(
            name: "list_unifi_log_series",
            description: "List Loki log stream label sets for a selector over a recent time range, restricted to UniFi jobs only.",
            parameters: [
                ToolParameter(name: "query", type: "string", description: "Log stream selector or pipeline. Selector is replaced with UniFi-only scope automatically.", required: false),
                ToolParameter(name: "minutes", type: "integer", description: "How far back to inspect in minutes (1-1440). Default: 60.", required: false),
                ToolParameter(name: "limit", type: "integer", description: "Maximum series to return (1-200). Default: 50.", required: false),
            ],
            audience: .advanced
        ),
        ToolDefinition(
            name: "get_unifi_log_stats",
            description: "Get Loki index stats (streams/chunks/entries/bytes) for a selector over a recent time range, restricted to UniFi jobs only.",
            parameters: [
                ToolParameter(name: "query", type: "string", description: "Log stream selector or pipeline. Selector is replaced with UniFi-only scope automatically.", required: false),
                ToolParameter(name: "minutes", type: "integer", description: "How far back to inspect in minutes (1-1440). Default: 60.", required: false),
            ],
            audience: .advanced
        ),
    ]

    static func availableTools(for mode: AssistantMode) -> [ToolDefinition] {
        switch mode {
        case .advanced:
            return all
        case .basic:
            return all.filter { $0.audience == .basic }
        }
    }

    static func supports(_ toolName: String, in mode: AssistantMode) -> Bool {
        availableTools(for: mode).contains { $0.name == toolName }
    }

    /// Builds the Claude-formatted tool schema array used in chat requests.
    static func claudeToolSchemas(for mode: AssistantMode) -> [[String: Any]] {
        availableTools(for: mode).map { tool in
            var schema: [String: Any] = [
                "name": tool.name,
                "description": tool.description,
            ]
            var properties: [String: Any] = [:]
            var required: [String] = []
            for param in tool.parameters {
                properties[param.name] = [
                    "type": param.type,
                    "description": param.description,
                ]
                if param.required { required.append(param.name) }
            }
            schema["input_schema"] = [
                "type": "object",
                "properties": properties,
                "required": required,
            ]
            return schema
        }
    }

    /// Builds the OpenAI-formatted tool schema array used in chat requests.
    static func openAIToolSchemas(for mode: AssistantMode) -> [[String: Any]] {
        availableTools(for: mode).map { tool in
            var properties: [String: Any] = [:]
            var required: [String] = []
            for param in tool.parameters {
                properties[param.name] = [
                    "type": param.type,
                    "description": param.description,
                ]
                if param.required { required.append(param.name) }
            }
            return [
                "type": "function",
                "function": [
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": [
                        "type": "object",
                        "properties": properties,
                        "required": required,
                    ],
                ] as [String: Any],
            ]
        }
    }
}

import Foundation

struct ToolDefinition {
    let name: String
    let description: String
    let parameters: [ToolParameter]
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
            description: "List all currently connected network clients.",
            parameters: []
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
            name: "list_firewall_policies",
            description: "List all firewall policies.",
            parameters: []
        ),
        ToolDefinition(
            name: "list_firewall_zones",
            description: "List all firewall zones.",
            parameters: []
        ),
        ToolDefinition(
            name: "list_acl_rules",
            description: "List all access control rules.",
            parameters: []
        ),
        ToolDefinition(
            name: "list_dns_policies",
            description: "List all DNS filter policies.",
            parameters: []
        ),
        ToolDefinition(
            name: "list_vpn_servers",
            description: "List all VPN server configurations.",
            parameters: []
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
            ]
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
            ]
        ),
        ToolDefinition(
            name: "network_traceroute",
            description: "Run traceroute to a target host/IP to inspect path hops and latency.",
            parameters: [
                ToolParameter(name: "target", type: "string", description: "Target host or IP.", required: true),
                ToolParameter(name: "max_hops", type: "integer", description: "Maximum hops (5-64). Default: 20.", required: false),
                ToolParameter(name: "timeout_seconds", type: "integer", description: "Per-hop timeout seconds (1-5). Default: 2.", required: false),
            ]
        ),
        ToolDefinition(
            name: "lookup_client_identity",
            description: "Resolve a UniFi client by GUID/IP/MAC/name and return friendly identity fields.",
            parameters: [
                ToolParameter(name: "query", type: "string", description: "Client id, IP, MAC, hostname, or display name fragment.", required: true),
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
            ]
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
            parameters: []
        ),
        ToolDefinition(
            name: "security_summary",
            description: "Security posture summary: ACL rules, DNS policies, VPN, RADIUS profiles.",
            parameters: []
        ),
        ToolDefinition(
            name: "wan_gateway_health",
            description: "Summarize gateway/WAN health from UniFi device data plus recent WAN-related SIEM logs.",
            parameters: [
                ToolParameter(name: "minutes", type: "integer", description: "How far back to inspect logs (1-1440). Default: 120.", required: false),
            ]
        ),
        ToolDefinition(
            name: "config_diff_from_logs",
            description: "Summarize recent config/admin/security changes from UniFi SIEM logs, with optional duration and filter.",
            parameters: [
                ToolParameter(name: "minutes", type: "integer", description: "How far back to inspect logs (1-10080). Default: 180.", required: false),
                ToolParameter(name: "limit", type: "integer", description: "Max matching events to include (1-200). Default: 80.", required: false),
                ToolParameter(name: "contains", type: "string", description: "Optional text filter, e.g. firewall, vpn, admin, backup.", required: false),
            ]
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
            ]
        ),
        ToolDefinition(
            name: "query_unifi_logs_instant",
            description: "Run an instant Loki query for recent matching UniFi logs, restricted to UniFi jobs only.",
            parameters: [
                ToolParameter(name: "query", type: "string", description: "Loki query pipeline or selector+pipeline. Selector is replaced with UniFi-only scope automatically.", required: true),
                ToolParameter(name: "limit", type: "integer", description: "Maximum log lines to return (1-500). Default: 50.", required: false),
            ]
        ),
        ToolDefinition(
            name: "list_unifi_log_labels",
            description: "List all available label names in Loki.",
            parameters: []
        ),
        ToolDefinition(
            name: "list_unifi_log_label_values",
            description: "List values for a specific Loki label key.",
            parameters: [
                ToolParameter(name: "label", type: "string", description: "Label name, e.g. host, job, level.", required: true),
            ]
        ),
        ToolDefinition(
            name: "list_unifi_log_series",
            description: "List Loki log stream label sets for a selector over a recent time range, restricted to UniFi jobs only.",
            parameters: [
                ToolParameter(name: "query", type: "string", description: "Log stream selector or pipeline. Selector is replaced with UniFi-only scope automatically.", required: false),
                ToolParameter(name: "minutes", type: "integer", description: "How far back to inspect in minutes (1-1440). Default: 60.", required: false),
                ToolParameter(name: "limit", type: "integer", description: "Maximum series to return (1-200). Default: 50.", required: false),
            ]
        ),
        ToolDefinition(
            name: "get_unifi_log_stats",
            description: "Get Loki index stats (streams/chunks/entries/bytes) for a selector over a recent time range, restricted to UniFi jobs only.",
            parameters: [
                ToolParameter(name: "query", type: "string", description: "Log stream selector or pipeline. Selector is replaced with UniFi-only scope automatically.", required: false),
                ToolParameter(name: "minutes", type: "integer", description: "How far back to inspect in minutes (1-1440). Default: 60.", required: false),
            ]
        ),
    ]

    static func claudeToolSchemas() -> [[String: Any]] {
        all.map { tool in
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

    static func openAIToolSchemas() -> [[String: Any]] {
        all.map { tool in
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

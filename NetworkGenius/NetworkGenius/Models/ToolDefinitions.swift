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

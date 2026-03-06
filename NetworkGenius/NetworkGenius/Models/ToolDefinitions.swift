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

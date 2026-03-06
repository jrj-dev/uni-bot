import Foundation

final class ToolExecutor {
    private let queryService: UniFiQueryService
    private let summaryService: UniFiSummaryService
    private let networkMonitor: NetworkMonitor

    init(queryService: UniFiQueryService, summaryService: UniFiSummaryService, networkMonitor: NetworkMonitor) {
        self.queryService = queryService
        self.summaryService = summaryService
        self.networkMonitor = networkMonitor
    }

    @MainActor
    func execute(toolCall: LLMToolCall) async -> String {
        guard networkMonitor.isOnNetwork else {
            return "Error: Not connected to the local network. Unable to query the UniFi console."
        }

        do {
            switch toolCall.name {
            case "list_devices":
                return try await queryService.query("devices")
            case "list_clients":
                return try await queryService.query("clients")
            case "list_networks":
                return try await queryService.query("networks")
            case "list_wifi_broadcasts":
                return try await queryService.query("wifi-broadcasts")
            case "list_firewall_policies":
                return try await queryService.query("firewall-policies")
            case "list_firewall_zones":
                return try await queryService.query("firewall-zones")
            case "list_acl_rules":
                return try await queryService.query("acl-rules")
            case "list_dns_policies":
                return try await queryService.query("dns-policies")
            case "list_vpn_servers":
                return try await queryService.query("vpn-servers")
            case "list_pending_devices":
                return try await queryService.query("pending-devices")
            case "get_device_details":
                return try await queryService.query("device", resourceID: toolCall.arguments["device_id"])
            case "get_device_stats":
                return try await queryService.query("device-stats", resourceID: toolCall.arguments["device_id"])
            case "get_client_details":
                return try await queryService.query("client", resourceID: toolCall.arguments["client_id"])
            case "network_overview":
                return try await summaryService.summary("overview")
            case "clients_summary":
                return try await summaryService.summary("clients")
            case "wifi_summary":
                return try await summaryService.summary("wifi")
            case "firewall_summary":
                return try await summaryService.summary("firewall")
            case "security_summary":
                return try await summaryService.summary("security")
            default:
                return "Unknown tool: \(toolCall.name)"
            }
        } catch {
            return "Error executing \(toolCall.name): \(error.localizedDescription)"
        }
    }
}

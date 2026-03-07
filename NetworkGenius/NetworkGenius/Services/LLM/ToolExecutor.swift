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

        let startedAt = Date()
        debugLog("Tool '\(toolCall.name)' started", category: "Tools")
        do {
            let output: String
            switch toolCall.name {
            case "list_devices":
                output = try await queryService.query("devices")
            case "list_clients":
                output = try await queryService.query("clients")
            case "list_networks":
                output = try await queryService.query("networks")
            case "list_wifi_broadcasts":
                output = try await queryService.query("wifi-broadcasts")
            case "list_firewall_policies":
                output = try await queryService.query("firewall-policies")
            case "list_firewall_zones":
                output = try await queryService.query("firewall-zones")
            case "list_acl_rules":
                output = try await queryService.query("acl-rules")
            case "list_dns_policies":
                output = try await queryService.query("dns-policies")
            case "list_vpn_servers":
                output = try await queryService.query("vpn-servers")
            case "list_pending_devices":
                output = try await queryService.query("pending-devices")
            case "get_device_details":
                output = try await queryService.query("device", resourceID: toolCall.arguments["device_id"])
            case "get_device_stats":
                output = try await queryService.query("device-stats", resourceID: toolCall.arguments["device_id"])
            case "get_client_details":
                output = try await queryService.query("client", resourceID: toolCall.arguments["client_id"])
            case "network_overview":
                output = try await summaryService.summary("overview")
            case "clients_summary":
                output = try await summaryService.summary("clients")
            case "wifi_summary":
                output = try await summaryService.summary("wifi")
            case "firewall_summary":
                output = try await summaryService.summary("firewall")
            case "security_summary":
                output = try await summaryService.summary("security")
            default:
                output = "Unknown tool: \(toolCall.name)"
            }
            let elapsedMS = Int(Date().timeIntervalSince(startedAt) * 1000)
            debugLog("Tool '\(toolCall.name)' completed in \(elapsedMS)ms", category: "Tools")
            return output
        } catch {
            let elapsedMS = Int(Date().timeIntervalSince(startedAt) * 1000)
            debugLog("Tool '\(toolCall.name)' failed in \(elapsedMS)ms: \(error.localizedDescription)", category: "Tools")
            return "Error executing \(toolCall.name): \(error.localizedDescription)"
        }
    }
}

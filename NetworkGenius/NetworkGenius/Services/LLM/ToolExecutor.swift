import Foundation
import Network
import Darwin

final class ToolExecutor {
    private static let offNetworkCapableTools: Set<String> = [
        "search_unifi_docs",
        "get_unifi_doc",
    ]

    private let apiClient: UniFiAPIClient
    private let queryService: UniFiQueryService
    private let summaryService: UniFiSummaryService
    private let networkMonitor: NetworkMonitor
    private let docsService = UniFiDocumentationService()
    private let lokiService: GrafanaLokiService
    private let diagnosticsService = ClientDiagnosticsService()
    private let sshLogService = UniFiSSHLogService()
    private let appBlockService: UniFiAppBlockService
    private let assistantMode: AssistantMode

    init(
        apiClient: UniFiAPIClient,
        queryService: UniFiQueryService,
        summaryService: UniFiSummaryService,
        networkMonitor: NetworkMonitor,
        lokiBaseURL: String,
        clientModificationApprovals: [ClientModificationApproval],
        assistantMode: AssistantMode
    ) {
        self.apiClient = apiClient
        self.queryService = queryService
        self.summaryService = summaryService
        self.networkMonitor = networkMonitor
        self.lokiService = GrafanaLokiService(baseURL: lokiBaseURL)
        self.assistantMode = assistantMode
        self.appBlockService = UniFiAppBlockService(
            apiClient: apiClient,
            approvals: clientModificationApprovals
        )
    }

    @MainActor
    /// Routes an LLM tool call to the matching UniFi, diagnostics, docs, or app-block operation.
    func execute(toolCall: LLMToolCall) async -> String {
        let requiresLocalNetwork = !Self.offNetworkCapableTools.contains(toolCall.name)
        guard ToolCatalog.supports(toolCall.name, in: assistantMode) else {
            return "Error: \(toolCall.name) is only available in Advanced mode."
        }
        guard !requiresLocalNetwork || networkMonitor.isOnNetwork else {
            return "Error: Not connected to the local network. Unable to query the UniFi console."
        }

        let startedAt = Date()
        debugLog("Tool '\(toolCall.name)' started", category: "Tools")
        do {
            let output = try await executeRoutedTool(toolCall)
            let elapsedMS = Int(Date().timeIntervalSince(startedAt) * 1000)
            debugLog("Tool '\(toolCall.name)' completed in \(elapsedMS)ms", category: "Tools")
            return output
        } catch {
            let elapsedMS = Int(Date().timeIntervalSince(startedAt) * 1000)
            debugLog("Tool '\(toolCall.name)' failed in \(elapsedMS)ms: \(error.localizedDescription)", category: "Tools")
            return formattedToolError(error, toolName: toolCall.name)
        }
    }

    /// Dispatches one tool call into the domain-specific handler that owns its behavior.
    private func executeRoutedTool(_ toolCall: LLMToolCall) async throws -> String {
        if let output = try await executeInventoryTool(toolCall) { return output }
        if let output = try await executeDiagnosticsTool(toolCall) { return output }
        if let output = try await executeRankingTool(toolCall) { return output }
        if let output = try await executeAppBlockTool(toolCall) { return output }
        if let output = try await executeSummaryTool(toolCall) { return output }
        if let output = try await executeDocsAndLogsTool(toolCall) { return output }
        return "Unknown tool: \(toolCall.name)"
    }

    /// Handles direct UniFi inventory and detail queries.
    private func executeInventoryTool(_ toolCall: LLMToolCall) async throws -> String? {
        switch toolCall.name {
        case "list_devices":
            return try await queryService.query("devices")
        case "list_clients":
            return try await listClients(includeInactiveRaw: toolCall.arguments["include_inactive"])
        case "list_networks":
            return try await queryService.query("networks")
        case "list_wifi_broadcasts":
            return try await queryService.query("wifi-broadcasts")
        case "list_network_events":
            return try await queryService.query("events")
        case "list_wlan_configs":
            return try await queryService.query("wlanconf")
        case "list_network_configs":
            return try await queryService.query("networkconf")
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
        default:
            return nil
        }
    }

    /// Handles client diagnostics and identity lookups that operate on one target host or client.
    private func executeDiagnosticsTool(_ toolCall: LLMToolCall) async throws -> String? {
        switch toolCall.name {
        case "ping_client":
            return await diagnosticsService.probeReachability(
                target: toolCall.arguments["target"],
                timeoutSeconds: Int(toolCall.arguments["timeout_seconds"] ?? "")
            )
        case "resolve_client_dns":
            return diagnosticsService.resolveDNS(target: toolCall.arguments["target"])
        case "http_probe_client":
            return await diagnosticsService.httpProbe(
                target: toolCall.arguments["target"],
                scheme: toolCall.arguments["scheme"],
                path: toolCall.arguments["path"],
                timeoutSeconds: Int(toolCall.arguments["timeout_seconds"] ?? "")
            )
        case "port_check_client":
            return await diagnosticsService.portCheck(
                target: toolCall.arguments["target"],
                portsCSV: toolCall.arguments["ports"],
                timeoutSeconds: Int(toolCall.arguments["timeout_seconds"] ?? "")
            )
        case "network_traceroute":
            return await diagnosticsService.traceroute(
                target: toolCall.arguments["target"],
                maxHops: Int(toolCall.arguments["max_hops"] ?? ""),
                timeoutSeconds: Int(toolCall.arguments["timeout_seconds"] ?? "")
            )
        case "lookup_client_identity":
            return try await diagnosticsService.lookupClientIdentity(
                queryService: queryService,
                query: toolCall.arguments["query"]
            )
        case "ssh_collect_unifi_logs":
            return await sshLogService.run(
                host: toolCall.arguments["host"],
                commandID: toolCall.arguments["command_id"],
                approveToken: toolCall.arguments["approve_token"],
                timeoutSeconds: Int(toolCall.arguments["timeout_seconds"] ?? "")
            )
        default:
            return nil
        }
    }

    /// Handles ranking-style tools that summarize larger inventories into ordered results.
    private func executeRankingTool(_ toolCall: LLMToolCall) async throws -> String? {
        if let request = ClientRankingKind.request(forToolName: toolCall.name) {
            return try await rankedClientSummary(
                kind: request.kind,
                limit: request.resolvedLimit(rawLimit: toolCall.arguments["limit"]),
                includeInactiveRaw: toolCall.arguments["include_inactive"]
            )
        }

        switch toolCall.name {
        case "rank_network_entities":
            return try await rankNetworkEntities(
                entityType: toolCall.arguments["entity_type"],
                metric: toolCall.arguments["metric"],
                limit: Int(toolCall.arguments["limit"] ?? ""),
                includeInactiveRaw: toolCall.arguments["include_inactive"],
                siteRef: toolCall.arguments["site_ref"]
            )
        default:
            return nil
        }
    }

    /// Handles guarded simple app-block planning and execution.
    private func executeAppBlockTool(_ toolCall: LLMToolCall) async throws -> String? {
        switch toolCall.name {
        case "resolve_client_for_app_block":
            return try await appBlockService.resolveClientForAppBlock(
                queryService: queryService,
                query: toolCall.arguments["query"],
                siteRef: toolCall.arguments["site_ref"]
            )
        case "resolve_dpi_application":
            return try await appBlockService.resolveDPIApplication(
                queryService: queryService,
                query: toolCall.arguments["query"]
            )
        case "resolve_dpi_category":
            return try await appBlockService.resolveDPICategory(
                queryService: queryService,
                query: toolCall.arguments["query"]
            )
        case "list_dpi_applications":
            return try await appBlockService.listDPIApplications(
                queryService: queryService,
                search: toolCall.arguments["search"],
                limit: Int(toolCall.arguments["limit"] ?? "")
            )
        case "list_dpi_categories":
            return try await appBlockService.listDPICategories(
                queryService: queryService,
                search: toolCall.arguments["search"],
                limit: Int(toolCall.arguments["limit"] ?? "")
            )
        case "plan_client_app_block":
            return try await appBlockService.planClientAppBlock(
                queryService: queryService,
                clientSelector: toolCall.arguments["client"],
                appsCSV: toolCall.arguments["apps"],
                categoriesCSV: toolCall.arguments["categories"],
                policyName: toolCall.arguments["policy_name"],
                siteRef: toolCall.arguments["site_ref"]
            )
        case "apply_client_app_block":
            return try await appBlockService.applyClientAppBlock(
                approveToken: toolCall.arguments["approve_token"]
            )
        case "remove_client_app_block":
            return try await appBlockService.removeClientAppBlock(
                queryService: queryService,
                clientSelector: toolCall.arguments["client"],
                appsCSV: toolCall.arguments["apps"],
                categoriesCSV: toolCall.arguments["categories"],
                siteRef: toolCall.arguments["site_ref"]
            )
        case "list_client_app_block":
            return try await appBlockService.listClientAppBlock(
                queryService: queryService,
                clientSelector: toolCall.arguments["client"],
                siteRef: toolCall.arguments["site_ref"]
            )
        case "list_clients_with_app_blocks":
            return try await appBlockService.listClientsWithAppBlocks(
                queryService: queryService,
                limit: Int(toolCall.arguments["limit"] ?? ""),
                siteRef: toolCall.arguments["site_ref"]
            )
        default:
            return nil
        }
    }

    /// Handles high-level summaries and health snapshots.
    private func executeSummaryTool(_ toolCall: LLMToolCall) async throws -> String? {
        switch toolCall.name {
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
        case "wan_gateway_health":
            return try await wanGatewayHealth(
                logMinutes: Int(toolCall.arguments["minutes"] ?? "")
            )
        default:
            return nil
        }
    }

    /// Handles documentation search/fetch plus Loki-backed log analysis tools.
    private func executeDocsAndLogsTool(_ toolCall: LLMToolCall) async throws -> String? {
        switch toolCall.name {
        case "config_diff_from_logs":
            return try await lokiService.configDiffSummary(
                minutes: Int(toolCall.arguments["minutes"] ?? ""),
                limit: Int(toolCall.arguments["limit"] ?? ""),
                contains: toolCall.arguments["contains"]
            )
        case "search_unifi_docs":
            return try await docsService.search(
                query: toolCall.arguments["query"] ?? "",
                maxResults: Int(toolCall.arguments["max_results"] ?? "")
            )
        case "get_unifi_doc":
            return try await docsService.article(
                articleID: toolCall.arguments["article_id"],
                articleURL: toolCall.arguments["article_url"]
            )
        case "query_unifi_logs":
            return try await lokiService.queryRange(
                query: toolCall.arguments["query"],
                minutes: Int(toolCall.arguments["minutes"] ?? ""),
                limit: Int(toolCall.arguments["limit"] ?? ""),
                direction: toolCall.arguments["direction"]
            )
        case "query_unifi_logs_instant":
            return try await lokiService.queryInstant(
                query: toolCall.arguments["query"],
                limit: Int(toolCall.arguments["limit"] ?? "")
            )
        case "list_unifi_log_labels":
            return try await lokiService.listLabels()
        case "list_unifi_log_label_values":
            return try await lokiService.labelValues(label: toolCall.arguments["label"])
        case "list_unifi_log_series":
            return try await lokiService.listSeries(
                query: toolCall.arguments["query"],
                minutes: Int(toolCall.arguments["minutes"] ?? ""),
                limit: Int(toolCall.arguments["limit"] ?? "")
            )
        case "get_unifi_log_stats":
            return try await lokiService.indexStats(
                query: toolCall.arguments["query"],
                minutes: Int(toolCall.arguments["minutes"] ?? "")
            )
        default:
            return nil
        }
    }

    private func formattedToolError(_ error: Error, toolName: String) -> String {
        if let llmError = error as? LLMError,
           case let .httpError(statusCode, _) = llmError
        {
            if statusCode == 401 || statusCode == 403 {
                return "AUTH_ERROR: \(toolName) was denied by the remote API (HTTP \(statusCode)). Check API key or permissions."
            }
            if statusCode == 429 {
                return "THROTTLED: \(toolName) hit rate limits (HTTP 429). Retry with a smaller query or shortly later."
            }
        }
        return "TOOL_ERROR: \(toolName) failed: \(error.localizedDescription)"
    }

    /// Summarizes gateway health by combining live device inventory with recent UniFi log signals.
    private func wanGatewayHealth(logMinutes rawMinutes: Int?) async throws -> String {
        let devices = try await queryService.queryItems("devices")
        let gateways = devices.filter { isLikelyGateway($0) }
        let minutes = max(1, min(rawMinutes ?? 120, 1440))
        let gatewayLines = formattedGatewayLines(gateways)
        let wanLogs = try await lokiService.queryRange(
            query: #"|~ "(?i)wan|gateway|failover|packet loss|latency|jitter|uplink|isp""#,
            minutes: minutes,
            limit: 40,
            direction: "backward"
        )

        return formattedWANHealthSnapshot(gatewayLines: gatewayLines, minutes: minutes, wanLogs: wanLogs)
    }

    /// Formats the gateway inventory section of the WAN snapshot so inventory extraction
    /// stays separate from the higher-level report layout.
    private func formattedGatewayLines(_ gateways: [[String: Any]]) -> [String] {
        var lines: [String] = gateways.map { gateway in
            let name = firstString(in: gateway, keys: ["name", "hostname", "model", "id"]) ?? "unknown"
            let ip = firstString(in: gateway, keys: ["ipAddress", "ip", "lanIp"]) ?? "unknown"
            let mac = firstString(in: gateway, keys: ["macAddress", "mac"]) ?? "unknown"
            let state = firstString(in: gateway, keys: ["state", "status", "connectionState", "adoptionState"]) ?? "unknown"
            let version = firstString(in: gateway, keys: ["firmwareVersion", "version"]) ?? "unknown"
            return "- \(name) ip=\(ip) mac=\(mac) state=\(state) version=\(version)"
        }
        if lines.isEmpty {
            lines = ["- No gateway devices were identified from current device inventory."]
        }
        return lines
    }

    private func formattedWANHealthSnapshot(gatewayLines: [String], minutes: Int, wanLogs: String) -> String {
        """
        WAN/Gateway health snapshot:
        \(gatewayLines.joined(separator: "\n"))

        Recent WAN/gateway SIEM events (\(minutes)m):
        \(wanLogs)
        """
    }

    /// Returns true when a device row looks like a UniFi gateway or router.
    private func isLikelyGateway(_ device: [String: Any]) -> Bool {
        let candidates = [
            firstString(in: device, keys: ["type"]),
            firstString(in: device, keys: ["role"]),
            firstString(in: device, keys: ["name"]),
            firstString(in: device, keys: ["model"]),
        ]
        let joined = candidates.compactMap { $0?.lowercased() }.joined(separator: " ")
        if joined.contains("gateway") || joined.contains("udm") || joined.contains("uxg") {
            return true
        }
        return device.keys.contains("wan") || device.keys.contains("uplink")
    }

    /// Returns the first non-empty string found in the provided dictionary keys.
    private func firstString(in dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dict[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    /// Lists UniFi clients, optionally including inactive rows when the tool request asks for them.
    private func listClients(includeInactiveRaw: String?) async throws -> String {
        let includeInactive = parseFlexibleBool(includeInactiveRaw)
        if !includeInactive {
            return try await queryService.query("clients")
        }
        let rows = try await resolveClientsIncludingInactive()
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    /// Loads active and inactive client inventories and merges them into one deduplicated list.
    private func resolveClientsIncludingInactive(siteRefHint: String? = nil) async throws -> [[String: Any]] {
        var bestRows = try await bestIntegrationClientRows()
        let siteRef = try await resolveLegacySiteRef(siteRefHint)
        let legacyPath = "/proxy/network/api/s/\(siteRef)/stat/alluser"
        if let legacyPayload = try? await apiClient.getJSON(path: legacyPath) {
            let legacyRows = rowsFromAnyPayload(legacyPayload)
            if legacyRows.count > bestRows.count {
                bestRows = legacyRows
            }
        }
        return bestRows
    }

    /// Probes the supported integration endpoints and keeps the richest client inventory response.
    private func bestIntegrationClientRows() async throws -> [[String: Any]] {
        var bestRows: [[String: Any]] = []

        if let rows = try? await queryService.queryItems("clients-all"), rows.count > bestRows.count {
            bestRows = rows
        }
        if let rows = try? await queryService.queryItems("clients"), rows.count > bestRows.count {
            bestRows = rows
        }

        return bestRows
    }

    /// Resolves the site reference needed by the legacy `/api/s/{site_ref}` fallback path.
    private func resolveLegacySiteRef(_ siteRefHint: String?) async throws -> String {
        var siteRef = (siteRefHint ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !siteRef.isEmpty {
            return siteRef
        }

        if let sites = try? await queryService.queryItems("sites") {
            if let defaultRef = sites.first(where: { (($0["internalReference"] as? String) ?? "") == "default" })?["internalReference"] as? String,
               !defaultRef.isEmpty
            {
                siteRef = defaultRef
            } else if let firstRef = sites.first?["internalReference"] as? String, !firstRef.isEmpty {
                siteRef = firstRef
            }
        }

        return siteRef.isEmpty ? "default" : siteRef
    }

    /// Extracts row dictionaries from either a raw array payload or a paginated UniFi response wrapper.
    private func rowsFromAnyPayload(_ payload: Any) -> [[String: Any]] {
        if let rows = payload as? [[String: Any]] {
            return rows
        }
        if let dict = payload as? [String: Any] {
            if let data = dict["data"] as? [[String: Any]] {
                return data
            }
            if let result = dict["result"] as? [[String: Any]] {
                return result
            }
        }
        return []
    }

    /// Interprets common truthy and falsy strings used in tool arguments.
    private func parseFlexibleBool(_ raw: String?) -> Bool {
        let value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch value {
        case "1", "true", "yes", "y", "on":
            return true
        default:
            return false
        }
    }

    /// Ranks clients in code and returns only the requested top or bottom results.
    private func rankedClientSummary(
        kind: ClientRankingKind,
        limit rawLimit: Int?,
        includeInactiveRaw: String?
    ) async throws -> String {
        let includeInactive = parseFlexibleBool(includeInactiveRaw)
        let limit = max(1, min(rawLimit ?? (kind.defaultLimit), 20))
        let clients = try await loadClientsForRanking(includeInactive: includeInactive)
        let ranked = rankClients(clients, by: kind)

        guard !ranked.isEmpty else {
            return "No clients exposed a usable \(kind.metricLabel) metric."
        }

        let selected = Array(ranked.prefix(limit))
        logRankedClientSummary(kind: kind, selectedCount: selected.count, totalCount: ranked.count, includeInactive: includeInactive)
        return formattedRankedClientSummary(kind: kind, selected: selected, consideredCount: ranked.count, limit: limit)
    }

    /// Applies the metric-specific extraction and ordering for client-ranking tools.
    private func rankClients(_ clients: [[String: Any]], by kind: ClientRankingKind) -> [RankedClientMetric] {
        clients.compactMap { client -> RankedClientMetric? in
            guard let value = metricValue(for: kind, client: client) else { return nil }
            if kind.requiresWireless, isWiredClient(client) { return nil }
            return RankedClientMetric(client: client, value: value)
        }
        .sorted { lhs, rhs in
            if lhs.value != rhs.value {
                return kind.prefersLowerValues ? lhs.value < rhs.value : lhs.value > rhs.value
            }
            return clientDisplayLabel(lhs.client).localizedCaseInsensitiveCompare(clientDisplayLabel(rhs.client)) == .orderedAscending
        }
    }

    private func logRankedClientSummary(
        kind: ClientRankingKind,
        selectedCount: Int,
        totalCount: Int,
        includeInactive: Bool
    ) {
        debugLog(
            "\(kind.toolLabel) ranked \(selectedCount) of \(totalCount) clients (include_inactive=\(includeInactive))",
            category: "Tools"
        )
    }

    private func formattedRankedClientSummary(
        kind: ClientRankingKind,
        selected: [RankedClientMetric],
        consideredCount: Int,
        limit: Int
    ) -> String {
        let heading = limit == 1 ? kind.singularHeading : kind.pluralHeading
        let lines = selected.enumerated().map { index, item in
            formatRankedClientLine(index: index + 1, item: item, kind: kind)
        }
        return """
        \(heading):
        - metric: \(kind.metricLabel)
        - considered_clients: \(consideredCount)
        - returned_clients: \(selected.count)
        \(lines.joined(separator: "\n"))
        """
    }

    /// Loads the client rows used by the ranking tools without returning them to the LLM.
    private func loadClientsForRanking(includeInactive: Bool) async throws -> [[String: Any]] {
        let rows = includeInactive
            ? try await resolveClientsIncludingInactive()
            : try await queryService.queryItems("clients")
        debugLog("Client ranking source loaded (\(rows.count) clients, include_inactive=\(includeInactive))", category: "Tools")
        return rows
    }

    /// Extracts the numeric metric used by a client-ranking tool from a client row.
    private func metricValue(for kind: ClientRankingKind, client: [String: Any]) -> Double? {
        switch kind {
        case .slowestSpeed:
            let candidates = numericValues(
                in: client,
                keys: [
                    "txRate", "rxRate", "tx_rate", "rx_rate", "tx_rate_kbps", "rx_rate_kbps",
                    "linkSpeed", "link_speed", "wiredRate", "wired_rate", "speed", "uplinkSpeed"
                ]
            ).filter { $0 > 0 }
            guard !candidates.isEmpty else { return nil }
            return candidates.min()
        case .weakestSignal:
            let candidates = numericValues(
                in: client,
                keys: ["signal", "signalStrength", "wifiSignal", "rssi"]
            )
            guard !candidates.isEmpty else { return nil }
            if let negative = candidates.filter({ $0 < 0 }).max() {
                return negative
            }
            return candidates.min()
        case .highestLatency:
            let candidates = numericValues(
                in: client,
                keys: ["latency", "avgLatency", "latencyMs", "latency_ms", "ping", "pingMs", "ping_ms"]
            ).filter { $0 >= 0 }
            guard !candidates.isEmpty else { return nil }
            return candidates.max()
        }
    }

    /// Formats one ranked client result as a compact, LLM-friendly summary line.
    private func formatRankedClientLine(index: Int, item: RankedClientMetric, kind: ClientRankingKind) -> String {
        let name = clientDisplayLabel(item.client)
        let mac = firstString(in: item.client, keys: ["mac", "macAddress", "clientMac", "staMac"]) ?? "unknown"
        let ip = firstString(in: item.client, keys: ["ip", "ipAddress", "last_ip", "lastIp"]) ?? "unknown"
        let ap = firstString(in: item.client, keys: ["uplinkDeviceName", "uplink_name", "ap_name", "apName", "radioName"])
            ?? firstString(in: item.client, keys: ["uplinkDeviceId", "ap_mac"])
            ?? "unknown"
        let medium = isWiredClient(item.client) ? "wired" : "wifi"
        return "\(index). name=\(name), \(kind.metricLabel)=\(kind.formatted(item.value)), medium=\(medium), ip=\(ip), mac=\(mac), uplink=\(ap)"
    }

    /// Returns the best display label for compact client-ranking results.
    private func clientDisplayLabel(_ client: [String: Any]) -> String {
        let name = firstString(
            in: client,
            keys: ["name", "displayName", "clientName", "hostname", "hostName", "dhcpHostname", "ip", "ipAddress"]
        ) ?? "unknown-client"
        let suffix = firstString(in: client, keys: ["ip", "ipAddress"])
        if let suffix, !suffix.isEmpty, suffix != name {
            return "\(name) (\(suffix))"
        }
        return name
    }

    /// Returns true when a client row appears to represent a wired client.
    private func isWiredClient(_ client: [String: Any]) -> Bool {
        if let value = boolValue(client["is_wired"]) ?? boolValue(client["isWired"]) {
            return value
        }
        if let radio = firstString(in: client, keys: ["medium", "connectionType", "radio"])?.lowercased(),
           radio.contains("wired") || radio.contains("ethernet") {
            return true
        }
        return false
    }

    /// Extracts numeric values from a client row for the provided key list.
    private func numericValues(in row: [String: Any], keys: [String]) -> [Double] {
        var values: [Double] = []
        for key in keys {
            if let value = numericValue(row[key]) {
                values.append(value)
                continue
            }
            if let nested = row[key] as? [String: Any] {
                values.append(contentsOf: nested.values.compactMap(numericValue))
            }
        }
        return values
    }

    /// Converts a JSON field into a numeric value when possible.
    private func numericValue(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return Double(trimmed)
        case let dict as [String: Any]:
            for candidate in ["value", "current", "avg", "mean"] {
                if let number = numericValue(dict[candidate]) {
                    return number
                }
            }
            return nil
        default:
            return nil
        }
    }

    /// Converts a flexible JSON value into a boolean when possible.
    private func boolValue(_ value: Any?) -> Bool? {
        switch value {
        case let bool as Bool:
            return bool
        case let number as NSNumber:
            return number.boolValue
        case let string as String:
            let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch normalized {
            case "1", "true", "yes", "y", "on":
                return true
            case "0", "false", "no", "n", "off":
                return false
            default:
                return nil
            }
        default:
            return nil
        }
    }

    /// Computes compact rankings for clients, APs, networks, rules, and ports without returning raw inventories.
    private func rankNetworkEntities(
        entityType rawEntityType: String?,
        metric rawMetric: String?,
        limit rawLimit: Int?,
        includeInactiveRaw: String?,
        siteRef rawSiteRef: String?
    ) async throws -> String {
        guard let request = parsedNetworkRankingRequest(
            entityType: rawEntityType,
            metric: rawMetric,
            limit: rawLimit,
            includeInactiveRaw: includeInactiveRaw,
            siteRef: rawSiteRef
        ) else {
            return "Error: rank_network_entities requires non-empty 'entity_type' and 'metric'."
        }
        guard let results = try await rankedNetworkEntityResults(for: request) else {
            return "Error: Unsupported entity_type/metric combination '\(request.entityType)' / '\(request.metric)'."
        }

        let selected = Array(results.prefix(request.limit))
        guard !selected.isEmpty else {
            return "No \(request.displayEntityType) results exposed a usable '\(request.metric)' metric."
        }

        logNetworkRankingCompletion(request: request, returnedCount: selected.count)
        return formattedNetworkRankingResults(request: request, selected: selected)
    }

    private func parsedNetworkRankingRequest(
        entityType rawEntityType: String?,
        metric rawMetric: String?,
        limit rawLimit: Int?,
        includeInactiveRaw: String?,
        siteRef rawSiteRef: String?
    ) -> NetworkRankingRequest? {
        let entityType = normalizeRankingToken(rawEntityType)
        let metric = normalizeRankingToken(rawMetric)
        guard !entityType.isEmpty, !metric.isEmpty else {
            return nil
        }
        return NetworkRankingRequest(
            entityType: entityType,
            metric: metric,
            limit: max(1, min(rawLimit ?? 5, 20)),
            includeInactive: parseFlexibleBool(includeInactiveRaw),
            siteRef: normalizedSiteRef(rawSiteRef)
        )
    }

    /// Routes one normalized entity-ranking request to the helper that owns its metric logic.
    private func rankedNetworkEntityResults(
        for request: NetworkRankingRequest
    ) async throws -> [RankedEntityResult]? {
        switch (request.entityType, request.metric) {
        case ("client", "highest_bandwidth"):
            return try await rankClientsByHighestBandwidth(includeInactive: request.includeInactive)
        case ("client", "reconnect_churn"):
            return try await rankClientsByReconnectChurn(includeInactive: true)
        case ("client", "most_retransmits"):
            return try await rankClientsByMostRetransmits(includeInactive: request.includeInactive)
        case ("client", "offline_recent"):
            return try await rankRecentlyOfflineClients()
        case ("client", "recent_ip_changes"):
            return try await rankClientsByRecentIPChanges(includeInactive: true)
        case ("client", "slowest_speed"):
            return try await rankClientsByMetric(kind: .slowestSpeed, includeInactive: request.includeInactive)
        case ("client", "weakest_signal"):
            return try await rankClientsByMetric(kind: .weakestSignal, includeInactive: request.includeInactive)
        case ("client", "highest_latency"):
            return try await rankClientsByMetric(kind: .highestLatency, includeInactive: request.includeInactive)
        case ("access_point", "client_count"):
            return try await rankAccessPointsByClientCount(includeInactive: request.includeInactive)
        case ("access_point", "weakest_average_signal"):
            return try await rankAccessPointsByWeakestAverageSignal(includeInactive: request.includeInactive)
        case ("access_point", "roam_churn"):
            return try await rankAccessPointsByChurn(kind: .roam, includeInactive: true)
        case ("access_point", "disconnect_churn"):
            return try await rankAccessPointsByChurn(kind: .disconnect, includeInactive: true)
        case ("wifi_broadcast", "client_count"):
            return try await rankWiFiBroadcastsByClientCount(includeInactive: request.includeInactive)
        case ("wifi_broadcast", "weakest_average_signal"):
            return try await rankWiFiBroadcastsByAverageSignal(includeInactive: request.includeInactive, strongest: false)
        case ("wifi_broadcast", "strongest_average_signal"):
            return try await rankWiFiBroadcastsByAverageSignal(includeInactive: request.includeInactive, strongest: true)
        case ("network", "client_count"):
            return try await rankNetworksByClientCount(includeInactive: request.includeInactive)
        case ("network", "reference_count"):
            return try await rankNetworksByReferenceCount()
        case ("switch_port", "errors"):
            return try await rankSwitchPortsByErrors()
        case ("switch_port", "disconnected_client_count"):
            return try await rankSwitchPortsByDisconnectedClients()
        case ("switch_port", "flapping"):
            return try await rankSwitchPortsByFlapping()
        case ("firewall_rule", "hits"):
            return try await rankFirewallRulesByHits()
        case ("firewall_rule", "shadow_risk"):
            return try await rankFirewallRulesByShadowRisk()
        case ("acl_rule", "ordering_risk"):
            return try await rankACLRulesByOrderingRisk()
        case ("vpn_tunnel", "down"):
            return try await rankVPNTunnels(metric: .down)
        case ("vpn_tunnel", "up"):
            return try await rankVPNTunnels(metric: .up)
        case ("vpn_tunnel", "stale"):
            return try await rankVPNTunnels(metric: .stale)
        case ("wan_profile", "healthy"):
            return try await rankWANProfiles(metric: .healthy)
        case ("wan_profile", "unhealthy"):
            return try await rankWANProfiles(metric: .unhealthy)
        case ("dns_policy", "client_count"):
            return try await rankDNSPoliciesByClientCount()
        case ("app_block", "target_count"):
            return try await rankAppBlocksByTargetCount(siteRef: request.siteRef)
        default:
            return nil
        }
    }

    private func logNetworkRankingCompletion(request: NetworkRankingRequest, returnedCount: Int) {
        debugLog(
            "rank_network_entities completed (entity_type=\(request.entityType), metric=\(request.metric), returned=\(returnedCount), include_inactive=\(request.includeInactive))",
            category: "Tools"
        )
    }

    private func formattedNetworkRankingResults(
        request: NetworkRankingRequest,
        selected: [RankedEntityResult]
    ) -> String {
        let lines = selected.enumerated().map { index, item in
            "\(index + 1). \(item.label), \(request.metric)=\(item.valueText)\(item.detail.isEmpty ? "" : ", \(item.detail)")"
        }
        return """
        Ranked \(request.displayEntityType) results:
        - metric: \(request.metric)
        - result_count: \(selected.count)
        \(lines.joined(separator: "\n"))
        """
    }

    /// Ranks clients by one of the compact built-in client metrics.
    private func rankClientsByMetric(kind: ClientRankingKind, includeInactive: Bool) async throws -> [RankedEntityResult] {
        let clients = try await loadClientsForRanking(includeInactive: includeInactive)
        return clients.compactMap { client -> RankedEntityResult? in
            guard let value = metricValue(for: kind, client: client) else { return nil }
            if kind.requiresWireless, isWiredClient(client) { return nil }
            return RankedEntityResult(
                label: "client=\(clientDisplayLabel(client))",
                value: value,
                valueText: kind.formatted(value),
                detail: clientIdentityDetail(client)
            )
        }
        .sorted {
            if $0.value != $1.value {
                return kind.prefersLowerValues ? $0.value < $1.value : $0.value > $1.value
            }
            return $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
    }

    /// Ranks clients by estimated current bandwidth using the best available transmit and receive counters.
    private func rankClientsByHighestBandwidth(includeInactive: Bool) async throws -> [RankedEntityResult] {
        let clients = try await loadClientsForRanking(includeInactive: includeInactive)
        return clients.compactMap { client -> RankedEntityResult? in
            let total = sumNumericValues(
                in: client,
                keys: [
                    "txRate", "rxRate", "tx_rate", "rx_rate", "tx_rate_kbps", "rx_rate_kbps",
                    "downloadKbps", "uploadKbps", "downloadRate", "uploadRate", "throughput"
                ]
            )
            guard total > 0 else { return nil }
            return RankedEntityResult(
                label: "client=\(clientDisplayLabel(client))",
                value: total,
                valueText: String(format: "%.0f Mbps", total),
                detail: clientIdentityDetail(client)
            )
        }
        .sorted { $0.value == $1.value ? $0.label < $1.label : $0.value > $1.value }
    }

    /// Ranks clients by reconnect, reassociation, and disconnect churn counters.
    private func rankClientsByReconnectChurn(includeInactive: Bool) async throws -> [RankedEntityResult] {
        let clients = try await loadClientsForRanking(includeInactive: includeInactive)
        return clients.compactMap { client -> RankedEntityResult? in
            let total = sumNumericValues(
                in: client,
                keys: [
                    "disconnectCount", "disconnect_count", "disconnects", "reconnectCount", "reconnect_count",
                    "reconnects", "reassocCount", "reassoc_count", "associationFailures", "authFailures"
                ]
            )
            guard total > 0 else { return nil }
            return RankedEntityResult(
                label: "client=\(clientDisplayLabel(client))",
                value: total,
                valueText: String(format: "%.0f", total),
                detail: clientIdentityDetail(client)
            )
        }
        .sorted { $0.value == $1.value ? $0.label < $1.label : $0.value > $1.value }
    }

    /// Ranks clients by retransmit or retry counts.
    private func rankClientsByMostRetransmits(includeInactive: Bool) async throws -> [RankedEntityResult] {
        let clients = try await loadClientsForRanking(includeInactive: includeInactive)
        return clients.compactMap { client -> RankedEntityResult? in
            let total = sumNumericValues(
                in: client,
                keys: [
                    "retries", "retryCount", "retry_count", "txRetries", "rxRetries",
                    "tx_retries", "rx_retries", "txRetry", "rxRetry", "txRetryPct", "tx_retry_pct"
                ]
            )
            guard total > 0 else { return nil }
            return RankedEntityResult(
                label: "client=\(clientDisplayLabel(client))",
                value: total,
                valueText: String(format: "%.0f", total),
                detail: clientIdentityDetail(client)
            )
        }
        .sorted { $0.value == $1.value ? $0.label < $1.label : $0.value > $1.value }
    }

    /// Ranks inactive clients by how recently they were last seen.
    private func rankRecentlyOfflineClients() async throws -> [RankedEntityResult] {
        let clients = try await loadClientsForRanking(includeInactive: true)
        return clients.compactMap { client -> RankedEntityResult? in
            guard !isClientActiveForRanking(client) else { return nil }
            guard let date = latestDate(in: client, keys: ["lastSeen", "last_seen", "lastConnected", "disconnect_timestamp", "connectedAt"]) else {
                return nil
            }
            return RankedEntityResult(
                label: "client=\(clientDisplayLabel(client))",
                value: date.timeIntervalSince1970,
                valueText: isoDateString(date),
                detail: clientIdentityDetail(client)
            )
        }
        .sorted { $0.value == $1.value ? $0.label < $1.label : $0.value > $1.value }
    }

    /// Ranks clients that appear to have changed IP by the number of distinct observed IP fields.
    private func rankClientsByRecentIPChanges(includeInactive: Bool) async throws -> [RankedEntityResult] {
        let clients = try await loadClientsForRanking(includeInactive: includeInactive)
        return clients.compactMap { client -> RankedEntityResult? in
            let ips = uniqueRankingStrings(
                stringCandidates(in: client, keys: ["ip", "ipAddress", "last_ip", "lastIp", "fixed_ip", "fixedIp", "previous_ip", "previousIp"])
            )
            guard ips.count > 1 else { return nil }
            let changeCount = Double(ips.count - 1)
            return RankedEntityResult(
                label: "client=\(clientDisplayLabel(client))",
                value: changeCount,
                valueText: "\(Int(changeCount))",
                detail: "ips=\(ips.joined(separator: " -> ")), \(clientIdentityDetail(client))"
            )
        }
        .sorted { $0.value == $1.value ? $0.label < $1.label : $0.value > $1.value }
    }

    /// Ranks access points by the number of currently associated clients.
    private func rankAccessPointsByClientCount(includeInactive: Bool) async throws -> [RankedEntityResult] {
        let context = try await accessPointRankingContext()
        let clients = try await loadClientsForRanking(includeInactive: includeInactive)
        let activeClients = clients.filter { isClientActiveForRanking($0) }
        let grouped = groupClientsByAccessPoint(
            activeClients,
            onlineDeviceIDs: context.onlineDeviceIDs
        )
        return rankedAccessPointCounts(grouped, nameByID: context.deviceNameByID)
    }

    /// Ranks access points by the weakest average signal across their associated WiFi clients.
    private func rankAccessPointsByWeakestAverageSignal(includeInactive: Bool) async throws -> [RankedEntityResult] {
        let context = try await accessPointRankingContext()
        let clients = try await loadClientsForRanking(includeInactive: includeInactive)
        let activeWirelessClients = clients.filter { isClientActiveForRanking($0) && !isWiredClient($0) }
        let grouped = groupClientsByAccessPoint(
            activeWirelessClients,
            onlineDeviceIDs: context.onlineDeviceIDs
        )
        return rankedAccessPointAverages(
            grouped,
            nameByID: context.deviceNameByID,
            metricExtractor: { metricValue(for: .weakestSignal, client: $0) },
            valueFormatter: { String(format: "%.1f dBm", $0) },
            detailFormatter: { "clients=\($0.rows.count), device_id=\($0.uplinkID)" },
            prefersLowerValues: true
        )
    }

    /// Ranks access points by cumulative roam or disconnect churn observed in their associated clients.
    private func rankAccessPointsByChurn(kind: AccessPointChurnKind, includeInactive: Bool) async throws -> [RankedEntityResult] {
        let context = try await accessPointRankingContext()
        let clients = try await loadClientsForRanking(includeInactive: includeInactive)
        let grouped = groupClientsByAccessPoint(clients)
        return rankedAccessPointTotals(
            grouped,
            nameByID: context.deviceNameByID,
            totalExtractor: { rows in rows.reduce(0) { $0 + sumNumericValues(in: $1, keys: kind.keys) } }
        )
    }

    /// Builds the shared AP/device lookup tables used across access-point ranking helpers.
    private func accessPointRankingContext() async throws -> AccessPointRankingContext {
        let devices = try await queryService.queryItems("devices")
        let onlineDeviceIDs = Set(devices.compactMap { device -> String? in
            guard isDeviceOnlineForRanking(device) else { return nil }
            return firstString(in: device, keys: ["id", "_id"])
        })
        let deviceNameByID = Dictionary(uniqueKeysWithValues: devices.compactMap { device -> (String, String)? in
            guard let id = firstString(in: device, keys: ["id", "_id"]) else { return nil }
            return (id, firstString(in: device, keys: ["name", "hostname", "model"]) ?? id)
        })
        return AccessPointRankingContext(deviceNameByID: deviceNameByID, onlineDeviceIDs: onlineDeviceIDs)
    }

    /// Groups client rows by uplink device, optionally restricting to online APs and a caller-supplied predicate.
    private func groupClientsByAccessPoint(
        _ clients: [[String: Any]],
        onlineDeviceIDs: Set<String>? = nil,
        predicate: (([String: Any]) -> Bool)? = nil
    ) -> [String: [[String: Any]]] {
        let filtered = clients.filter { client in
            if let predicate, !predicate(client) {
                return false
            }
            guard let uplinkID = accessPointID(for: client) else {
                return false
            }
            if let onlineDeviceIDs {
                return onlineDeviceIDs.contains(uplinkID)
            }
            return true
        }
        return Dictionary(grouping: filtered) { accessPointID(for: $0) ?? "unknown" }
    }

    private func accessPointID(for client: [String: Any]) -> String? {
        firstString(in: client, keys: ["uplinkDeviceId", "uplink_device_id", "apId", "ap_id", "uplinkApId"])
    }

    private func rankedAccessPointCounts(
        _ grouped: [String: [[String: Any]]],
        nameByID: [String: String]
    ) -> [RankedEntityResult] {
        grouped.compactMap { uplinkID, rows in
            guard uplinkID != "unknown" else { return nil }
            let label = nameByID[uplinkID] ?? uplinkID
            return RankedEntityResult(
                label: "access_point=\(label)",
                value: Double(rows.count),
                valueText: "\(rows.count)",
                detail: "device_id=\(uplinkID)"
            )
        }
        .sorted { $0.value == $1.value ? $0.label < $1.label : $0.value > $1.value }
    }

    private func rankedAccessPointAverages(
        _ grouped: [String: [[String: Any]]],
        nameByID: [String: String],
        metricExtractor: ([String: Any]) -> Double?,
        valueFormatter: (Double) -> String,
        detailFormatter: ((uplinkID: String, rows: [[String: Any]])) -> String,
        prefersLowerValues: Bool
    ) -> [RankedEntityResult] {
        grouped.compactMap { uplinkID, rows in
            let values = rows.compactMap(metricExtractor)
            guard !values.isEmpty else { return nil }
            let average = values.reduce(0, +) / Double(values.count)
            let label = nameByID[uplinkID] ?? uplinkID
            return RankedEntityResult(
                label: "access_point=\(label)",
                value: average,
                valueText: valueFormatter(average),
                detail: detailFormatter((uplinkID, rows))
            )
        }
        .sorted {
            if $0.value == $1.value { return $0.label < $1.label }
            return prefersLowerValues ? ($0.value < $1.value) : ($0.value > $1.value)
        }
    }

    private func rankedAccessPointTotals(
        _ grouped: [String: [[String: Any]]],
        nameByID: [String: String],
        totalExtractor: ([[String: Any]]) -> Double
    ) -> [RankedEntityResult] {
        grouped.compactMap { uplinkID, rows in
            let total = totalExtractor(rows)
            guard total > 0 else { return nil }
            let label = nameByID[uplinkID] ?? uplinkID
            return RankedEntityResult(
                label: "access_point=\(label)",
                value: total,
                valueText: String(format: "%.0f", total),
                detail: "clients=\(rows.count), device_id=\(uplinkID)"
            )
        }
        .sorted { $0.value == $1.value ? $0.label < $1.label : $0.value > $1.value }
    }

    /// Ranks WiFi broadcasts by the number of associated wireless clients.
    private func rankWiFiBroadcastsByClientCount(includeInactive: Bool) async throws -> [RankedEntityResult] {
        let wifiBroadcasts = try await queryService.queryItems("wifi-broadcasts")
        let clients = try await loadClientsForRanking(includeInactive: includeInactive)
        let grouped = groupWirelessClientsByBroadcast(clients, broadcasts: wifiBroadcasts)
        return rankedNamedCounts(grouped, labelPrefix: "wifi_broadcast", detailBuilder: { _ in "" })
    }

    /// Ranks WiFi broadcasts by their average client signal, strongest or weakest first.
    private func rankWiFiBroadcastsByAverageSignal(includeInactive: Bool, strongest: Bool) async throws -> [RankedEntityResult] {
        let wifiBroadcasts = try await queryService.queryItems("wifi-broadcasts")
        let clients = try await loadClientsForRanking(includeInactive: includeInactive)
        let grouped = groupWirelessClientsByBroadcast(clients, broadcasts: wifiBroadcasts)
        return rankedNamedAverages(
            grouped,
            labelPrefix: "wifi_broadcast",
            metricExtractor: { metricValue(for: .weakestSignal, client: $0) },
            valueFormatter: { String(format: "%.1f dBm", $0) },
            detailFormatter: { rows in "clients=\(rows.count)" },
            prefersLowerValues: !strongest
        )
    }

    /// Ranks networks by how many client rows currently point at them.
    private func rankNetworksByClientCount(includeInactive: Bool) async throws -> [RankedEntityResult] {
        let networks = try await queryService.queryItems("networks")
        let networkNameByID = networkNameMap(networks)
        let clients = try await loadClientsForRanking(includeInactive: includeInactive)
        let grouped = groupActiveClientsByNetwork(clients)
        return rankedNetworkCounts(grouped, nameByID: networkNameByID)
    }

    /// Ranks networks by how many policy-like objects reference them.
    private func rankNetworksByReferenceCount() async throws -> [RankedEntityResult] {
        let networks = try await queryService.queryItems("networks")
        let wifiBroadcasts = try await queryService.queryItems("wifi-broadcasts")
        let dnsPolicies = try await queryService.queryItems("dns-policies")
        let firewallPolicies = try await queryService.queryItems("firewall-policies")
        let aclRules = try await queryService.queryItems("acl-rules")

        return networks.compactMap { network -> RankedEntityResult? in
            guard let networkID = firstString(in: network, keys: ["id", "_id"]) else { return nil }
            let count =
                referenceCount(for: networkID, in: wifiBroadcasts) +
                referenceCount(for: networkID, in: dnsPolicies) +
                referenceCount(for: networkID, in: firewallPolicies) +
                referenceCount(for: networkID, in: aclRules)
            return makeNetworkRankingResult(networkID: networkID, label: firstString(in: network, keys: ["name"]) ?? networkID, count: count)
        }
        .sorted { $0.value == $1.value ? $0.label < $1.label : $0.value > $1.value }
    }

    /// Groups active wireless clients by resolved Wi-Fi broadcast name.
    private func groupWirelessClientsByBroadcast(
        _ clients: [[String: Any]],
        broadcasts: [[String: Any]]
    ) -> [String: [[String: Any]]] {
        let wirelessClients = clients.filter { !isWiredClient($0) && isClientActiveForRanking($0) }
        return Dictionary(grouping: wirelessClients) { client in
            wifiBroadcastName(for: client, broadcasts: broadcasts) ?? "unknown"
        }
    }

    private func rankedNamedCounts(
        _ grouped: [String: [[String: Any]]],
        labelPrefix: String,
        detailBuilder: (String) -> String
    ) -> [RankedEntityResult] {
        grouped.compactMap { name, rows in
            guard name != "unknown" else { return nil }
            return RankedEntityResult(
                label: "\(labelPrefix)=\(name)",
                value: Double(rows.count),
                valueText: "\(rows.count)",
                detail: detailBuilder(name)
            )
        }
        .sorted { $0.value == $1.value ? $0.label < $1.label : $0.value > $1.value }
    }

    private func rankedNamedAverages(
        _ grouped: [String: [[String: Any]]],
        labelPrefix: String,
        metricExtractor: ([String: Any]) -> Double?,
        valueFormatter: (Double) -> String,
        detailFormatter: ([[String: Any]]) -> String,
        prefersLowerValues: Bool
    ) -> [RankedEntityResult] {
        grouped.compactMap { name, rows in
            guard name != "unknown" else { return nil }
            let values = rows.compactMap(metricExtractor)
            guard !values.isEmpty else { return nil }
            let average = values.reduce(0, +) / Double(values.count)
            return RankedEntityResult(
                label: "\(labelPrefix)=\(name)",
                value: average,
                valueText: valueFormatter(average),
                detail: detailFormatter(rows)
            )
        }
        .sorted {
            if $0.value == $1.value { return $0.label < $1.label }
            return prefersLowerValues ? ($0.value < $1.value) : ($0.value > $1.value)
        }
    }

    private func networkNameMap(_ networks: [[String: Any]]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: networks.compactMap { network -> (String, String)? in
            guard let id = firstString(in: network, keys: ["id", "_id"]) else { return nil }
            return (id, firstString(in: network, keys: ["name"]) ?? id)
        })
    }

    private func groupActiveClientsByNetwork(_ clients: [[String: Any]]) -> [String: [[String: Any]]] {
        let currentClients = clients.filter { isClientActiveForRanking($0) }
        return Dictionary(grouping: currentClients) { client in
            firstString(in: client, keys: ["networkId", "network_id", "last_connection_network_id", "lastConnectionNetworkId"]) ?? "unknown"
        }
    }

    private func rankedNetworkCounts(
        _ grouped: [String: [[String: Any]]],
        nameByID: [String: String]
    ) -> [RankedEntityResult] {
        grouped.compactMap { networkID, rows in
            guard networkID != "unknown" else { return nil }
            let label = nameByID[networkID] ?? networkID
            return RankedEntityResult(
                label: "network=\(label)",
                value: Double(rows.count),
                valueText: "\(rows.count)",
                detail: "network_id=\(networkID)"
            )
        }
        .sorted { $0.value == $1.value ? $0.label < $1.label : $0.value > $1.value }
    }

    private func makeNetworkRankingResult(networkID: String, label: String, count: Int) -> RankedEntityResult? {
        guard count > 0 else { return nil }
        return RankedEntityResult(
            label: "network=\(label)",
            value: Double(count),
            valueText: "\(count)",
            detail: "network_id=\(networkID)"
        )
    }

    /// Ranks switch ports by accumulated error counters exposed in the device payload.
    private func rankSwitchPortsByErrors() async throws -> [RankedEntityResult] {
        let context = try await switchPortRankingContext()
        return rankedSwitchPorts(
            devices: context.devices,
            valueExtractor: { port in
                sumNumericValues(
                    in: port,
                    keys: ["errors", "errorCount", "rxErrors", "txErrors", "crcErrors", "drops", "dropped", "discarded"]
                )
            },
            valueFormatter: { String(format: "%.0f", $0) },
            minimumValue: 0
        )
    }

    /// Ranks switch ports by how many inactive clients last reported behind them.
    private func rankSwitchPortsByDisconnectedClients() async throws -> [RankedEntityResult] {
        let context = try await switchPortRankingContext()
        let clients = try await loadClientsForRanking(includeInactive: true)
        let counts = disconnectedClientCountsBySwitchPort(clients)
        return rankedDisconnectedSwitchPorts(counts, nameByID: context.deviceNameByID)
    }

    /// Ranks switch ports by flap-like counters that indicate repeated link state changes.
    private func rankSwitchPortsByFlapping() async throws -> [RankedEntityResult] {
        let context = try await switchPortRankingContext()
        return rankedSwitchPorts(
            devices: context.devices,
            valueExtractor: { port in
                sumNumericValues(
                    in: port,
                    keys: ["linkFlaps", "link_flaps", "flaps", "upDownCount", "up_down_count", "linkDownCount", "linkUpCount", "stpTransitions", "stateChanges"]
                )
            },
            valueFormatter: { String(format: "%.0f", $0) },
            minimumValue: 0
        )
    }

    /// Builds the shared switch/device lookup tables used across switch-port ranking helpers.
    private func switchPortRankingContext() async throws -> SwitchPortRankingContext {
        let devices = try await queryService.queryItems("devices")
        let deviceNameByID = Dictionary(uniqueKeysWithValues: devices.compactMap { device -> (String, String)? in
            guard let id = firstString(in: device, keys: ["id", "_id"]) else { return nil }
            return (id, firstString(in: device, keys: ["name", "hostname", "model"]) ?? id)
        })
        return SwitchPortRankingContext(devices: devices, deviceNameByID: deviceNameByID)
    }

    /// Extracts one ranked result per switch port using the provided numeric port metric.
    private func rankedSwitchPorts(
        devices: [[String: Any]],
        valueExtractor: ([String: Any]) -> Double,
        valueFormatter: (Double) -> String,
        minimumValue: Double
    ) -> [RankedEntityResult] {
        var results: [RankedEntityResult] = []
        for device in devices {
            let deviceLabel = firstString(in: device, keys: ["name", "hostname", "model", "id"]) ?? "unknown-device"
            for port in extractPortRows(from: device) {
                let value = valueExtractor(port)
                guard value > minimumValue else { continue }
                let portLabel = switchPortLabel(port)
                results.append(
                    RankedEntityResult(
                        label: "switch_port=\(deviceLabel) port \(portLabel)",
                        value: value,
                        valueText: valueFormatter(value),
                        detail: "device=\(deviceLabel)"
                    )
                )
            }
        }
        return results.sorted { $0.value == $1.value ? $0.label < $1.label : $0.value > $1.value }
    }

    private func disconnectedClientCountsBySwitchPort(_ clients: [[String: Any]]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for client in clients where !isClientActiveForRanking(client) {
            guard let key = switchPortKey(for: client) else { continue }
            counts[key, default: 0] += 1
        }
        return counts
    }

    private func rankedDisconnectedSwitchPorts(
        _ counts: [String: Int],
        nameByID: [String: String]
    ) -> [RankedEntityResult] {
        counts.map { key, count in
            let parsed = splitSwitchPortKey(key)
            let deviceLabel = nameByID[parsed.deviceID] ?? parsed.deviceID
            return RankedEntityResult(
                label: "switch_port=\(deviceLabel) port \(parsed.portLabel)",
                value: Double(count),
                valueText: "\(count)",
                detail: "device=\(deviceLabel)"
            )
        }
        .sorted { $0.value == $1.value ? $0.label < $1.label : $0.value > $1.value }
    }

    private func switchPortLabel(_ port: [String: Any]) -> String {
        firstString(in: port, keys: ["name", "portName", "port", "portIdx", "index", "id"]) ?? "unknown-port"
    }

    /// Ranks firewall rules by hit or match counters.
    private func rankFirewallRulesByHits() async throws -> [RankedEntityResult] {
        let policies = try await queryService.queryItems("firewall-policies")
        return rankedRuleHits(
            policies,
            labelPrefix: "firewall_rule",
            detailPrefix: "rule_id"
        )
    }

    /// Ranks firewall rules that look shadowed by earlier rules with matching scope.
    private func rankFirewallRulesByShadowRisk() async throws -> [RankedEntityResult] {
        let policies = try await queryService.queryItems("firewall-policies")
        return rankRulesByOrderingRisk(rows: policies, labelPrefix: "firewall_rule", detailPrefix: "rule_id")
    }

    /// Ranks ACL rules that look misordered relative to earlier rules with matching scope.
    private func rankACLRulesByOrderingRisk() async throws -> [RankedEntityResult] {
        let rules = try await queryService.queryItems("acl-rules")
        return rankRulesByOrderingRisk(rows: rules, labelPrefix: "acl_rule", detailPrefix: "rule_id")
    }

    /// Ranks VPN tunnels by state or staleness without returning the full tunnel list.
    private func rankVPNTunnels(metric: VPNTunnelMetric) async throws -> [RankedEntityResult] {
        let tunnels = try await queryService.queryItems("site-to-site-vpn")
        return tunnels.compactMap { rankedVPNTunnel($0, metric: metric) }
            .sorted { $0.value == $1.value ? $0.label < $1.label : $0.value > $1.value }
    }

    /// Ranks WAN profiles by a heuristic health score derived from state and available telemetry.
    private func rankWANProfiles(metric: WANHealthMetric) async throws -> [RankedEntityResult] {
        let profiles = try await queryService.queryItems("wan-profiles")
        return profiles.compactMap { rankedWANProfile($0, metric: metric) }
            .sorted { $0.value == $1.value ? $0.label < $1.label : $0.value > $1.value }
    }

    /// Ranks DNS policies by the number of explicit clients or devices they target.
    private func rankDNSPoliciesByClientCount() async throws -> [RankedEntityResult] {
        let policies = try await queryService.queryItems("dns-policies")
        return rankedTargetCounts(
            policies,
            labelPrefix: "dns_policy",
            detailPrefix: "policy_id",
            countExtractor: { targetCount(for: $0) }
        )
    }

    /// Ranks simple app-block rules by how many client targets they contain.
    private func rankAppBlocksByTargetCount(siteRef: String) async throws -> [RankedEntityResult] {
        let payload = try await apiClient.getJSON(path: "/proxy/network/v2/api/site/\(siteRef)/firewall-app-blocks")
        let rules = rowsFromAnyPayload(payload)
        return rankedTargetCounts(
            rules,
            labelPrefix: "app_block",
            detailPrefix: "site_ref",
            countExtractor: { max(targetCount(for: $0), stringCandidates(in: $0, keys: ["client_macs"]).count) },
            detailValue: siteRef
        )
    }

    private func rankedRuleHits(
        _ rows: [[String: Any]],
        labelPrefix: String,
        detailPrefix: String
    ) -> [RankedEntityResult] {
        rows.compactMap { row in
            let hits = firstPositiveValue(
                in: row,
                keys: ["hitCount", "hit_count", "hits", "packetCount", "matchCount", "matchedPackets"],
                nestedKeys: ["statistics", "stats"]
            )
            guard let hits, hits > 0 else { return nil }
            return RankedEntityResult(
                label: "\(labelPrefix)=\(ruleDisplayLabel(row))",
                value: hits,
                valueText: String(format: "%.0f", hits),
                detail: "\(detailPrefix)=\(ruleIdentifier(row))"
            )
        }
        .sorted { $0.value == $1.value ? $0.label < $1.label : $0.value > $1.value }
    }

    private func rankedVPNTunnel(_ tunnel: [String: Any], metric: VPNTunnelMetric) -> RankedEntityResult? {
        let state = ruleStateText(from: tunnel)
        let isUp = stateLooksHealthy(state)
        let label = "vpn_tunnel=\(vpnTunnelLabel(tunnel))"
        let detail = vpnTunnelLastSeenDetail(tunnel)
        let age = vpnTunnelAge(tunnel)

        switch metric {
        case .down:
            guard !isUp else { return nil }
            return RankedEntityResult(
                label: label,
                value: age > 0 ? age : 1,
                valueText: state.isEmpty ? "down" : state,
                detail: detail
            )
        case .up:
            guard isUp else { return nil }
            return RankedEntityResult(
                label: label,
                value: latestDate(in: tunnel, keys: vpnTunnelLastSeenKeys)?.timeIntervalSince1970 ?? 1,
                valueText: state.isEmpty ? "up" : state,
                detail: detail
            )
        case .stale:
            guard age > 0 else { return nil }
            return RankedEntityResult(
                label: label,
                value: age,
                valueText: String(format: "%.0f min", age / 60),
                detail: "state=\(state.isEmpty ? "unknown" : state)"
            )
        }
    }

    private var vpnTunnelLastSeenKeys: [String] {
        ["lastSeen", "last_seen", "lastConnected", "connectedAt", "updatedAt", "lastHandshake", "last_handshake"]
    }

    private func vpnTunnelLabel(_ tunnel: [String: Any]) -> String {
        firstString(in: tunnel, keys: ["name", "displayName", "remoteSiteName", "peerName", "id", "_id"]) ?? "unknown-tunnel"
    }

    private func vpnTunnelAge(_ tunnel: [String: Any]) -> Double {
        latestDate(in: tunnel, keys: vpnTunnelLastSeenKeys).map { max(0, Date().timeIntervalSince($0)) } ?? 0
    }

    private func vpnTunnelLastSeenDetail(_ tunnel: [String: Any]) -> String {
        latestDate(in: tunnel, keys: vpnTunnelLastSeenKeys).map { "last_seen=\(isoDateString($0))" } ?? "last_seen=unknown"
    }

    private func rankedWANProfile(_ profile: [String: Any], metric: WANHealthMetric) -> RankedEntityResult? {
        let telemetry = wanProfileTelemetry(profile)
        let detail = wanProfileDetail(telemetry)
        let label = "wan_profile=\(wanProfileLabel(profile))"

        switch metric {
        case .healthy:
            guard telemetry.healthyScore > 0 else { return nil }
            return RankedEntityResult(
                label: label,
                value: telemetry.healthyScore,
                valueText: String(format: "%.0f", telemetry.healthyScore),
                detail: detail
            )
        case .unhealthy:
            guard telemetry.penalty > 0 else { return nil }
            return RankedEntityResult(
                label: label,
                value: telemetry.penalty,
                valueText: String(format: "%.0f", telemetry.penalty),
                detail: detail
            )
        }
    }

    private func wanProfileLabel(_ profile: [String: Any]) -> String {
        firstString(in: profile, keys: ["name", "displayName", "ispName", "id", "_id"]) ?? "unknown-wan"
    }

    private func wanProfileTelemetry(_ profile: [String: Any]) -> (state: String, packetLoss: Double, latency: Double, jitter: Double, penalty: Double, healthyScore: Double) {
        let state = ruleStateText(from: profile)
        let packetLoss = firstPositiveValue(in: profile, keys: ["packetLoss", "packet_loss", "lossPct", "loss_percent"], nestedKeys: ["health", "statistics", "stats"]) ?? 0
        let latency = firstPositiveValue(in: profile, keys: ["latency", "avgLatency", "latencyMs", "latency_ms"], nestedKeys: ["health", "statistics", "stats"]) ?? 0
        let jitter = firstPositiveValue(in: profile, keys: ["jitter", "jitterMs", "jitter_ms"], nestedKeys: ["health", "statistics", "stats"]) ?? 0
        let penalty = (stateLooksHealthy(state) ? 0 : 100) + packetLoss * 5 + (latency / 10) + (jitter / 5)
        let healthyScore = max(0, 100 - penalty)
        return (state, packetLoss, latency, jitter, penalty, healthyScore)
    }

    private func wanProfileDetail(_ telemetry: (state: String, packetLoss: Double, latency: Double, jitter: Double, penalty: Double, healthyScore: Double)) -> String {
        "state=\(telemetry.state.isEmpty ? "unknown" : telemetry.state), loss=\(Int(telemetry.packetLoss))%, latency=\(Int(telemetry.latency))ms, jitter=\(Int(telemetry.jitter))ms"
    }

    private func rankedTargetCounts(
        _ rows: [[String: Any]],
        labelPrefix: String,
        detailPrefix: String,
        countExtractor: ([String: Any]) -> Int,
        detailValue: String? = nil
    ) -> [RankedEntityResult] {
        rows.compactMap { row in
            let count = countExtractor(row)
            guard count > 0 else { return nil }
            let label = firstString(in: row, keys: ["name", "_id", "id"]) ?? "unknown"
            let detail = detailValue ?? ruleIdentifier(row)
            return RankedEntityResult(
                label: "\(labelPrefix)=\(label)",
                value: Double(count),
                valueText: "\(count)",
                detail: "\(detailPrefix)=\(detail)"
            )
        }
        .sorted { $0.value == $1.value ? $0.label < $1.label : $0.value > $1.value }
    }

    private func ruleDisplayLabel(_ row: [String: Any]) -> String {
        firstString(in: row, keys: ["name", "id", "_id"]) ?? "unknown-rule"
    }

    private func ruleIdentifier(_ row: [String: Any]) -> String {
        firstString(in: row, keys: ["id", "_id"]) ?? "unknown"
    }

    /// Normalizes ranking tokens so tool arguments can use spaces, hyphens, or underscores interchangeably.
    private func normalizeRankingToken(_ value: String?) -> String {
        (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    /// Builds a compact client identity suffix for ranked result lines.
    private func clientIdentityDetail(_ client: [String: Any]) -> String {
        let medium = isWiredClient(client) ? "wired" : "wifi"
        let ip = firstString(in: client, keys: ["ip", "ipAddress", "last_ip", "lastIp"]) ?? "unknown"
        let mac = firstString(in: client, keys: ["mac", "macAddress", "clientMac", "staMac"]) ?? "unknown"
        let uplink = firstString(in: client, keys: ["uplinkDeviceName", "uplinkDeviceId", "ap_name", "apName"]) ?? "unknown"
        return "medium=\(medium), ip=\(ip), mac=\(mac), uplink=\(uplink)"
    }

    /// Returns true when a client row appears to be active or currently connected.
    private func isClientActiveForRanking(_ client: [String: Any]) -> Bool {
        if let active = boolValue(client["active"]) ?? boolValue(client["isActive"]) ?? boolValue(client["is_online"]) ?? boolValue(client["isOnline"]) {
            return active
        }
        if let state = firstString(in: client, keys: ["state", "status", "connectionState"])?.lowercased() {
            if state.contains("offline") || state.contains("disconnected") || state.contains("inactive") {
                return false
            }
            if state.contains("online") || state.contains("connected") || state.contains("active") {
                return true
            }
        }
        if let timestamp = latestDate(in: client, keys: ["disconnect_timestamp"]), timestamp <= Date() {
            return false
        }
        return true
    }

    /// Returns true when a device row appears to be online and currently serving traffic.
    private func isDeviceOnlineForRanking(_ device: [String: Any]) -> Bool {
        if let active = boolValue(device["active"]) ?? boolValue(device["isActive"]) ?? boolValue(device["is_online"]) ?? boolValue(device["isOnline"]) {
            return active
        }
        if let state = firstString(in: device, keys: ["state", "status", "connectionState", "uplink_status"])?.lowercased() {
            if state.contains("offline") || state.contains("disconnected") || state.contains("inactive") || state.contains("down") {
                return false
            }
            if state.contains("online") || state.contains("connected") || state.contains("active") || state.contains("up") {
                return true
            }
        }
        return true
    }

    /// Sums numeric values across a set of likely field names.
    private func sumNumericValues(in row: [String: Any], keys: [String]) -> Double {
        keys.reduce(0) { partial, key in
            partial + (numericValue(row[key]) ?? 0)
        }
    }

    /// Returns the first positive numeric value from direct or nested dictionaries.
    private func firstPositiveValue(in row: [String: Any], keys: [String], nestedKeys: [String]) -> Double? {
        for key in keys {
            if let value = numericValue(row[key]), value > 0 {
                return value
            }
        }
        for nestedKey in nestedKeys {
            guard let nested = row[nestedKey] as? [String: Any] else { continue }
            for key in keys {
                if let value = numericValue(nested[key]), value > 0 {
                    return value
                }
            }
        }
        return nil
    }

    /// Collects non-empty string candidates from direct fields or string arrays.
    private func stringCandidates(in row: [String: Any], keys: [String]) -> [String] {
        var values: [String] = []
        for key in keys {
            if let text = firstString(in: row, keys: [key]), !text.isEmpty {
                values.append(text)
            }
            if let array = row[key] as? [Any] {
                values.append(contentsOf: array.map { String(describing: $0) }.filter { !$0.isEmpty })
            }
        }
        return uniqueRankingStrings(values)
    }

    /// Returns the input strings with empties removed and duplicates collapsed in order.
    private func uniqueRankingStrings(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var output: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            output.append(trimmed)
        }
        return output
    }

    /// Returns the normalized site reference, defaulting to `default` when omitted.
    private func normalizedSiteRef(_ rawSiteRef: String?) -> String {
        let candidate = (rawSiteRef ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.isEmpty ? "default" : candidate
    }

    /// Returns the most recent date parsed from a set of likely timestamp fields.
    private func latestDate(in row: [String: Any], keys: [String]) -> Date? {
        keys.compactMap { dateValue(row[$0]) }.max()
    }

    /// Converts a timestamp-like JSON value into a Date when possible.
    private func dateValue(_ value: Any?) -> Date? {
        switch value {
        case let number as NSNumber:
            let raw = number.doubleValue
            if raw > 10_000_000_000 {
                return Date(timeIntervalSince1970: raw / 1000)
            }
            return Date(timeIntervalSince1970: raw)
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if let seconds = Double(trimmed) {
                return dateValue(NSNumber(value: seconds))
            }
            let formatter = ISO8601DateFormatter()
            return formatter.date(from: trimmed)
        default:
            return nil
        }
    }

    /// Formats a Date in ISO-8601 form for compact ranking outputs.
    private func isoDateString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// Extracts candidate switch-port dictionaries from a device row.
    private func extractPortRows(from device: [String: Any]) -> [[String: Any]] {
        let keys = ["ports", "port_table", "portTable", "interfaces", "ethernet_table", "ethernetPorts"]
        for key in keys {
            if let rows = device[key] as? [[String: Any]], !rows.isEmpty {
                return rows
            }
            if let values = device[key] as? [Any] {
                let rows = values.compactMap { $0 as? [String: Any] }
                if !rows.isEmpty {
                    return rows
                }
            }
        }
        return []
    }

    /// Counts the explicit targets attached to a rule or policy payload.
    private func targetCount(for row: [String: Any]) -> Int {
        let directArrays = [
            row["client_macs"], row["client_ids"], row["clientIds"], row["devices"], row["deviceIds"],
            row["targetDevices"], row["target_devices"], row["source_devices"], row["network_ids"], row["networks"]
        ]
        let directCount = directArrays.reduce(0) { partial, value in
            partial + ((value as? [Any])?.count ?? 0)
        }
        if directCount > 0 { return directCount }
        if let target = row["target"] as? [String: Any] {
            return targetCount(for: target)
        }
        return 0
    }

    /// Resolves the WiFi broadcast name a client most likely belongs to using direct SSID fields or broadcast IDs.
    private func wifiBroadcastName(for client: [String: Any], broadcasts: [[String: Any]]) -> String? {
        if let direct = firstString(in: client, keys: ["essid", "ssid", "wifiName", "network", "networkName", "wlan", "radioName"]) {
            return direct
        }
        let broadcastID = firstString(in: client, keys: ["wifiBroadcastId", "wifi_broadcast_id", "wlanconfId", "wlanconf_id"])
        let networkID = firstString(in: client, keys: ["networkId", "network_id", "last_connection_network_id", "lastConnectionNetworkId"])
        for broadcast in broadcasts {
            if let id = firstString(in: broadcast, keys: ["id", "_id"]), id == broadcastID {
                return firstString(in: broadcast, keys: ["name", "ssid", "essid"]) ?? id
            }
            if let id = firstString(in: broadcast, keys: ["networkId", "network_id"]), id == networkID {
                return firstString(in: broadcast, keys: ["name", "ssid", "essid"]) ?? id
            }
        }
        return nil
    }

    /// Counts how often a given network identifier appears anywhere inside a collection of policy-like rows.
    private func referenceCount(for networkID: String, in rows: [[String: Any]]) -> Int {
        rows.reduce(0) { partial, row in
            partial + (rowContainsToken(row, token: networkID) ? 1 : 0)
        }
    }

    /// Returns true when a nested row contains a token in any string field or array element.
    private func rowContainsToken(_ value: Any, token: String) -> Bool {
        let normalizedToken = token.lowercased()
        switch value {
        case let string as String:
            return string.lowercased().contains(normalizedToken)
        case let array as [Any]:
            return array.contains { rowContainsToken($0, token: token) }
        case let dict as [String: Any]:
            return dict.values.contains { rowContainsToken($0, token: token) }
        default:
            return false
        }
    }

    /// Builds heuristic ordering-risk results by looking for later enabled rules that duplicate earlier scope.
    private func rankRulesByOrderingRisk(rows: [[String: Any]], labelPrefix: String, detailPrefix: String) -> [RankedEntityResult] {
        var priorBySignature: [String: Int] = [:]
        var results: [RankedEntityResult] = []
        for (index, row) in rows.enumerated() {
            guard !(boolValue(row["enabled"]) == false) else { continue }
            let signature = ruleSignature(for: row)
            let duplicates = priorBySignature[signature] ?? 0
            if duplicates > 0 {
                let name = firstString(in: row, keys: ["name", "description", "id", "_id"]) ?? "unnamed-rule"
                results.append(
                    RankedEntityResult(
                        label: "\(labelPrefix)=\(name)",
                        value: Double(duplicates * 100 + index),
                        valueText: "\(duplicates)",
                        detail: "\(detailPrefix)=\(firstString(in: row, keys: ["id", "_id"]) ?? "unknown"), order=\(index + 1)"
                    )
                )
            }
            priorBySignature[signature, default: 0] += 1
        }
        return results.sorted { $0.value == $1.value ? $0.label < $1.label : $0.value > $1.value }
    }

    /// Collapses the most relevant matching fields from a policy row into a comparison signature.
    private func ruleSignature(for row: [String: Any]) -> String {
        let source = ruleScopeSignature(for: row["source"])
        let destination = ruleScopeSignature(for: row["destination"])
        let action = ruleStateText(from: row["action"] as? [String: Any] ?? row)
        let traffic = uniqueRankingStrings(stringCandidates(in: row, keys: ["protocol", "protocols", "trafficMatchingListId", "traffic_matching_list_id", "ipVersion", "ip_version", "port", "ports"]))
        return [source, destination, action, traffic.joined(separator: "|")].joined(separator: "||").lowercased()
    }

    /// Extracts a compact scope signature from a nested source/destination object.
    private func ruleScopeSignature(for value: Any?) -> String {
        guard let row = value as? [String: Any] else { return "any" }
        let zone = firstString(in: row, keys: ["zoneId", "zone_id", "id", "_id"]) ?? "any"
        let network = firstString(in: row, keys: ["networkId", "network_id"]) ?? "any"
        let country = firstString(in: row, keys: ["countryCode", "country_code"]) ?? "any"
        return "\(zone):\(network):\(country)"
    }

    /// Returns a compact state string from top-level or nested status fields.
    private func ruleStateText(from row: [String: Any]) -> String {
        firstString(in: row, keys: ["state", "status", "connectionState", "tunnelState", "health", "type", "name"]) ?? ""
    }

    /// Returns true when a state string appears healthy or connected.
    private func stateLooksHealthy(_ state: String) -> Bool {
        let normalized = state.lowercased()
        if normalized.contains("down") || normalized.contains("fail") || normalized.contains("disconnected") || normalized.contains("offline") {
            return false
        }
        return normalized.contains("up") || normalized.contains("connected") || normalized.contains("online") || normalized.contains("active") || normalized.contains("established")
    }

    /// Builds a stable switch-port key from a client row when uplink device and port details are available.
    private func switchPortKey(for client: [String: Any]) -> String? {
        guard let deviceID = firstString(in: client, keys: ["uplinkDeviceId", "uplink_device_id", "sw_mac", "switchId", "switch_id"]) else {
            return nil
        }
        guard let port = firstString(in: client, keys: ["uplinkPort", "uplink_port", "uplinkPortIdx", "switchPort", "switch_port", "swPort", "port", "last_connection_port"]) else {
            return nil
        }
        return "\(deviceID)|\(port)"
    }

    /// Splits the internal switch-port key back into device and port parts.
    private func splitSwitchPortKey(_ key: String) -> (deviceID: String, portLabel: String) {
        let parts = key.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let deviceID = parts.first.map(String.init) ?? "unknown-device"
        let portLabel = parts.count > 1 ? String(parts[1]) : "unknown-port"
        return (deviceID, portLabel)
    }
}

private struct RankedClientMetric {
    let client: [String: Any]
    let value: Double
}

private struct RankedEntityResult {
    let label: String
    let value: Double
    let valueText: String
    let detail: String
}

private struct NetworkRankingRequest {
    let entityType: String
    let metric: String
    let limit: Int
    let includeInactive: Bool
    let siteRef: String

    var displayEntityType: String {
        entityType.replacingOccurrences(of: "_", with: " ")
    }
}

private struct AccessPointRankingContext {
    let deviceNameByID: [String: String]
    let onlineDeviceIDs: Set<String>
}

private struct SwitchPortRankingContext {
    let devices: [[String: Any]]
    let deviceNameByID: [String: String]
}

private enum AccessPointChurnKind {
    case roam
    case disconnect

    var keys: [String] {
        switch self {
        case .roam:
            return ["roamCount", "roam_count", "roams", "roamEvents", "roam_events"]
        case .disconnect:
            return ["disconnectCount", "disconnect_count", "disconnects", "reconnectCount", "reconnect_count", "reconnects"]
        }
    }
}

private enum VPNTunnelMetric {
    case down
    case up
    case stale
}

private enum WANHealthMetric {
    case healthy
    case unhealthy
}

private enum ClientRankingKind {
    struct ToolRequest {
        let kind: ClientRankingKind
        let singleResult: Bool

        func resolvedLimit(rawLimit: String?) -> Int? {
            singleResult ? 1 : Int(rawLimit ?? "")
        }
    }

    case slowestSpeed
    case weakestSignal
    case highestLatency

    static func request(forToolName toolName: String) -> ToolRequest? {
        switch toolName {
        case "find_slowest_client":
            return ToolRequest(kind: .slowestSpeed, singleResult: true)
        case "top_slowest_clients":
            return ToolRequest(kind: .slowestSpeed, singleResult: false)
        case "find_weakest_wifi_client":
            return ToolRequest(kind: .weakestSignal, singleResult: true)
        case "top_weakest_wifi_clients":
            return ToolRequest(kind: .weakestSignal, singleResult: false)
        case "find_highest_latency_client":
            return ToolRequest(kind: .highestLatency, singleResult: true)
        case "top_highest_latency_clients":
            return ToolRequest(kind: .highestLatency, singleResult: false)
        default:
            return nil
        }
    }

    var metricLabel: String {
        switch self {
        case .slowestSpeed: return "speed"
        case .weakestSignal: return "signal"
        case .highestLatency: return "latency"
        }
    }

    var singularHeading: String {
        switch self {
        case .slowestSpeed: return "Slowest client"
        case .weakestSignal: return "Weakest WiFi client"
        case .highestLatency: return "Highest-latency client"
        }
    }

    var pluralHeading: String {
        switch self {
        case .slowestSpeed: return "Slowest clients"
        case .weakestSignal: return "Weakest WiFi clients"
        case .highestLatency: return "Highest-latency clients"
        }
    }

    var prefersLowerValues: Bool {
        switch self {
        case .slowestSpeed, .weakestSignal:
            return true
        case .highestLatency:
            return false
        }
    }

    var requiresWireless: Bool {
        switch self {
        case .weakestSignal:
            return true
        case .slowestSpeed, .highestLatency:
            return false
        }
    }

    var defaultLimit: Int {
        switch self {
        case .slowestSpeed, .weakestSignal, .highestLatency:
            return 5
        }
    }

    var toolLabel: String {
        switch self {
        case .slowestSpeed: return "find_slowest_client"
        case .weakestSignal: return "find_weakest_wifi_client"
        case .highestLatency: return "find_highest_latency_client"
        }
    }

    func formatted(_ value: Double) -> String {
        switch self {
        case .slowestSpeed:
            return String(format: "%.0f Mbps", value)
        case .weakestSignal:
            return String(format: "%.0f dBm", value)
        case .highestLatency:
            return String(format: "%.1f ms", value)
        }
    }
}

private struct GrafanaLokiService {
    private let baseURL: String
    private let unifiSelector = "{job=\"unifi_siem\"}"

    init(baseURL: String) {
        self.baseURL = UniFiAPIClient.normalizeBaseURL(baseURL)
        if self.baseURL.isEmpty {
            debugLog("Loki service configured without base URL", category: "Logs")
        } else {
            let host = URL(string: self.baseURL)?.host ?? "unknown"
            debugLog("Loki service configured (host=\(host))", category: "Logs")
        }
    }

    /// Queries range.
    func queryRange(query: String?, minutes rawMinutes: Int?, limit rawLimit: Int?, direction rawDirection: String?) async throws -> String {
        guard !baseURL.isEmpty else {
            debugLog("Loki query_range skipped: base URL missing", category: "Logs")
            return "Error: Loki base URL is not configured in Settings."
        }

        let q = normalizedQuery(query)
        let minutes = max(1, min(rawMinutes ?? 60, 1440))
        let limit = max(1, min(rawLimit ?? 100, 500))
        let direction = normalizedDirection(rawDirection)
        let requestID = lokiRequestID()
        debugLog(
            "Loki query_range requested (request_id=\(requestID), minutes=\(minutes), limit=\(limit), direction=\(direction), query=\(previewLokiQuery(q)))",
            category: "Logs"
        )
        let endNanos = unixNanos(Date())
        let startNanos = unixNanos(Date().addingTimeInterval(-Double(minutes) * 60.0))

        var components = URLComponents(string: "\(baseURL)/loki/api/v1/query_range")!
        components.queryItems = [
            URLQueryItem(name: "query", value: q),
            URLQueryItem(name: "start", value: startNanos),
            URLQueryItem(name: "end", value: endNanos),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "direction", value: direction),
        ]
        guard let url = components.url else {
            debugLog("Loki query_range URL construction failed", category: "Logs")
            return "Error: Unable to construct Loki query_range URL."
        }

        let data = try await get(url: url, requestID: requestID, operation: "query_range", querySummary: previewLokiQuery(q))
        return formatLogResponse(data: data, description: "Loki query_range", query: q, limit: limit)
    }

    /// Queries instant.
    func queryInstant(query: String?, limit rawLimit: Int?) async throws -> String {
        guard !baseURL.isEmpty else {
            debugLog("Loki instant query skipped: base URL missing", category: "Logs")
            return "Error: Loki base URL is not configured in Settings."
        }

        let q = normalizedQuery(query)
        let limit = max(1, min(rawLimit ?? 50, 500))
        let requestID = lokiRequestID()
        debugLog("Loki instant query requested (request_id=\(requestID), limit=\(limit), query=\(previewLokiQuery(q)))", category: "Logs")

        var components = URLComponents(string: "\(baseURL)/loki/api/v1/query")!
        components.queryItems = [
            URLQueryItem(name: "query", value: q),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        guard let url = components.url else {
            debugLog("Loki query URL construction failed", category: "Logs")
            return "Error: Unable to construct Loki query URL."
        }

        let data = try await get(url: url, requestID: requestID, operation: "query", querySummary: previewLokiQuery(q))
        return formatLogResponse(data: data, description: "Loki instant query", query: q, limit: limit)
    }

    /// Lists labels.
    func listLabels() async throws -> String {
        guard !baseURL.isEmpty else {
            debugLog("Loki labels query skipped: base URL missing", category: "Logs")
            return "Error: Loki base URL is not configured in Settings."
        }
        let requestID = lokiRequestID()
        guard let url = URL(string: "\(baseURL)/loki/api/v1/labels") else {
            debugLog("Loki labels URL construction failed", category: "Logs")
            return "Error: Unable to construct Loki labels URL."
        }
        let data = try await get(url: url, requestID: requestID, operation: "labels", querySummary: nil)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let labels = json["data"] as? [String] else {
            debugLog("Loki labels parse failed: unexpected payload shape", category: "Logs")
            return "Error: Unexpected Loki labels response format."
        }
        if labels.isEmpty { return "No Loki labels found." }
        return "Loki labels (\(labels.count)): " + labels.sorted().joined(separator: ", ")
    }

    /// Lists the observed values for a specific Loki label.
    func labelValues(label rawLabel: String?) async throws -> String {
        guard !baseURL.isEmpty else {
            debugLog("Loki label values query skipped: base URL missing", category: "Logs")
            return "Error: Loki base URL is not configured in Settings."
        }
        let label = (rawLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else {
            debugLog("Loki label values query skipped: empty label", category: "Logs")
            return "Error: list_unifi_log_label_values requires a non-empty 'label'."
        }
        let requestID = lokiRequestID()
        debugLog("Loki label values requested (request_id=\(requestID), label=\(label))", category: "Logs")
        guard let url = URL(string: "\(baseURL)/loki/api/v1/label/\(label)/values") else {
            debugLog("Loki label values URL construction failed", category: "Logs")
            return "Error: Unable to construct Loki label values URL."
        }
        let data = try await get(url: url, requestID: requestID, operation: "label_values", querySummary: "label=\(label)")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = json["data"] as? [String] else {
            debugLog("Loki label values parse failed: unexpected payload shape", category: "Logs")
            return "Error: Unexpected Loki label values response format."
        }
        if values.isEmpty { return "No values found for label '\(label)'." }
        return "Loki label '\(label)' values (\(values.count)): " + values.sorted().joined(separator: ", ")
    }

    /// Lists series.
    func listSeries(query rawQuery: String?, minutes rawMinutes: Int?, limit rawLimit: Int?) async throws -> String {
        guard !baseURL.isEmpty else {
            debugLog("Loki series query skipped: base URL missing", category: "Logs")
            return "Error: Loki base URL is not configured in Settings."
        }

        let query = normalizedQuery(rawQuery)
        let minutes = max(1, min(rawMinutes ?? 60, 1440))
        let limit = max(1, min(rawLimit ?? 50, 200))
        let endNanos = unixNanos(Date())
        let startNanos = unixNanos(Date().addingTimeInterval(-Double(minutes) * 60.0))
        let requestID = lokiRequestID()
        debugLog("Loki series query requested (request_id=\(requestID), minutes=\(minutes), limit=\(limit), query=\(previewLokiQuery(query)))", category: "Logs")

        var components = URLComponents(string: "\(baseURL)/loki/api/v1/series")!
        components.queryItems = [
            URLQueryItem(name: "match[]", value: query),
            URLQueryItem(name: "start", value: startNanos),
            URLQueryItem(name: "end", value: endNanos),
        ]
        guard let url = components.url else {
            debugLog("Loki series URL construction failed", category: "Logs")
            return "Error: Unable to construct Loki series URL."
        }
        let data = try await get(url: url, requestID: requestID, operation: "series", querySummary: previewLokiQuery(query))
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let series = json["data"] as? [[String: String]] else {
            debugLog("Loki series parse failed: unexpected payload shape", category: "Logs")
            return "Error: Unexpected Loki series response format."
        }
        if series.isEmpty {
            return "Loki series: no streams found for query '\(query)'."
        }

        let formatted = series.prefix(limit).enumerated().map { index, labels in
            let text = labels
                .sorted(by: { $0.key < $1.key })
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ", ")
            return "\(index + 1). \(text)"
        }
        return """
        Loki series (\(min(limit, series.count)) of \(series.count), query=\(query)):
        \(formatted.joined(separator: "\n"))
        """
    }

    /// Summarizes Loki index statistics for the requested query window.
    func indexStats(query rawQuery: String?, minutes rawMinutes: Int?) async throws -> String {
        guard !baseURL.isEmpty else {
            debugLog("Loki index stats query skipped: base URL missing", category: "Logs")
            return "Error: Loki base URL is not configured in Settings."
        }

        let query = normalizedQuery(rawQuery)
        let minutes = max(1, min(rawMinutes ?? 60, 1440))
        let endNanos = unixNanos(Date())
        let startNanos = unixNanos(Date().addingTimeInterval(-Double(minutes) * 60.0))
        let requestID = lokiRequestID()
        debugLog("Loki index stats requested (request_id=\(requestID), minutes=\(minutes), query=\(previewLokiQuery(query)))", category: "Logs")

        var components = URLComponents(string: "\(baseURL)/loki/api/v1/index/stats")!
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "start", value: startNanos),
            URLQueryItem(name: "end", value: endNanos),
        ]
        guard let url = components.url else {
            debugLog("Loki index stats URL construction failed", category: "Logs")
            return "Error: Unable to construct Loki index stats URL."
        }

        let data = try await get(url: url, requestID: requestID, operation: "index_stats", querySummary: previewLokiQuery(query))
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stats = json["data"] as? [String: Any] else {
            debugLog("Loki index stats parse failed: unexpected payload shape", category: "Logs")
            return "Error: Unexpected Loki index stats response format."
        }

        let streams = stats["streams"] ?? "unknown"
        let chunks = stats["chunks"] ?? "unknown"
        let entries = stats["entries"] ?? "unknown"
        let bytes = stats["bytes"] ?? "unknown"
        return """
        Loki index stats (query=\(query), minutes=\(minutes)):
        - streams: \(streams)
        - chunks: \(chunks)
        - entries: \(entries)
        - bytes: \(bytes)
        """
    }

    /// Summarizes recent configuration-change signals from UniFi logs.
    func configDiffSummary(minutes rawMinutes: Int?, limit rawLimit: Int?, contains rawContains: String?) async throws -> String {
        guard !baseURL.isEmpty else {
            return "Error: Loki base URL is not configured in Settings."
        }

        let minutes = max(1, min(rawMinutes ?? 180, 10080))
        let limit = max(1, min(rawLimit ?? 80, 200))
        let escapedContains = ((rawContains ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        var query = #"|~ "(?i)config|setting|policy|firewall|acl|dns|vpn|admin|login|logout|backup|restore|upgrade|update|changed|applied|rule""#
        if !escapedContains.isEmpty {
            query += #" |= "\#(escapedContains)""#
        }
        let result = try await queryRange(query: query, minutes: minutes, limit: limit, direction: "backward")
        return """
        Config/admin/security change summary from logs:
        - window: last \(minutes) minutes
        - hint: for current state, keep a short window (5-30m); for historical diffs, increase minutes.
        \(result)
        """
    }

    /// Performs a GET request for the documentation and Loki helpers and returns the raw response body.
    private func get(url: URL, requestID: String, operation: String, querySummary: String?) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 25

        let token = (KeychainHelper.loadString(key: .grafanaLokiAPIKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        debugLog("Loki auth mode: \(token.isEmpty ? "none" : "bearer") (request_id=\(requestID))", category: "Logs")
        logLokiEndpointResolution(url: url, requestID: requestID, operation: operation)

        debugLog(
            "Loki request started (request_id=\(requestID), op=\(operation), timeout=\(Int(request.timeoutInterval))s, url=\(url.absoluteString)\(querySummary.map { ", query=\($0)" } ?? ""))",
            category: "Logs"
        )
        let startedAt = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let elapsedMS = Int(Date().timeIntervalSince(startedAt) * 1000)
            if let http = response as? HTTPURLResponse {
                let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
                debugLog(
                    "Loki response received (request_id=\(requestID), op=\(operation), status=\(http.statusCode), elapsed_ms=\(elapsedMS), bytes=\(data.count), content_type=\(contentType))",
                    category: "Logs"
                )
                guard (200..<300).contains(http.statusCode) else {
                    let bodyPreview = String(data: data.prefix(400), encoding: .utf8)?
                        .replacingOccurrences(of: "\n", with: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        ?? "<non-utf8 body>"
                    debugLog("Loki HTTP failure (request_id=\(requestID), op=\(operation), status=\(http.statusCode), body_preview=\(bodyPreview))", category: "Logs")
                    throw LLMError.httpError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
                }
            } else {
                debugLog("Loki response received with non-HTTP metadata (request_id=\(requestID), op=\(operation))", category: "Logs")
            }
            return data
        } catch {
            let elapsedMS = Int(Date().timeIntervalSince(startedAt) * 1000)
            let nsError = error as NSError
            let timeoutText = nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut ? " timeout=true" : ""
            debugLog(
                "Loki request failed (request_id=\(requestID), op=\(operation), elapsed_ms=\(elapsedMS), domain=\(nsError.domain), code=\(nsError.code), description=\(error.localizedDescription)\(timeoutText)\(querySummary.map { ", query=\($0)" } ?? ""))",
                category: "Logs"
            )
            throw error
        }
    }

    /// Returns a short identifier that correlates multi-line Loki request logs.
    private func lokiRequestID() -> String {
        String(UUID().uuidString.prefix(8))
    }

    /// Trims and shortens LogQL text so request logs stay readable.
    private func previewLokiQuery(_ query: String) -> String {
        let flattened = query
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if flattened.count <= 220 {
            return flattened
        }
        return String(flattened.prefix(220)) + "..."
    }

    /// Logs the concrete address candidates the OS resolver returns for the Loki host.
    private func logLokiEndpointResolution(url: URL, requestID: String, operation: String) {
        guard let host = url.host, !host.isEmpty else {
            debugLog("Loki endpoint resolution skipped (request_id=\(requestID), op=\(operation), reason=missing_host)", category: "Logs")
            return
        }
        let port = url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
        let addresses = resolveHostAddresses(host: host, port: port)
        if addresses.isEmpty {
            debugLog("Loki endpoint resolution returned no addresses (request_id=\(requestID), op=\(operation), host=\(host), port=\(port))", category: "Logs")
            return
        }
        debugLog(
            "Loki endpoint resolved (request_id=\(requestID), op=\(operation), host=\(host), port=\(port), addresses=\(addresses.joined(separator: ", ")))",
            category: "Logs"
        )
    }

    /// Resolves a host and port into numeric address strings for diagnostic logging.
    private func resolveHostAddresses(host: String, port: Int) -> [String] {
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var resultPointer: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &resultPointer)
        guard status == 0, let first = resultPointer else {
            return []
        }
        defer { freeaddrinfo(first) }

        var addresses: [String] = []
        var seen: Set<String> = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            let family = info.pointee.ai_family
            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(
                info.pointee.ai_addr,
                info.pointee.ai_addrlen,
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 {
                let address = String(cString: hostBuffer)
                if !address.isEmpty {
                    let formatted = family == AF_INET6 ? "[\(address)]" : address
                    if seen.insert(formatted).inserted {
                        addresses.append(formatted)
                    }
                }
            }
            cursor = info.pointee.ai_next
        }
        return addresses
    }

    /// Formats log response.
    private func formatLogResponse(data: Data, description: String, query: String, limit: Int) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let root = json["data"] as? [String: Any],
              let result = root["result"] as? [[String: Any]] else {
            let preview = String(data: data.prefix(300), encoding: .utf8) ?? "<non-utf8 payload>"
            debugLog("Loki parse failed for \(description): payloadPreview=\(preview)", category: "Logs")
            return "Error: Unexpected Loki response format."
        }

        var entries: [String] = []
        for stream in result {
            let labels = stream["stream"] as? [String: String] ?? [:]
            let labelText = labels
                .sorted(by: { $0.key < $1.key })
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ", ")
            let values = stream["values"] as? [[String]] ?? []
            for pair in values {
                guard pair.count >= 2 else { continue }
                let timestamp = formattedUnixNanos(pair[0]) ?? pair[0]
                let line = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
                let compactLine = line.count > 240 ? String(line.prefix(240)) + "..." : line
                if labelText.isEmpty {
                    entries.append("[\(timestamp)] \(compactLine)")
                } else {
                    entries.append("[\(timestamp)] [\(labelText)] \(compactLine)")
                }
            }
        }

        if entries.isEmpty {
            debugLog("Loki returned no log lines for query=\(query)", category: "Logs")
            return "NO_DATA: \(description): no log lines returned for query '\(query)'."
        }

        let selected = entries.prefix(limit)
        return """
        \(description) results (\(selected.count) lines, query=\(query)):
        \(selected.joined(separator: "\n"))
        """
    }

    /// Normalizes a user-supplied Loki query and applies the default UniFi stream selector.
    private func normalizedQuery(_ rawQuery: String?) -> String {
        let q = (rawQuery ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return unifiSelector }

        if q.hasPrefix("{"), let close = q.firstIndex(of: "}") {
            let pipeline = q[q.index(after: close)...].trimmingCharacters(in: .whitespacesAndNewlines)
            return pipeline.isEmpty ? unifiSelector : "\(unifiSelector) \(pipeline)"
        }
        if q.hasPrefix("|") {
            return "\(unifiSelector) \(q)"
        }
        let escaped = q
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\(unifiSelector) |= \"\(escaped)\""
    }

    /// Normalizes the requested Loki query direction.
    private func normalizedDirection(_ rawDirection: String?) -> String {
        let direction = (rawDirection ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return direction == "forward" ? "forward" : "backward"
    }

    /// Formats a Date as Unix nanoseconds for Loki query parameters.
    private func unixNanos(_ date: Date) -> String {
        String(Int64(date.timeIntervalSince1970 * 1_000_000_000))
    }

    /// Formats a Unix-nanosecond string as a readable timestamp for summaries.
    private func formattedUnixNanos(_ raw: String) -> String? {
        guard let nanos = Double(raw) else { return nil }
        let date = Date(timeIntervalSince1970: nanos / 1_000_000_000)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private struct UniFiDocumentationService {
    private struct SearchResponse: Decodable {
        let count: Int
        let results: [Article]
    }

    private struct ArticleResponse: Decodable {
        let article: Article
    }

    private struct Article: Decodable {
        let id: Int
        let title: String
        let htmlURL: String?
        let body: String?
        let snippet: String?
        let updatedAt: String?
        let labelNames: [String]?

        enum CodingKeys: String, CodingKey {
            case id
            case title
            case htmlURL = "html_url"
            case body
            case snippet
            case updatedAt = "updated_at"
            case labelNames = "label_names"
        }
    }

    /// Searches UniFi documentation and returns a compact list of matching articles.
    func search(query: String, maxResults rawMaxResults: Int?) async throws -> String {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return "Error: search_unifi_docs requires a non-empty 'query'."
        }

        let maxResults = max(1, min(rawMaxResults ?? 5, 8))
        var components = URLComponents(string: "https://help.ui.com/api/v2/help_center/articles/search.json")!
        components.queryItems = [
            URLQueryItem(name: "locale", value: "en-us"),
            URLQueryItem(name: "query", value: trimmedQuery),
        ]

        guard let url = components.url else {
            return "Error: Unable to construct UniFi documentation search URL."
        }

        let data = try await get(url: url)
        let response = try JSONDecoder().decode(SearchResponse.self, from: data)
        guard !response.results.isEmpty else {
            return "No official UniFi Help Center articles found for '\(trimmedQuery)'."
        }

        let selected = Array(response.results.prefix(maxResults))
        let lines = selected.enumerated().map { index, article in
            let url = article.htmlURL ?? "unknown"
            let updated = article.updatedAt.flatMap(formatDate) ?? "unknown"
            let snippet = compact(article.snippet ?? article.body ?? "", maxLength: 220)
            return "\(index + 1). [\(article.id)] \(article.title)\n   URL: \(url)\n   Updated: \(updated)\n   Summary: \(snippet)"
        }

        return """
        UniFi Help Center search results for "\(trimmedQuery)" (\(selected.count) of \(response.count)):
        \(lines.joined(separator: "\n"))
        """
    }

    /// Fetches and compacts a single UniFi documentation article.
    func article(articleID: String?, articleURL: String?) async throws -> String {
        let resolvedID = resolveArticleID(articleID: articleID, articleURL: articleURL)
        guard let resolvedID else {
            return "Error: get_unifi_doc requires either 'article_id' or 'article_url'."
        }

        guard let url = URL(string: "https://help.ui.com/api/v2/help_center/en-us/articles/\(resolvedID).json") else {
            return "Error: Invalid article ID."
        }

        let data = try await get(url: url)
        let response = try JSONDecoder().decode(ArticleResponse.self, from: data)
        let article = response.article
        let summary = compact(article.body ?? article.snippet ?? "", maxLength: 5000)
        let labels = (article.labelNames ?? []).prefix(8).joined(separator: ", ")
        let labelsText = labels.isEmpty ? "none" : labels
        let updated = article.updatedAt.flatMap(formatDate) ?? "unknown"
        return """
        UniFi Help Center article:
        - id: \(article.id)
        - title: \(article.title)
        - url: \(article.htmlURL ?? "unknown")
        - updated: \(updated)
        - labels: \(labelsText)
        - content_summary:
        \(summary)
        """
    }

    /// Performs a GET request for the documentation and Loki helpers and returns the raw response body.
    private func get(url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20

        debugLog("UniFi docs request started: \(url.absoluteString)", category: "Docs")
        let startedAt = Date()
        let (data, response) = try await URLSession.shared.data(for: request)
        let elapsedMS = Int(Date().timeIntervalSince(startedAt) * 1000)
        if let http = response as? HTTPURLResponse {
            debugLog("UniFi docs response HTTP \(http.statusCode) in \(elapsedMS)ms", category: "Docs")
            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                throw LLMError.httpError(http.statusCode, body)
            }
        }
        return data
    }

    /// Resolves article ID.
    private func resolveArticleID(articleID: String?, articleURL: String?) -> String? {
        let trimmedID = articleID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedID.isEmpty {
            return trimmedID
        }

        guard let articleURL else { return nil }
        let trimmedURL = articleURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return nil }
        guard let regex = try? NSRegularExpression(pattern: #"/articles/(\d+)"#) else { return nil }
        let range = NSRange(trimmedURL.startIndex..., in: trimmedURL)
        guard let match = regex.firstMatch(in: trimmedURL, options: [], range: range),
              let idRange = Range(match.range(at: 1), in: trimmedURL) else {
            return nil
        }
        return String(trimmedURL[idRange])
    }

    /// Compacts long HTML or text content for chat-friendly output.
    private func compact(_ htmlOrText: String, maxLength: Int) -> String {
        let withoutTags = htmlOrText.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let decoded = withoutTags
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
        let normalized = decoded
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.count <= maxLength {
            return normalized
        }
        let end = normalized.index(normalized.startIndex, offsetBy: maxLength)
        return String(normalized[..<end]) + "..."
    }

    /// Formats date.
    private func formatDate(_ raw: String) -> String? {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: raw) else { return nil }
        let output = DateFormatter()
        output.dateStyle = .medium
        output.timeStyle = .none
        return output.string(from: date)
    }
}

private actor AppBlockApprovalStore {
    struct PendingPlan {
        let token: String
        let expiresAt: Date
        let siteRef: String
        let clientName: String
        let payloads: [[String: Any]]
    }

    private var pending: [String: PendingPlan] = [:]

    /// Issues a short-lived approval token for a staged operation.
    func issue(siteRef: String, clientName: String, payloads: [[String: Any]]) -> String {
        let token = String(UUID().uuidString.prefix(8)).lowercased()
        pending[token] = PendingPlan(
            token: token,
            expiresAt: Date().addingTimeInterval(300),
            siteRef: siteRef,
            clientName: clientName,
            payloads: payloads
        )
        return token
    }

    /// Consumes an approval token and returns the staged operation it authorizes.
    func consume(token: String) -> PendingPlan? {
        let key = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let plan = pending[key] else { return nil }
        pending[key] = nil
        guard plan.expiresAt > Date() else { return nil }
        return plan
    }
}

private struct UniFiAppBlockService {
    private struct SimpleAppBlockApplyResult {
        let rules: [[String: Any]]
        let createdCount: Int
        let updatedCount: Int
        let resultLines: [String]
    }

    private struct SimpleAppBlockRemovalResult {
        let rules: [[String: Any]]
        let deletedCount: Int
        let updatedCount: Int
    }

    private enum SimpleAppBlockRemovalAction {
        case delete
        case update([String: Any])
        case unchanged
    }

    private let apiClient: UniFiAPIClient
    private let approvedAppBlockClients: [ClientModificationApproval]
    private let approvals = AppBlockApprovalStore()
    private let dpiCache = DPICatalogCache()

    init(apiClient: UniFiAPIClient, approvals: [ClientModificationApproval]) {
        self.apiClient = apiClient
        self.approvedAppBlockClients = approvals.filter(\.allowClientModifications)
    }

    /// Lists dpiapplications.
    func listDPIApplications(
        queryService: UniFiQueryService,
        search rawSearch: String?,
        limit rawLimit: Int?
    ) async throws -> String {
        let items = try await loadDPIApplications(queryService: queryService)
        return formatDPIList(
            items: items,
            search: rawSearch,
            limit: rawLimit,
            title: "DPI applications"
        )
    }

    /// Resolves client for app-block.
    func resolveClientForAppBlock(
        queryService: UniFiQueryService,
        query rawQuery: String?,
        siteRef rawSiteRef: String?
    ) async throws -> String {
        let query = (rawQuery ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return "Error: resolve_client_for_app_block requires 'query'."
        }
        let siteRef = normalizedSiteRef(rawSiteRef)
        let clients = try await resolveClientsForAppBlock(queryService: queryService, siteRef: siteRef)
        guard let match = bestClientMatch(query, in: clients) else {
            debugLog("resolve_client_for_app_block no match (query=\(query), site_ref=\(siteRef), candidates=\(clients.count))", category: "Tools")
            return "No client matched '\(query)'."
        }
        let client = match.client
        let name = clientDisplayName(client)
        let id = normalize(client["id"] as? String ?? client["_id"] as? String ?? client["clientId"] as? String)
        let mac = normalize(client["mac"] as? String ?? client["macAddress"] as? String)
        let ip = normalize(client["ip"] as? String ?? client["ipAddress"] as? String ?? client["last_ip"] as? String)
        let allowed = isClientAllowed(client)
        debugLog(
            "resolve_client_for_app_block matched (query=\(query), site_ref=\(siteRef), score=\(match.score), result=\(previewJSON(client)))",
            category: "Tools"
        )
        return """
        Resolved client:
        - name: \(name)
        - id: \(id.isEmpty ? "unknown" : id)
        - ip: \(ip.isEmpty ? "unknown" : ip)
        - mac: \(mac.isEmpty ? "unknown" : mac)
        - allowlisted_for_app_block: \(allowed ? "yes" : "no")
        - score: \(match.score)
        - site_ref: \(siteRef)
        """
    }

    /// Resolves dpiapplication.
    func resolveDPIApplication(
        queryService: UniFiQueryService,
        query rawQuery: String?
    ) async throws -> String {
        let query = (rawQuery ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return "Error: resolve_dpi_application requires 'query'."
        }
        let apps = try await loadDPIApplications(queryService: queryService)
        guard let best = bestNamedMatch(query, in: apps) else {
            debugLog("resolve_dpi_application no match (query=\(query), candidates=\(apps.count))", category: "Tools")
            return "No DPI application matched '\(query)'."
        }
        let id = namedIdentifier(best.row) ?? "unknown"
        let name = stringValue(best.row["name"]) ?? "unknown"
        debugLog(
            "resolve_dpi_application matched (query=\(query), score=\(best.score), result=\(previewJSON(best.row)))",
            category: "Tools"
        )
        return """
        Resolved DPI application:
        - name: \(name)
        - id: \(id)
        - score: \(best.score)
        """
    }

    /// Resolves dpicategory.
    func resolveDPICategory(
        queryService: UniFiQueryService,
        query rawQuery: String?
    ) async throws -> String {
        let query = (rawQuery ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return "Error: resolve_dpi_category requires 'query'."
        }
        let categories = try await loadDPICategories(queryService: queryService)
        guard let best = bestNamedMatch(query, in: categories) else {
            debugLog("resolve_dpi_category no match (query=\(query), candidates=\(categories.count))", category: "Tools")
            return "No DPI category matched '\(query)'."
        }
        let id = namedIdentifier(best.row) ?? "unknown"
        let name = stringValue(best.row["name"]) ?? "unknown"
        debugLog(
            "resolve_dpi_category matched (query=\(query), score=\(best.score), result=\(previewJSON(best.row)))",
            category: "Tools"
        )
        return """
        Resolved DPI category:
        - name: \(name)
        - id: \(id)
        - score: \(best.score)
        """
    }

    /// Lists dpicategories.
    func listDPICategories(
        queryService: UniFiQueryService,
        search rawSearch: String?,
        limit rawLimit: Int?
    ) async throws -> String {
        let items = try await loadDPICategories(queryService: queryService)
        return formatDPIList(
            items: items,
            search: rawSearch,
            limit: rawLimit,
            title: "DPI categories"
        )
    }

    /// Resolves a client and app selectors into a staged simple app-block plan and approval token.
    func planClientAppBlock(
        queryService: UniFiQueryService,
        clientSelector rawClientSelector: String?,
        appsCSV rawApps: String?,
        categoriesCSV rawCategories: String?,
        policyName rawPolicyName: String?,
        siteRef rawSiteRef: String?
    ) async throws -> String {
        let clientSelector = (rawClientSelector ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientSelector.isEmpty else {
            return "Error: plan_client_app_block requires 'client'."
        }
        guard !approvedAppBlockClients.isEmpty else {
            return "Error: No app-block approvals configured. Enable app blocks for one or more clients in Settings."
        }

        let appSelectors = parseCSV(rawApps)
        let categorySelectors = parseCSV(rawCategories)
        guard !appSelectors.isEmpty || !categorySelectors.isEmpty else {
            return "Error: Provide at least one app or category selector."
        }
        let siteRef = normalizedSiteRef(rawSiteRef)

        let clients = try await resolveClientsForAppBlock(queryService: queryService, siteRef: siteRef)
        let applications = try await loadDPIApplications(queryService: queryService)
        let categories = try await loadDPICategories(queryService: queryService)
        let client = try resolveClient(clientSelector, in: clients)
        guard isClientAllowed(client) else {
            let display = clientDisplayName(client)
            return "Error: Client '\(display)' is not approved for app blocks. Update Settings -> Client Modify Whitelist."
        }

        let resolvedApps = try resolveNamedSelectors(appSelectors, in: applications, kind: "application")
        let resolvedCategories = try resolveNamedSelectors(categorySelectors, in: categories, kind: "category")
        let policyName = (rawPolicyName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let effectivePolicyName = policyName.isEmpty
            ? "Block for \(clientDisplayName(client))"
            : policyName

        var payloads: [[String: Any]] = []
        let clientMac = resolvedClientMAC(client, allClients: clients)
        guard !clientMac.isEmpty else {
            return "Error: Could not resolve client MAC for '\(clientDisplayName(client))'. Try selecting the client by MAC from list_clients(include_inactive=true)."
        }
        if !resolvedApps.isEmpty {
            payloads.append([
                "name": effectivePolicyName,
                "type": "DEVICE",
                "target_type": "APP_ID",
                "client_macs": [clientMac],
                "network_ids": [],
                "source_devices": [client],
                "source_networks": [],
                "schedule": ["mode": "ALWAYS"],
                "app_ids": resolvedApps.compactMap { $0["id"] },
                "app_category_ids": [],
            ])
        }
        if !resolvedCategories.isEmpty {
            let categoryName = resolvedApps.isEmpty ? effectivePolicyName : "\(effectivePolicyName) (Categories)"
            payloads.append([
                "name": categoryName,
                "type": "DEVICE",
                "target_type": "APP_CATEGORY",
                "client_macs": [clientMac],
                "network_ids": [],
                "source_devices": [client],
                "source_networks": [],
                "schedule": ["mode": "ALWAYS"],
                "app_ids": [],
                "app_category_ids": resolvedCategories.compactMap { $0["id"] },
            ])
        }
        if payloads.isEmpty {
            return "Error: No app/category IDs could be resolved from provided selectors."
        }

        debugLog(
            "plan_client_app_block resolved (client=\(clientDisplayName(client)), site_ref=\(siteRef), app_selectors=\(appSelectors.joined(separator: ",")), category_selectors=\(categorySelectors.joined(separator: ",")), payloads=\(previewJSON(payloads)))",
            category: "Tools"
        )

        let token = await approvals.issue(
            siteRef: siteRef,
            clientName: clientDisplayName(client),
            payloads: payloads
        )
        let appNames = resolvedApps.compactMap { $0["name"] as? String }
        let categoryNames = resolvedCategories.compactMap { $0["name"] as? String }
        return """
        App-block plan ready:
        - client: \(clientDisplayName(client))
        - site_ref: \(siteRef)
        - apps: \(appNames.isEmpty ? "none" : appNames.joined(separator: ", "))
        - categories: \(categoryNames.isEmpty ? "none" : categoryNames.joined(separator: ", "))
        - payload_count: \(payloads.count)
        Re-run apply_client_app_block with:
        - approve_token: \(token)
        Token expires in 5 minutes.
        """
    }

    /// Consumes an approval token, merges the planned blocks into the current collection, and writes the full simple app-block set back to UniFi.
    func applyClientAppBlock(approveToken rawToken: String?) async throws -> String {
        let token = (rawToken ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            return "Error: apply_client_app_block requires 'approve_token'."
        }
        guard let plan = await approvals.consume(token: token) else {
            return "Error: approve_token is invalid or expired. Run plan_client_app_block again."
        }

        // UniFi persists simple app blocks by replacing the full collection, not by
        // posting individual traffic rules, so we fetch, merge, then POST the whole list.
        let existingRules = try await fetchSimpleAppBlocks(siteRef: plan.siteRef)
        let applyResult = try buildApplyResult(for: plan, existingRules: existingRules)
        let response = try await writeSimpleAppBlocks(siteRef: plan.siteRef, blocks: applyResult.rules)
        let verifiedRules = try await fetchSimpleAppBlocks(siteRef: plan.siteRef)
        let verifiedCount = verifyAppliedRuleCount(payloads: plan.payloads, in: verifiedRules)
        return """
        App-block apply completed:
        - client: \(plan.clientName)
        - site_ref: \(plan.siteRef)
        - rules_created: \(applyResult.createdCount)
        - rules_updated: \(applyResult.updatedCount)
        - verified_rules: \(verifiedCount)/\(plan.payloads.count)
        - response_preview:
        \(String(previewJSON(response).prefix(220)))
        \(applyResult.resultLines.joined(separator: "\n"))
        """
    }

    /// Removes matching apps or categories from a client's simple app blocks and rewrites the remaining collection.
    func removeClientAppBlock(
        queryService: UniFiQueryService,
        clientSelector rawClientSelector: String?,
        appsCSV rawApps: String?,
        categoriesCSV rawCategories: String?,
        siteRef rawSiteRef: String?
    ) async throws -> String {
        let clientSelector = (rawClientSelector ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientSelector.isEmpty else {
            return "Error: remove_client_app_block requires 'client'."
        }
        let siteRef = normalizedSiteRef(rawSiteRef)

        let clients = try await resolveClientsForAppBlock(queryService: queryService, siteRef: siteRef)
        let client = try resolveClient(clientSelector, in: clients)
        guard isClientAllowed(client) else {
            let display = clientDisplayName(client)
            return "Error: Client '\(display)' is not approved for app blocks. Update Settings -> Client Modify Whitelist."
        }
        let clientMac = normalize(client["mac"] as? String ?? client["macAddress"] as? String ?? "")
        guard !clientMac.isEmpty else {
            return "Error: Could not resolve client MAC for removal."
        }

        let appSelectors = parseCSV(rawApps)
        let categorySelectors = parseCSV(rawCategories)
        let applications = appSelectors.isEmpty ? [] : try await loadDPIApplications(queryService: queryService)
        let categories = categorySelectors.isEmpty ? [] : try await loadDPICategories(queryService: queryService)
        let appIDs = Set(try resolveNamedSelectors(appSelectors, in: applications, kind: "application")
            .compactMap { normalize($0["id"]) })
        let categoryIDs = Set(try resolveNamedSelectors(categorySelectors, in: categories, kind: "category")
            .compactMap { normalize($0["id"]) })

        // Deletions use the same collection-write flow as creation, so we edit the
        // in-memory list and submit the full replacement set once.
        let rules = try await fetchSimpleAppBlocks(siteRef: siteRef)
        let removal = removeTargetsFromRules(rules, clientMac: clientMac, appIDs: appIDs, categoryIDs: categoryIDs)

        _ = try await writeSimpleAppBlocks(siteRef: siteRef, blocks: removal.rules)

        return """
        App-block removal completed:
        - client: \(clientDisplayName(client))
        - site_ref: \(siteRef)
        - rules_deleted: \(removal.deletedCount)
        - rules_updated: \(removal.updatedCount)
        """
    }

    /// Lists the simple app-block rules that currently target a resolved client.
    func listClientAppBlock(
        queryService: UniFiQueryService,
        clientSelector rawClientSelector: String?,
        siteRef rawSiteRef: String?
    ) async throws -> String {
        let clientSelector = (rawClientSelector ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientSelector.isEmpty else {
            return "Error: list_client_app_block requires 'client'."
        }
        let siteRef = normalizedSiteRef(rawSiteRef)
        let clients = try await resolveClientsForAppBlock(queryService: queryService, siteRef: siteRef)
        let client = try resolveClient(clientSelector, in: clients)
        let clientMac = resolvedClientMAC(client, allClients: clients)
        guard !clientMac.isEmpty else {
            return "Error: Could not resolve client MAC for listing."
        }

        let applications = try await loadDPIApplications(queryService: queryService)
        let categories = try await loadDPICategories(queryService: queryService)
        let appNameByID = nameMapByID(applications)
        let categoryNameByID = nameMapByID(categories)

        let rules = try await clientAppBlockRules(siteRef: siteRef, clientMac: clientMac)
        let lines = formattedClientAppBlockLines(
            rules: rules,
            appNameByID: appNameByID,
            categoryNameByID: categoryNameByID
        )

        return """
        Client app-block rules:
        - client: \(clientDisplayName(client))
        - mac: \(clientMac)
        - site_ref: \(siteRef)
        - rule_count: \(rules.count)
        \(lines.isEmpty ? "- rules: none" : lines.joined(separator: "\n"))
        """
    }

    /// Returns a compact bottom-up summary of clients that currently have simple app-block rules.
    func listClientsWithAppBlocks(
        queryService: UniFiQueryService,
        limit rawLimit: Int?,
        siteRef rawSiteRef: String?
    ) async throws -> String {
        let siteRef = normalizedSiteRef(rawSiteRef)
        let limit = max(1, min(rawLimit ?? 20, 100))
        let allRules = try await fetchSimpleAppBlocks(siteRef: siteRef)
        let rules = allRules.filter(isSimpleAppRule)
        let clients = try await resolveClientsForAppBlock(queryService: queryService, siteRef: siteRef)
        return formatClientsWithAppBlocks(
            rules: rules,
            clients: clients,
            siteRef: siteRef,
            limit: limit
        )
    }

    /// Formats dpilist.
    private func formatDPIList(
        items: [[String: Any]],
        search rawSearch: String?,
        limit rawLimit: Int?,
        title: String
    ) -> String {
        let search = normalize(rawSearch)
        let limit = max(1, min(rawLimit ?? 50, 200))
        let filtered = items.filter { item in
            guard !search.isEmpty else { return true }
            let name = normalize(item["name"])
            let id = normalize(item["id"])
            return name.contains(search) || id.contains(search)
        }
        let lines = filtered.prefix(limit).enumerated().map { index, item in
            let name = (item["name"] as? String) ?? "unknown"
            let id = "\(item["id"] ?? "unknown")"
            return "\(index + 1). name=\(name), id=\(id)"
        }
        return """
        \(title) (\(lines.count) of \(filtered.count)):
        \(lines.joined(separator: "\n"))
        """
    }

    /// Loads and caches the UniFi DPI application catalog used for app-block resolution.
    private func loadDPIApplications(queryService: UniFiQueryService) async throws -> [[String: Any]] {
        if let cached = await dpiCache.applicationsIfFresh() {
            debugLog("loadDPIApplications cache hit (\(cached.count) items)", category: "Tools")
            return cached
        }
        let items = try await queryService.queryItems("dpi-applications")
        debugLog("loadDPIApplications fetched (\(items.count) items)", category: "Tools")
        await dpiCache.storeApplications(items)
        return items
    }

    /// Loads and caches the UniFi DPI category catalog used for app-block resolution.
    private func loadDPICategories(queryService: UniFiQueryService) async throws -> [[String: Any]] {
        if let cached = await dpiCache.categoriesIfFresh() {
            debugLog("loadDPICategories cache hit (\(cached.count) items)", category: "Tools")
            return cached
        }
        let items = try await queryService.queryItems("dpi-categories")
        debugLog("loadDPICategories fetched (\(items.count) items)", category: "Tools")
        await dpiCache.storeCategories(items)
        return items
    }

    /// Fetches the client inventory used when resolving app-block targets.
    private func resolveClientsForAppBlock(queryService: UniFiQueryService, siteRef: String) async throws -> [[String: Any]] {
        var sources: [[[String: Any]]] = []
        if let rows = try? await queryService.queryItems("clients-all") {
            debugLog("resolveClientsForAppBlock source clients-all (\(rows.count) rows)", category: "Tools")
            sources.append(rows)
        }
        if let rows = try? await queryService.queryItems("clients") {
            debugLog("resolveClientsForAppBlock source clients (\(rows.count) rows)", category: "Tools")
            sources.append(rows)
        }
        let legacyPath = "/proxy/network/api/s/\(siteRef)/stat/alluser"
        if let payload = try? await apiClient.getJSON(path: legacyPath) {
            let rows = rowsFromPayload(payload)
            debugLog("resolveClientsForAppBlock source legacy alluser (\(rows.count) rows)", category: "Tools")
            sources.append(rows)
        }

        var mergedByKey: [String: [String: Any]] = [:]
        for rows in sources {
            for row in rows {
                let key = clientMergeKey(row)
                if let existing = mergedByKey[key] {
                    mergedByKey[key] = mergeClientRow(existing: existing, incoming: row)
                } else {
                    mergedByKey[key] = row
                }
            }
        }
        let merged = Array(mergedByKey.values)
        debugLog("resolveClientsForAppBlock merged (\(merged.count) clients, site_ref=\(siteRef))", category: "Tools")
        return merged
    }

    /// Extracts rule dictionaries from the firewall-app-blocks API response shape.
    private func rowsFromPayload(_ payload: Any) -> [[String: Any]] {
        if let rows = payload as? [[String: Any]] {
            return rows
        }
        if let dict = payload as? [String: Any] {
            if let data = dict["data"] as? [[String: Any]] {
                return data
            }
            if let result = dict["result"] as? [[String: Any]] {
                return result
            }
        }
        return []
    }

    /// Fetches the current simple app-block collection from UniFi.
    private func fetchSimpleAppBlocks(siteRef: String) async throws -> [[String: Any]] {
        let payload = try await apiClient.getJSON(path: simpleAppBlockPath(siteRef: siteRef))
        return rowsFromPayload(payload)
    }

    /// Returns the first usable identifier for an existing simple app-block rule.
    private func trafficRuleID(_ rule: [String: Any]) -> String? {
        let id = (rule["_id"] as? String) ?? (rule["id"] as? String)
        let trimmed = (id ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Checks whether a rule belongs to the simple app-block collection shape.
    private func isSimpleAppRule(_ rule: [String: Any]) -> Bool {
        let type = normalize(rule["type"])
        let targetType = canonicalTargetType(rule)
        return type == "device" && (targetType == "app_id" || targetType == "app_category")
    }

    /// Checks whether a rule targets the specified client MAC address.
    private func ruleTargetsClient(_ rule: [String: Any], mac: String) -> Bool {
        let macs = Set(extractClientDevices(rule).map(normalize))
        return macs.contains(normalize(mac))
    }

    /// Finds an existing simple app-block rule that matches the same client, target type, and schedule.
    private func findMatchingRule(for payload: [String: Any], in rules: [[String: Any]]) -> [String: Any]? {
        let payloadType = canonicalTargetType(payload)
        let payloadMacs = Set(extractClientDevices(payload).map(normalize))
        let payloadSchedule = scheduleSignature(payload["schedule"])
        guard !payloadMacs.isEmpty else { return nil }
        return rules.first(where: { rule in
            guard isSimpleAppRule(rule) else { return false }
            let ruleType = canonicalTargetType(rule)
            if ruleType != payloadType { return false }
            let ruleMacs = Set(extractClientDevices(rule).map(normalize))
            if ruleMacs != payloadMacs { return false }
            return scheduleSignature(rule["schedule"]) == payloadSchedule
        })
    }

    /// Filters the full collection down to simple app-block rules for one resolved client.
    private func clientAppBlockRules(siteRef: String, clientMac: String) async throws -> [[String: Any]] {
        try await fetchSimpleAppBlocks(siteRef: siteRef)
            .filter { isSimpleAppRule($0) && ruleTargetsClient($0, mac: clientMac) }
    }

    /// Returns the best available client row for one normalized MAC address.
    private func clientRow(forMAC mac: String, in clients: [[String: Any]]) -> [String: Any]? {
        let canonical = canonicalMAC(mac)
        return clients.first { row in
            canonicalMAC((row["mac"] as? String) ?? (row["macAddress"] as? String) ?? "") == canonical
        }
    }

    /// Builds the compact blocked-client summary from already-fetched rules and client rows.
    fileprivate func formatClientsWithAppBlocks(
        rules: [[String: Any]],
        clients: [[String: Any]],
        siteRef: String,
        limit: Int
    ) -> String {
        guard !rules.isEmpty else {
            return """
            Clients with app blocks:
            - site_ref: \(siteRef)
            - blocked_client_count: 0
            - rules_considered: 0
            - clients: none
            """
        }

        var byMAC: [String: (rules: Int, appIDs: Set<String>, categoryIDs: Set<String>)] = [:]
        for rule in rules {
            let appIDs = Set(uniqueStrings(arrayStrings(rule["app_ids"]) + arrayStrings(rule["appIds"])).map(normalize))
            let categoryIDs = Set(uniqueStrings(arrayStrings(rule["app_category_ids"]) + arrayStrings(rule["appCategoryIds"])).map(normalize))
            for mac in Set(extractClientDevices(rule).compactMap(canonicalMAC)) {
                var summary = byMAC[mac] ?? (rules: 0, appIDs: Set<String>(), categoryIDs: Set<String>())
                summary.rules += 1
                summary.appIDs.formUnion(appIDs)
                summary.categoryIDs.formUnion(categoryIDs)
                byMAC[mac] = summary
            }
        }

        let sorted = byMAC.keys.sorted { lhs, rhs in
            let left = byMAC[lhs]!
            let right = byMAC[rhs]!
            if left.rules != right.rules {
                return left.rules > right.rules
            }
            return lhs < rhs
        }

        let lines = sorted.prefix(limit).enumerated().map { index, mac in
            let summary = byMAC[mac]!
            let client = clientRow(forMAC: mac, in: clients)
            let name = client.map(clientDisplayName) ?? "Unknown client"
            let ip = client.flatMap { stringValue($0["ip"]) ?? stringValue($0["ipAddress"]) ?? stringValue($0["last_ip"]) } ?? "unknown"
            let allowed = client.map { isClientAllowed($0) } ?? false
            return "\(index + 1). name=\(name), ip=\(ip), mac=\(mac), rules=\(summary.rules), app_ids=\(summary.appIDs.count), category_ids=\(summary.categoryIDs.count), allowlisted_for_app_block=\(allowed ? "yes" : "no")"
        }

        return """
        Clients with app blocks:
        - site_ref: \(siteRef)
        - blocked_client_count: \(byMAC.count)
        - rules_considered: \(rules.count)
        - showing: \(lines.count)
        \(lines.isEmpty ? "- clients: none" : lines.joined(separator: "\n"))
        """
    }

    /// Merges newly requested app or category targets into an existing simple app-block rule.
    private func mergeRule(existing: [String: Any], incoming: [String: Any]) -> [String: Any] {
        var merged = existing
        for key in ["name", "type", "target_type", "client_macs", "network_ids", "source_devices", "source_networks", "schedule"] {
            if let value = incoming[key] {
                merged[key] = value
            }
        }

        let targetType = canonicalTargetType(incoming)
        if targetType == "app_id" {
            let ids = Set(
                arrayStrings(existing["app_ids"])
                    + arrayStrings(incoming["app_ids"])
            )
            merged["app_ids"] = Array(ids).sorted()
            merged["app_category_ids"] = []
        } else if targetType == "app_category" {
            let ids = Set(
                arrayStrings(existing["app_category_ids"])
                    + arrayStrings(incoming["app_category_ids"])
            )
            merged["app_category_ids"] = Array(ids).sorted()
            merged["app_ids"] = []
        }
        return merged
    }

    /// Merges one approved plan into the fetched collection and returns the replacement write payload.
    private func buildApplyResult(
        for plan: AppBlockApprovalStore.PendingPlan,
        existingRules: [[String: Any]]
    ) throws -> SimpleAppBlockApplyResult {
        var createdCount = 0
        var updatedCount = 0
        var resultLines: [String] = []
        var nextRules = existingRules

        for rawPayload in plan.payloads {
            let payload = materializeSimpleAppBlockPayload(rawPayload)
            debugLog(
                "apply_client_app_block materialized payload (site_ref=\(plan.siteRef), payload=\(previewJSON(payload)))",
                category: "Tools"
            )
            try validateAppBlockPayloadClientMAC(payload, clientName: plan.clientName)

            if let existing = findMatchingRule(for: payload, in: nextRules),
               let ruleID = trafficRuleID(existing)
            {
                let merged = mergeRule(existing: existing, incoming: payload)
                updatedCount += 1
                nextRules = nextRules.map { trafficRuleID($0) == ruleID ? merged : $0 }
                resultLines.append("updated \(ruleID): \(String(previewJSON(merged).prefix(220)))")
                continue
            }

            createdCount += 1
            nextRules.append(payload)
            resultLines.append("created: \(String(previewJSON(payload).prefix(220)))")
        }

        return SimpleAppBlockApplyResult(
            rules: nextRules,
            createdCount: createdCount,
            updatedCount: updatedCount,
            resultLines: resultLines
        )
    }

    /// Ensures an approved plan still resolves to a concrete target MAC before we rewrite the collection.
    private func validateAppBlockPayloadClientMAC(_ payload: [String: Any], clientName: String) throws {
        let targetClientMac = canonicalMAC(String(describing: (payload["client_macs"] as? [Any])?.first ?? "")) ?? ""
        guard !targetClientMac.isEmpty else {
            throw NSError(
                domain: "UniFiAppBlockService",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "App-block apply aborted because client_macs is missing or invalid for client '\(clientName)'. Re-run plan_client_app_block and select the client by MAC."
                ]
            )
        }
    }

    /// Counts how many planned payloads can be found again after the replacement write completes.
    private func verifyAppliedRuleCount(payloads: [[String: Any]], in rules: [[String: Any]]) -> Int {
        payloads.filter { findMatchingRule(for: materializeSimpleAppBlockPayload($0), in: rules) != nil }.count
    }

    /// Applies removals in memory so the caller can do one collection replacement write.
    private func removeTargetsFromRules(
        _ rules: [[String: Any]],
        clientMac: String,
        appIDs: Set<String>,
        categoryIDs: Set<String>
    ) -> SimpleAppBlockRemovalResult {
        var nextRules = rules
        var deletedCount = 0
        var updatedCount = 0

        for rule in rules {
            guard isSimpleAppRule(rule), ruleTargetsClient(rule, mac: clientMac) else { continue }
            guard let ruleID = trafficRuleID(rule) else { continue }

            switch removalAction(for: rule, appIDs: appIDs, categoryIDs: categoryIDs) {
            case .delete:
                nextRules.removeAll { trafficRuleID($0) == ruleID }
                deletedCount += 1
            case let .update(updatedRule):
                nextRules = nextRules.map { trafficRuleID($0) == ruleID ? updatedRule : $0 }
                updatedCount += 1
            case .unchanged:
                continue
            }
        }

        return SimpleAppBlockRemovalResult(
            rules: nextRules,
            deletedCount: deletedCount,
            updatedCount: updatedCount
        )
    }

    /// Decides whether one existing rule should be deleted, updated, or left alone by a removal request.
    private func removalAction(
        for rule: [String: Any],
        appIDs: Set<String>,
        categoryIDs: Set<String>
    ) -> SimpleAppBlockRemovalAction {
        if appIDs.isEmpty, categoryIDs.isEmpty {
            return .delete
        }

        switch canonicalTargetType(rule) {
        case "app_id" where !appIDs.isEmpty:
            let kept = arrayStrings(rule["app_ids"]).filter { !appIDs.contains(normalize($0)) }
            guard !kept.isEmpty else { return .delete }
            var next = rule
            next["app_ids"] = kept
            return .update(materializeSimpleAppBlockPayload(next))
        case "app_category" where !categoryIDs.isEmpty:
            let kept = arrayStrings(rule["app_category_ids"]).filter { !categoryIDs.contains(normalize($0)) }
            guard !kept.isEmpty else { return .delete }
            var next = rule
            next["app_category_ids"] = kept
            return .update(materializeSimpleAppBlockPayload(next))
        default:
            return .unchanged
        }
    }

    /// Builds the normalized payload sent to UniFi's firewall-app-blocks collection API.
    private func materializeSimpleAppBlockPayload(_ raw: [String: Any]) -> [String: Any] {
        // The app plan can carry richer local-only fields; this strips each rule down
        // to the browser-style shape accepted by /firewall-app-blocks.
        let candidateMACs = arrayStrings(raw["client_macs"]) + extractClientDevices(raw)
        let macs = Array(Set(candidateMACs.compactMap(canonicalMAC))).sorted()
        let targetType = canonicalTargetType(raw)
        var payload: [String: Any] = [
            "name": raw["name"] ?? "App Block",
            "type": "DEVICE",
            "client_macs": macs,
            "network_ids": arrayStrings(raw["network_ids"]),
            "target_type": targetType == "app_category" ? "APP_CATEGORY" : "APP_ID",
            "schedule": raw["schedule"] ?? ["mode": "ALWAYS"],
        ]

        if targetType == "app_category" {
            let categoryIDs = arrayStrings(raw["app_category_ids"])
            let resolved = Array(Set(categoryIDs)).sorted()
            payload["app_ids"] = []
            payload["app_category_ids"] = resolved
        } else {
            let appIDs = arrayStrings(raw["app_ids"])
            let resolved = Array(Set(appIDs)).sorted()
            payload["app_ids"] = resolved
            payload["app_category_ids"] = []
        }

        return payload
    }

    /// Returns the canonical target type for a simple app-block rule.
    private func canonicalTargetType(_ rule: [String: Any]) -> String {
        let explicit = normalize(rule["target_type"] ?? rule["targetType"])
        if explicit.contains("category") {
            return "app_category"
        }
        if explicit.contains("app") {
            return "app_id"
        }
        let matchingTarget = normalize(rule["matchingTarget"] ?? rule["matching_target"])
        if matchingTarget.contains("category") {
            return "app_category"
        }
        return "app_id"
    }

    /// Extracts normalized client MAC addresses from the rule's target device fields.
    private func extractClientDevices(_ rule: [String: Any]) -> [String] {
        let direct = arrayStrings(rule["client_macs"])
        if !direct.isEmpty { return direct }
        let ids = arrayStrings(rule["client_ids"])
        if !ids.isEmpty { return ids }
        if let sourceDevices = rule["source_devices"] as? [Any] {
            let devices = sourceDevices.compactMap { item -> String? in
                guard let dict = item as? [String: Any] else { return nil }
                return (dict["mac"] as? String) ?? (dict["id"] as? String)
            }
            if !devices.isEmpty { return devices }
        }
        let source = rule["targetDevices"] ?? rule["target_devices"]
        guard let targetDevices = source as? [Any] else { return [] }
        var devices: [String] = []
        for item in targetDevices {
            if let value = item as? String, !value.isEmpty {
                devices.append(value)
                continue
            }
            if let dict = item as? [String: Any] {
                let candidate = (dict["mac"] as? String)
                    ?? (dict["id"] as? String)
                    ?? (dict["device"] as? String)
                if let candidate, !candidate.isEmpty {
                    devices.append(candidate)
                }
            }
        }
        return devices
    }

    /// Returns the UniFi collection endpoint used for full simple-app-block replacement writes.
    private func simpleAppBlockPath(siteRef: String) -> String {
        "/proxy/network/v2/api/site/\(siteRef)/firewall-app-blocks"
    }

    /// Posts the full simple app-block collection back to UniFi in one replacement write.
    private func writeSimpleAppBlocks(siteRef: String, blocks: [[String: Any]]) async throws -> Any {
        // This endpoint expects the complete simple-app-block collection in one POST.
        debugLog(
            "SimpleAppBlocks POST payload: count=\(blocks.count), first=\(blocks.first.map(summarizeTrafficRulePayload) ?? "none")",
            category: "UniFiAPI"
        )
        return try await apiClient.postJSON(path: simpleAppBlockPath(siteRef: siteRef), body: blocks)
    }

    /// Builds a compact log summary of a simple app-block payload before submission.
    private func summarizeTrafficRulePayload(_ payload: [String: Any]) -> String {
        let targetType = String(describing: payload["target_type"] ?? "nil")
        let clientMACs = arrayStrings(payload["client_macs"]).joined(separator: ",")
        let action = String(describing: payload["action"] ?? "nil")
        let matchingTarget = String(describing: payload["matchingTarget"] ?? "nil")
        let targetDeviceCount = (payload["targetDevices"] as? [Any])?.count ?? 0
        let appCount = (payload["app_ids"] as? [Any])?.count ?? 0
        let categoryCount = (payload["app_category_ids"] as? [Any])?.count ?? 0

        let scheduleMode: String = {
            guard let schedule = payload["schedule"] as? [String: Any] else { return "none" }
            if let mode = schedule["mode"] {
                return String(describing: mode)
            }
            if let timeAllDay = schedule["time_all_day"] {
                return "time_all_day=\(timeAllDay)"
            }
            return "custom"
        }()

        return "action=\(action), matchingTarget=\(matchingTarget), target_type=\(targetType), client_macs=\(clientMACs), targetDevices.count=\(targetDeviceCount), app_ids.count=\(appCount), app_category_ids.count=\(categoryCount), schedule=\(scheduleMode)"
    }

    /// Formats the per-rule lines for list_client_app_block so the route method stays focused on orchestration.
    private func formattedClientAppBlockLines(
        rules: [[String: Any]],
        appNameByID: [String: String],
        categoryNameByID: [String: String]
    ) -> [String] {
        rules.enumerated().map { index, rule in
            let ruleID = trafficRuleID(rule) ?? "unknown"
            let targetType = canonicalTargetType(rule)
            let action = String(describing: rule["action"] ?? "BLOCK")
            let schedule = scheduleMode(rule)
            let appIDs = uniqueStrings(arrayStrings(rule["app_ids"]) + arrayStrings(rule["appIds"]))
            let categoryIDs = uniqueStrings(arrayStrings(rule["app_category_ids"]) + arrayStrings(rule["appCategoryIds"]))
            let appSummary = summarizeResolvedIDs(appIDs, nameMap: appNameByID)
            let categorySummary = summarizeResolvedIDs(categoryIDs, nameMap: categoryNameByID)
            let targetLabel = targetType == "app_category" ? "APP_CATEGORY" : "APP"
            return "\(index + 1). id=\(ruleID), target=\(targetLabel), action=\(action), schedule=\(schedule), apps=\(appSummary), categories=\(categorySummary)"
        }
    }

    /// Builds a shortened JSON preview string for debug logging.
    private func previewJSON(_ value: Any, limit: Int = 500) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else {
            let fallback = String(describing: value)
            return String(fallback.prefix(limit))
        }
        return String(text.prefix(limit))
    }

    /// Normalizes an arbitrary JSON field into an array of strings.
    private func arrayStrings(_ any: Any?) -> [String] {
        guard let array = any as? [Any] else { return [] }
        return array.map { String(describing: $0) }.filter { !$0.isEmpty }
    }

    /// Builds a stable signature string for comparing rule schedules.
    private func scheduleSignature(_ value: Any?) -> String {
        guard let schedule = value as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: schedule, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return text
    }

    /// Extracts the rule's schedule mode in uppercase form.
    private func scheduleMode(_ rule: [String: Any]) -> String {
        guard let schedule = rule["schedule"] as? [String: Any] else { return "unknown" }
        if let mode = schedule["mode"] as? String, !mode.isEmpty {
            return mode
        }
        return "custom"
    }

    /// Builds an ID-to-name lookup from UniFi catalog rows.
    private func nameMapByID(_ rows: [[String: Any]]) -> [String: String] {
        var out: [String: String] = [:]
        for row in rows {
            let id = normalize(row["id"])
            let name = (row["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !id.isEmpty, !name.isEmpty else { continue }
            out[id] = name
        }
        return out
    }

    /// Returns the input strings with empties removed and duplicates collapsed in order.
    private func uniqueStrings(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for value in values {
            let key = normalize(value)
            if key.isEmpty || seen.contains(key) { continue }
            seen.insert(key)
            out.append(value)
        }
        return out
    }

    /// Formats resolved IDs with friendly names for tool responses.
    private func summarizeResolvedIDs(_ ids: [String], nameMap: [String: String]) -> String {
        if ids.isEmpty { return "none" }
        return ids.map { id in
            let key = normalize(id)
            if let name = nameMap[key], !name.isEmpty {
                return "\(name) (\(id))"
            }
            return id
        }.joined(separator: ", ")
    }

    /// Splits a comma-separated selector string into trimmed values.
    private func parseCSV(_ value: String?) -> [String] {
        (value ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Returns the normalized site reference, defaulting to `default` when omitted.
    private func normalizedSiteRef(_ rawSiteRef: String?) -> String {
        let candidate = (rawSiteRef ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.isEmpty ? "default" : candidate
    }

    /// Resolves a single client selector against the current client inventory.
    private func resolveClient(_ selector: String, in clients: [[String: Any]]) throws -> [String: Any] {
        try resolveSingle(selector, in: clients, kind: "client") { item in
            clientCandidateValues(item)
        }
    }

    /// Resolves user-entered app or category selectors against a named catalog.
    private func resolveNamedSelectors(_ selectors: [String], in rows: [[String: Any]], kind: String) throws -> [[String: Any]] {
        var output: [[String: Any]] = []
        var seen: Set<String> = []
        for selector in selectors {
            let resolved: [String: Any]
            do {
                resolved = try resolveSingle(selector, in: rows, kind: kind) { item in
                    namedCandidateValues(item)
                }
            } catch let error as LLMError {
                if case .invalidResponse = error,
                   (kind == "application" || kind == "category"),
                   isNumericSelector(selector)
                {
                    // Allow direct numeric DPI ID selectors even if catalog name mapping is missing.
                    resolved = ["id": selector.trimmingCharacters(in: .whitespacesAndNewlines), "name": "id:\(selector)"]
                } else {
                    throw error
                }
            }
            let key = normalize(namedIdentifier(resolved) ?? UUID().uuidString)
            if !seen.contains(key) {
                output.append(resolved)
                seen.insert(key)
            }
        }
        return output
    }

    /// Returns exactly one fuzzy-matched row or throws when the selector is ambiguous.
    private func resolveSingle(
        _ selector: String,
        in rows: [[String: Any]],
        kind: String,
        candidates: ([String: Any]) -> [String]
    ) throws -> [String: Any] {
        let query = normalize(selector)
        let exact = rows.filter { row in candidates(row).map(normalize).contains(query) }
        if exact.count == 1, let one = exact.first { return one }
        if exact.count > 1 {
            throw LLMError.invalidResponse("Ambiguous \(kind) selector '\(selector)'.")
        }
        let contains = rows.filter { row in candidates(row).map(normalize).contains(where: { $0.contains(query) }) }
        if contains.count == 1, let one = contains.first { return one }
        if contains.count > 1 {
            throw LLMError.invalidResponse("Ambiguous \(kind) selector '\(selector)'; multiple matches.")
        }
        throw LLMError.invalidResponse("\(kind.capitalized) selector '\(selector)' did not match.")
    }

    /// Finds the highest-scoring client row for the provided selector text.
    private func bestClientMatch(_ selector: String, in rows: [[String: Any]]) -> (client: [String: Any], score: Int)? {
        bestMatch(selector, in: rows) { clientCandidateValues($0) }.map { ($0.row, $0.score) }
    }

    /// Finds the highest-scoring named catalog row for the provided selector text.
    private func bestNamedMatch(_ selector: String, in rows: [[String: Any]]) -> (row: [String: Any], score: Int)? {
        bestMatch(selector, in: rows, candidates: namedCandidateValues)
    }

    /// Finds the best fuzzy match in a list of candidate strings.
    private func bestMatch(
        _ selector: String,
        in rows: [[String: Any]],
        candidates: ([String: Any]) -> [String]
    ) -> (row: [String: Any], score: Int)? {
        let query = normalizeMatchText(selector)
        guard !query.isEmpty else { return nil }

        var bestRow: [String: Any]?
        var bestScore = Int.min
        for row in rows {
            let values = candidates(row).map(normalizeMatchText).filter { !$0.isEmpty }
            var localBest = Int.min
            for value in values {
                localBest = max(localBest, matchScore(query: query, candidate: value))
            }
            if localBest > bestScore {
                bestScore = localBest
                bestRow = row
            }
        }
        guard let bestRow, bestScore >= 35 else { return nil }
        return (bestRow, bestScore)
    }

    /// Scores a selector against a candidate string so exact and prefix matches win first.
    private func matchScore(query: String, candidate: String) -> Int {
        if candidate == query { return 120 }
        if candidate.hasPrefix(query) || query.hasPrefix(candidate) { return 95 }
        if candidate.contains(query) { return 85 }
        if query.contains(candidate), candidate.count >= 4 { return 70 }

        let distance = editDistance(query, candidate)
        if distance <= 1 { return 72 }
        if distance <= 2 { return 62 }
        if distance <= 3, min(query.count, candidate.count) >= 6 { return 48 }
        return 0
    }

    /// Normalizes text before fuzzy matching by lowercasing and stripping punctuation noise.
    private func normalizeMatchText(_ input: String) -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasSuffix(".local") {
            text = String(text.dropLast(6))
        }
        let allowed = CharacterSet.alphanumerics
        let scalars = text.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : Character(" ")
        }
        return String(scalars)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// Computes Levenshtein edit distance for fuzzy selector matching.
    private func editDistance(_ lhs: String, _ rhs: String) -> Int {
        if lhs == rhs { return 0 }
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }
        let a = Array(lhs)
        let b = Array(rhs)
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = Array(repeating: 0, count: b.count + 1)
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + cost
                )
            }
            previous = current
        }
        return previous[b.count]
    }

    /// Returns true when client allowed.
    private func isClientAllowed(_ client: [String: Any]) -> Bool {
        let fields = clientCandidateValues(client).map(normalize)
        for approval in approvedAppBlockClients {
            let allowedFields = [
                approval.approvalKey,
                approval.clientID,
                approval.name,
                approval.hostname,
                approval.mac,
                approval.ip,
            ]
            .map(normalize)
            .filter { !$0.isEmpty }
            if allowedFields.contains(where: { allowed in
                fields.contains(where: { $0 == allowed || $0.contains(allowed) || allowed.contains($0) })
            }) {
                return true
            }
        }
        return false
    }

    /// Builds the human-readable client label shown in tool responses.
    private func clientDisplayName(_ client: [String: Any]) -> String {
        (client["name"] as? String)
            ?? (client["displayName"] as? String)
            ?? (client["clientName"] as? String)
            ?? (client["hostname"] as? String)
            ?? (client["hostName"] as? String)
            ?? (client["dhcpHostname"] as? String)
            ?? (client["ip"] as? String)
            ?? (client["ipAddress"] as? String)
            ?? "unknown-client"
    }

    /// Normalizes a free-form string for comparisons and matching.
    private func normalize(_ value: Any?) -> String {
        let cleaned = String(describing: value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if cleaned.isEmpty || cleaned == "null" || cleaned == "<null>" || cleaned == "(null)" {
            return ""
        }
        return cleaned
    }

    /// Collects the client fields that should participate in selector matching.
    private func clientCandidateValues(_ client: [String: Any]) -> [String] {
        let raw: [String?] = [
            client["id"] as? String,
            client["_id"] as? String,
            client["clientId"] as? String,
            client["client_id"] as? String,
            client["guid"] as? String,
            client["name"] as? String,
            client["displayName"] as? String,
            client["clientName"] as? String,
            client["hostname"] as? String,
            client["hostName"] as? String,
            client["dhcpHostname"] as? String,
            client["mac"] as? String,
            client["macAddress"] as? String,
            client["ip"] as? String,
            client["ipAddress"] as? String,
            client["last_ip"] as? String,
            client["lastIp"] as? String,
            client["fixed_ip"] as? String,
            client["fixedIp"] as? String,
        ]
        var values = raw.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }

        // Add canonicalized variants so selector matching is resilient to MAC separator/casing differences.
        for value in values {
            let macCanonical = value.replacingOccurrences(of: "-", with: ":").lowercased()
            if macCanonical != value.lowercased() {
                values.append(macCanonical)
            }
        }
        return Array(Set(values))
    }

    /// Collects the candidate text fields for app and category matching.
    private func namedCandidateValues(_ row: [String: Any]) -> [String] {
        let raw: [Any?] = [
            row["id"],
            row["appId"],
            row["app_id"],
            row["categoryId"],
            row["category_id"],
            row["name"],
            row["displayName"],
        ]
        return raw.compactMap { stringValue($0) }
    }

    /// Returns the stable identifier string for a named catalog row.
    private func namedIdentifier(_ row: [String: Any]) -> String? {
        stringValue(row["id"])
            ?? stringValue(row["appId"])
            ?? stringValue(row["app_id"])
            ?? stringValue(row["categoryId"])
            ?? stringValue(row["category_id"])
            ?? stringValue(row["name"])
    }

    /// Returns a trimmed string value when the JSON field can be represented as text.
    private func stringValue(_ any: Any?) -> String? {
        guard let any else { return nil }
        let text = String(describing: any).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Returns true when the selector looks like a numeric DPI identifier.
    private func isNumericSelector(_ value: String) -> Bool {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        return text.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) }
    }

    /// Normalizes a MAC address into lowercase colon-delimited form.
    private func canonicalMAC(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let hexOnly = trimmed
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        guard hexOnly.count == 12 else { return nil }
        guard hexOnly.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) }) else {
            return nil
        }
        var chunks: [String] = []
        var idx = hexOnly.startIndex
        while idx < hexOnly.endIndex {
            let next = hexOnly.index(idx, offsetBy: 2)
            chunks.append(String(hexOnly[idx..<next]).lowercased())
            idx = next
        }
        return chunks.joined(separator: ":")
    }

    /// Builds the deduplication key used when merging client inventories.
    private func clientMergeKey(_ row: [String: Any]) -> String {
        let mac = normalize(
            row["mac"] as? String
                ?? row["macAddress"] as? String
                ?? row["clientMac"] as? String
                ?? row["staMac"] as? String
        )
        if !mac.isEmpty { return "mac:\(mac)" }
        let ip = normalize(
            row["ip"] as? String
                ?? row["ipAddress"] as? String
                ?? row["last_ip"] as? String
                ?? row["lastIp"] as? String
        )
        if !ip.isEmpty { return "ip:\(ip)" }
        let id = normalize(
            row["id"] as? String
                ?? row["_id"] as? String
                ?? row["clientId"] as? String
                ?? row["client_id"] as? String
                ?? row["guid"] as? String
        )
        if !id.isEmpty { return "id:\(id)" }
        return "row:\(UUID().uuidString.lowercased())"
    }

    /// Combines two client rows while preferring the richer set of fields.
    private func mergeClientRow(existing: [String: Any], incoming: [String: Any]) -> [String: Any] {
        var merged = existing
        for (key, value) in incoming {
            if let current = merged[key] as? String,
               !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                continue
            }
            merged[key] = value
        }
        return merged
    }

    /// Returns the best MAC address available for a resolved client row.
    private func resolvedClientMAC(_ client: [String: Any], allClients: [[String: Any]]) -> String {
        if let direct = canonicalMAC(trimmedString(
            client["mac"] as? String
                ?? client["macAddress"] as? String
                ?? client["clientMac"] as? String
                ?? client["staMac"] as? String
        )) {
            return direct
        }

        let identity = Set(clientCandidateValues(client).map(normalize).filter { !$0.isEmpty })
        guard !identity.isEmpty else { return "" }
        for candidate in allClients {
            let candidateIdentity = Set(clientCandidateValues(candidate).map(normalize).filter { !$0.isEmpty })
            if identity.isDisjoint(with: candidateIdentity) { continue }
            let candidateMAC = trimmedString(
                candidate["mac"] as? String
                    ?? candidate["macAddress"] as? String
                    ?? candidate["clientMac"] as? String
                    ?? candidate["staMac"] as? String
            )
            if let canonical = canonicalMAC(candidateMAC) {
                return canonical
            }
        }
        return ""
    }

    /// Returns a string with surrounding whitespace removed, or an empty string for nil.
    private func trimmedString(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

#if DEBUG
func _testOnlyFormatClientsWithAppBlocks(
    rules: [[String: Any]],
    clients: [[String: Any]],
    approvals: [ClientModificationApproval] = [],
    siteRef: String = "default",
    limit: Int = 20
) -> String {
    let service = UniFiAppBlockService(
        apiClient: UniFiAPIClient(baseURL: "https://127.0.0.1", allowSelfSigned: true),
        approvals: approvals
    )
    return service.formatClientsWithAppBlocks(
        rules: rules,
        clients: clients,
        siteRef: siteRef,
        limit: max(1, min(limit, 100))
    )
}
#endif

private actor DPICatalogCache {
    private let ttlSeconds: TimeInterval = 600
    private var applications: [[String: Any]]?
    private var applicationsFetchedAt: Date?
    private var categories: [[String: Any]]?
    private var categoriesFetchedAt: Date?

    /// Returns cached DPI applications when the cache is still fresh enough to reuse.
    func applicationsIfFresh() -> [[String: Any]]? {
        guard let applications, let fetchedAt = applicationsFetchedAt else { return nil }
        guard Date().timeIntervalSince(fetchedAt) <= ttlSeconds else { return nil }
        debugLog("DPI applications cache hit (\(applications.count) items)", category: "Tools")
        return applications
    }

    /// Returns cached DPI categories when the cache is still fresh enough to reuse.
    func categoriesIfFresh() -> [[String: Any]]? {
        guard let categories, let fetchedAt = categoriesFetchedAt else { return nil }
        guard Date().timeIntervalSince(fetchedAt) <= ttlSeconds else { return nil }
        debugLog("DPI categories cache hit (\(categories.count) items)", category: "Tools")
        return categories
    }

    /// Stores a refreshed DPI application catalog in the in-memory cache.
    func storeApplications(_ rows: [[String: Any]]) {
        applications = rows
        applicationsFetchedAt = Date()
        debugLog("DPI applications cache store (\(rows.count) items)", category: "Tools")
    }

    /// Stores a refreshed DPI category catalog in the in-memory cache.
    func storeCategories(_ rows: [[String: Any]]) {
        categories = rows
        categoriesFetchedAt = Date()
        debugLog("DPI categories cache store (\(rows.count) items)", category: "Tools")
    }
}

private actor SSHApprovalStore {
    private struct PendingApproval {
        let token: String
        let signature: String
        let expiresAt: Date
    }

    private var pending: [String: PendingApproval] = [:]

    /// Issues a short-lived approval token for a staged operation.
    func issue(host: String, commandID: String) -> String {
        let token = String(UUID().uuidString.prefix(8)).lowercased()
        let signature = "\(host)|\(commandID)".lowercased()
        let approval = PendingApproval(
            token: token,
            signature: signature,
            expiresAt: Date().addingTimeInterval(300)
        )
        pending[token] = approval
        return token
    }

    /// Consumes an approval token and returns the staged operation it authorizes.
    func consume(token: String, host: String, commandID: String) -> Bool {
        let key = token.lowercased()
        guard let approval = pending[key] else { return false }
        pending[key] = nil
        guard approval.expiresAt > Date() else { return false }
        return approval.signature == "\(host)|\(commandID)".lowercased()
    }
}

private struct UniFiSSHLogService {
    private let approvals = SSHApprovalStore()
    private let allowedCommands: [String: String] = [
        "logread_tail": "logread | tail -n 200",
        "messages_tail": "tail -n 200 /var/log/messages",
        "dmesg_tail": "dmesg | tail -n 200",
        "kernel_tail": "tail -n 200 /var/log/kern.log",
    ]

    /// Runs the guarded UniFi SSH log collection flow.
    func run(
        host rawHost: String?,
        commandID rawCommandID: String?,
        approveToken rawApproveToken: String?,
        timeoutSeconds rawTimeoutSeconds: Int?
    ) async -> String {
        let host = (rawHost ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let commandID = (rawCommandID ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty else {
            return "Error: ssh_collect_unifi_logs requires 'host'."
        }
        guard let command = allowedCommands[commandID] else {
            return "Error: Unsupported command_id. Allowed: \(allowedCommands.keys.sorted().joined(separator: ", "))."
        }

        let token = (rawApproveToken ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            let approvalToken = await approvals.issue(host: host, commandID: commandID)
            return """
            Approval required: SSH command execution is gated.
            Re-run ssh_collect_unifi_logs with:
            - host: \(host)
            - command_id: \(commandID)
            - approve_token: \(approvalToken)
            Token expires in 5 minutes.
            """
        }
        guard await approvals.consume(token: token, host: host, commandID: commandID) else {
            return "Error: approve_token is invalid or expired. Request a new token by calling without approve_token."
        }

        let username = (KeychainHelper.loadString(key: .unifiSSHUsername) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let privateKey = (KeychainHelper.loadString(key: .unifiSSHPrivateKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let password = (KeychainHelper.loadString(key: .unifiSSHPassword) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else {
            return "Error: UniFi SSH username not configured in Settings."
        }
        guard !privateKey.isEmpty || !password.isEmpty else {
            return "Error: Configure either UniFi SSH private key or SSH password in Settings."
        }

        let timeout = max(5, min(rawTimeoutSeconds ?? 15, 60))
        return await executeSSH(
            username: username,
            host: host,
            commandID: commandID,
            command: command,
            privateKey: privateKey,
            password: password,
            timeoutSeconds: timeout
        )
    }

    /// Executes the approved SSH log collection command against the target UniFi host.
    private func executeSSH(
        username: String,
        host: String,
        commandID: String,
        command: String,
        privateKey: String,
        password: String,
        timeoutSeconds: Int
    ) async -> String {
        #if os(macOS) || targetEnvironment(macCatalyst)
        let process = Process()
        if !privateKey.isEmpty {
            let tempDir = FileManager.default.temporaryDirectory
            let keyURL = tempDir.appendingPathComponent("unifi_ssh_\(UUID().uuidString).key")
            do {
                try privateKey.write(to: keyURL, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: Int16(0o600))],
                    ofItemAtPath: keyURL.path
                )
            } catch {
                return "Error: Unable to prepare temporary SSH key file."
            }
            defer { try? FileManager.default.removeItem(at: keyURL) }

            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = [
                "-i", keyURL.path,
                "-o", "BatchMode=yes",
                "-o", "StrictHostKeyChecking=accept-new",
                "-o", "ConnectTimeout=\(timeoutSeconds)",
                "\(username)@\(host)",
                command,
            ]
        } else {
            let sshpassPath = "/opt/homebrew/bin/sshpass"
            guard FileManager.default.isReadableFile(atPath: sshpassPath) else {
                return "Error: SSH password auth requires sshpass at /opt/homebrew/bin/sshpass."
            }
            process.executableURL = URL(fileURLWithPath: sshpassPath)
            process.arguments = [
                "-p", password,
                "/usr/bin/ssh",
                "-o", "StrictHostKeyChecking=accept-new",
                "-o", "ConnectTimeout=\(timeoutSeconds)",
                "\(username)@\(host)",
                command,
            ]
        }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
            process.waitUntilExit()
            let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let output = out.trimmingCharacters(in: .whitespacesAndNewlines)
            let errors = err.trimmingCharacters(in: .whitespacesAndNewlines)
            if process.terminationStatus == 0 {
                let clipped = String(output.prefix(4000))
                return """
                SSH log command completed (host=\(host), command_id=\(commandID)):
                \(clipped.isEmpty ? "<no output>" : clipped)
                """
            }
            return "Error: SSH command failed (status=\(process.terminationStatus)): \(errors.isEmpty ? "unknown error" : errors)"
        } catch {
            return "Error: SSH command failed to start: \(error.localizedDescription)"
        }
        #else
        return "Error: SSH command execution is not supported on this iOS runtime. Use the local CLI skill for SSH log collection."
        #endif
    }
}

private struct ClientDiagnosticsService {
    private let probePorts: [UInt16] = [22, 53, 80, 443]

    /// Probes reachability.
    func probeReachability(target rawTarget: String?, timeoutSeconds rawTimeout: Int?) async -> String {
        let target = (rawTarget ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            return "Error: ping_client requires 'target'."
        }
        let timeout = max(1, min(rawTimeout ?? 3, 10))
        for port in probePorts {
            if await tcpProbe(host: target, port: port, timeoutSeconds: timeout) {
                return "Reachability probe success: \(target) responded on TCP port \(port)."
            }
        }
        return "Reachability probe failed: no TCP response from \(target) on ports \(probePorts.map(String.init).joined(separator: ", "))."
    }

    /// Resolves DNS.
    func resolveDNS(target rawTarget: String?) -> String {
        let target = (rawTarget ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            return "Error: resolve_client_dns requires 'target'."
        }
        if let reverse = reverseLookupIfIPAddress(target) {
            return reverse
        }
        let addresses = resolveHost(target)
        if addresses.isEmpty {
            return "DNS resolution failed for \(target)."
        }
        return "DNS \(target) -> \(addresses.joined(separator: ", "))"
    }

    /// Runs an HTTP probe against a client target and summarizes the response.
    func httpProbe(
        target rawTarget: String?,
        scheme rawScheme: String?,
        path rawPath: String?,
        timeoutSeconds rawTimeout: Int?
    ) async -> String {
        let target = (rawTarget ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            return "Error: http_probe_client requires 'target'."
        }
        let scheme = ((rawScheme ?? "http").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "https") ? "https" : "http"
        let path = {
            let p = (rawPath ?? "/").trimmingCharacters(in: .whitespacesAndNewlines)
            if p.isEmpty { return "/" }
            return p.hasPrefix("/") ? p : "/\(p)"
        }()
        let timeout = max(1, min(rawTimeout ?? 5, 20))
        guard let url = URL(string: "\(scheme)://\(target)\(path)") else {
            return "Error: Invalid URL for target '\(target)'."
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = TimeInterval(timeout)
        request.setValue("close", forHTTPHeaderField: "Connection")
        let started = Date()
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let elapsedMS = Int(Date().timeIntervalSince(started) * 1000)
            if let http = response as? HTTPURLResponse {
                return "HTTP probe \(url.absoluteString) -> status \(http.statusCode) in \(elapsedMS)ms."
            }
            return "HTTP probe \(url.absoluteString) completed in \(elapsedMS)ms (non-HTTP response)."
        } catch {
            return "HTTP probe failed for \(url.absoluteString): \(error.localizedDescription)"
        }
    }

    /// Runs TCP port checks against a client target and summarizes the results.
    func portCheck(target rawTarget: String?, portsCSV rawPorts: String?, timeoutSeconds rawTimeout: Int?) async -> String {
        let target = (rawTarget ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            return "Error: port_check_client requires 'target'."
        }
        let ports = (rawPorts ?? "")
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { $0 > 0 && $0 <= 65535 }
        guard !ports.isEmpty else {
            return "Error: port_check_client requires valid comma-separated ports."
        }
        let timeout = max(1, min(rawTimeout ?? 2, 10))
        var lines: [String] = []
        for port in ports.prefix(20) {
            let ok = await tcpProbe(host: target, port: UInt16(port), timeoutSeconds: timeout)
            lines.append("port \(port): \(ok ? "open/reachable" : "no response/blocked")")
        }
        return """
        Port check for \(target):
        \(lines.joined(separator: "\n"))
        """
    }

    /// Runs a traceroute to the target and summarizes each hop.
    func traceroute(target rawTarget: String?, maxHops rawMaxHops: Int?, timeoutSeconds rawTimeout: Int?) async -> String {
        let target = (rawTarget ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            return "Error: network_traceroute requires 'target'."
        }
        let maxHops = max(5, min(rawMaxHops ?? 20, 64))
        let timeout = max(1, min(rawTimeout ?? 2, 5))

        #if os(macOS) || targetEnvironment(macCatalyst)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/traceroute")
        process.arguments = ["-n", "-m", String(maxHops), "-w", String(timeout), target]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
            process.waitUntilExit()
            let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let merged = (out + "\n" + err).trimmingCharacters(in: .whitespacesAndNewlines)
            let clipped = String(merged.prefix(5000))
            if clipped.isEmpty {
                return "Traceroute produced no output for \(target)."
            }
            return """
            Traceroute (\(target), max_hops=\(maxHops), timeout=\(timeout)s):
            \(clipped)
            """
        } catch {
            return "Traceroute failed to start: \(error.localizedDescription)"
        }
        #else
        return "Error: traceroute is not supported on this iOS runtime."
        #endif
    }

    /// Finds the best-matching UniFi client and summarizes its identity fields.
    func lookupClientIdentity(queryService: UniFiQueryService, query rawQuery: String?) async throws -> String {
        let raw = (rawQuery ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let query = normalizeClientLookupText(raw)
        guard !query.isEmpty else {
            return "Error: lookup_client_identity requires 'query'."
        }
        let clients = try await queryService.queryItems("clients")
        let rankedMatches: [(client: [String: Any], score: Int)] = clients.compactMap { client in
            let fields = clientIdentityFields(client)
            let normalizedFields = fields.map(normalizeClientLookupText).filter { !$0.isEmpty }

            var score = 0
            for field in normalizedFields {
                if field == query {
                    score = max(score, 100)
                } else if field.contains(query) {
                    score = max(score, 90)
                } else if query.contains(field), field.count >= 4 {
                    score = max(score, 70)
                } else if field.hasPrefix(query) || query.hasPrefix(field) {
                    score = max(score, 65)
                } else {
                    let distance = editDistance(query, field)
                    if distance <= 2 {
                        score = max(score, 50 - (distance * 10))
                    } else if distance <= 4 && min(query.count, field.count) >= 8 {
                        score = max(score, 20)
                    }
                }
            }

            if score == 0 {
                return nil
            }
            return (client: client, score: score)
        }

        let matches = rankedMatches
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    let lhsName = (lhs.client["name"] as? String ?? lhs.client["hostname"] as? String ?? "").lowercased()
                    let rhsName = (rhs.client["name"] as? String ?? rhs.client["hostname"] as? String ?? "").lowercased()
                    return lhsName < rhsName
                }
                return lhs.score > rhs.score
            }
            .map(\.client)

        if matches.isEmpty {
            return "No client matched '\(raw)'."
        }
        let lines = matches.prefix(10).enumerated().map { idx, item in
            let id = item["id"] as? String ?? "unknown"
            let name = item["name"] as? String ?? item["hostname"] as? String ?? "unknown"
            let ip = item["ipAddress"] as? String ?? "unknown"
            let mac = item["macAddress"] as? String ?? "unknown"
            return "\(idx + 1). name=\(name), ip=\(ip), mac=\(mac), id=\(id)"
        }
        return """
        Client identity matches (\(lines.count)):
        \(lines.joined(separator: "\n"))
        """
    }

    /// Builds the ordered identity fields used in client lookup matching.
    private func clientIdentityFields(_ client: [String: Any]) -> [String] {
        let keys = [
            "id",
            "name",
            "hostname",
            "ipAddress",
            "macAddress",
            "displayName",
            "display_name",
            "alias",
            "userName",
            "user_name",
            "dhcpHostname",
            "dhcp_hostname",
            "vendorName",
            "vendor_name",
        ]
        return keys.compactMap { key in
            guard let value = client[key] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    /// Normalizes client lookup text.
    private func normalizeClientLookupText(_ input: String) -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasSuffix(".local") {
            text = String(text.dropLast(6))
        }
        let allowed = CharacterSet.alphanumerics
        let scalars = text.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : Character(" ")
        }
        let collapsed = String(scalars)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return collapsed
    }

    /// Computes Levenshtein edit distance for fuzzy selector matching.
    private func editDistance(_ lhs: String, _ rhs: String) -> Int {
        if lhs == rhs { return 0 }
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }
        let a = Array(lhs)
        let b = Array(rhs)
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = Array(repeating: 0, count: b.count + 1)
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + cost
                )
            }
            previous = current
        }
        return previous[b.count]
    }

    /// Attempts a single TCP connection to determine whether a port is reachable.
    private func tcpProbe(host: String, port: UInt16, timeoutSeconds: Int) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        return await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            let queue = DispatchQueue(label: "networkgenius.tcpProbe")

            actor OneShot {
                private var done = false
                /// Marks the probe as finished exactly once across success, timeout, and failure paths.
                func mark() -> Bool {
                    if done { return false }
                    done = true
                    return true
                }
            }
            let oneShot = OneShot()

            /// Resumes the waiting continuation once the TCP probe has completed.
            @Sendable func finish(_ result: Bool) {
                // Avoid resuming the continuation more than once by coordinating via the actor.
                Task {
                    if await oneShot.mark() {
                        connection.cancel()
                        continuation.resume(returning: result)
                    }
                }
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(true)
                case .failed, .cancelled:
                    finish(false)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + .seconds(timeoutSeconds)) {
                finish(false)
            }
        }
    }

    /// Resolves host.
    private func resolveHost(_ host: String) -> [String] {
        var hints = addrinfo(
            ai_flags: AI_DEFAULT,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        guard status == 0, let first = result else { return [] }
        defer { freeaddrinfo(result) }

        var output: [String] = []
        for pointer in sequence(first: first, next: { $0.pointee.ai_next }) {
            guard let addr = pointer.pointee.ai_addr else { continue }
            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let rc = getnameinfo(
                addr,
                pointer.pointee.ai_addrlen,
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            if rc == 0 {
                output.append(String(cString: hostBuffer))
            }
        }
        return Array(Set(output)).sorted()
    }

    /// Runs a reverse DNS lookup when the input already appears to be an IP address.
    private func reverseLookupIfIPAddress(_ input: String) -> String? {
        var sockaddrStorage = sockaddr_storage()
        var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))

        if input.contains(":") {
            var addr6 = in6_addr()
            if inet_pton(AF_INET6, input, &addr6) == 1 {
                var addr = sockaddr_in6()
                addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                addr.sin6_family = sa_family_t(AF_INET6)
                addr.sin6_addr = addr6
                memcpy(&sockaddrStorage, &addr, MemoryLayout<sockaddr_in6>.size)
                let rc = withUnsafePointer(to: &sockaddrStorage) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                        getnameinfo(
                            saPtr,
                            socklen_t(MemoryLayout<sockaddr_in6>.size),
                            &hostBuffer,
                            socklen_t(hostBuffer.count),
                            nil,
                            0,
                            NI_NAMEREQD
                        )
                    }
                }
                if rc == 0 {
                    return "Reverse DNS \(input) -> \(String(cString: hostBuffer))"
                }
                return "Reverse DNS lookup failed for \(input)."
            }
        } else {
            var addr4 = in_addr()
            if inet_pton(AF_INET, input, &addr4) == 1 {
                var addr = sockaddr_in()
                addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_addr = addr4
                memcpy(&sockaddrStorage, &addr, MemoryLayout<sockaddr_in>.size)
                let rc = withUnsafePointer(to: &sockaddrStorage) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                        getnameinfo(
                            saPtr,
                            socklen_t(MemoryLayout<sockaddr_in>.size),
                            &hostBuffer,
                            socklen_t(hostBuffer.count),
                            nil,
                            0,
                            NI_NAMEREQD
                        )
                    }
                }
                if rc == 0 {
                    return "Reverse DNS \(input) -> \(String(cString: hostBuffer))"
                }
                return "Reverse DNS lookup failed for \(input)."
            }
        }
        return nil
    }
}

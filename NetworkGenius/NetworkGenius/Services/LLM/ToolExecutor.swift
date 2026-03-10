import Foundation
import Network
import Darwin

final class ToolExecutor {
    private let apiClient: UniFiAPIClient
    private let queryService: UniFiQueryService
    private let summaryService: UniFiSummaryService
    private let networkMonitor: NetworkMonitor
    private let docsService = UniFiDocumentationService()
    private let lokiService: GrafanaLokiService
    private let diagnosticsService = ClientDiagnosticsService()
    private let sshLogService = UniFiSSHLogService()
    private let appBlockService: UniFiAppBlockService

    init(
        apiClient: UniFiAPIClient,
        queryService: UniFiQueryService,
        summaryService: UniFiSummaryService,
        networkMonitor: NetworkMonitor,
        lokiBaseURL: String,
        appBlockAllowedClients: String
    ) {
        self.apiClient = apiClient
        self.queryService = queryService
        self.summaryService = summaryService
        self.networkMonitor = networkMonitor
        self.lokiService = GrafanaLokiService(baseURL: lokiBaseURL)
        self.appBlockService = UniFiAppBlockService(
            apiClient: apiClient,
            allowlistCSV: appBlockAllowedClients
        )
    }

    @MainActor
    func execute(toolCall: LLMToolCall) async -> String {
        let supportsOffNetwork = Set(["search_unifi_docs", "get_unifi_doc"])
        let requiresLocalNetwork = !supportsOffNetwork.contains(toolCall.name)
        guard !requiresLocalNetwork || networkMonitor.isOnNetwork else {
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
                output = try await listClients(includeInactiveRaw: toolCall.arguments["include_inactive"])
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
            case "ping_client":
                output = await diagnosticsService.probeReachability(
                    target: toolCall.arguments["target"],
                    timeoutSeconds: Int(toolCall.arguments["timeout_seconds"] ?? "")
                )
            case "resolve_client_dns":
                output = diagnosticsService.resolveDNS(target: toolCall.arguments["target"])
            case "http_probe_client":
                output = await diagnosticsService.httpProbe(
                    target: toolCall.arguments["target"],
                    scheme: toolCall.arguments["scheme"],
                    path: toolCall.arguments["path"],
                    timeoutSeconds: Int(toolCall.arguments["timeout_seconds"] ?? "")
                )
            case "port_check_client":
                output = await diagnosticsService.portCheck(
                    target: toolCall.arguments["target"],
                    portsCSV: toolCall.arguments["ports"],
                    timeoutSeconds: Int(toolCall.arguments["timeout_seconds"] ?? "")
                )
            case "network_traceroute":
                output = await diagnosticsService.traceroute(
                    target: toolCall.arguments["target"],
                    maxHops: Int(toolCall.arguments["max_hops"] ?? ""),
                    timeoutSeconds: Int(toolCall.arguments["timeout_seconds"] ?? "")
                )
            case "lookup_client_identity":
                output = try await diagnosticsService.lookupClientIdentity(
                    queryService: queryService,
                    query: toolCall.arguments["query"]
                )
            case "resolve_client_for_app_block":
                output = try await appBlockService.resolveClientForAppBlock(
                    queryService: queryService,
                    query: toolCall.arguments["query"],
                    siteRef: toolCall.arguments["site_ref"]
                )
            case "resolve_dpi_application":
                output = try await appBlockService.resolveDPIApplication(
                    queryService: queryService,
                    query: toolCall.arguments["query"]
                )
            case "resolve_dpi_category":
                output = try await appBlockService.resolveDPICategory(
                    queryService: queryService,
                    query: toolCall.arguments["query"]
                )
            case "list_dpi_applications":
                output = try await appBlockService.listDPIApplications(
                    queryService: queryService,
                    search: toolCall.arguments["search"],
                    limit: Int(toolCall.arguments["limit"] ?? "")
                )
            case "list_dpi_categories":
                output = try await appBlockService.listDPICategories(
                    queryService: queryService,
                    search: toolCall.arguments["search"],
                    limit: Int(toolCall.arguments["limit"] ?? "")
                )
            case "plan_client_app_block":
                output = try await appBlockService.planClientAppBlock(
                    queryService: queryService,
                    clientSelector: toolCall.arguments["client"],
                    appsCSV: toolCall.arguments["apps"],
                    categoriesCSV: toolCall.arguments["categories"],
                    policyName: toolCall.arguments["policy_name"],
                    siteRef: toolCall.arguments["site_ref"]
                )
            case "apply_client_app_block":
                output = try await appBlockService.applyClientAppBlock(
                    approveToken: toolCall.arguments["approve_token"]
                )
            case "remove_client_app_block":
                output = try await appBlockService.removeClientAppBlock(
                    queryService: queryService,
                    clientSelector: toolCall.arguments["client"],
                    appsCSV: toolCall.arguments["apps"],
                    categoriesCSV: toolCall.arguments["categories"],
                    siteRef: toolCall.arguments["site_ref"]
                )
            case "list_client_app_block":
                output = try await appBlockService.listClientAppBlock(
                    queryService: queryService,
                    clientSelector: toolCall.arguments["client"],
                    siteRef: toolCall.arguments["site_ref"]
                )
            case "ssh_collect_unifi_logs":
                output = await sshLogService.run(
                    host: toolCall.arguments["host"],
                    commandID: toolCall.arguments["command_id"],
                    approveToken: toolCall.arguments["approve_token"],
                    timeoutSeconds: Int(toolCall.arguments["timeout_seconds"] ?? "")
                )
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
            case "wan_gateway_health":
                output = try await wanGatewayHealth(
                    logMinutes: Int(toolCall.arguments["minutes"] ?? "")
                )
            case "config_diff_from_logs":
                output = try await lokiService.configDiffSummary(
                    minutes: Int(toolCall.arguments["minutes"] ?? ""),
                    limit: Int(toolCall.arguments["limit"] ?? ""),
                    contains: toolCall.arguments["contains"]
                )
            case "search_unifi_docs":
                output = try await docsService.search(
                    query: toolCall.arguments["query"] ?? "",
                    maxResults: Int(toolCall.arguments["max_results"] ?? "")
                )
            case "get_unifi_doc":
                output = try await docsService.article(
                    articleID: toolCall.arguments["article_id"],
                    articleURL: toolCall.arguments["article_url"]
                )
            case "query_unifi_logs":
                output = try await lokiService.queryRange(
                    query: toolCall.arguments["query"],
                    minutes: Int(toolCall.arguments["minutes"] ?? ""),
                    limit: Int(toolCall.arguments["limit"] ?? ""),
                    direction: toolCall.arguments["direction"]
                )
            case "query_unifi_logs_instant":
                output = try await lokiService.queryInstant(
                    query: toolCall.arguments["query"],
                    limit: Int(toolCall.arguments["limit"] ?? "")
                )
            case "list_unifi_log_labels":
                output = try await lokiService.listLabels()
            case "list_unifi_log_label_values":
                output = try await lokiService.labelValues(label: toolCall.arguments["label"])
            case "list_unifi_log_series":
                output = try await lokiService.listSeries(
                    query: toolCall.arguments["query"],
                    minutes: Int(toolCall.arguments["minutes"] ?? ""),
                    limit: Int(toolCall.arguments["limit"] ?? "")
                )
            case "get_unifi_log_stats":
                output = try await lokiService.indexStats(
                    query: toolCall.arguments["query"],
                    minutes: Int(toolCall.arguments["minutes"] ?? "")
                )
            default:
                output = "Unknown tool: \(toolCall.name)"
            }
            let elapsedMS = Int(Date().timeIntervalSince(startedAt) * 1000)
            debugLog("Tool '\(toolCall.name)' completed in \(elapsedMS)ms", category: "Tools")
            return output
        } catch {
            let elapsedMS = Int(Date().timeIntervalSince(startedAt) * 1000)
            debugLog("Tool '\(toolCall.name)' failed in \(elapsedMS)ms: \(error.localizedDescription)", category: "Tools")
            if let llmError = error as? LLMError,
               case let .httpError(statusCode, _) = llmError
            {
                if statusCode == 401 || statusCode == 403 {
                    return "AUTH_ERROR: \(toolCall.name) was denied by the remote API (HTTP \(statusCode)). Check API key or permissions."
                }
                if statusCode == 429 {
                    return "THROTTLED: \(toolCall.name) hit rate limits (HTTP 429). Retry with a smaller query or shortly later."
                }
            }
            return "TOOL_ERROR: \(toolCall.name) failed: \(error.localizedDescription)"
        }
    }

    private func wanGatewayHealth(logMinutes rawMinutes: Int?) async throws -> String {
        let devices = try await queryService.queryItems("devices")
        let gateways = devices.filter { isLikelyGateway($0) }
        let minutes = max(1, min(rawMinutes ?? 120, 1440))

        var gatewayLines: [String] = []
        for gateway in gateways {
            let name = firstString(in: gateway, keys: ["name", "hostname", "model", "id"]) ?? "unknown"
            let ip = firstString(in: gateway, keys: ["ipAddress", "ip", "lanIp"]) ?? "unknown"
            let mac = firstString(in: gateway, keys: ["macAddress", "mac"]) ?? "unknown"
            let state = firstString(in: gateway, keys: ["state", "status", "connectionState", "adoptionState"]) ?? "unknown"
            let version = firstString(in: gateway, keys: ["firmwareVersion", "version"]) ?? "unknown"
            gatewayLines.append("- \(name) ip=\(ip) mac=\(mac) state=\(state) version=\(version)")
        }
        if gatewayLines.isEmpty {
            gatewayLines = ["- No gateway devices were identified from current device inventory."]
        }

        let wanLogs = try await lokiService.queryRange(
            query: #"|~ "(?i)wan|gateway|failover|packet loss|latency|jitter|uplink|isp""#,
            minutes: minutes,
            limit: 40,
            direction: "backward"
        )

        return """
        WAN/Gateway health snapshot:
        \(gatewayLines.joined(separator: "\n"))

        Recent WAN/gateway SIEM events (\(minutes)m):
        \(wanLogs)
        """
    }

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

    private func firstString(in dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dict[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func listClients(includeInactiveRaw: String?) async throws -> String {
        let includeInactive = parseFlexibleBool(includeInactiveRaw)
        if !includeInactive {
            return try await queryService.query("clients")
        }
        let rows = try await resolveClientsIncludingInactive()
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private func resolveClientsIncludingInactive(siteRefHint: String? = nil) async throws -> [[String: Any]] {
        var bestRows: [[String: Any]] = []

        if let rows = try? await queryService.queryItems("clients-all"), rows.count > bestRows.count {
            bestRows = rows
        }
        if let rows = try? await queryService.queryItems("clients"), rows.count > bestRows.count {
            bestRows = rows
        }

        var siteRef = (siteRefHint ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if siteRef.isEmpty, let sites = try? await queryService.queryItems("sites") {
            if let defaultRef = sites.first(where: { (($0["internalReference"] as? String) ?? "") == "default" })?["internalReference"] as? String,
               !defaultRef.isEmpty
            {
                siteRef = defaultRef
            } else if let firstRef = sites.first?["internalReference"] as? String, !firstRef.isEmpty {
                siteRef = firstRef
            }
        }
        if siteRef.isEmpty {
            siteRef = "default"
        }

        let legacyPath = "/proxy/network/api/s/\(siteRef)/stat/alluser"
        if let legacyPayload = try? await apiClient.getJSON(path: legacyPath) {
            let legacyRows = rowsFromAnyPayload(legacyPayload)
            if legacyRows.count > bestRows.count {
                bestRows = legacyRows
            }
        }
        return bestRows
    }

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

    private func parseFlexibleBool(_ raw: String?) -> Bool {
        let value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch value {
        case "1", "true", "yes", "y", "on":
            return true
        default:
            return false
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

    func queryRange(query: String?, minutes rawMinutes: Int?, limit rawLimit: Int?, direction rawDirection: String?) async throws -> String {
        guard !baseURL.isEmpty else {
            debugLog("Loki query_range skipped: base URL missing", category: "Logs")
            return "Error: Loki base URL is not configured in Settings."
        }

        let q = normalizedQuery(query)
        let minutes = max(1, min(rawMinutes ?? 60, 1440))
        let limit = max(1, min(rawLimit ?? 100, 500))
        let direction = normalizedDirection(rawDirection)
        debugLog(
            "Loki query_range requested (minutes=\(minutes), limit=\(limit), direction=\(direction), query=\(q))",
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

        let data = try await get(url: url)
        return formatLogResponse(data: data, description: "Loki query_range", query: q, limit: limit)
    }

    func queryInstant(query: String?, limit rawLimit: Int?) async throws -> String {
        guard !baseURL.isEmpty else {
            debugLog("Loki instant query skipped: base URL missing", category: "Logs")
            return "Error: Loki base URL is not configured in Settings."
        }

        let q = normalizedQuery(query)
        let limit = max(1, min(rawLimit ?? 50, 500))
        debugLog("Loki instant query requested (limit=\(limit), query=\(q))", category: "Logs")

        var components = URLComponents(string: "\(baseURL)/loki/api/v1/query")!
        components.queryItems = [
            URLQueryItem(name: "query", value: q),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        guard let url = components.url else {
            debugLog("Loki query URL construction failed", category: "Logs")
            return "Error: Unable to construct Loki query URL."
        }

        let data = try await get(url: url)
        return formatLogResponse(data: data, description: "Loki instant query", query: q, limit: limit)
    }

    func listLabels() async throws -> String {
        guard !baseURL.isEmpty else {
            debugLog("Loki labels query skipped: base URL missing", category: "Logs")
            return "Error: Loki base URL is not configured in Settings."
        }
        guard let url = URL(string: "\(baseURL)/loki/api/v1/labels") else {
            debugLog("Loki labels URL construction failed", category: "Logs")
            return "Error: Unable to construct Loki labels URL."
        }
        let data = try await get(url: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let labels = json["data"] as? [String] else {
            debugLog("Loki labels parse failed: unexpected payload shape", category: "Logs")
            return "Error: Unexpected Loki labels response format."
        }
        if labels.isEmpty { return "No Loki labels found." }
        return "Loki labels (\(labels.count)): " + labels.sorted().joined(separator: ", ")
    }

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
        debugLog("Loki label values requested (label=\(label))", category: "Logs")
        guard let url = URL(string: "\(baseURL)/loki/api/v1/label/\(label)/values") else {
            debugLog("Loki label values URL construction failed", category: "Logs")
            return "Error: Unable to construct Loki label values URL."
        }
        let data = try await get(url: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = json["data"] as? [String] else {
            debugLog("Loki label values parse failed: unexpected payload shape", category: "Logs")
            return "Error: Unexpected Loki label values response format."
        }
        if values.isEmpty { return "No values found for label '\(label)'." }
        return "Loki label '\(label)' values (\(values.count)): " + values.sorted().joined(separator: ", ")
    }

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
        debugLog("Loki series query requested (minutes=\(minutes), limit=\(limit), query=\(query))", category: "Logs")

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
        let data = try await get(url: url)
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

    func indexStats(query rawQuery: String?, minutes rawMinutes: Int?) async throws -> String {
        guard !baseURL.isEmpty else {
            debugLog("Loki index stats query skipped: base URL missing", category: "Logs")
            return "Error: Loki base URL is not configured in Settings."
        }

        let query = normalizedQuery(rawQuery)
        let minutes = max(1, min(rawMinutes ?? 60, 1440))
        let endNanos = unixNanos(Date())
        let startNanos = unixNanos(Date().addingTimeInterval(-Double(minutes) * 60.0))
        debugLog("Loki index stats requested (minutes=\(minutes), query=\(query))", category: "Logs")

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

        let data = try await get(url: url)
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

    private func get(url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 25

        let token = (KeychainHelper.loadString(key: .grafanaLokiAPIKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        debugLog("Loki auth mode: \(token.isEmpty ? "none" : "bearer")", category: "Logs")

        debugLog("Loki request started: \(url.absoluteString)", category: "Logs")
        let startedAt = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let elapsedMS = Int(Date().timeIntervalSince(startedAt) * 1000)
            if let http = response as? HTTPURLResponse {
                let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
                debugLog(
                    "Loki response HTTP \(http.statusCode) in \(elapsedMS)ms (bytes=\(data.count), contentType=\(contentType))",
                    category: "Logs"
                )
                guard (200..<300).contains(http.statusCode) else {
                    let bodyPreview = String(data: data.prefix(400), encoding: .utf8)?
                        .replacingOccurrences(of: "\n", with: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        ?? "<non-utf8 body>"
                    debugLog("Loki HTTP \(http.statusCode) bodyPreview=\(bodyPreview)", category: "Logs")
                    throw LLMError.httpError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
                }
            } else {
                debugLog("Loki response received with non-HTTP metadata", category: "Logs")
            }
            return data
        } catch {
            let elapsedMS = Int(Date().timeIntervalSince(startedAt) * 1000)
            let nsError = error as NSError
            debugLog(
                "Loki request failed in \(elapsedMS)ms domain=\(nsError.domain) code=\(nsError.code) description=\(error.localizedDescription)",
                category: "Logs"
            )
            throw error
        }
    }

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

    private func normalizedDirection(_ rawDirection: String?) -> String {
        let direction = (rawDirection ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return direction == "forward" ? "forward" : "backward"
    }

    private func unixNanos(_ date: Date) -> String {
        String(Int64(date.timeIntervalSince1970 * 1_000_000_000))
    }

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

    func consume(token: String) -> PendingPlan? {
        let key = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let plan = pending[key] else { return nil }
        pending[key] = nil
        guard plan.expiresAt > Date() else { return nil }
        return plan
    }
}

private struct UniFiAppBlockService {
    private let apiClient: UniFiAPIClient
    private let allowedClientSelectors: [String]
    private let approvals = AppBlockApprovalStore()
    private let dpiCache = DPICatalogCache()

    init(apiClient: UniFiAPIClient, allowlistCSV: String) {
        self.apiClient = apiClient
        self.allowedClientSelectors = allowlistCSV
            .split(separator: ",")
            .map {
                String($0)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
            }
            .filter { !$0.isEmpty }
    }

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
        guard !allowedClientSelectors.isEmpty else {
            return "Error: No app-block allowlist configured. Add allowed clients in Settings -> Change Guardrails."
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
            return "Error: Client '\(display)' is not in the app-block allowlist. Update Settings -> Change Guardrails."
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
        let path = "/proxy/network/v2/api/site/\(plan.siteRef)/firewall-app-blocks"
        var existingRules = try await fetchSimpleAppBlocks(siteRef: plan.siteRef)
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
            let targetClientMac = canonicalMAC(String(describing: (payload["client_macs"] as? [Any])?.first ?? "")) ?? ""
            guard !targetClientMac.isEmpty else {
                return "Error: App-block apply aborted because client_macs is missing or invalid for client '\(plan.clientName)'. Re-run plan_client_app_block and select the client by MAC."
            }

            if let existing = findMatchingRule(for: payload, in: existingRules),
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
        let response = try await writeSimpleAppBlocks(path: path, blocks: nextRules)
        existingRules = try await fetchSimpleAppBlocks(siteRef: plan.siteRef)
        let verifiedCount = plan.payloads.filter { findMatchingRule(for: materializeSimpleAppBlockPayload($0), in: existingRules) != nil }.count
        return """
        App-block apply completed:
        - client: \(plan.clientName)
        - site_ref: \(plan.siteRef)
        - rules_created: \(createdCount)
        - rules_updated: \(updatedCount)
        - verified_rules: \(verifiedCount)/\(plan.payloads.count)
        - response_preview:
        \(String(previewJSON(response).prefix(220)))
        \(resultLines.joined(separator: "\n"))
        """
    }

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
            return "Error: Client '\(display)' is not in the app-block allowlist. Update Settings -> Change Guardrails."
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
        var rules = try await fetchSimpleAppBlocks(siteRef: siteRef)
        let path = "/proxy/network/v2/api/site/\(siteRef)/firewall-app-blocks"
        var deleted = 0
        var updated = 0

        for rule in rules {
            guard isSimpleAppRule(rule), ruleTargetsClient(rule, mac: clientMac) else { continue }
            guard let ruleID = trafficRuleID(rule) else { continue }
            let targetType = normalize(rule["target_type"] ?? rule["targetType"])

            if appIDs.isEmpty, categoryIDs.isEmpty {
                rules.removeAll { trafficRuleID($0) == ruleID }
                deleted += 1
                continue
            }

            var next = rule
            if targetType == "app_id", !appIDs.isEmpty {
                let kept = arrayStrings(rule["app_ids"]).filter { !appIDs.contains(normalize($0)) }
                next["app_ids"] = kept
                if kept.isEmpty {
                    rules.removeAll { trafficRuleID($0) == ruleID }
                    deleted += 1
                    continue
                }
            } else if targetType == "app_category", !categoryIDs.isEmpty {
                let kept = arrayStrings(rule["app_category_ids"]).filter { !categoryIDs.contains(normalize($0)) }
                next["app_category_ids"] = kept
                if kept.isEmpty {
                    rules.removeAll { trafficRuleID($0) == ruleID }
                    deleted += 1
                    continue
                }
            } else {
                continue
            }

            let updatedRule = materializeSimpleAppBlockPayload(next)
            rules = rules.map { trafficRuleID($0) == ruleID ? updatedRule : $0 }
            updated += 1
        }

        _ = try await writeSimpleAppBlocks(path: path, blocks: rules)

        return """
        App-block removal completed:
        - client: \(clientDisplayName(client))
        - site_ref: \(siteRef)
        - rules_deleted: \(deleted)
        - rules_updated: \(updated)
        """
    }

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

        let rules = try await fetchSimpleAppBlocks(siteRef: siteRef)
            .filter { isSimpleAppRule($0) && ruleTargetsClient($0, mac: clientMac) }

        let lines = rules.enumerated().map { index, rule in
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

        return """
        Client app-block rules:
        - client: \(clientDisplayName(client))
        - mac: \(clientMac)
        - site_ref: \(siteRef)
        - rule_count: \(rules.count)
        \(lines.isEmpty ? "- rules: none" : lines.joined(separator: "\n"))
        """
    }

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

    private func fetchSimpleAppBlocks(siteRef: String) async throws -> [[String: Any]] {
        let path = "/proxy/network/v2/api/site/\(siteRef)/firewall-app-blocks"
        let payload = try await apiClient.getJSON(path: path)
        if let rows = payload as? [[String: Any]] {
            return rows
        }
        if let dict = payload as? [String: Any], let data = dict["data"] as? [[String: Any]] {
            return data
        }
        return []
    }

    private func normalizeTrafficRule(_ payload: Any) -> [String: Any]? {
        if let dict = payload as? [String: Any] {
            if let data = dict["data"] as? [[String: Any]], let first = data.first {
                return first
            }
            return dict
        }
        return nil
    }

    private func trafficRuleID(_ rule: [String: Any]) -> String? {
        let id = (rule["_id"] as? String) ?? (rule["id"] as? String)
        let trimmed = (id ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func isSimpleAppRule(_ rule: [String: Any]) -> Bool {
        let type = normalize(rule["type"])
        let targetType = canonicalTargetType(rule)
        return type == "device" && (targetType == "app_id" || targetType == "app_category")
    }

    private func ruleTargetsClient(_ rule: [String: Any], mac: String) -> Bool {
        let macs = Set(extractClientDevices(rule).map(normalize))
        return macs.contains(normalize(mac))
    }

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

    private func writeSimpleAppBlocks(path: String, blocks: [[String: Any]]) async throws -> Any {
        // This endpoint expects the complete simple-app-block collection in one POST.
        debugLog(
            "SimpleAppBlocks POST payload: count=\(blocks.count), first=\(blocks.first.map(summarizeTrafficRulePayload) ?? "none")",
            category: "UniFiAPI"
        )
        return try await apiClient.postJSON(path: path, body: blocks)
    }

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

    private func arrayStrings(_ any: Any?) -> [String] {
        guard let array = any as? [Any] else { return [] }
        return array.map { String(describing: $0) }.filter { !$0.isEmpty }
    }

    private func scheduleSignature(_ value: Any?) -> String {
        guard let schedule = value as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: schedule, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return text
    }

    private func scheduleMode(_ rule: [String: Any]) -> String {
        guard let schedule = rule["schedule"] as? [String: Any] else { return "unknown" }
        if let mode = schedule["mode"] as? String, !mode.isEmpty {
            return mode
        }
        return "custom"
    }

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

    private func parseCSV(_ value: String?) -> [String] {
        (value ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func normalizedSiteRef(_ rawSiteRef: String?) -> String {
        let candidate = (rawSiteRef ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.isEmpty ? "default" : candidate
    }

    private func resolveClient(_ selector: String, in clients: [[String: Any]]) throws -> [String: Any] {
        try resolveSingle(selector, in: clients, kind: "client") { item in
            clientCandidateValues(item)
        }
    }

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

    private func bestClientMatch(_ selector: String, in rows: [[String: Any]]) -> (client: [String: Any], score: Int)? {
        bestMatch(selector, in: rows) { clientCandidateValues($0) }.map { ($0.row, $0.score) }
    }

    private func bestNamedMatch(_ selector: String, in rows: [[String: Any]]) -> (row: [String: Any], score: Int)? {
        bestMatch(selector, in: rows, candidates: namedCandidateValues)
    }

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

    private func isClientAllowed(_ client: [String: Any]) -> Bool {
        let fields = clientCandidateValues(client).map(normalize)

        for allow in allowedClientSelectors {
            if fields.contains(where: { $0 == allow || $0.contains(allow) }) {
                return true
            }
        }
        return false
    }

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

    private func normalize(_ value: Any?) -> String {
        let cleaned = String(describing: value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if cleaned.isEmpty || cleaned == "null" || cleaned == "<null>" || cleaned == "(null)" {
            return ""
        }
        return cleaned
    }

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

    private func namedIdentifier(_ row: [String: Any]) -> String? {
        stringValue(row["id"])
            ?? stringValue(row["appId"])
            ?? stringValue(row["app_id"])
            ?? stringValue(row["categoryId"])
            ?? stringValue(row["category_id"])
            ?? stringValue(row["name"])
    }

    private func stringValue(_ any: Any?) -> String? {
        guard let any else { return nil }
        let text = String(describing: any).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func isNumericSelector(_ value: String) -> Bool {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        return text.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) }
    }

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

    private func trimmedString(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private actor DPICatalogCache {
    private let ttlSeconds: TimeInterval = 600
    private var applications: [[String: Any]]?
    private var applicationsFetchedAt: Date?
    private var categories: [[String: Any]]?
    private var categoriesFetchedAt: Date?

    func applicationsIfFresh() -> [[String: Any]]? {
        guard let applications, let fetchedAt = applicationsFetchedAt else { return nil }
        guard Date().timeIntervalSince(fetchedAt) <= ttlSeconds else { return nil }
        debugLog("DPI applications cache hit (\(applications.count) items)", category: "Tools")
        return applications
    }

    func categoriesIfFresh() -> [[String: Any]]? {
        guard let categories, let fetchedAt = categoriesFetchedAt else { return nil }
        guard Date().timeIntervalSince(fetchedAt) <= ttlSeconds else { return nil }
        debugLog("DPI categories cache hit (\(categories.count) items)", category: "Tools")
        return categories
    }

    func storeApplications(_ rows: [[String: Any]]) {
        applications = rows
        applicationsFetchedAt = Date()
        debugLog("DPI applications cache store (\(rows.count) items)", category: "Tools")
    }

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

    private func tcpProbe(host: String, port: UInt16, timeoutSeconds: Int) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        return await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            let queue = DispatchQueue(label: "networkgenius.tcpProbe")

            actor OneShot {
                private var done = false
                func mark() -> Bool {
                    if done { return false }
                    done = true
                    return true
                }
            }
            let oneShot = OneShot()

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

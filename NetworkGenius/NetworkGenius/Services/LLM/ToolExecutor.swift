import Foundation

final class ToolExecutor {
    private let queryService: UniFiQueryService
    private let summaryService: UniFiSummaryService
    private let networkMonitor: NetworkMonitor
    private let docsService = UniFiDocumentationService()
    private let lokiService: GrafanaLokiService

    init(
        queryService: UniFiQueryService,
        summaryService: UniFiSummaryService,
        networkMonitor: NetworkMonitor,
        lokiBaseURL: String
    ) {
        self.queryService = queryService
        self.summaryService = summaryService
        self.networkMonitor = networkMonitor
        self.lokiService = GrafanaLokiService(baseURL: lokiBaseURL)
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
            return "Error executing \(toolCall.name): \(error.localizedDescription)"
        }
    }
}

private struct GrafanaLokiService {
    private let baseURL: String
    private let unifiSelector = "{job=~\"unifi|unifi_alarm_manager|unifi_network_events\"}"

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
            return "\(description): no log lines returned for query '\(query)'."
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

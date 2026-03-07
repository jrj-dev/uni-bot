import Foundation

final class ToolExecutor {
    private let queryService: UniFiQueryService
    private let summaryService: UniFiSummaryService
    private let networkMonitor: NetworkMonitor
    private let docsService = UniFiDocumentationService()

    init(queryService: UniFiQueryService, summaryService: UniFiSummaryService, networkMonitor: NetworkMonitor) {
        self.queryService = queryService
        self.summaryService = summaryService
        self.networkMonitor = networkMonitor
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

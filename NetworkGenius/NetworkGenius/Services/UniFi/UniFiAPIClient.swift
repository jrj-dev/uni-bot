import Foundation

enum UniFiAPIError: LocalizedError {
    case missingAPIKey
    case invalidURL(String)
    case httpError(Int, String)
    case networkError(String)
    case siteResolutionFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "UniFi API key not found in Keychain."
        case .invalidURL(let url): return "Invalid URL: \(url)"
        case .httpError(let code, let body): return "HTTP \(code): \(body)"
        case .networkError(let msg): return "Network error: \(msg)"
        case .siteResolutionFailed(let msg): return "Could not resolve UniFi site ID: \(msg)"
        }
    }
}

final class UniFiAPIClient {
    let baseURL: String
    let allowSelfSigned: Bool

    init(baseURL: String, allowSelfSigned: Bool) {
        let normalized = Self.normalizeBaseURL(baseURL)
        self.baseURL = normalized.hasSuffix("/") ? String(normalized.dropLast()) : normalized
        self.allowSelfSigned = allowSelfSigned
    }

    static func normalizeBaseURL(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("https//") {
            value = "https://" + value.dropFirst("https//".count)
        } else if value.hasPrefix("http//") {
            value = "http://" + value.dropFirst("http//".count)
        } else if !value.contains("://"), !value.isEmpty {
            value = "https://\(value)"
        }
        guard let components = URLComponents(string: value),
              let host = components.host,
              !host.isEmpty
        else {
            return value
        }
        if isInvalidIPv4Address(host) {
            return ""
        }
        return value
    }

    private static func isInvalidIPv4Address(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let value = Int(part), value >= 0, value <= 255 else {
                return true
            }
        }
        return false
    }

    func get(path: String, queryItems: [URLQueryItem] = []) async throws -> Data {
        guard let apiKey = KeychainHelper.loadString(key: .unifiAPIKey) else {
            throw UniFiAPIError.missingAPIKey
        }

        var urlString = "\(baseURL)\(path)"
        if !queryItems.isEmpty {
            var components = URLComponents(string: urlString)
            let existing = components?.queryItems ?? []
            components?.queryItems = existing + queryItems
            urlString = components?.string ?? urlString
        }

        guard let url = URL(string: urlString) else {
            throw UniFiAPIError.invalidURL(urlString)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.timeoutInterval = 20

        let session = URLSessionFactory.makeSession(allowSelfSigned: allowSelfSigned)
        let startedAt = Date()
        debugLog("GET \(path) started", category: "UniFiAPI")
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse {
                let elapsedMS = Int(Date().timeIntervalSince(startedAt) * 1000)
                debugLog("GET \(path) -> HTTP \(http.statusCode) in \(elapsedMS)ms", category: "UniFiAPI")
                if !(200..<300).contains(http.statusCode) {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    throw UniFiAPIError.httpError(http.statusCode, body)
                }
            } else {
                let elapsedMS = Int(Date().timeIntervalSince(startedAt) * 1000)
                debugLog("GET \(path) completed in \(elapsedMS)ms (non-HTTP response)", category: "UniFiAPI")
            }

            return data
        } catch let error as UniFiAPIError {
            let elapsedMS = Int(Date().timeIntervalSince(startedAt) * 1000)
            debugLog("GET \(path) failed in \(elapsedMS)ms: \(error.localizedDescription)", category: "UniFiAPI")
            throw error
        } catch {
            let elapsedMS = Int(Date().timeIntervalSince(startedAt) * 1000)
            debugLog("GET \(path) failed in \(elapsedMS)ms: \(error.localizedDescription)", category: "UniFiAPI")
            throw UniFiAPIError.networkError(error.localizedDescription)
        }
    }

    func getJSON(path: String, queryItems: [URLQueryItem] = []) async throws -> Any {
        let data = try await get(path: path, queryItems: queryItems)
        return try JSONSerialization.jsonObject(with: data)
    }

    func postJSON(path: String, body: [String: Any]) async throws -> Any {
        try await sendJSON(method: "POST", path: path, body: body)
    }

    func postJSON(path: String, body: [[String: Any]]) async throws -> Any {
        try await sendJSON(method: "POST", path: path, body: body)
    }

    private func sendJSON(method: String, path: String, body: Any) async throws -> Any {
        // Shared JSON transport so app-block writes can send either a single object
        // or the full collection array through the same authenticated request path.
        guard let apiKey = KeychainHelper.loadString(key: .unifiAPIKey) else {
            throw UniFiAPIError.missingAPIKey
        }
        guard let url = URL(string: "\(baseURL)\(path)") else {
            throw UniFiAPIError.invalidURL("\(baseURL)\(path)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 20

        let session = URLSessionFactory.makeSession(allowSelfSigned: allowSelfSigned)
        let startedAt = Date()
        debugLog("\(method) \(path) started body=\(previewJSON(body))", category: "UniFiAPI")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse {
            let elapsedMS = Int(Date().timeIntervalSince(startedAt) * 1000)
            debugLog("\(method) \(path) -> HTTP \(http.statusCode) in \(elapsedMS)ms", category: "UniFiAPI")
            if !(200..<300).contains(http.statusCode) {
                let bodyText = String(data: data, encoding: .utf8) ?? ""
                throw UniFiAPIError.httpError(http.statusCode, bodyText)
            }
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    func putJSON(path: String, body: [String: Any]) async throws -> Any {
        guard let apiKey = KeychainHelper.loadString(key: .unifiAPIKey) else {
            throw UniFiAPIError.missingAPIKey
        }
        guard let url = URL(string: "\(baseURL)\(path)") else {
            throw UniFiAPIError.invalidURL("\(baseURL)\(path)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 20

        let session = URLSessionFactory.makeSession(allowSelfSigned: allowSelfSigned)
        let startedAt = Date()
        debugLog("PUT \(path) started body=\(previewJSON(body))", category: "UniFiAPI")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse {
            let elapsedMS = Int(Date().timeIntervalSince(startedAt) * 1000)
            debugLog("PUT \(path) -> HTTP \(http.statusCode) in \(elapsedMS)ms", category: "UniFiAPI")
            if !(200..<300).contains(http.statusCode) {
                let bodyText = String(data: data, encoding: .utf8) ?? ""
                throw UniFiAPIError.httpError(http.statusCode, bodyText)
            }
        }
        if data.isEmpty { return ["status": "ok"] }
        return try JSONSerialization.jsonObject(with: data)
    }

    func deleteJSON(path: String) async throws -> Any {
        guard let apiKey = KeychainHelper.loadString(key: .unifiAPIKey) else {
            throw UniFiAPIError.missingAPIKey
        }
        guard let url = URL(string: "\(baseURL)\(path)") else {
            throw UniFiAPIError.invalidURL("\(baseURL)\(path)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.timeoutInterval = 20

        let session = URLSessionFactory.makeSession(allowSelfSigned: allowSelfSigned)
        let startedAt = Date()
        debugLog("DELETE \(path) started", category: "UniFiAPI")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse {
            let elapsedMS = Int(Date().timeIntervalSince(startedAt) * 1000)
            debugLog("DELETE \(path) -> HTTP \(http.statusCode) in \(elapsedMS)ms", category: "UniFiAPI")
            if !(200..<300).contains(http.statusCode) {
                let bodyText = String(data: data, encoding: .utf8) ?? ""
                throw UniFiAPIError.httpError(http.statusCode, bodyText)
            }
        }
        if data.isEmpty { return ["status": "ok"] }
        return try JSONSerialization.jsonObject(with: data)
    }

    func getAllPages(path: String, pageSize: Int = 100) async throws -> [[String: Any]] {
        var allItems: [[String: Any]] = []
        var offset = 0

        while true {
            let queryItems = [
                URLQueryItem(name: "offset", value: String(offset)),
                URLQueryItem(name: "limit", value: String(pageSize)),
            ]
            let data = try await get(path: path, queryItems: queryItems)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["data"] as? [[String: Any]],
                  let totalCount = json["totalCount"] as? Int
            else {
                // Non-paginated response
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let items = json["data"] as? [[String: Any]]
                {
                    debugLog("GET \(path) non-paginated (\(items.count) items)", category: "UniFiAPI")
                    return items
                }
                debugLog("GET \(path) returned unrecognized payload shape", category: "UniFiAPI")
                return allItems
            }

            allItems.append(contentsOf: items)
            offset += items.count
            if items.isEmpty || offset >= totalCount {
                break
            }
        }
        debugLog("GET \(path) completed pagination with \(allItems.count) items", category: "UniFiAPI")
        return allItems
    }

    private func previewJSON(_ value: Any, limit: Int = 800) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else {
            let fallback = String(describing: value)
            return String(fallback.prefix(limit))
        }
        return String(text.prefix(limit))
    }
}

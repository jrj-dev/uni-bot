import Foundation

enum UniFiAPIError: LocalizedError {
    case missingAPIKey
    case invalidURL(String)
    case httpError(Int, String)
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "UniFi API key not found in Keychain."
        case .invalidURL(let url): return "Invalid URL: \(url)"
        case .httpError(let code, let body): return "HTTP \(code): \(body)"
        case .networkError(let msg): return "Network error: \(msg)"
        }
    }
}

final class UniFiAPIClient {
    let baseURL: String
    let allowSelfSigned: Bool

    init(baseURL: String, allowSelfSigned: Bool) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.allowSelfSigned = allowSelfSigned
    }

    func get(path: String, queryItems: [URLQueryItem] = []) async throws -> Data {
        guard let apiKey = KeychainHelper.loadString(key: .unifiAPIKey) else {
            throw UniFiAPIError.missingAPIKey
        }

        var urlString = "\(baseURL)\(path)"
        if !queryItems.isEmpty {
            var components = URLComponents(string: urlString)
            components?.queryItems = queryItems
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
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                let body = String(data: data, encoding: .utf8) ?? ""
                throw UniFiAPIError.httpError(http.statusCode, body)
            }
            return data
        } catch let error as UniFiAPIError {
            throw error
        } catch {
            throw UniFiAPIError.networkError(error.localizedDescription)
        }
    }

    func getJSON(path: String, queryItems: [URLQueryItem] = []) async throws -> Any {
        let data = try await get(path: path, queryItems: queryItems)
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
                    return items
                }
                return allItems
            }

            allItems.append(contentsOf: items)
            offset += items.count
            if items.isEmpty || offset >= totalCount {
                break
            }
        }
        return allItems
    }
}

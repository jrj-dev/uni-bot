import Foundation
import Darwin
import CFNetwork

final class LMStudioLLMService: LLMService {
    private let model: String
    private let baseURL: String
    private let session: URLSession
    private let requestTimeoutSeconds: TimeInterval = 35

    init(baseURL: String, model: String) {
        self.baseURL = UniFiAPIClient.normalizeBaseURL(baseURL)
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        // Local providers should bypass system proxies when possible.
        config.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: 0,
            "HTTPSEnable": 0,
            kCFNetworkProxiesProxyAutoConfigEnable as String: 0,
        ]
        self.session = URLSession(configuration: config)
        if self.baseURL.isEmpty {
            debugLog("LM Studio service configured without base URL", category: "LLM")
        } else {
            let host = URL(string: self.baseURL)?.host ?? "unknown"
            debugLog("LM Studio service configured (host=\(host), model=\(self.model))", category: "LLM")
        }
    }

    func sendMessages(_ messages: [LLMMessage], tools: [[String: Any]], systemPrompt: String) async throws -> LLMResponse {
        guard !baseURL.isEmpty else {
            throw LLMError.invalidResponse("LM Studio base URL is not configured.")
        }
        guard !model.isEmpty else {
            throw LLMError.invalidResponse("LM Studio model is not set. Load models in Settings and select one.")
        }
        guard let rawKey = KeychainHelper.loadString(key: .lmStudioAPIKey) else {
            throw LLMError.missingAPIKey
        }
        let apiKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { throw LLMError.missingAPIKey }

        guard var components = URLComponents(string: baseURL) else {
            throw LLMError.invalidResponse("Invalid LM Studio base URL.")
        }
        if let originalHost = components.host {
            if let resolvedIP = resolvedIPv4Address(for: originalHost), resolvedIP != originalHost {
                components.host = resolvedIP
                debugLog("LM Studio host resolved to IP \(resolvedIP) (from \(originalHost))", category: "LLM")
            } else if !looksLikeIPv4(originalHost) {
                debugLog("LM Studio hostname resolution failed for '\(originalHost)'", category: "LLM")
                throw LLMError.invalidResponse(
                    "LM Studio host '\(originalHost)' could not be resolved on this device. Use a direct LAN IP (e.g. http://192.168.x.x:1234)."
                )
            }
        }
        components.path = "/v1/chat/completions"
        guard let url = components.url else {
            throw LLMError.invalidResponse("Invalid LM Studio base URL.")
        }

        var lmMessages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt],
        ]
        for msg in messages {
            lmMessages.append(openAIMessage(msg))
        }

        do {
            return try await executeRequest(
                url: url,
                apiKey: apiKey,
                lmMessages: lmMessages,
                tools: tools
            )
        } catch {
            if isTimeoutError(error), !tools.isEmpty {
                debugLog(
                    "LM Studio timed out with tools payload; retrying once without tools",
                    category: "LLM"
                )
                return try await executeRequest(
                    url: url,
                    apiKey: apiKey,
                    lmMessages: lmMessages,
                    tools: []
                )
            }
            if isTimeoutError(error) {
                throw LLMError.invalidResponse(
                    "LM Studio timed out. Confirm LM Studio is running and bound to 0.0.0.0:1234 (not localhost-only), and that this device can reach it on LAN/VPN."
                )
            }
            throw error
        }
    }

    private func executeRequest(
        url: URL,
        apiKey: String,
        lmMessages: [[String: Any]],
        tools: [[String: Any]]
    ) async throws -> LLMResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = requestTimeoutSeconds

        var body: [String: Any] = [
            "model": model,
            "messages": lmMessages,
        ]
        if !tools.isEmpty {
            body["tools"] = tools
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let startedAt = Date()
        debugLog(
            "LM Studio request started (model=\(model), messages=\(lmMessages.count), tools=\(tools.count), timeout=\(Int(requestTimeoutSeconds))s, url=\(url.absoluteString))",
            category: "LLM"
        )
        do {
            let (data, response) = try await dataWithTimeout(for: request, timeoutSeconds: requestTimeoutSeconds)
            if let http = response as? HTTPURLResponse {
                let elapsedMS = Int(Date().timeIntervalSince(startedAt) * 1000)
                let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
                debugLog(
                    "LM Studio response HTTP \(http.statusCode) in \(elapsedMS)ms (bytes=\(data.count), contentType=\(contentType))",
                    category: "LLM"
                )
                guard (200..<300).contains(http.statusCode) else {
                    let bodyText = String(data: data, encoding: .utf8) ?? ""
                    let bodyPreview = String(bodyText.prefix(400)).replacingOccurrences(of: "\n", with: " ")
                    debugLog("LM Studio error response bodyPreview=\(bodyPreview)", category: "LLM")
                    if http.statusCode == 502 {
                        throw LLMError.invalidResponse(
                            "LM Studio returned HTTP 502 (often proxy interference). Use direct LAN IP/hostname and disable iCloud Private Relay/Limit IP Address Tracking for this Wi-Fi."
                        )
                    }
                    throw LLMError.httpError(http.statusCode, bodyText)
                }
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let choice = choices.first,
                  let message = choice["message"] as? [String: Any]
            else {
                let preview = String(data: data.prefix(400), encoding: .utf8) ?? "<non-utf8 payload>"
                debugLog("LM Studio parse failed: missing choices/message payloadPreview=\(preview)", category: "LLM")
                throw LLMError.invalidResponse("Missing choices in response")
            }

            let finishReason = choice["finish_reason"] as? String
            let text = message["content"] as? String
            var toolCalls: [LLMToolCall] = []

            if let tcs = message["tool_calls"] as? [[String: Any]] {
                for tc in tcs {
                    let id = tc["id"] as? String ?? UUID().uuidString
                    let function = tc["function"] as? [String: Any] ?? [:]
                    let name = function["name"] as? String ?? ""
                    let argsString = function["arguments"] as? String ?? "{}"
                    let argsData = argsString.data(using: .utf8) ?? Data()
                    let args = (try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]) ?? [:]
                    toolCalls.append(LLMToolCall(id: id, name: name, arguments: args.mapValues { "\($0)" }))
                }
            }

            return LLMResponse(
                text: text,
                toolCalls: toolCalls,
                stopReason: finishReason == "tool_calls" ? .toolUse : .endTurn
            )
        } catch {
            let elapsedMS = Int(Date().timeIntervalSince(startedAt) * 1000)
            let nsError = error as NSError
            debugLog(
                "LM Studio request failed in \(elapsedMS)ms domain=\(nsError.domain) code=\(nsError.code) description=\(error.localizedDescription)",
                category: "LLM"
            )
            throw error
        }
    }

    private func openAIMessage(_ msg: LLMMessage) -> [String: Any] {
        switch msg.role {
        case .user:
            return ["role": "user", "content": msg.content]
        case .assistant:
            if let toolCalls = msg.toolCalls, !toolCalls.isEmpty {
                var result: [String: Any] = ["role": "assistant"]
                if !msg.content.isEmpty {
                    result["content"] = msg.content
                }
                result["tool_calls"] = toolCalls.map { tc in
                    [
                        "id": tc.id,
                        "type": "function",
                        "function": [
                            "name": tc.name,
                            "arguments": (try? JSONSerialization.data(
                                withJSONObject: tc.arguments
                            )).flatMap { String(data: $0, encoding: .utf8) } ?? "{}",
                        ],
                    ] as [String: Any]
                }
                return result
            }
            return ["role": "assistant", "content": msg.content]
        case .tool:
            return [
                "role": "tool",
                "tool_call_id": msg.toolCallID ?? "",
                "content": msg.content,
            ]
        }
    }

    private func resolvedIPv4Address(for host: String) -> String? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Host already looks like IPv4.
        if trimmed.split(separator: ".").count == 4,
           trimmed.allSatisfy({ $0.isNumber || $0 == "." }) {
            return trimmed
        }

        var hints = addrinfo(
            ai_flags: AI_DEFAULT,
            ai_family: AF_INET,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(trimmed, nil, &hints, &result)
        guard status == 0, let first = result else {
            return nil
        }
        defer { freeaddrinfo(result) }

        for pointer in sequence(first: first, next: { $0.pointee.ai_next }) {
            guard let sockaddr = pointer.pointee.ai_addr else { continue }
            guard sockaddr.pointee.sa_family == sa_family_t(AF_INET) else { continue }

            var address = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            let ipv4 = UnsafeRawPointer(sockaddr).assumingMemoryBound(to: sockaddr_in.self)
            var sinAddr = ipv4.pointee.sin_addr
            let converted = withUnsafePointer(to: &sinAddr) { ptr in
                inet_ntop(AF_INET, ptr, &address, socklen_t(INET_ADDRSTRLEN))
            }
            if converted != nil {
                return String(cString: address)
            }
        }
        return nil
    }

    private func looksLikeIPv4(_ host: String) -> Bool {
        host.split(separator: ".").count == 4 && host.allSatisfy { $0.isNumber || $0 == "." }
    }

    private func dataWithTimeout(for request: URLRequest, timeoutSeconds: TimeInterval) async throws -> (Data, URLResponse) {
        try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
            group.addTask {
                try await self.session.data(for: request)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw URLError(.timedOut)
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    private func isTimeoutError(_ error: Error) -> Bool {
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == URLError.timedOut.rawValue
    }
}

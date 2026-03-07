import Foundation

final class OpenAILLMService: LLMService {
    private let model = "gpt-4o"
    private let maxAttempts = 4

    func sendMessages(_ messages: [LLMMessage], tools: [[String: Any]], systemPrompt: String) async throws -> LLMResponse {
        guard let rawKey = KeychainHelper.loadString(key: .openaiAPIKey) else {
            throw LLMError.missingAPIKey
        }
        let apiKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { throw LLMError.missingAPIKey }

        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60

        var openAIMessages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt],
        ]
        for msg in messages {
            openAIMessages.append(openAIMessage(msg))
        }

        var body: [String: Any] = [
            "model": model,
            "messages": openAIMessages,
        ]
        if !tools.isEmpty {
            body["tools"] = tools
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        debugLog("OpenAI request started (model=\(model), messages=\(openAIMessages.count), tools=\(tools.count))", category: "LLM")
        return try await sendWithRetry(request: request)
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

    private func sendWithRetry(request: URLRequest) async throws -> LLMResponse {
        var attempt = 1
        while true {
            let startedAt = Date()
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw LLMError.invalidResponse("Non-HTTP response from OpenAI")
                }

                let elapsedMS = Int(Date().timeIntervalSince(startedAt) * 1000)
                debugLog("OpenAI response HTTP \(http.statusCode) in \(elapsedMS)ms (attempt=\(attempt)/\(maxAttempts))", category: "LLM")

                if !(200..<300).contains(http.statusCode) {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    if shouldRetry(statusCode: http.statusCode), attempt < maxAttempts {
                        let delay = retryDelay(statusCode: http.statusCode, headers: http.allHeaderFields, attempt: attempt)
                        debugLog(
                            "OpenAI throttled/transient HTTP \(http.statusCode); retrying in \(String(format: "%.2f", delay))s (attempt=\(attempt + 1)/\(maxAttempts))",
                            category: "LLM"
                        )
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        attempt += 1
                        continue
                    }
                    throw LLMError.httpError(http.statusCode, body)
                }

                return try parseLLMResponse(data)
            } catch {
                if Task.isCancelled { throw error }
                if isRetryableNetworkError(error), attempt < maxAttempts {
                    let delay = retryDelay(statusCode: nil, headers: [:], attempt: attempt)
                    let nsError = error as NSError
                    debugLog(
                        "OpenAI network error domain=\(nsError.domain) code=\(nsError.code); retrying in \(String(format: "%.2f", delay))s (attempt=\(attempt + 1)/\(maxAttempts))",
                        category: "LLM"
                    )
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    attempt += 1
                    continue
                }
                throw error
            }
        }
    }

    private func parseLLMResponse(_ data: Data) throws -> LLMResponse {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let choice = choices.first,
              let message = choice["message"] as? [String: Any]
        else {
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
    }

    private func shouldRetry(statusCode: Int) -> Bool {
        statusCode == 429 || statusCode == 408 || statusCode == 500 || statusCode == 502 || statusCode == 503 || statusCode == 504
    }

    private func retryDelay(statusCode: Int?, headers: [AnyHashable: Any], attempt: Int) -> TimeInterval {
        if statusCode == 429 {
            if let retryAfter = headerValue("Retry-After", headers: headers),
               let parsed = parseRetryAfterSeconds(retryAfter) {
                return min(max(parsed, 0.5), 30)
            }
            if let reset = headerValue("x-ratelimit-reset-requests", headers: headers),
               let parsed = parseResetDurationSeconds(reset) {
                return min(max(parsed, 0.5), 30)
            }
        }

        let base = min(pow(2.0, Double(attempt - 1)), 8.0)
        let jitter = Double.random(in: 0...0.35)
        return base + jitter
    }

    private func headerValue(_ key: String, headers: [AnyHashable: Any]) -> String? {
        for (headerKey, value) in headers {
            if String(describing: headerKey).caseInsensitiveCompare(key) == .orderedSame {
                return String(describing: value)
            }
        }
        return nil
    }

    private func parseRetryAfterSeconds(_ value: String) -> TimeInterval? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = Double(trimmed) { return seconds }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        guard let date = formatter.date(from: trimmed) else { return nil }
        return date.timeIntervalSinceNow
    }

    private func parseResetDurationSeconds(_ value: String) -> TimeInterval? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let seconds = Double(trimmed) { return seconds }
        if trimmed.hasSuffix("ms"), let ms = Double(trimmed.dropLast(2)) { return ms / 1000.0 }
        if trimmed.hasSuffix("s"), let s = Double(trimmed.dropLast(1)) { return s }
        if trimmed.hasSuffix("m"), let m = Double(trimmed.dropLast(1)) { return m * 60 }
        return nil
    }

    private func isRetryableNetworkError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed, .notConnectedToInternet:
            return true
        default:
            return false
        }
    }
}

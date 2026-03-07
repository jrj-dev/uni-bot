import Foundation

final class OpenAILLMService: LLMService {
    private let model = "gpt-4o"

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

        let startedAt = Date()
        debugLog("OpenAI request started (model=\(model), messages=\(openAIMessages.count), tools=\(tools.count))", category: "LLM")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            let elapsedMS = Int(Date().timeIntervalSince(startedAt) * 1000)
            debugLog("OpenAI response HTTP \(http.statusCode) in \(elapsedMS)ms", category: "LLM")
            if !(200..<300).contains(http.statusCode) {
                let body = String(data: data, encoding: .utf8) ?? ""
                throw LLMError.httpError(http.statusCode, body)
            }
        }

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
}

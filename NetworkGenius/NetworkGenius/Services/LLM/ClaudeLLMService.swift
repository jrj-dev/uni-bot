import Foundation

final class ClaudeLLMService: LLMService {
    private let model = "claude-sonnet-4-20250514"

    func sendMessages(_ messages: [LLMMessage], tools: [[String: Any]], systemPrompt: String) async throws -> LLMResponse {
        guard let apiKey = KeychainHelper.loadString(key: .claudeAPIKey) else {
            throw LLMError.missingAPIKey
        }

        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 60

        var body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "system": systemPrompt,
            "messages": messages.map { claudeMessage($0) },
        ]
        if !tools.isEmpty {
            body["tools"] = tools
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.httpError(http.statusCode, body)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]]
        else {
            throw LLMError.invalidResponse("Missing content in response")
        }

        let stopReason = json["stop_reason"] as? String
        var text: String?
        var toolCalls: [LLMToolCall] = []

        for block in content {
            let type = block["type"] as? String
            if type == "text" {
                text = block["text"] as? String
            } else if type == "tool_use" {
                let id = block["id"] as? String ?? UUID().uuidString
                let name = block["name"] as? String ?? ""
                let input = block["input"] as? [String: Any] ?? [:]
                let args = input.mapValues { "\($0)" }
                toolCalls.append(LLMToolCall(id: id, name: name, arguments: args))
            }
        }

        return LLMResponse(
            text: text,
            toolCalls: toolCalls,
            stopReason: stopReason == "tool_use" ? .toolUse : .endTurn
        )
    }

    private func claudeMessage(_ msg: LLMMessage) -> [String: Any] {
        switch msg.role {
        case .user:
            return ["role": "user", "content": msg.content]
        case .assistant:
            if let toolCalls = msg.toolCalls, !toolCalls.isEmpty {
                var content: [[String: Any]] = []
                if !msg.content.isEmpty {
                    content.append(["type": "text", "text": msg.content])
                }
                for tc in toolCalls {
                    content.append([
                        "type": "tool_use",
                        "id": tc.id,
                        "name": tc.name,
                        "input": tc.arguments,
                    ])
                }
                return ["role": "assistant", "content": content]
            }
            return ["role": "assistant", "content": msg.content]
        case .tool:
            return [
                "role": "user",
                "content": [
                    [
                        "type": "tool_result",
                        "tool_use_id": msg.toolCallID ?? "",
                        "content": msg.content,
                    ] as [String: Any]
                ],
            ]
        }
    }
}

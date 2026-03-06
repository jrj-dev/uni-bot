import Foundation

protocol LLMService {
    func sendMessages(_ messages: [LLMMessage], tools: [[String: Any]], systemPrompt: String) async throws -> LLMResponse
}

enum LLMError: LocalizedError {
    case missingAPIKey
    case invalidResponse(String)
    case httpError(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "LLM API key not found in Keychain."
        case .invalidResponse(let msg): return "Invalid response: \(msg)"
        case .httpError(let code, let body): return "HTTP \(code): \(body)"
        }
    }
}

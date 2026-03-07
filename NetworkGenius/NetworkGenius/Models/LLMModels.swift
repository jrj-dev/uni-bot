import Foundation

struct LLMMessage: Codable {
    enum Role: String, Codable {
        case user, assistant, tool
    }

    let role: Role
    let content: String
    var toolCallID: String?
    var toolCalls: [LLMToolCall]?
}

struct LLMToolCall: Identifiable, Codable {
    let id: String
    let name: String
    let arguments: [String: String]
}

struct LLMResponse {
    let text: String?
    let toolCalls: [LLMToolCall]
    let stopReason: StopReason

    enum StopReason {
        case endTurn
        case toolUse
    }
}

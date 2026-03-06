import Foundation

enum MessageRole: String, Codable {
    case user
    case assistant
    case toolCall
    case toolResult
}

struct ChatMessage: Identifiable {
    let id: UUID
    let role: MessageRole
    let content: String
    let timestamp: Date
    var toolName: String?
    var toolCallID: String?

    init(role: MessageRole, content: String, toolName: String? = nil, toolCallID: String? = nil) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = Date()
        self.toolName = toolName
        self.toolCallID = toolCallID
    }
}

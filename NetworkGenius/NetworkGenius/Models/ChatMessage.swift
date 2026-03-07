import Foundation
import SwiftData

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
        self.init(
            id: UUID(),
            role: role,
            content: content,
            timestamp: Date(),
            toolName: toolName,
            toolCallID: toolCallID
        )
    }

    init(
        id: UUID,
        role: MessageRole,
        content: String,
        timestamp: Date,
        toolName: String? = nil,
        toolCallID: String? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.toolName = toolName
        self.toolCallID = toolCallID
    }
}

@Model
final class ConversationThread {
    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var llmTranscriptData: Data?
    @Relationship(deleteRule: .cascade, inverse: \PersistedChatMessage.thread)
    var messages: [PersistedChatMessage]

    init(
        id: UUID = UUID(),
        title: String = "New Chat",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        llmTranscriptData: Data? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.llmTranscriptData = llmTranscriptData
        self.messages = []
    }
}

@Model
final class PersistedChatMessage {
    @Attribute(.unique) var id: UUID
    var roleRaw: String
    var content: String
    var timestamp: Date
    var toolName: String?
    var toolCallID: String?
    var thread: ConversationThread?

    init(
        id: UUID = UUID(),
        roleRaw: String,
        content: String,
        timestamp: Date = Date(),
        toolName: String? = nil,
        toolCallID: String? = nil,
        thread: ConversationThread? = nil
    ) {
        self.id = id
        self.roleRaw = roleRaw
        self.content = content
        self.timestamp = timestamp
        self.toolName = toolName
        self.toolCallID = toolCallID
        self.thread = thread
    }
}

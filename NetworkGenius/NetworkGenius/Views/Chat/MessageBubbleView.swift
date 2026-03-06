import SwiftUI

struct MessageBubbleView: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer() }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                if message.role == .toolCall {
                    Label(message.content, systemImage: "network")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                } else {
                    Text(message.content)
                        .padding(12)
                        .background(backgroundColor)
                        .foregroundStyle(foregroundColor)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
            }
            .frame(maxWidth: 300, alignment: message.role == .user ? .trailing : .leading)

            if message.role != .user { Spacer() }
        }
    }

    private var backgroundColor: Color {
        switch message.role {
        case .user: return .blue
        case .assistant: return Color(.systemGray5)
        case .toolCall, .toolResult: return Color(.systemGray6)
        }
    }

    private var foregroundColor: Color {
        message.role == .user ? .white : .primary
    }
}

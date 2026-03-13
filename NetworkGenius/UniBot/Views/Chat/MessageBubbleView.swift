import SwiftUI

struct MessageBubbleView: View {
    let message: ChatMessage
    var canRetry: Bool = false
    var onRetry: (() -> Void)? = nil

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

                if message.role == .user, message.sendFailed {
                    Button {
                        onRetry?()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(canRetry ? "Not sent. Tap to retry." : "Not sent.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!canRetry || onRetry == nil)
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

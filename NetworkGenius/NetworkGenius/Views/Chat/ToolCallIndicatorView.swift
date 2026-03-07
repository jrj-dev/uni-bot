import SwiftUI

struct ToolCallIndicatorView: View {
    let toolName: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(statusText(at: context.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func statusText(at date: Date) -> String {
        let cycle = Int(date.timeIntervalSinceReferenceDate * 2) % 4
        let dots = String(repeating: ".", count: cycle)
        let base = toolName.map { "Querying \($0)" } ?? "Thinking"
        return "\(base)\(dots)"
    }
}

import SwiftUI

struct NetworkStatusBadge: View {
    @EnvironmentObject private var networkMonitor: NetworkMonitor

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(networkMonitor.isOnNetwork ? .green : .gray)
                .frame(width: 8, height: 8)
            Text(networkMonitor.isOnNetwork ? "On Network" : "Off Network")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

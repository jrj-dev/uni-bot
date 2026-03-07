import SwiftUI

struct NetworkStatusBadge: View {
    @EnvironmentObject private var networkMonitor: NetworkMonitor

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(networkMonitor.isOnNetwork ? .green : .gray)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(networkMonitor.isOnNetwork ? .green : .secondary)
        }
    }

    private var statusText: String {
        guard networkMonitor.isOnNetwork else { return "Network: Offline" }
        if networkMonitor.isVPNConnected {
            return "Network: Connected via VPN"
        }
        if networkMonitor.isWiFiConnected {
            return "Network: Connected via Wi-Fi"
        }
        return "Network: Connected"
    }
}

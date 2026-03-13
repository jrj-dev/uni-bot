import SwiftUI

struct ConnectionTestButton: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task { await viewModel.testConnection() }
            } label: {
                HStack {
                    if viewModel.isTesting {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("Test Connection")
                }
            }
            .disabled(viewModel.consoleURL.isEmpty || viewModel.unifiAPIKey.isEmpty || viewModel.isTesting)

            if let result = viewModel.connectionTestResult {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(result.hasPrefix("Connected") ? .green : .red)
            }
        }
    }
}

import SwiftUI

struct UniFiSettingsSection: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Section("UniFi Console") {
            TextField("Console URL", text: $viewModel.consoleURL)
                .keyboardType(.URL)
                .textContentType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            SecureField("API Key", text: $viewModel.unifiAPIKey)
                .textContentType(.password)

            TextField("SSH Username (optional)", text: $viewModel.unifiSSHUsername)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            SecureField("SSH Password (optional)", text: $viewModel.unifiSSHPassword)
                .textContentType(.password)

            VStack(alignment: .leading, spacing: 6) {
                Text("SSH Private Key (optional)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $viewModel.unifiSSHPrivateKey)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 90, maxHeight: 140)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
            }

            TextField("Site ID (optional)", text: $viewModel.siteID)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            Toggle("Allow Self-Signed Certificates", isOn: $viewModel.allowSelfSignedCerts)

            ConnectionTestButton(viewModel: viewModel)
        }

        Section("Grafana Loki Logs") {
            TextField("Loki Base URL", text: $viewModel.grafanaLokiURL)
                .keyboardType(.URL)
                .textContentType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            SecureField("Loki API Key (optional)", text: $viewModel.grafanaLokiAPIKey)
                .textContentType(.password)

            VStack(alignment: .leading, spacing: 8) {
                Button {
                    Task { await viewModel.testLokiConnection() }
                } label: {
                    HStack {
                        if viewModel.isTestingLokiConnection {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text("Test Loki Connection")
                    }
                }
                .disabled(
                    UniFiAPIClient.normalizeBaseURL(viewModel.grafanaLokiURL).isEmpty
                        || viewModel.isTestingLokiConnection
                )

                if let result = viewModel.lokiConnectionTestResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(result.hasPrefix("Connected") ? .green : .red)
                }
            }
        }
    }
}

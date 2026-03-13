import SwiftUI

struct UniFiSettingsSection: View {
    @ObservedObject var viewModel: SettingsViewModel
    let isAdvancedMode: Bool

    var body: some View {
        Section("UniFi Console") {
            TextField("Console URL", text: $viewModel.consoleURL)
                .keyboardType(.URL)
                .textContentType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            SecureField("API Key", text: $viewModel.unifiAPIKey)
                .textContentType(.password)

            TextField("Site ID (optional)", text: $viewModel.siteID)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            Toggle("Allow Self-Signed Certificates", isOn: $viewModel.allowSelfSignedCerts)

            ConnectionTestButton(viewModel: viewModel)
        }

        if isAdvancedMode {
            SSHSettingsSection(viewModel: viewModel)

            Section("Client Guardrails") {
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        Task { await viewModel.refreshClientModificationApprovals() }
                    } label: {
                        HStack {
                            if viewModel.isLoadingClientModificationApprovals {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text("Load Clients From UniFi")
                        }
                    }

                    Text("Curate which clients are allowed for write-capable actions. Entries are keyed by MAC when available so approvals survive reconnects, and inactive clients stay in the list.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let result = viewModel.clientModificationApprovalResult {
                        Text(result)
                            .font(.caption)
                            .foregroundStyle(result.hasPrefix("Loaded") ? .green : .red)
                    }
                }

                if viewModel.clientModificationApprovals.isEmpty {
                    Text("No clients loaded yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.clientModificationApprovals) { approval in
                        VStack(alignment: .leading, spacing: 8) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text(approval.displayName)
                                    if approval.isLegacyHistoryEntry && !approval.isCurrentlyConnected {
                                        Text("Legacy history")
                                            .font(.caption2)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.orange.opacity(0.15))
                                            .foregroundStyle(.orange)
                                            .clipShape(Capsule())
                                    }
                                }
                                if !approval.detailLine.isEmpty {
                                    Text(approval.detailLine)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Toggle(
                                "Allow client modifications",
                                isOn: Binding(
                                    get: { approval.allowClientModifications },
                                    set: { viewModel.setClientModificationApproval($0, for: approval.id) }
                                )
                            )
                                .font(.caption)
                        }
                        .padding(.vertical, 4)
                        .swipeActions {
                            Button(role: .destructive) {
                                viewModel.removeClientModificationApproval(approval)
                            } label: {
                                Text("Remove")
                            }
                        }
                    }
                }
            }

            Section("Legacy Client History") {
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        Task { await viewModel.loadLegacyGuardrailClients() }
                    } label: {
                        HStack {
                            if viewModel.isLoadingLegacyGuardrailClients {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text("Load Legacy History")
                        }
                    }

                    Text("Loads historical UniFi clients from the legacy alluser feed that are not in the current live guardrail source and were seen within the last week. Use this to add offline clients back into Client Guardrails explicitly.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField("Search legacy clients", text: $viewModel.legacyGuardrailClientSearchText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    if let result = viewModel.legacyGuardrailClientsLoadResult {
                        Text(result)
                            .font(.caption)
                            .foregroundStyle(result.hasPrefix("Loaded") || result.hasPrefix("Added") ? .green : .red)
                    }
                }

                let filteredLegacyClients = viewModel.availableLegacyGuardrailClients.filter {
                    viewModel.legacyGuardrailClientSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || $0.searchText.contains(viewModel.legacyGuardrailClientSearchText.lowercased())
                }

                if filteredLegacyClients.isEmpty {
                    Text("No legacy-only clients loaded.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredLegacyClients) { option in
                        VStack(alignment: .leading, spacing: 8) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(option.title)
                                if !option.subtitle.isEmpty {
                                    Text(option.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Button("Add To Client Guardrails") {
                                viewModel.addLegacyGuardrailClient(option)
                            }
                            .font(.caption)
                        }
                        .padding(.vertical, 4)
                    }
                }
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
}

private struct SSHSettingsSection: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Section("UniFi SSH") {
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
        }
    }
}

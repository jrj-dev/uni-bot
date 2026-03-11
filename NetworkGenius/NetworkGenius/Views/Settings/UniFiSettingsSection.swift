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
            if isAdvancedMode {
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

        if isAdvancedMode {
            Section("Client Modify Whitelist") {
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

                    Text("Curate which clients are allowed for write-capable actions such as changes and restarts. Entries are keyed by MAC when available so approvals survive reconnects.")
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
                    ForEach($viewModel.clientModificationApprovals) { $approval in
                        Toggle(isOn: $approval.isApproved) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(approval.wrappedValue.displayName)
                                if !approval.wrappedValue.detailLine.isEmpty {
                                    Text(approval.wrappedValue.detailLine)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                viewModel.removeClientModificationApproval(approval.wrappedValue)
                            } label: {
                                Text("Remove")
                            }
                        }
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

        Section("Change Guardrails") {
            Text("App Block Allowed Clients")
                .font(.caption)
                .foregroundStyle(.secondary)

            if viewModel.appBlockAllowedClientSelectors.isEmpty {
                Text("No clients allowlisted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.appBlockAllowedClientSelectors, id: \.self) { selector in
                    let matched = viewModel.availableGuardrailClients.first(where: { $0.selector == selector })
                    let cachedName = viewModel.cachedGuardrailClientName(for: selector)
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            if let matched {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(matched.isActive ? Color.green : Color.gray)
                                        .frame(width: 8, height: 8)
                                    Text(matched.title)
                                        .font(.caption)
                                }
                                Text(selector)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            } else if let cachedName, !cachedName.isEmpty {
                                Text(cachedName)
                                    .font(.caption)
                                Text(selector)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            } else {
                                Text(selector)
                                    .font(.caption)
                                    .textSelection(.enabled)
                            }
                        }
                        Spacer(minLength: 8)
                        Button("Remove", role: .destructive) {
                            viewModel.removeGuardrailClient(selector: selector)
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                    }
                }
            }

            Button {
                Task { await viewModel.loadGuardrailClients() }
            } label: {
                HStack {
                    if viewModel.isLoadingGuardrailClients {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("Load Clients")
                }
            }
            .disabled(
                UniFiAPIClient.normalizeBaseURL(viewModel.consoleURL).isEmpty
                    || viewModel.isLoadingGuardrailClients
            )

            if let result = viewModel.guardrailClientsLoadResult {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(result.hasPrefix("Loaded") ? .green : .red)
            }

            let selectable = viewModel.availableGuardrailClients.filter { option in
                !viewModel.appBlockAllowedClientSelectors.contains(option.selector)
            }
            if !selectable.isEmpty {
                TextField("Search clients", text: $viewModel.guardrailClientSearchText)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                Text("Add Clients")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                let search = viewModel.guardrailClientSearchText
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                let filtered = search.isEmpty
                    ? selectable
                    : selectable.filter { $0.searchText.contains(search) }

                ForEach(filtered) { option in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(option.isActive ? Color.green : Color.gray)
                                    .frame(width: 8, height: 8)
                                Text(option.title)
                            }
                            Text(option.subtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button("Add") {
                            viewModel.addGuardrailClient(option)
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                    }
                }

                if filtered.isEmpty {
                    Text("No clients match your search.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

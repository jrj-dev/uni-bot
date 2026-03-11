import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = SettingsViewModel()
    @StateObject private var logStore = DebugLogStore.shared

    var body: some View {
        NavigationStack {
            Form {
                Section("Mode") {
                    Picker("Assistant Mode", selection: $viewModel.selectedAssistantMode) {
                        ForEach(AssistantMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(viewModel.isAdvancedMode
                         ? "Advanced mode exposes technical diagnostics, local-model options, and log-driven workflows."
                         : "Basic mode keeps the experience focused on plain-language troubleshooting and hides operator features.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                UniFiSettingsSection(viewModel: viewModel, isAdvancedMode: viewModel.isAdvancedMode)
                LLMSettingsSection(viewModel: viewModel, isAdvancedMode: viewModel.isAdvancedMode)
                VoiceSettingsSection(viewModel: viewModel)
                Section("Appearance") {
                    Toggle("Dark Mode", isOn: $viewModel.darkModeEnabled)
                }
                if viewModel.isAdvancedMode {
                    Section("Diagnostics") {
                    NavigationLink("App Console Logs") {
                        DebugLogListView(logStore: logStore)
                    }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        viewModel.save(to: appState)
                        dismiss()
                    }
                }
            }
            .onAppear {
                viewModel.load(from: appState)
            }
            .onChange(of: viewModel.selectedAssistantMode) { _, _ in
                viewModel.handleAssistantModeChange()
            }
        }
    }
}

private struct DebugLogListView: View {
    @ObservedObject var logStore: DebugLogStore

    var body: some View {
        List(logStore.entries.reversed()) { entry in
            VStack(alignment: .leading, spacing: 4) {
                Text("[\(entry.category)] \(entry.message)")
                    .font(.caption)
                    .textSelection(.enabled)
                Text(Self.timeFormatter.string(from: entry.timestamp))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
        .navigationTitle("Debug Logs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Clear") {
                    logStore.clear()
                }
                .disabled(logStore.entries.isEmpty)
            }
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}

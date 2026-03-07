import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = SettingsViewModel()
    @StateObject private var logStore = DebugLogStore.shared

    var body: some View {
        NavigationStack {
            Form {
                UniFiSettingsSection(viewModel: viewModel)
                LLMSettingsSection(viewModel: viewModel)
                VoiceSettingsSection(viewModel: viewModel)
                Section("Appearance") {
                    Toggle("Dark Mode", isOn: $viewModel.darkModeEnabled)
                }
                Section("Diagnostics") {
                    NavigationLink("App Console Logs") {
                        DebugLogListView(logStore: logStore)
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

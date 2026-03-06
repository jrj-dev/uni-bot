import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = SettingsViewModel()

    var body: some View {
        NavigationStack {
            Form {
                UniFiSettingsSection(viewModel: viewModel)
                LLMSettingsSection(viewModel: viewModel)
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

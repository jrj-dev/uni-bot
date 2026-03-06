import SwiftUI

struct SetupView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    @StateObject private var viewModel = SettingsViewModel()
    @State private var currentStep = 0

    var body: some View {
        NavigationStack {
            VStack {
                TabView(selection: $currentStep) {
                    unifiStep.tag(0)
                    llmStep.tag(1)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .animation(.easeInOut, value: currentStep)
            }
            .navigationTitle("Setup")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var unifiStep: some View {
        Form {
            Section("UniFi Console") {
                TextField("Console URL (e.g. https://192.168.1.1)", text: $viewModel.consoleURL)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                SecureField("API Key", text: $viewModel.unifiAPIKey)

                TextField("Site ID", text: $viewModel.siteID)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                Toggle("Allow Self-Signed Certificates", isOn: $viewModel.allowSelfSignedCerts)

                ConnectionTestButton(viewModel: viewModel)
            }

            Section {
                Button("Next") {
                    currentStep = 1
                }
                .disabled(viewModel.consoleURL.isEmpty || viewModel.unifiAPIKey.isEmpty || viewModel.siteID.isEmpty)
            }
        }
    }

    private var llmStep: some View {
        Form {
            Section("AI Provider") {
                Picker("Provider", selection: $viewModel.selectedProvider) {
                    ForEach(LLMProvider.allCases) { provider in
                        Text(provider.rawValue).tag(provider)
                    }
                }

                switch viewModel.selectedProvider {
                case .claude:
                    SecureField("Claude API Key", text: $viewModel.claudeAPIKey)
                case .openai:
                    SecureField("OpenAI API Key", text: $viewModel.openaiAPIKey)
                }
            }

            Section {
                Button("Get Started") {
                    viewModel.save(to: appState)
                }
                .disabled(!viewModel.isValid)
            }

            Section {
                Button("Back") {
                    currentStep = 0
                }
            }
        }
    }
}

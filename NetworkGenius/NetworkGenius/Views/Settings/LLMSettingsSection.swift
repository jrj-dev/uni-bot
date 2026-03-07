import SwiftUI

struct LLMSettingsSection: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Section("AI Provider") {
            Picker("Provider", selection: $viewModel.selectedProvider) {
                ForEach(LLMProvider.allCases) { provider in
                    Text(provider.rawValue).tag(provider)
                }
            }

            switch viewModel.selectedProvider {
            case .claude:
                SecureField("Claude API Key", text: $viewModel.claudeAPIKey)
                    .textContentType(.password)
            case .openai:
                SecureField("OpenAI API Key", text: $viewModel.openaiAPIKey)
                    .textContentType(.password)
            }

            Toggle("Share Device Context With AI", isOn: $viewModel.shareDeviceContextWithLLM)
            Text("When enabled, the app sends masked device/network context with prompts to improve answers about this device.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Button {
                    Task { await viewModel.testSelectedLLMKey() }
                } label: {
                    HStack {
                        if viewModel.isTestingLLMKey {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text("Test API Key")
                    }
                }
                .disabled(!viewModel.hasSelectedLLMKey || viewModel.isTestingLLMKey)

                if let result = viewModel.llmKeyTestResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(result.hasPrefix("Connected") ? .green : .red)
                }
            }
        }
    }
}

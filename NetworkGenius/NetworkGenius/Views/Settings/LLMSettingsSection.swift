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
        }
    }
}

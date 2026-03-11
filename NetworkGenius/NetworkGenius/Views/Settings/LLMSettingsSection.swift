import SwiftUI

struct LLMSettingsSection: View {
    @ObservedObject var viewModel: SettingsViewModel
    let isAdvancedMode: Bool

    var body: some View {
        Section("AI Provider") {
            Picker("Provider", selection: $viewModel.selectedProvider) {
                ForEach(viewModel.availableProviders) { provider in
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
            case .lmStudio:
                TextField("LM Studio Base URL", text: $viewModel.lmStudioBaseURL)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("LM Studio Model ID", text: $viewModel.lmStudioModel)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Local Prompt Size")
                        Spacer()
                        Text("\(Int(viewModel.lmStudioMaxPromptChars)) chars")
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: $viewModel.lmStudioMaxPromptChars,
                        in: 1028...9026,
                        step: 1
                    )
                    Text("Limits LM Studio prompt history sent per request.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                SecureField("LM Studio API Key", text: $viewModel.lmStudioAPIKey)
                    .textContentType(.password)
                Text("LM Studio is treated as local-only and should be reachable on local Wi-Fi or VPN.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    Task { await viewModel.loadLMStudioModels() }
                } label: {
                    HStack {
                        if viewModel.isLoadingLMStudioModels {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text("Load Models")
                    }
                }
                .disabled(viewModel.isLoadingLMStudioModels || !viewModel.hasSelectedLLMKey || viewModel.lmStudioBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if !viewModel.lmStudioModels.isEmpty {
                    Picker("Loaded Models", selection: $viewModel.lmStudioModel) {
                        ForEach(viewModel.lmStudioModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                }

                if let result = viewModel.lmStudioModelListResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(result.hasPrefix("Loaded") ? .green : .red)
                }

                Button {
                    Task { await viewModel.testLMStudioChat() }
                } label: {
                    HStack {
                        if viewModel.isTestingLMStudioChat {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text("Test Local LLM")
                    }
                }
                .disabled(
                    viewModel.isTestingLMStudioChat
                        || !viewModel.hasSelectedLLMKey
                        || viewModel.lmStudioBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )

                if let result = viewModel.lmStudioChatTestResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(result.hasPrefix("Connected") ? .green : .red)
                }
            }

            if isAdvancedMode {
                Toggle("Share Device Context With AI", isOn: $viewModel.shareDeviceContextWithLLM)
                Text("When enabled, the app sends masked device/network context with prompts to improve answers about this device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Hide Reasoning Output", isOn: $viewModel.hideReasoningOutput)
                Text("For reasoning models, internal thinking is suppressed from chat and voice output.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
                .disabled(!viewModel.hasSelectedLLMConfig || viewModel.isTestingLLMKey)

                if let result = viewModel.llmKeyTestResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(result.hasPrefix("Connected") ? .green : .red)
                }
            }
        }
    }
}

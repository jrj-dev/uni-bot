import SwiftUI

struct VoiceSettingsSection: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Section("Voice") {
            Toggle("Voice Responses", isOn: $viewModel.voiceEnabled)

            if viewModel.voiceEnabled {
                Picker("Speech Engine", selection: $viewModel.ttsProvider) {
                    ForEach(SpeechService.TTSProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }

                switch viewModel.ttsProvider {
                case .local:
                    Picker("Voice", selection: $viewModel.selectedVoiceID) {
                        Text("System Default").tag("")
                        ForEach(SpeechService.availableVoices, id: \.id) { voice in
                            Text("\(voice.name) (\(voice.language))")
                                .tag(voice.id)
                        }
                    }
                case .openAINeural:
                    Picker("Neural Voice", selection: $viewModel.openAICloudVoice) {
                        ForEach(SpeechService.availableCloudVoices, id: \.self) { voice in
                            Text(voice.capitalized).tag(voice)
                        }
                    }
                }
            }
        }
    }
}

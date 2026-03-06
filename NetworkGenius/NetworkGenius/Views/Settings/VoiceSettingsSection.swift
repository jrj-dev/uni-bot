import SwiftUI

struct VoiceSettingsSection: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Section("Voice") {
            Toggle("Voice Responses", isOn: $viewModel.voiceEnabled)

            if viewModel.voiceEnabled {
                Picker("Voice", selection: $viewModel.selectedVoiceID) {
                    Text("System Default").tag("")
                    ForEach(SpeechService.availableVoices, id: \.id) { voice in
                        Text("\(voice.name) (\(voice.language))")
                            .tag(voice.id)
                    }
                }
            }
        }
    }
}

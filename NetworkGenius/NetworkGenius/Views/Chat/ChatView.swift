import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    @StateObject private var viewModel = ChatViewModel()
    @StateObject private var speechService = SpeechService()
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(viewModel.messages) { message in
                                MessageBubbleView(message: message)
                                    .id(message.id)
                            }
                            if viewModel.isLoading {
                                ToolCallIndicatorView(toolName: viewModel.currentToolName)
                                    .id("loading")
                            }
                        }
                        .padding()
                    }
                    .onChange(of: viewModel.messages.count) {
                        if let last = viewModel.messages.last {
                            withAnimation {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }

                ChatInputBar(isLoading: viewModel.isLoading, onSend: { text in
                    Task {
                        await viewModel.sendMessage(text)
                    }
                }, speechService: speechService)
            }
            .navigationTitle("Network Genius")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NetworkStatusBadge()
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    // Voice toggle
                    Button {
                        speechService.voiceEnabled.toggle()
                        if !speechService.voiceEnabled {
                            speechService.stopSpeaking()
                        }
                    } label: {
                        Image(systemName: speechService.voiceEnabled ? "speaker.wave.2.fill" : "speaker.slash")
                    }

                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gear")
                    }
                }
            }
            .sheet(isPresented: $showSettings, onDismiss: {
                speechService.voiceEnabled = UserDefaults.standard.bool(forKey: "voiceEnabled")
                speechService.selectedVoiceIdentifier = UserDefaults.standard.string(forKey: "selectedVoiceID") ?? ""
            }) {
                SettingsView()
            }
            .onAppear {
                viewModel.speechService = speechService
                viewModel.configure(appState: appState, networkMonitor: networkMonitor)
                Task {
                    await speechService.requestPermissions()
                    await networkMonitor.probeConsole(
                        baseURL: appState.consoleURL,
                        allowSelfSigned: appState.allowSelfSignedCerts
                    )
                }
            }
        }
    }
}

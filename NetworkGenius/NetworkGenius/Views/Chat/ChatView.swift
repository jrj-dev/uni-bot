import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    @StateObject private var viewModel = ChatViewModel()
    @StateObject private var speechService = SpeechService()
    @StateObject private var logStore = DebugLogStore.shared
    @State private var showSettings = false
    @State private var showLogs = false

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
                    .onChange(of: viewModel.isLoading) { _, isLoading in
                        guard isLoading else { return }
                        withAnimation {
                            proxy.scrollTo("loading", anchor: .bottom)
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
                    Button {
                        showLogs = true
                    } label: {
                        Image(systemName: "terminal")
                    }

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
            .sheet(isPresented: $showLogs) {
                DebugLogSheetView(logStore: logStore)
            }
            .onAppear {
                debugLog("Chat view appeared", category: "UI")
                viewModel.speechService = speechService
                viewModel.configure(appState: appState, networkMonitor: networkMonitor)
                Task {
                    await speechService.requestPermissions()
                    debugLog("Probing UniFi console reachability", category: "UI")
                    await networkMonitor.probeConsole(
                        baseURL: appState.consoleURL,
                        allowSelfSigned: appState.allowSelfSignedCerts
                    )
                    await viewModel.showValidatedIntroIfNeeded()
                }
            }
        }
    }
}

private struct DebugLogSheetView: View {
    @ObservedObject var logStore: DebugLogStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
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
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear") {
                        logStore.clear()
                    }
                    .disabled(logStore.entries.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}

import SwiftUI
import SwiftData

private enum ChatSheet: String, Identifiable {
    case settings
    case conversations

    var id: String { rawValue }
}

struct ChatView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = ChatViewModel()
    @StateObject private var speechService = SpeechService()
    @State private var activeSheet: ChatSheet?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(viewModel.messages) { message in
                                MessageBubbleView(
                                    message: message,
                                    canRetry: !viewModel.isLoading
                                ) {
                                    Task {
                                        await viewModel.retryMessage(message.id)
                                    }
                                }
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
                }, onOpenSettings: {
                    activeSheet = .settings
                }, speechService: speechService)
            }
            .navigationTitle("UniBot WiFi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task {
                            await viewModel.startNewChat()
                            await viewModel.showValidatedIntroIfNeeded()
                        }
                    } label: {
                        Label("New Chat", systemImage: "square.and.pencil")
                    }
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 2) {
                        Text("UniBot WiFi")
                            .font(.headline)
                        NetworkStatusBadge()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        activeSheet = .conversations
                    } label: {
                        Label("Chats", systemImage: "text.bubble")
                    }
                }
            }
            .sheet(item: $activeSheet, onDismiss: handleSheetDismiss) { sheet in
                switch sheet {
                case .settings:
                    SettingsView()
                case .conversations:
                    NavigationStack {
                        List(viewModel.conversationSummaries) { convo in
                            Button {
                                Task {
                                    await viewModel.loadConversation(id: convo.id)
                                    activeSheet = nil
                                }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(convo.title)
                                            .font(.body)
                                            .lineLimit(1)
                                        Text(convo.updatedAt, style: .relative)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if convo.id == viewModel.currentConversationID {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        .navigationTitle("Chats")
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") { activeSheet = nil }
                            }
                        }
                    }
                }
            }
            .onAppear {
                debugLog("Chat view appeared", category: "UI")
                activeSheet = nil
                DispatchQueue.main.async {
                    // Extra pass after view restoration/state replay.
                    activeSheet = nil
                }
                viewModel.speechService = speechService
                viewModel.configure(appState: appState, networkMonitor: networkMonitor, modelContext: modelContext)
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
            .task {
                while !Task.isCancelled {
                    await networkMonitor.probeConsole(
                        baseURL: appState.consoleURL,
                        allowSelfSigned: appState.allowSelfSignedCerts
                    )
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    activeSheet = nil
                    Task {
                        debugLog("App became active; re-probing console reachability", category: "UI")
                        await networkMonitor.probeConsole(
                            baseURL: appState.consoleURL,
                            allowSelfSigned: appState.allowSelfSignedCerts
                        )
                    }
                case .inactive, .background:
                    // Prevent sheet restoration from dropping users back into settings/chats.
                    activeSheet = nil
                @unknown default:
                    break
                }
            }
            .onChange(of: networkMonitor.isWiFiConnected) { _, _ in
                Task {
                    await networkMonitor.probeConsole(
                        baseURL: appState.consoleURL,
                        allowSelfSigned: appState.allowSelfSignedCerts
                    )
                }
            }
            .onChange(of: networkMonitor.isVPNConnected) { _, _ in
                Task {
                    await networkMonitor.probeConsole(
                        baseURL: appState.consoleURL,
                        allowSelfSigned: appState.allowSelfSignedCerts
                    )
                }
            }
        }
    }

    private func handleSheetDismiss() {
        speechService.voiceEnabled = UserDefaults.standard.bool(forKey: "voiceEnabled")
        speechService.selectedVoiceIdentifier = UserDefaults.standard.string(forKey: "selectedVoiceID") ?? ""
        if let rawProvider = UserDefaults.standard.string(forKey: "ttsProvider"),
           let provider = SpeechService.TTSProvider(rawValue: rawProvider)
        {
            speechService.ttsProvider = provider
        } else {
            speechService.ttsProvider = .local
        }
        speechService.openAICloudVoice = UserDefaults.standard.string(forKey: "openAICloudVoice") ?? "alloy"
        viewModel.configure(appState: appState, networkMonitor: networkMonitor, modelContext: modelContext)
        Task {
            await networkMonitor.probeConsole(
                baseURL: appState.consoleURL,
                allowSelfSigned: appState.allowSelfSignedCerts
            )
        }
    }
}

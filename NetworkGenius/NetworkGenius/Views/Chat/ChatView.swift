import SwiftUI
import SwiftData

struct ChatView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = ChatViewModel()
    @StateObject private var speechService = SpeechService()
    @State private var showSettings = false
    @State private var showConversationList = false

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
                    showSettings = true
                }, speechService: speechService)
            }
            .navigationTitle("NetworkGenius")
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
                        Text("NetworkGenius UniFi WiFi")
                            .font(.headline)
                        NetworkStatusBadge()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showConversationList = true
                    } label: {
                        Label("Chats", systemImage: "text.bubble")
                    }
                }
            }
            .sheet(isPresented: $showSettings, onDismiss: {
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
                // Rebuild clients/tool executor with latest Settings values (Loki URL, console URL, model config, etc).
                viewModel.configure(appState: appState, networkMonitor: networkMonitor, modelContext: modelContext)
                Task {
                    await networkMonitor.probeConsole(
                        baseURL: appState.consoleURL,
                        allowSelfSigned: appState.allowSelfSignedCerts
                    )
                }
            }) {
                SettingsView()
            }
            .onAppear {
                debugLog("Chat view appeared", category: "UI")
                showSettings = false
                showConversationList = false
                DispatchQueue.main.async {
                    // Extra pass after view restoration/state replay.
                    showSettings = false
                    showConversationList = false
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
                    showSettings = false
                    showConversationList = false
                    Task {
                        debugLog("App became active; re-probing console reachability", category: "UI")
                        await networkMonitor.probeConsole(
                            baseURL: appState.consoleURL,
                            allowSelfSigned: appState.allowSelfSignedCerts
                        )
                    }
                case .inactive, .background:
                    // Prevent sheet restoration from dropping users back into settings/chats.
                    showSettings = false
                    showConversationList = false
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
            .sheet(isPresented: $showConversationList) {
                NavigationStack {
                    List(viewModel.conversationSummaries) { convo in
                        Button {
                            Task {
                                await viewModel.loadConversation(id: convo.id)
                                showConversationList = false
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
                            Button("Done") { showConversationList = false }
                        }
                    }
                }
            }
        }
    }
}

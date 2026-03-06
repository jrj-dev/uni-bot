import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    @StateObject private var viewModel = ChatViewModel()
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

                ChatInputBar(isLoading: viewModel.isLoading) { text in
                    Task {
                        await viewModel.sendMessage(text)
                    }
                }
            }
            .navigationTitle("Network Genius")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NetworkStatusBadge()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gear")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .onAppear {
                viewModel.configure(appState: appState, networkMonitor: networkMonitor)
                Task {
                    await networkMonitor.probeConsole(
                        baseURL: appState.consoleURL,
                        allowSelfSigned: appState.allowSelfSignedCerts
                    )
                }
            }
        }
    }
}

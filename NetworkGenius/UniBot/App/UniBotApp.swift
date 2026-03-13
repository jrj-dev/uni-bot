import SwiftUI
import SwiftData

@main
struct UniBotApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var networkMonitor = NetworkMonitor()

    var body: some Scene {
        WindowGroup {
            Group {
                if appState.isConfigured {
                    ChatView()
                        .environmentObject(appState)
                        .environmentObject(networkMonitor)
                } else {
                    SetupView()
                        .environmentObject(appState)
                        .environmentObject(networkMonitor)
                }
            }
            .preferredColorScheme(appState.darkModeEnabled ? .dark : nil)
        }
        .modelContainer(for: [ConversationThread.self, PersistedChatMessage.self])
    }
}

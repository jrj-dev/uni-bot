import SwiftUI

@main
struct NetworkGeniusApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var networkMonitor = NetworkMonitor()

    var body: some Scene {
        WindowGroup {
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
    }
}

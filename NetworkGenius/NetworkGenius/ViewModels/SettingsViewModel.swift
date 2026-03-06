import Foundation
import SwiftUI

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var consoleURL: String = ""
    @Published var siteID: String = ""
    @Published var unifiAPIKey: String = ""
    @Published var claudeAPIKey: String = ""
    @Published var openaiAPIKey: String = ""
    @Published var allowSelfSignedCerts: Bool = true
    @Published var selectedProvider: LLMProvider = .claude

    @Published var voiceEnabled: Bool = false
    @Published var selectedVoiceID: String = ""

    @Published var connectionTestResult: String?
    @Published var isTesting = false

    func load(from appState: AppState) {
        consoleURL = appState.consoleURL
        siteID = appState.siteID
        allowSelfSignedCerts = appState.allowSelfSignedCerts
        selectedProvider = appState.llmProvider
        unifiAPIKey = KeychainHelper.loadString(key: .unifiAPIKey) ?? ""
        claudeAPIKey = KeychainHelper.loadString(key: .claudeAPIKey) ?? ""
        openaiAPIKey = KeychainHelper.loadString(key: .openaiAPIKey) ?? ""
        voiceEnabled = UserDefaults.standard.bool(forKey: "voiceEnabled")
        selectedVoiceID = UserDefaults.standard.string(forKey: "selectedVoiceID") ?? ""
    }

    func save(to appState: AppState) {
        appState.consoleURL = consoleURL.trimmingCharacters(in: .whitespacesAndNewlines)
        appState.siteID = siteID.trimmingCharacters(in: .whitespacesAndNewlines)
        appState.allowSelfSignedCerts = allowSelfSignedCerts
        appState.llmProvider = selectedProvider

        if !unifiAPIKey.isEmpty {
            KeychainHelper.save(key: .unifiAPIKey, string: unifiAPIKey)
        }
        if !claudeAPIKey.isEmpty {
            KeychainHelper.save(key: .claudeAPIKey, string: claudeAPIKey)
        }
        if !openaiAPIKey.isEmpty {
            KeychainHelper.save(key: .openaiAPIKey, string: openaiAPIKey)
        }

        UserDefaults.standard.set(voiceEnabled, forKey: "voiceEnabled")
        UserDefaults.standard.set(selectedVoiceID, forKey: "selectedVoiceID")
    }

    var isValid: Bool {
        !consoleURL.isEmpty && !siteID.isEmpty && !unifiAPIKey.isEmpty && hasSelectedLLMKey
    }

    var hasSelectedLLMKey: Bool {
        switch selectedProvider {
        case .claude: return !claudeAPIKey.isEmpty
        case .openai: return !openaiAPIKey.isEmpty
        }
    }

    func testConnection() async {
        isTesting = true
        connectionTestResult = nil
        defer { isTesting = false }

        let client = UniFiAPIClient(baseURL: consoleURL, allowSelfSigned: allowSelfSignedCerts)
        // Temporarily save the key so the client can use it
        let hadKey = KeychainHelper.exists(key: .unifiAPIKey)
        if !unifiAPIKey.isEmpty {
            KeychainHelper.save(key: .unifiAPIKey, string: unifiAPIKey)
        }

        do {
            let data = try await client.getJSON(path: "/proxy/network/integration/v1/sites")
            if let dict = data as? [String: Any], let items = dict["data"] as? [Any] {
                connectionTestResult = "Connected! Found \(items.count) site(s)."
            } else {
                connectionTestResult = "Connected but unexpected response format."
            }
        } catch {
            connectionTestResult = "Failed: \(error.localizedDescription)"
            if !hadKey {
                KeychainHelper.delete(key: .unifiAPIKey)
            }
        }
    }
}

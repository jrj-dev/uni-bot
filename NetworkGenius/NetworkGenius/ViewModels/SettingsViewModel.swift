import Foundation
import SwiftUI

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var consoleURL: String = ""
    @Published var siteID: String = ""
    @Published var unifiAPIKey: String = ""
    @Published var grafanaLokiURL: String = ""
    @Published var grafanaLokiAPIKey: String = ""
    @Published var claudeAPIKey: String = ""
    @Published var openaiAPIKey: String = ""
    @Published var allowSelfSignedCerts: Bool = true
    @Published var selectedProvider: LLMProvider = .claude
    @Published var shareDeviceContextWithLLM: Bool = false
    @Published var darkModeEnabled: Bool = true

    @Published var voiceEnabled: Bool = false
    @Published var selectedVoiceID: String = ""
    @Published var ttsProvider: SpeechService.TTSProvider = .local
    @Published var openAICloudVoice: String = "alloy"

    @Published var connectionTestResult: String?
    @Published var isTesting = false
    @Published var llmKeyTestResult: String?
    @Published var isTestingLLMKey = false

    func load(from appState: AppState) {
        consoleURL = appState.consoleURL
        grafanaLokiURL = appState.grafanaLokiURL
        siteID = appState.siteID
        allowSelfSignedCerts = appState.allowSelfSignedCerts
        selectedProvider = appState.llmProvider
        shareDeviceContextWithLLM = appState.shareDeviceContextWithLLM
        darkModeEnabled = appState.darkModeEnabled
        unifiAPIKey = KeychainHelper.loadString(key: .unifiAPIKey) ?? ""
        grafanaLokiAPIKey = KeychainHelper.loadString(key: .grafanaLokiAPIKey) ?? ""
        claudeAPIKey = KeychainHelper.loadString(key: .claudeAPIKey) ?? ""
        openaiAPIKey = KeychainHelper.loadString(key: .openaiAPIKey) ?? ""
        voiceEnabled = UserDefaults.standard.bool(forKey: "voiceEnabled")
        selectedVoiceID = UserDefaults.standard.string(forKey: "selectedVoiceID") ?? ""
        if let rawTTS = UserDefaults.standard.string(forKey: "ttsProvider"),
           let provider = SpeechService.TTSProvider(rawValue: rawTTS)
        {
            ttsProvider = provider
        } else {
            ttsProvider = .local
        }
        openAICloudVoice = UserDefaults.standard.string(forKey: "openAICloudVoice") ?? "alloy"
    }

    func save(to appState: AppState) {
        appState.consoleURL = UniFiAPIClient.normalizeBaseURL(consoleURL)
        appState.grafanaLokiURL = UniFiAPIClient.normalizeBaseURL(grafanaLokiURL)
        appState.siteID = siteID.trimmingCharacters(in: .whitespacesAndNewlines)
        appState.allowSelfSignedCerts = allowSelfSignedCerts
        appState.llmProvider = selectedProvider
        appState.shareDeviceContextWithLLM = shareDeviceContextWithLLM
        appState.darkModeEnabled = darkModeEnabled

        let normalizedUniFiKey = normalizedKey(unifiAPIKey)
        let normalizedGrafanaLokiKey = normalizedKey(grafanaLokiAPIKey)
        let normalizedClaudeKey = normalizedKey(claudeAPIKey)
        let normalizedOpenAIKey = normalizedKey(openaiAPIKey)

        if !normalizedUniFiKey.isEmpty {
            KeychainHelper.save(key: .unifiAPIKey, string: normalizedUniFiKey)
        }
        if !normalizedGrafanaLokiKey.isEmpty {
            KeychainHelper.save(key: .grafanaLokiAPIKey, string: normalizedGrafanaLokiKey)
        }
        if !normalizedClaudeKey.isEmpty {
            KeychainHelper.save(key: .claudeAPIKey, string: normalizedClaudeKey)
        }
        if !normalizedOpenAIKey.isEmpty {
            KeychainHelper.save(key: .openaiAPIKey, string: normalizedOpenAIKey)
        }

        UserDefaults.standard.set(voiceEnabled, forKey: "voiceEnabled")
        UserDefaults.standard.set(selectedVoiceID, forKey: "selectedVoiceID")
        UserDefaults.standard.set(ttsProvider.rawValue, forKey: "ttsProvider")
        UserDefaults.standard.set(openAICloudVoice, forKey: "openAICloudVoice")
    }

    var isValid: Bool {
        !UniFiAPIClient.normalizeBaseURL(consoleURL).isEmpty
            && !normalizedKey(unifiAPIKey).isEmpty
            && hasSelectedLLMKey
    }

    var hasSelectedLLMKey: Bool {
        switch selectedProvider {
        case .claude: return !normalizedKey(claudeAPIKey).isEmpty
        case .openai: return !normalizedKey(openaiAPIKey).isEmpty
        }
    }

    func testConnection() async {
        isTesting = true
        connectionTestResult = nil
        defer { isTesting = false }

        let normalizedConsoleURL = UniFiAPIClient.normalizeBaseURL(consoleURL)
        let client = UniFiAPIClient(baseURL: normalizedConsoleURL, allowSelfSigned: allowSelfSignedCerts)
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

    func testSelectedLLMKey() async {
        isTestingLLMKey = true
        llmKeyTestResult = nil
        defer { isTestingLLMKey = false }

        do {
            switch selectedProvider {
            case .claude:
                try await testClaudeKey()
                llmKeyTestResult = "Connected! Claude API key is valid."
            case .openai:
                try await testOpenAIKey()
                llmKeyTestResult = "Connected! OpenAI API key is valid."
            }
        } catch let error as LLMError {
            llmKeyTestResult = "Failed: \(error.localizedDescription)"
        } catch {
            llmKeyTestResult = "Failed: \(error.localizedDescription)"
        }
    }

    private func testOpenAIKey() async throws {
        let apiKey = normalizedKey(openaiAPIKey)
        guard !apiKey.isEmpty else {
            throw LLMError.missingAPIKey
        }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTP(response: response, data: data)
    }

    private func testClaudeKey() async throws {
        let apiKey = normalizedKey(claudeAPIKey)
        guard !apiKey.isEmpty else {
            throw LLMError.missingAPIKey
        }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models")!)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTP(response: response, data: data)
    }

    private func validateHTTP(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse("missing HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.httpError(http.statusCode, body)
        }
    }

    private func normalizedKey(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

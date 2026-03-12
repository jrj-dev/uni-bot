import Foundation
import SwiftUI
import Darwin
import CFNetwork

struct GuardrailClientOption: Identifiable, Hashable {
    let id: String
    let selector: String
    let title: String
    let subtitle: String
    var isActive: Bool

    var searchText: String {
        "\(title) \(subtitle) \(selector)".lowercased()
    }
}

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var consoleURL: String = ""
    @Published var siteID: String = ""
    @Published var unifiAPIKey: String = ""
    @Published var unifiSSHUsername: String = ""
    @Published var unifiSSHPrivateKey: String = ""
    @Published var unifiSSHPassword: String = ""
    @Published var grafanaLokiURL: String = ""
    @Published var grafanaLokiAPIKey: String = ""
    @Published var availableGuardrailClients: [GuardrailClientOption] = []
    @Published var guardrailClientSearchText: String = ""
    @Published var isLoadingGuardrailClients = false
    @Published var guardrailClientsLoadResult: String?
    @Published var availableLegacyGuardrailClients: [GuardrailClientOption] = []
    @Published var legacyGuardrailClientSearchText: String = ""
    @Published var isLoadingLegacyGuardrailClients = false
    @Published var legacyGuardrailClientsLoadResult: String?
    @Published var lmStudioBaseURL: String = ""
    @Published var lmStudioModel: String = ""
    @Published var lmStudioMaxPromptChars: Double = 4098
    @Published var lmStudioAPIKey: String = ""
    @Published var claudeAPIKey: String = ""
    @Published var openaiAPIKey: String = ""
    @Published var allowSelfSignedCerts: Bool = true
    @Published var selectedAssistantMode: AssistantMode = .basic
    @Published var selectedProvider: LLMProvider = .claude
    @Published var shareDeviceContextWithLLM: Bool = false
    @Published var hideReasoningOutput: Bool = true
    @Published var darkModeEnabled: Bool = true
    @Published var hapticFeedbackEnabled: Bool = true
    @Published var clientModificationApprovals: [ClientModificationApproval] = []
    @Published var isLoadingClientModificationApprovals = false
    @Published var clientModificationApprovalResult: String?

    @Published var voiceEnabled: Bool = false
    @Published var selectedVoiceID: String = ""
    @Published var ttsProvider: SpeechService.TTSProvider = .local
    @Published var openAICloudVoice: String = "alloy"

    @Published var connectionTestResult: String?
    @Published var isTesting = false
    @Published var lokiConnectionTestResult: String?
    @Published var isTestingLokiConnection = false
    @Published var llmKeyTestResult: String?
    @Published var isTestingLLMKey = false
    @Published var lmStudioModels: [String] = []
    @Published var isLoadingLMStudioModels = false
    @Published var lmStudioModelListResult: String?
    @Published var isTestingLMStudioChat = false
    @Published var lmStudioChatTestResult: String?
    private static let lmStudioLastKnownGoodModelKey = "lmStudioLastKnownGoodModel"
    private let lmStudioSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.connectionProxyDictionary = [:]
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    var isAdvancedMode: Bool {
        selectedAssistantMode == .advanced
    }

    var availableProviders: [LLMProvider] {
        isAdvancedMode ? LLMProvider.allCases : [.claude, .openai]
    }

    /// Loads persisted settings from AppState into the editable view-model fields.
    func load(from appState: AppState) {
        consoleURL = appState.consoleURL
        grafanaLokiURL = appState.grafanaLokiURL
        lmStudioBaseURL = appState.lmStudioBaseURL
        lmStudioModel = appState.lmStudioModel
        lmStudioMaxPromptChars = Double(appState.lmStudioMaxPromptChars)
        if normalizedKey(lmStudioModel).isEmpty,
           let lastGood = UserDefaults.standard.string(forKey: Self.lmStudioLastKnownGoodModelKey),
           !lastGood.isEmpty
        {
            lmStudioModel = lastGood
        }
        siteID = appState.siteID
        allowSelfSignedCerts = appState.allowSelfSignedCerts
        selectedAssistantMode = appState.assistantMode
        selectedProvider = appState.llmProvider
        shareDeviceContextWithLLM = appState.shareDeviceContextWithLLM
        hideReasoningOutput = appState.hideReasoningOutput
        darkModeEnabled = appState.darkModeEnabled
        hapticFeedbackEnabled = appState.hapticFeedbackEnabled
        clientModificationApprovals = appState.clientModificationApprovals
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        unifiAPIKey = KeychainHelper.loadString(key: .unifiAPIKey) ?? ""
        unifiSSHUsername = KeychainHelper.loadString(key: .unifiSSHUsername) ?? ""
        unifiSSHPrivateKey = KeychainHelper.loadString(key: .unifiSSHPrivateKey) ?? ""
        unifiSSHPassword = KeychainHelper.loadString(key: .unifiSSHPassword) ?? ""
        grafanaLokiAPIKey = KeychainHelper.loadString(key: .grafanaLokiAPIKey) ?? ""
        lmStudioAPIKey = KeychainHelper.loadString(key: .lmStudioAPIKey) ?? ""
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
        enforceSelectedProviderForCurrentMode()
    }

    /// Writes the current settings fields back into AppState and persisted storage.
    func save(to appState: AppState) {
        enforceSelectedProviderForCurrentMode()
        appState.consoleURL = UniFiAPIClient.normalizeBaseURL(consoleURL)
        appState.grafanaLokiURL = UniFiAPIClient.normalizeBaseURL(grafanaLokiURL)
        appState.appBlockAllowedClients = ""
        appState.appBlockAllowedClientNameMap = ""
        appState.lmStudioBaseURL = UniFiAPIClient.normalizeBaseURL(lmStudioBaseURL)
        appState.lmStudioModel = normalizedKey(lmStudioModel)
        appState.lmStudioMaxPromptChars = max(1028, min(Int(lmStudioMaxPromptChars.rounded()), 9026))
        appState.siteID = siteID.trimmingCharacters(in: .whitespacesAndNewlines)
        appState.allowSelfSignedCerts = allowSelfSignedCerts
        appState.assistantMode = selectedAssistantMode
        appState.llmProvider = selectedProvider
        appState.shareDeviceContextWithLLM = shareDeviceContextWithLLM
        appState.hideReasoningOutput = hideReasoningOutput
        appState.darkModeEnabled = darkModeEnabled
        appState.hapticFeedbackEnabled = hapticFeedbackEnabled
        appState.clientModificationApprovals = clientModificationApprovals

        let normalizedUniFiKey = normalizedKey(unifiAPIKey)
        let normalizedUniFiSSHUsername = normalizedKey(unifiSSHUsername)
        let normalizedUniFiSSHPrivateKey = unifiSSHPrivateKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedUniFiSSHPassword = normalizedKey(unifiSSHPassword)
        let normalizedGrafanaLokiKey = normalizedKey(grafanaLokiAPIKey)
        let normalizedLMStudioKey = normalizedKey(lmStudioAPIKey)
        let normalizedClaudeKey = normalizedKey(claudeAPIKey)
        let normalizedOpenAIKey = normalizedKey(openaiAPIKey)

        if !normalizedUniFiKey.isEmpty {
            KeychainHelper.save(key: .unifiAPIKey, string: normalizedUniFiKey)
        }
        if !normalizedUniFiSSHUsername.isEmpty {
            KeychainHelper.save(key: .unifiSSHUsername, string: normalizedUniFiSSHUsername)
        } else {
            KeychainHelper.delete(key: .unifiSSHUsername)
        }
        if !normalizedUniFiSSHPrivateKey.isEmpty {
            KeychainHelper.save(key: .unifiSSHPrivateKey, string: normalizedUniFiSSHPrivateKey)
        } else {
            KeychainHelper.delete(key: .unifiSSHPrivateKey)
        }
        if !normalizedUniFiSSHPassword.isEmpty {
            KeychainHelper.save(key: .unifiSSHPassword, string: normalizedUniFiSSHPassword)
        } else {
            KeychainHelper.delete(key: .unifiSSHPassword)
        }
        if !normalizedGrafanaLokiKey.isEmpty {
            KeychainHelper.save(key: .grafanaLokiAPIKey, string: normalizedGrafanaLokiKey)
        }
        if !normalizedLMStudioKey.isEmpty {
            KeychainHelper.save(key: .lmStudioAPIKey, string: normalizedLMStudioKey)
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
            && hasSelectedLLMConfig
    }

    func handleAssistantModeChange() {
        enforceSelectedProviderForCurrentMode()
        if !isAdvancedMode {
            shareDeviceContextWithLLM = false
        }
    }

    var hasSelectedLLMKey: Bool {
        switch selectedProvider {
        case .claude: return !normalizedKey(claudeAPIKey).isEmpty
        case .openai: return !normalizedKey(openaiAPIKey).isEmpty
        case .lmStudio: return !normalizedKey(lmStudioAPIKey).isEmpty
        }
    }

    var hasSelectedLLMConfig: Bool {
        switch selectedProvider {
        case .claude, .openai:
            return hasSelectedLLMKey
        case .lmStudio:
            return hasSelectedLLMKey
                && !UniFiAPIClient.normalizeBaseURL(lmStudioBaseURL).isEmpty
                && !normalizedKey(lmStudioModel).isEmpty
        }
    }

    func refreshClientModificationApprovals() async {
        isLoadingClientModificationApprovals = true
        clientModificationApprovalResult = nil
        defer { isLoadingClientModificationApprovals = false }

        let normalizedConsoleURL = UniFiAPIClient.normalizeBaseURL(consoleURL)
        guard !normalizedConsoleURL.isEmpty else {
            clientModificationApprovalResult = "Failed: Console URL is invalid."
            return
        }
        guard !normalizedKey(unifiAPIKey).isEmpty || KeychainHelper.exists(key: .unifiAPIKey) else {
            clientModificationApprovalResult = "Failed: UniFi API key is required."
            return
        }

        let hadKey = KeychainHelper.exists(key: .unifiAPIKey)
        if !normalizedKey(unifiAPIKey).isEmpty {
            KeychainHelper.save(key: .unifiAPIKey, string: normalizedKey(unifiAPIKey))
        }

        do {
            let client = UniFiAPIClient(baseURL: normalizedConsoleURL, allowSelfSigned: allowSelfSignedCerts)
            let options = try await fetchGuardrailClientOptions(client: client)
            availableGuardrailClients = options
            clientModificationApprovals = mergeGuardrailOptionsIntoApprovals(
                options,
                existing: clientModificationApprovals
            )
            clientModificationApprovalResult = clientModificationApprovals.isEmpty
                ? "Loaded 0 clients."
                : "Loaded \(clientModificationApprovals.count) clients (including inactive when available)."
        } catch {
            clientModificationApprovalResult = "Failed: \(error.localizedDescription)"
        }

        if !hadKey && normalizedKey(unifiAPIKey).isEmpty {
            KeychainHelper.delete(key: .unifiAPIKey)
        }
    }

    func removeClientModificationApproval(_ approval: ClientModificationApproval) {
        clientModificationApprovals.removeAll { $0.id == approval.id }
    }

    /// Adds a historical client into the main guardrail list without automatically approving writes.
    func addLegacyGuardrailClient(_ option: GuardrailClientOption) {
        let key = normalizedApprovalKey(from: option.selector)
        guard !key.isEmpty else { return }
        guard !clientModificationApprovals.contains(where: { $0.approvalKey == key }) else {
            legacyGuardrailClientsLoadResult = "\(option.title) is already in Client Guardrails."
            return
        }

        clientModificationApprovals.append(
            ClientModificationApproval(
                approvalKey: key,
                clientID: option.id,
                name: option.title,
                hostname: inferredHostname(from: option),
                mac: inferredMAC(from: option),
                ip: inferredIP(from: option),
                allowClientModifications: false,
                allowAppBlocks: false,
                isCurrentlyConnected: option.isActive
            )
        )
        clientModificationApprovals.sort { lhs, rhs in
            if lhs.allowClientModifications != rhs.allowClientModifications {
                return lhs.allowClientModifications && !rhs.allowClientModifications
            }
            if lhs.isCurrentlyConnected != rhs.isCurrentlyConnected {
                return lhs.isCurrentlyConnected && !rhs.isCurrentlyConnected
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
        availableLegacyGuardrailClients.removeAll { normalizedApprovalKey(from: $0.selector) == key }
        legacyGuardrailClientsLoadResult = "Added \(option.title) to Client Guardrails."
    }

    /// Tests the configured UniFi connection and updates the settings UI with the result.
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

    /// Tests the API key for the currently selected LLM provider.
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
            case .lmStudio:
                try await testLMStudioKey()
                llmKeyTestResult = "Connected! LM Studio API key is valid."
            }
        } catch let error as LLMError {
            llmKeyTestResult = "Failed: \(error.localizedDescription)"
        } catch {
            llmKeyTestResult = "Failed: \(friendlyLMStudioError(error))"
        }
    }

    /// Loads and resolves the client options shown in the guardrail settings UI.
    func loadGuardrailClients() async {
        isLoadingGuardrailClients = true
        guardrailClientsLoadResult = nil
        defer { isLoadingGuardrailClients = false }

        let normalizedConsoleURL = UniFiAPIClient.normalizeBaseURL(consoleURL)
        guard !normalizedConsoleURL.isEmpty else {
            guardrailClientsLoadResult = "Failed: Console URL is invalid."
            return
        }
        guard !normalizedKey(unifiAPIKey).isEmpty || KeychainHelper.exists(key: .unifiAPIKey) else {
            guardrailClientsLoadResult = "Failed: UniFi API key is required."
            return
        }

        let hadKey = KeychainHelper.exists(key: .unifiAPIKey)
        if !normalizedKey(unifiAPIKey).isEmpty {
            KeychainHelper.save(key: .unifiAPIKey, string: normalizedKey(unifiAPIKey))
        }

        do {
            let client = UniFiAPIClient(baseURL: normalizedConsoleURL, allowSelfSigned: allowSelfSignedCerts)
            availableGuardrailClients = try await fetchGuardrailClientOptions(client: client)
            let count = availableGuardrailClients.count
            guardrailClientsLoadResult = count == 0
                ? "Loaded 0 clients."
                : "Loaded \(count) clients (including inactive when available)."
        } catch {
            guardrailClientsLoadResult = "Failed: \(error.localizedDescription)"
        }

        if !hadKey && normalizedKey(unifiAPIKey).isEmpty {
            KeychainHelper.delete(key: .unifiAPIKey)
        }
    }

    /// Loads legacy client history entries that are not present in the main live guardrail source.
    func loadLegacyGuardrailClients() async {
        isLoadingLegacyGuardrailClients = true
        legacyGuardrailClientsLoadResult = nil
        defer { isLoadingLegacyGuardrailClients = false }

        let normalizedConsoleURL = UniFiAPIClient.normalizeBaseURL(consoleURL)
        guard !normalizedConsoleURL.isEmpty else {
            legacyGuardrailClientsLoadResult = "Failed: Console URL is invalid."
            return
        }
        guard !normalizedKey(unifiAPIKey).isEmpty || KeychainHelper.exists(key: .unifiAPIKey) else {
            legacyGuardrailClientsLoadResult = "Failed: UniFi API key is required."
            return
        }

        let hadKey = KeychainHelper.exists(key: .unifiAPIKey)
        if !normalizedKey(unifiAPIKey).isEmpty {
            KeychainHelper.save(key: .unifiAPIKey, string: normalizedKey(unifiAPIKey))
        }

        do {
            let client = UniFiAPIClient(baseURL: normalizedConsoleURL, allowSelfSigned: allowSelfSignedCerts)
            let currentOptions = try await fetchGuardrailClientOptions(client: client)
            let currentKeys = Set(currentOptions.map { normalizedApprovalKey(from: $0.selector) })
            let approvedKeys = Set(clientModificationApprovals.map(\.approvalKey))
            availableLegacyGuardrailClients = try await fetchLegacyGuardrailClientOptions(
                client: client,
                excludingApprovalKeys: currentKeys.union(approvedKeys)
            )
            let count = availableLegacyGuardrailClients.count
            legacyGuardrailClientsLoadResult = count == 0
                ? "Loaded 0 historical-only clients."
                : "Loaded \(count) historical-only clients from UniFi legacy history."
        } catch {
            legacyGuardrailClientsLoadResult = "Failed: \(error.localizedDescription)"
        }

        if !hadKey && normalizedKey(unifiAPIKey).isEmpty {
            KeychainHelper.delete(key: .unifiAPIKey)
        }
    }

    /// Tests the configured Grafana Loki connection and updates the settings UI.
    func testLokiConnection() async {
        isTestingLokiConnection = true
        lokiConnectionTestResult = nil
        defer { isTestingLokiConnection = false }

        let normalizedLokiURL = UniFiAPIClient.normalizeBaseURL(grafanaLokiURL)
        guard !normalizedLokiURL.isEmpty else {
            lokiConnectionTestResult = "Failed: Loki Base URL is invalid."
            debugLog("Loki test skipped: invalid Loki base URL", category: "Logs")
            return
        }
        guard let url = URL(string: "\(normalizedLokiURL)/loki/api/v1/labels") else {
            lokiConnectionTestResult = "Failed: Unable to build Loki labels URL."
            debugLog("Loki test failed: unable to build labels URL from base=\(normalizedLokiURL)", category: "Logs")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let token = normalizedKey(grafanaLokiAPIKey)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 20

        let session = URLSessionFactory.makeSession(allowSelfSigned: allowSelfSignedCerts)
        let startedAt = Date()
        debugLog(
            "Loki test started (url=\(url.absoluteString), auth=\(token.isEmpty ? "none" : "bearer"), allowSelfSigned=\(allowSelfSignedCerts))",
            category: "Logs"
        )
        do {
            let (data, response) = try await session.data(for: request)
            let elapsedMS = Int(Date().timeIntervalSince(startedAt) * 1000)
            if let http = response as? HTTPURLResponse {
                let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
                debugLog("Loki test HTTP \(http.statusCode) in \(elapsedMS)ms (contentType=\(contentType), bytes=\(data.count))", category: "Logs")
                if !(200..<300).contains(http.statusCode) {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    throw LLMError.httpError(http.statusCode, body)
                }
            } else {
                debugLog("Loki test received non-HTTP response in \(elapsedMS)ms", category: "Logs")
            }
            guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let labels = payload["data"] as? [String]
            else {
                let preview = String(data: data.prefix(300), encoding: .utf8)?
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? "<non-utf8 body>"
                debugLog("Loki test parse failed: payloadPreview=\(preview)", category: "Logs")
                throw LLMError.invalidResponse("Unexpected Loki labels response format.")
            }
            lokiConnectionTestResult = "Connected! Loki reachable in \(elapsedMS)ms (\(labels.count) labels)."
            debugLog("Loki test succeeded (labels=\(labels.count), elapsed=\(elapsedMS)ms)", category: "Logs")
        } catch let error as LLMError {
            lokiConnectionTestResult = "Failed: \(error.localizedDescription)"
            debugLog("Loki test failed: \(error.localizedDescription)", category: "Logs")
        } catch {
            lokiConnectionTestResult = "Failed: \(error.localizedDescription)"
            let nsError = error as NSError
            debugLog(
                "Loki test failed domain=\(nsError.domain) code=\(nsError.code) description=\(error.localizedDescription)",
                category: "Logs"
            )
        }
    }

    /// Fetches the LM Studio model list for the settings picker.
    func loadLMStudioModels() async {
        isLoadingLMStudioModels = true
        lmStudioModelListResult = nil
        defer { isLoadingLMStudioModels = false }

        do {
            let models = try await fetchLMStudioModels()
            lmStudioModels = models
            let selected = normalizedKey(lmStudioModel)
            if models.contains(selected), !selected.isEmpty {
                lmStudioModel = selected
            } else if let first = models.first {
                lmStudioModel = first
                UserDefaults.standard.set(first, forKey: Self.lmStudioLastKnownGoodModelKey)
            }
            lmStudioModelListResult = models.isEmpty
                ? "Connected, but no loaded models were returned."
                : "Loaded \(models.count) model(s)."
        } catch let error as LLMError {
            lmStudioModelListResult = "Failed: \(error.localizedDescription)"
        } catch {
            lmStudioModelListResult = "Failed: \(friendlyLMStudioError(error))"
        }
    }

    /// Runs a small chat request against LM Studio to validate end-to-end connectivity.
    func testLMStudioChat() async {
        isTestingLMStudioChat = true
        lmStudioChatTestResult = nil
        defer { isTestingLMStudioChat = false }

        do {
            let model = try await resolveLMStudioModelForChat()
            let apiKey = normalizedKey(lmStudioAPIKey)
            guard !apiKey.isEmpty else {
                throw LLMError.missingAPIKey
            }
            let url = try lmStudioURL(path: "/v1/chat/completions")
            let payload: [String: Any] = [
                "model": model,
                "messages": [
                    ["role": "user", "content": "reply with ok"],
                ],
            ]
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 25
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)

            debugLog("LM Studio chat test started (model=\(model), url=\(url.absoluteString))", category: "LLM")
            let startedAt = Date()
            let (data, response) = try await lmStudioSession.data(for: request)
            if let http = response as? HTTPURLResponse {
                let elapsedMS = Int(Date().timeIntervalSince(startedAt) * 1000)
                debugLog("LM Studio chat test HTTP \(http.statusCode) in \(elapsedMS)ms", category: "LLM")
            }
            try validateHTTP(response: response, data: data)

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let content = message["content"] as? String
            else {
                throw LLMError.invalidResponse("LM Studio chat test returned an unexpected response format.")
            }

            UserDefaults.standard.set(model, forKey: Self.lmStudioLastKnownGoodModelKey)
            lmStudioChatTestResult = "Connected! LM Studio responded: \(content.trimmingCharacters(in: .whitespacesAndNewlines))"
        } catch let error as LLMError {
            lmStudioChatTestResult = "Failed: \(error.localizedDescription)"
        } catch {
            lmStudioChatTestResult = "Failed: \(friendlyLMStudioError(error))"
        }
    }

    /// Runs a lightweight OpenAI request to validate the configured API key.
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

    /// Builds the display option used for a saved guardrail client selector.
    private static func guardrailOption(from row: [String: Any]) -> GuardrailClientOption? {
        let name = (
            (row["name"] as? String)
                ?? (row["displayName"] as? String)
                ?? (row["clientName"] as? String)
                ?? (row["user"] as? String)
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hostname = (
            (row["hostname"] as? String)
                ?? (row["hostName"] as? String)
                ?? (row["dhcpHostname"] as? String)
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let mac = ((row["mac"] as? String) ?? (row["macAddress"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let ip = ((row["ip"] as? String) ?? (row["ipAddress"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let id = ((row["id"] as? String) ?? UUID().uuidString)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let selector = !mac.isEmpty ? mac : (!hostname.isEmpty ? hostname : (!name.isEmpty ? name : id))
        let title = !name.isEmpty ? name : (!hostname.isEmpty ? hostname : selector)

        var detailParts: [String] = []
        if !ip.isEmpty { detailParts.append(ip) }
        if !mac.isEmpty { detailParts.append(mac) }
        if !hostname.isEmpty, hostname.caseInsensitiveCompare(title) != .orderedSame {
            detailParts.append(hostname)
        }
        if detailParts.isEmpty { detailParts.append(id) }

        let isActive = detectClientIsActive(row: row)

        return GuardrailClientOption(
            id: id,
            selector: selector,
            title: title,
            subtitle: detailParts.joined(separator: " • "),
            isActive: isActive
        )
    }

    /// Returns true when the client row appears to be currently active.
    private static func detectClientIsActive(row: [String: Any]) -> Bool {
        if let value = row["isOnline"] as? Bool { return value }
        if let value = row["online"] as? Bool { return value }
        if let value = row["is_connected"] as? Bool { return value }
        if let value = row["connected"] as? Bool { return value }

        let status = ((row["state"] as? String) ?? (row["status"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if !status.isEmpty {
            if status == "online" || status == "active" || status == "connected" || status == "up" {
                return true
            }
            if status == "offline" || status == "inactive" || status == "disconnected" || status == "down" {
                return false
            }
        }
        return false
    }

    /// Resolves the site path used when loading guardrail client choices.
    private func resolveSiteForGuardrailClientLoad(
        client: UniFiAPIClient,
        configuredSiteID: String
    ) async throws -> (id: String, reference: String) {
        let payload = try await client.getJSON(path: "/proxy/network/integration/v1/sites")
        guard let dict = payload as? [String: Any],
              let sites = dict["data"] as? [[String: Any]],
              !sites.isEmpty
        else {
            throw UniFiAPIError.siteResolutionFailed("unexpected /sites response format")
        }

        let trimmedConfigured = configuredSiteID.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedSite: [String: Any]
        if !trimmedConfigured.isEmpty,
           let matched = sites.first(where: {
               (($0["id"] as? String) == trimmedConfigured)
                   || (($0["internalReference"] as? String) == trimmedConfigured)
           })
        {
            selectedSite = matched
        } else if let defaultSite = sites.first(where: { ($0["internalReference"] as? String) == "default" }) {
            selectedSite = defaultSite
        } else {
            selectedSite = sites[0]
        }

        guard let id = selectedSite["id"] as? String, !id.isEmpty else {
            throw UniFiAPIError.siteResolutionFailed("selected site missing id")
        }
        let reference = (selectedSite["internalReference"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (id, (reference?.isEmpty == false) ? reference! : "default")
    }

    /// Fetches client rows from a UniFi endpoint used by guardrail settings.
    private func fetchGuardrailClientRows(path: String, client: UniFiAPIClient) async throws -> [[String: Any]] {
        if path.contains("/proxy/network/api/") {
            let payload = try await client.getJSON(path: path)
            return rowsFromAnyPayload(payload)
        }
        return try await client.getAllPages(path: path)
    }

    /// Resolves the widest client catalog available and normalizes it into guardrail options.
    private func fetchGuardrailClientOptions(client: UniFiAPIClient) async throws -> [GuardrailClientOption] {
        let configuredSiteID = siteID.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedSite = try await resolveSiteForGuardrailClientLoad(
            client: client,
            configuredSiteID: configuredSiteID
        )
        let siteIDPath = resolvedSite.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? resolvedSite.id
        let siteRefQuery = resolvedSite.reference.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? resolvedSite.reference
        let candidates: [String] = [
            "/proxy/network/integration/v1/sites/\(siteIDPath)/clients?includeInactive=true",
            "/proxy/network/integration/v1/sites/\(siteIDPath)/clients?includeOffline=true",
            "/proxy/network/integration/v1/clients?site_id=\(siteRefQuery)&includeInactive=true",
            "/proxy/network/integration/v1/clients?site_id=\(siteRefQuery)",
            "/proxy/network/integration/v1/sites/\(siteIDPath)/clients",
        ]

        var selectedRows: [[String: Any]] = []
        var selectedPath: String?
        for path in candidates {
            do {
                let rows = try await fetchGuardrailClientRows(path: path, client: client)
                debugLog("Guardrail clients candidate succeeded (path=\(path), rows=\(rows.count))", category: "Settings")
                if rows.count > selectedRows.count {
                    selectedRows = rows
                    selectedPath = path
                }
            } catch {
                debugLog("Guardrail clients candidate failed (path=\(path), error=\(error.localizedDescription))", category: "Settings")
            }
        }
        let rows = selectedRows
        if let selectedPath {
            debugLog("Guardrail clients selected endpoint: \(selectedPath) (rows=\(rows.count))", category: "Settings")
        }

        let activeRowsBySelector = await loadActiveClientRowsBySelector(
            client: client,
            siteIDPath: siteIDPath
        )
        let activeSelectors = Set(activeRowsBySelector.keys)

        var uniqueBySelector: [String: GuardrailClientOption] = [:]
        for row in rows {
            var sourceRow = row
            if let activeRow = Self.bestMatchingActiveRow(for: row, activeRowsBySelector: activeRowsBySelector) {
                sourceRow = Self.mergeClientRows(primary: activeRow, fallback: row)
            }
            guard let option = Self.guardrailOption(from: sourceRow) else { continue }
            var resolved = option
            if activeSelectors.contains(option.selector.lowercased()) {
                resolved.isActive = true
            }

            if let existingKey = Self.bestMatchingOptionKey(for: resolved, optionsBySelector: uniqueBySelector) {
                if let existing = uniqueBySelector[existingKey] {
                    uniqueBySelector.removeValue(forKey: existingKey)
                    uniqueBySelector[resolved.selector] = Self.mergeGuardrailOptions(primary: resolved, fallback: existing)
                }
            } else {
                uniqueBySelector[resolved.selector] = resolved
            }
        }

        return Array(uniqueBySelector.values).sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive {
                return lhs.isActive && !rhs.isActive
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    /// Loads legacy `alluser` clients, removes anything already visible in live guardrails, and deduplicates by stable approval key.
    private func fetchLegacyGuardrailClientOptions(
        client: UniFiAPIClient,
        excludingApprovalKeys: Set<String>
    ) async throws -> [GuardrailClientOption] {
        let configuredSiteID = siteID.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedSite = try await resolveSiteForGuardrailClientLoad(
            client: client,
            configuredSiteID: configuredSiteID
        )
        let siteRefQuery = resolvedSite.reference.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? resolvedSite.reference
        let path = "/proxy/network/api/s/\(siteRefQuery)/stat/alluser"
        let rows = try await fetchGuardrailClientRows(path: path, client: client)
        debugLog("Legacy guardrail clients loaded (path=\(path), rows=\(rows.count))", category: "Settings")

        var uniqueByKey: [String: GuardrailClientOption] = [:]
        for row in rows {
            guard Self.wasSeenWithinLastWeek(row) else { continue }
            guard let option = Self.guardrailOption(from: row) else { continue }
            let key = normalizedApprovalKey(from: option.selector)
            guard !key.isEmpty, !excludingApprovalKeys.contains(key) else { continue }
            if let existing = uniqueByKey[key] {
                uniqueByKey[key] = Self.mergeLegacyGuardrailOptions(primary: existing, fallback: option)
            } else {
                uniqueByKey[key] = option
            }
        }

        return uniqueByKey.values.sorted { lhs, rhs in
            lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    /// Returns true when a legacy `alluser` row was seen within the past seven days.
    private static func wasSeenWithinLastWeek(_ row: [String: Any]) -> Bool {
        let lastSeenCandidates: [Any?] = [
            row["last_seen"],
            row["lastSeen"],
            row["disconnect_timestamp"],
            row["disconnectTimestamp"]
        ]

        for value in lastSeenCandidates {
            if let timestamp = unixTimestamp(from: value) {
                return Date().timeIntervalSince1970 - timestamp <= 7 * 24 * 60 * 60
            }
        }
        return false
    }

    /// Normalizes UniFi timestamp fields into Unix seconds.
    private static func unixTimestamp(from value: Any?) -> TimeInterval? {
        switch value {
        case let seconds as TimeInterval:
            return seconds > 1_000_000_000_000 ? seconds / 1000 : seconds
        case let seconds as Double:
            return seconds > 1_000_000_000_000 ? seconds / 1000 : seconds
        case let seconds as Int:
            let interval = TimeInterval(seconds)
            return interval > 1_000_000_000_000 ? interval / 1000 : interval
        case let text as String:
            guard let parsed = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return nil
            }
            return parsed > 1_000_000_000_000 ? parsed / 1000 : parsed
        default:
            return nil
        }
    }

    /// Merges resolved client options into the persisted approval list without dropping offline entries.
    private func mergeGuardrailOptionsIntoApprovals(
        _ options: [GuardrailClientOption],
        existing: [ClientModificationApproval]
    ) -> [ClientModificationApproval] {
        let existingByKey = Dictionary(uniqueKeysWithValues: existing.map { ($0.approvalKey, $0) })
        var mergedByKey: [String: ClientModificationApproval] = [:]
        let activeKeys = Set(options.filter(\.isActive).map { normalizedApprovalKey(from: $0.selector) })

        for option in options {
            let key = normalizedApprovalKey(from: option.selector)
            guard !key.isEmpty else { continue }
            let previous = existingByKey[key]
            let detailParts = option.subtitle
                .split(separator: "•")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let inferredIP = detailParts.first(where: { $0.contains(".") })
            let inferredMAC = detailParts.first(where: { $0.contains(":") })
            let inferredHostname = detailParts.last(where: { !$0.contains(".") && !$0.contains(":") && $0.lowercased() != "offline" })

            mergedByKey[key] = ClientModificationApproval(
                approvalKey: key,
                clientID: previous?.clientID ?? option.id,
                name: option.title,
                hostname: previous?.hostname.isEmpty == false ? previous!.hostname : (inferredHostname ?? ""),
                mac: previous?.mac.isEmpty == false ? previous!.mac : (inferredMAC ?? (option.selector.contains(":") ? option.selector : "")),
                ip: previous?.ip.isEmpty == false ? previous!.ip : (inferredIP ?? ""),
                allowClientModifications: previous?.allowClientModifications ?? false,
                allowAppBlocks: previous?.allowClientModifications ?? false,
                isCurrentlyConnected: activeKeys.contains(key)
            )
        }

        return mergedByKey.values.sorted { lhs, rhs in
            if lhs.allowClientModifications != rhs.allowClientModifications {
                return lhs.allowClientModifications && !rhs.allowClientModifications
            }
            if lhs.isCurrentlyConnected != rhs.isCurrentlyConnected {
                return lhs.isCurrentlyConnected && !rhs.isCurrentlyConnected
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    /// Normalizes a selector into the approval key format used across persisted client guardrails.
    private func normalizedApprovalKey(from selector: String) -> String {
        selector.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Extracts the first IP-like detail from a guardrail option subtitle.
    private func inferredIP(from option: GuardrailClientOption) -> String {
        option.subtitle
            .split(separator: "•")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { $0.contains(".") }) ?? ""
    }

    /// Extracts the first MAC-like detail from a guardrail option subtitle or selector.
    private func inferredMAC(from option: GuardrailClientOption) -> String {
        if option.selector.contains(":") {
            return option.selector
        }
        return option.subtitle
            .split(separator: "•")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { $0.contains(":") }) ?? ""
    }

    /// Extracts the hostname-like detail from a guardrail option subtitle when present.
    private func inferredHostname(from option: GuardrailClientOption) -> String {
        option.subtitle
            .split(separator: "•")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: {
                !$0.contains(".") && !$0.contains(":") && $0.lowercased() != "offline" && $0.caseInsensitiveCompare(option.title) != .orderedSame
            }) ?? ""
    }

    /// Loads active client rows for the saved guardrail selectors.
    private func loadActiveClientRowsBySelector(
        client: UniFiAPIClient,
        siteIDPath: String
    ) async -> [String: [String: Any]]
    {
        let path = "/proxy/network/integration/v1/sites/\(siteIDPath)/clients"
        do {
            let rows = try await client.getAllPages(path: path)
            var bySelector: [String: [String: Any]] = [:]
            for row in rows {
                for token in Self.clientRowIdentityTokens(row) {
                    bySelector[token] = row
                }
            }
            debugLog(
                "Resolved active client selector set (rows=\(rows.count), identity_tokens=\(bySelector.count))",
                category: "Settings"
            )
            return bySelector
        } catch {
            debugLog("Failed loading active client selector set: \(error.localizedDescription)", category: "Settings")
            return [:]
        }
    }

    /// Extracts row dictionaries from either a raw array payload or a paginated UniFi response wrapper.
    private func rowsFromAnyPayload(_ payload: Any) -> [[String: Any]] {
        if let rows = payload as? [[String: Any]] {
            return rows
        }
        if let dict = payload as? [String: Any] {
            if let data = dict["data"] as? [[String: Any]] {
                return data
            }
            if let result = dict["result"] as? [[String: Any]] {
                return result
            }
        }
        return []
    }

    /// Builds the stable selector string stored for a guardrail client row.
    private static func selectorForClientRow(_ row: [String: Any]) -> String? {
        let name = (
            (row["name"] as? String)
                ?? (row["displayName"] as? String)
                ?? (row["clientName"] as? String)
                ?? (row["user"] as? String)
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hostname = (
            (row["hostname"] as? String)
                ?? (row["hostName"] as? String)
                ?? (row["dhcpHostname"] as? String)
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let mac = ((row["mac"] as? String) ?? (row["macAddress"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let id = ((row["id"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if !mac.isEmpty { return mac }
        if !hostname.isEmpty { return hostname }
        if !name.isEmpty { return name }
        if !id.isEmpty { return id }
        return nil
    }

    /// Returns normalized identity tokens used to match active and inactive rows for the same client.
    private static func clientRowIdentityTokens(_ row: [String: Any]) -> [String] {
        let name = (
            (row["name"] as? String)
                ?? (row["displayName"] as? String)
                ?? (row["clientName"] as? String)
                ?? (row["user"] as? String)
        )?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let hostname = (
            (row["hostname"] as? String)
                ?? (row["hostName"] as? String)
                ?? (row["dhcpHostname"] as? String)
        )?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let mac = ((row["mac"] as? String) ?? (row["macAddress"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return [mac, hostname, name].filter { !$0.isEmpty }
    }

    /// Finds the best active-row match for a potentially stale row using MAC first, then hostname/name.
    private static func bestMatchingActiveRow(
        for row: [String: Any],
        activeRowsBySelector: [String: [String: Any]]
    ) -> [String: Any]? {
        for token in clientRowIdentityTokens(row) {
            if let match = activeRowsBySelector[token] {
                return match
            }
        }
        return nil
    }

    /// Finds an existing option that represents the same client using MAC first, then hostname/name.
    private static func bestMatchingOptionKey(
        for option: GuardrailClientOption,
        optionsBySelector: [String: GuardrailClientOption]
    ) -> String? {
        let tokens = optionIdentityTokens(option)
        for (key, existing) in optionsBySelector {
            let existingTokens = optionIdentityTokens(existing)
            if !Set(tokens).isDisjoint(with: existingTokens) {
                return key
            }
        }
        return nil
    }

    /// Merges two guardrail options while preferring MAC-backed and active records.
    private static func mergeGuardrailOptions(
        primary: GuardrailClientOption,
        fallback: GuardrailClientOption
    ) -> GuardrailClientOption {
        let primaryHasMAC = primary.selector.contains(":") || primary.subtitle.contains(":")
        let fallbackHasMAC = fallback.selector.contains(":") || fallback.subtitle.contains(":")
        let chosen = (primaryHasMAC && !fallbackHasMAC) ? primary : fallback
        let secondary = (chosen.id == primary.id && chosen.selector == primary.selector) ? fallback : primary
        return GuardrailClientOption(
            id: chosen.id,
            selector: chosen.selector,
            title: chosen.title.isEmpty ? secondary.title : chosen.title,
            subtitle: chosen.subtitle.isEmpty ? secondary.subtitle : chosen.subtitle,
            isActive: primary.isActive || fallback.isActive
        )
    }

    /// Merges two legacy options for the same approval key while preferring the richer subtitle and human-friendly title.
    private static func mergeLegacyGuardrailOptions(
        primary: GuardrailClientOption,
        fallback: GuardrailClientOption
    ) -> GuardrailClientOption {
        let primaryLooksNamed = primary.title != primary.selector
        let fallbackLooksNamed = fallback.title != fallback.selector
        let chosen = (primaryLooksNamed && !fallbackLooksNamed) ? primary : fallback
        let secondary = (chosen.id == primary.id && chosen.selector == primary.selector) ? fallback : primary
        return GuardrailClientOption(
            id: chosen.id,
            selector: chosen.selector,
            title: chosen.title,
            subtitle: chosen.subtitle.count >= secondary.subtitle.count ? chosen.subtitle : secondary.subtitle,
            isActive: primary.isActive || fallback.isActive
        )
    }

    /// Returns the identity tokens used to collapse duplicate guardrail options.
    private static func optionIdentityTokens(_ option: GuardrailClientOption) -> [String] {
        let subtitleParts = option.subtitle
            .split(separator: "•")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let mac = subtitleParts.first(where: { $0.contains(":") }) ?? (option.selector.contains(":") ? option.selector.lowercased() : "")
        let hostname = subtitleParts.first(where: { !$0.contains(":") && !$0.contains(".") && $0 != "offline" }) ?? ""
        let title = option.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return [mac, hostname, title].filter { !$0.isEmpty }
    }

    /// Merges multiple client result sets into one deduplicated list.
    private static func mergeClientRows(primary: [String: Any], fallback: [String: Any]) -> [String: Any] {
        var merged = primary
        for (key, value) in fallback {
            if let current = merged[key] {
                if let text = current as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    continue
                }
            }
            merged[key] = value
        }
        return merged
    }

    /// Runs a lightweight Claude request to validate the configured API key.
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

    /// Runs a lightweight LM Studio request to validate the configured endpoint.
    private func testLMStudioKey() async throws {
        let apiKey = normalizedKey(lmStudioAPIKey)
        guard !apiKey.isEmpty else {
            throw LLMError.missingAPIKey
        }
        let url = try lmStudioURL(path: "/v1/models")

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20

        let startedAt = Date()
        debugLog("LM Studio models probe started (url=\(url.absoluteString))", category: "LLM")
        let (data, response) = try await lmStudioSession.data(for: request)
        if let http = response as? HTTPURLResponse {
            let elapsedMS = Int(Date().timeIntervalSince(startedAt) * 1000)
            debugLog("LM Studio models probe HTTP \(http.statusCode) in \(elapsedMS)ms", category: "LLM")
        }
        try validateHTTP(response: response, data: data)
    }

    /// Chooses a model ID for LM Studio chat tests.
    private func resolveLMStudioModelForChat() async throws -> String {
        let selected = normalizedKey(lmStudioModel)
        let models = try await fetchLMStudioModels()
        lmStudioModels = models
        if models.isEmpty {
            throw LLMError.invalidResponse("No LM Studio models are loaded.")
        }
        if !selected.isEmpty, models.contains(selected) {
            UserDefaults.standard.set(selected, forKey: Self.lmStudioLastKnownGoodModelKey)
            return selected
        }
        let fallback = models[0]
        lmStudioModel = fallback
        UserDefaults.standard.set(fallback, forKey: Self.lmStudioLastKnownGoodModelKey)
        debugLog("LM Studio model fallback selected for chat test: \(fallback)", category: "LLM")
        return fallback
    }

    /// Fetches the list of model IDs exposed by LM Studio.
    private func fetchLMStudioModels() async throws -> [String] {
        let apiKey = normalizedKey(lmStudioAPIKey)
        guard !apiKey.isEmpty else {
            throw LLMError.missingAPIKey
        }
        let url = try lmStudioURL(path: "/v1/models")

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20

        let startedAt = Date()
        debugLog("LM Studio model list request started (url=\(url.absoluteString))", category: "LLM")
        let (data, response) = try await lmStudioSession.data(for: request)
        if let http = response as? HTTPURLResponse {
            let elapsedMS = Int(Date().timeIntervalSince(startedAt) * 1000)
            debugLog(
                "LM Studio model list HTTP \(http.statusCode) in \(elapsedMS)ms (bytes=\(data.count))",
                category: "LLM"
            )
        }
        try validateHTTP(response: response, data: data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawModels = json["data"] as? [[String: Any]] else {
            throw LLMError.invalidResponse("LM Studio models response missing data array")
        }
        let ids = rawModels.compactMap { $0["id"] as? String }.sorted()
        return Array(Set(ids)).sorted()
    }

    /// Throws a user-facing error when an HTTP response is missing or unsuccessful.
    private func validateHTTP(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse("missing HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            let bodyPreview = String(body.prefix(300)).replacingOccurrences(of: "\n", with: " ")
            debugLog("LM Studio HTTP \(http.statusCode) bodyPreview=\(bodyPreview)", category: "LLM")
            if http.statusCode == 502 {
                throw LLMError.invalidResponse(
                    "LM Studio returned HTTP 502 (proxy/intermediary path). Use direct LAN URL/IP and disable iCloud Private Relay / Limit IP Address Tracking for this Wi-Fi."
                )
            }
            throw LLMError.httpError(http.statusCode, body)
        }
    }

    /// Builds a validated LM Studio endpoint URL for the requested path.
    private func lmStudioURL(path: String) throws -> URL {
        let normalizedBase = UniFiAPIClient.normalizeBaseURL(lmStudioBaseURL)
        guard var components = URLComponents(string: normalizedBase) else {
            throw LLMError.invalidResponse("LM Studio base URL is missing or invalid")
        }
        if let originalHost = components.host {
            if let resolvedIP = resolvedIPv4Address(for: originalHost), resolvedIP != originalHost {
                components.host = resolvedIP
                debugLog("LM Studio host resolved to IP \(resolvedIP) (from \(originalHost))", category: "LLM")
            } else if !looksLikeIPv4(originalHost) {
                debugLog("LM Studio hostname resolution failed for '\(originalHost)'", category: "LLM")
                throw LLMError.invalidResponse(
                    "LM Studio host '\(originalHost)' could not be resolved on this device. Use a direct LAN IP (e.g. http://192.168.x.x:1234)."
                )
            }
        }
        components.path = path
        guard let url = components.url else {
            throw LLMError.invalidResponse("LM Studio base URL is missing or invalid")
        }
        return url
    }

    /// Resolves a hostname to an IPv4 address when direct IP fallback is needed.
    private func resolvedIPv4Address(for host: String) -> String? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.split(separator: ".").count == 4,
           trimmed.allSatisfy({ $0.isNumber || $0 == "." }) {
            return trimmed
        }

        var hints = addrinfo(
            ai_flags: AI_DEFAULT,
            ai_family: AF_INET,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(trimmed, nil, &hints, &result)
        guard status == 0, let first = result else {
            return nil
        }
        defer { freeaddrinfo(result) }

        for pointer in sequence(first: first, next: { $0.pointee.ai_next }) {
            guard let sockaddr = pointer.pointee.ai_addr else { continue }
            guard sockaddr.pointee.sa_family == sa_family_t(AF_INET) else { continue }

            var address = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            let ipv4 = UnsafeRawPointer(sockaddr).assumingMemoryBound(to: sockaddr_in.self)
            var sinAddr = ipv4.pointee.sin_addr
            let converted = withUnsafePointer(to: &sinAddr) { ptr in
                inet_ntop(AF_INET, ptr, &address, socklen_t(INET_ADDRSTRLEN))
            }
            if converted != nil {
                return String(cString: address)
            }
        }
        return nil
    }

    /// Returns true when the host already looks like an IPv4 address.
    private func looksLikeIPv4(_ host: String) -> Bool {
        host.split(separator: ".").count == 4 && host.allSatisfy { $0.isNumber || $0 == "." }
    }

    private func enforceSelectedProviderForCurrentMode() {
        guard availableProviders.contains(selectedProvider) else {
            if let preferred = availableProviders.first(where: { $0 == .claude }) {
                selectedProvider = preferred
            } else if let fallback = availableProviders.first {
                selectedProvider = fallback
            }
            return
        }
    }

    private func decodeUniFiClients(from rows: [[String: Any]]) throws -> [UniFiClient] {
        let data = try JSONSerialization.data(withJSONObject: rows)
        return try JSONDecoder().decode([UniFiClient].self, from: data)
    }

    /// Normalizes an API key string by trimming surrounding whitespace.
    private func normalizedKey(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Converts LM Studio transport failures into clearer settings-screen error text.
    private func friendlyLMStudioError(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == URLError.timedOut.rawValue {
            return "LM Studio timed out. Confirm LM Studio is running, listening on 0.0.0.0:1234 (not localhost-only), and that your phone/simulator can reach this host on the same LAN/VPN."
        }
        return error.localizedDescription
    }
}

import Foundation
import SwiftUI
import Darwin
import CFNetwork

/// View-friendly representation of one UniFi client option, keeping stable identity
/// fields separate from the rendered subtitle so merge logic does not need to
/// reverse-engineer structured data from UI text.
struct GuardrailClientOption: Identifiable, Hashable {
    let id: String
    let selector: String
    let title: String
    let subtitle: String
    let hostname: String
    let mac: String
    let ip: String
    var isActive: Bool

    var approvalKey: String {
        selector.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var identityTokens: [String] {
        [
            mac.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
        ].filter { !$0.isEmpty }
    }

    var hasMAC: Bool {
        !mac.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var searchText: String {
        "\(title) \(subtitle) \(selector) \(hostname) \(mac) \(ip)".lowercased()
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
        clientModificationApprovals = sortClientModificationApprovals(appState.clientModificationApprovals)
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

        guard let client = prepareUniFiSettingsClient(errorSink: \.clientModificationApprovalResult) else {
            return
        }

        do {
            let options = try await withPreparedUniFiAPIKey {
                try await fetchGuardrailClientOptions(client: client)
            }
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
    }

    func removeClientModificationApproval(_ approval: ClientModificationApproval) {
        clientModificationApprovals.removeAll { $0.id == approval.id }
    }

    /// Adds a historical client into the main guardrail list without automatically approving writes.
    func addLegacyGuardrailClient(_ option: GuardrailClientOption) {
        let key = option.approvalKey
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
                hostname: option.hostname,
                mac: option.mac,
                ip: option.ip,
                allowClientModifications: false,
                allowAppBlocks: false,
                isCurrentlyConnected: option.isActive,
                isLegacyHistoryEntry: true
            )
        )
        sortClientModificationApprovals()
        availableLegacyGuardrailClients.removeAll { $0.approvalKey == key }
        legacyGuardrailClientsLoadResult = "Added \(option.title) to Client Guardrails."
    }

    /// Updates the write-approval flag and removes disabled legacy-only entries from the guardrail list.
    func setClientModificationApproval(_ isAllowed: Bool, for approvalID: String) {
        guard let index = clientModificationApprovals.firstIndex(where: { $0.id == approvalID }) else { return }
        clientModificationApprovals[index].allowClientModifications = isAllowed
        clientModificationApprovals[index].allowAppBlocks = isAllowed

        let approval = clientModificationApprovals[index]
        if !isAllowed && shouldReturnApprovalToLegacyHistory(approval) {
            restoreLegacyGuardrailOption(from: approval)
            clientModificationApprovals.remove(at: index)
            return
        }

        sortClientModificationApprovals()
    }

    /// Tests the configured UniFi connection and updates the settings UI with the result.
    func testConnection() async {
        isTesting = true
        connectionTestResult = nil
        defer { isTesting = false }

        guard let client = prepareUniFiSettingsClient(errorSink: \.connectionTestResult) else {
            return
        }

        do {
            let data = try await withPreparedUniFiAPIKey {
                try await client.getJSON(path: "/proxy/network/integration/v1/sites")
            }
            if let dict = data as? [String: Any], let items = dict["data"] as? [Any] {
                connectionTestResult = "Connected! Found \(items.count) site(s)."
            } else {
                connectionTestResult = "Connected but unexpected response format."
            }
        } catch {
            connectionTestResult = "Failed: \(error.localizedDescription)"
        }
    }

    /// Tests the API key for the currently selected LLM provider.
    func testSelectedLLMKey() async {
        isTestingLLMKey = true
        llmKeyTestResult = nil
        defer { isTestingLLMKey = false }

        do {
            try await validateSelectedLLMProviderKey()
            llmKeyTestResult = selectedProviderSuccessMessage(selectedProvider)
        } catch let error as LLMError {
            llmKeyTestResult = "Failed: \(error.localizedDescription)"
        } catch {
            llmKeyTestResult = "Failed: \(friendlyProviderError(error, provider: selectedProvider))"
        }
    }

    /// Loads and resolves the client options shown in the guardrail settings UI.
    func loadGuardrailClients() async {
        isLoadingGuardrailClients = true
        guardrailClientsLoadResult = nil
        defer { isLoadingGuardrailClients = false }

        guard let client = prepareUniFiSettingsClient(errorSink: \.guardrailClientsLoadResult) else {
            return
        }

        do {
            availableGuardrailClients = try await withPreparedUniFiAPIKey {
                try await fetchGuardrailClientOptions(client: client)
            }
            let count = availableGuardrailClients.count
            guardrailClientsLoadResult = count == 0
                ? "Loaded 0 clients."
                : "Loaded \(count) clients (including inactive when available)."
        } catch {
            guardrailClientsLoadResult = "Failed: \(error.localizedDescription)"
        }
    }

    /// Loads legacy client history entries that are not present in the main live guardrail source.
    func loadLegacyGuardrailClients() async {
        isLoadingLegacyGuardrailClients = true
        legacyGuardrailClientsLoadResult = nil
        defer { isLoadingLegacyGuardrailClients = false }

        guard let client = prepareUniFiSettingsClient(errorSink: \.legacyGuardrailClientsLoadResult) else {
            return
        }

        do {
            let currentOptions = try await withPreparedUniFiAPIKey {
                try await fetchGuardrailClientOptions(client: client)
            }
            let currentKeys = Set(currentOptions.map(\.approvalKey))
            let approvedKeys = Set(clientModificationApprovals.map(\.approvalKey))
            availableLegacyGuardrailClients = try await withPreparedUniFiAPIKey {
                try await fetchLegacyGuardrailClientOptions(
                    client: client,
                    excludingApprovalKeys: currentKeys.union(approvedKeys)
                )
            }
            let count = availableLegacyGuardrailClients.count
            legacyGuardrailClientsLoadResult = count == 0
                ? "Loaded 0 historical-only clients."
                : "Loaded \(count) historical-only clients from UniFi legacy history."
        } catch {
            legacyGuardrailClientsLoadResult = "Failed: \(error.localizedDescription)"
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
            applyLoadedLMStudioModels(models)
            lmStudioModelListResult = models.isEmpty
                ? "Connected, but no loaded models were returned."
                : "Loaded \(models.count) model(s)."
        } catch let error as LLMError {
            lmStudioModelListResult = "Failed: \(error.localizedDescription)"
        } catch {
            lmStudioModelListResult = "Failed: \(friendlyProviderError(error, provider: .lmStudio))"
        }
    }

    /// Runs a small chat request against LM Studio to validate end-to-end connectivity.
    func testLMStudioChat() async {
        isTestingLMStudioChat = true
        lmStudioChatTestResult = nil
        defer { isTestingLMStudioChat = false }

        do {
            let (model, content) = try await runLMStudioChatProbe()
            UserDefaults.standard.set(model, forKey: Self.lmStudioLastKnownGoodModelKey)
            lmStudioChatTestResult = "Connected! LM Studio responded: \(content.trimmingCharacters(in: .whitespacesAndNewlines))"
        } catch let error as LLMError {
            lmStudioChatTestResult = "Failed: \(error.localizedDescription)"
        } catch {
            lmStudioChatTestResult = "Failed: \(friendlyProviderError(error, provider: .lmStudio))"
        }
    }

    /// Runs a lightweight OpenAI request to validate the configured API key.
    private func testOpenAIKey() async throws {
        let apiKey = try requiredAPIKey(openaiAPIKey)
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        try await runHTTPValidationRequest(request)
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
            hostname: hostname,
            mac: mac,
            ip: ip,
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
        let candidatePaths = guardrailClientCandidatePaths(for: resolvedSite)
        let selection = await selectGuardrailClientRows(from: candidatePaths, client: client)
        let rows = selection.rows
        if let selectedPath = selection.path {
            debugLog("Guardrail clients selected endpoint: \(selectedPath) (rows=\(rows.count))", category: "Settings")
        } else {
            debugLog("Guardrail clients candidates returned no rows; falling back to active-only reconciliation", category: "Settings")
        }

        let activeRowsBySelector = await loadActiveClientRowsBySelector(
            client: client,
            siteIDPath: siteIDPath
        )
        return normalizeGuardrailClientOptions(rows, activeRowsBySelector: activeRowsBySelector)
    }

    /// Returns the ordered list of client endpoints to probe, preferring the widest
    /// inactive/offline-capable path available on the current controller version.
    private func guardrailClientCandidatePaths(for site: (id: String, reference: String)) -> [String] {
        let siteIDPath = site.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? site.id
        let siteRefQuery = site.reference.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? site.reference
        return [
            "/proxy/network/integration/v1/sites/\(siteIDPath)/clients?includeInactive=true",
            "/proxy/network/integration/v1/sites/\(siteIDPath)/clients?includeOffline=true",
            "/proxy/network/integration/v1/clients?site_id=\(siteRefQuery)&includeInactive=true",
            "/proxy/network/integration/v1/clients?site_id=\(siteRefQuery)",
            "/proxy/network/integration/v1/sites/\(siteIDPath)/clients",
        ]
    }

    /// Probes each candidate path and keeps the richest successful response so guardrail
    /// loading can tolerate controller-version differences without hard failing.
    private func selectGuardrailClientRows(
        from candidatePaths: [String],
        client: UniFiAPIClient
    ) async -> (path: String?, rows: [[String: Any]]) {
        var selectedRows: [[String: Any]] = []
        var selectedPath: String?

        for path in candidatePaths {
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

        return (selectedPath, selectedRows)
    }

    /// Reconciles inactive-capable rows with the active client feed so the final picker
    /// keeps the richest identity data while still marking currently connected devices.
    private func normalizeGuardrailClientOptions(
        _ rows: [[String: Any]],
        activeRowsBySelector: [String: [String: Any]]
    ) -> [GuardrailClientOption] {
        let activeSelectors = Set(activeRowsBySelector.keys)
        var uniqueBySelector: [String: GuardrailClientOption] = [:]

        for row in rows {
            let resolved = resolveGuardrailOption(from: row, activeRowsBySelector: activeRowsBySelector, activeSelectors: activeSelectors)
            guard let resolved else { continue }

            if let existingKey = Self.bestMatchingOptionKey(for: resolved, optionsBySelector: uniqueBySelector),
               let existing = uniqueBySelector[existingKey]
            {
                uniqueBySelector.removeValue(forKey: existingKey)
                uniqueBySelector[resolved.selector] = Self.mergeGuardrailOptions(primary: resolved, fallback: existing)
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

    /// Builds one normalized picker option from a raw client row, preferring the live
    /// active row when the wider inactive catalog points at the same client.
    private func resolveGuardrailOption(
        from row: [String: Any],
        activeRowsBySelector: [String: [String: Any]],
        activeSelectors: Set<String>
    ) -> GuardrailClientOption? {
        var sourceRow = row
        if let activeRow = Self.bestMatchingActiveRow(for: row, activeRowsBySelector: activeRowsBySelector) {
            sourceRow = Self.mergeClientRows(primary: activeRow, fallback: row)
        }
        guard var option = Self.guardrailOption(from: sourceRow) else {
            return nil
        }
        if activeSelectors.contains(option.selector.lowercased()) {
            option.isActive = true
        }
        return option
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

        let dedupedRows = Self.deduplicateLegacyRows(rows)
        var uniqueByKey: [String: GuardrailClientOption] = [:]
        for row in dedupedRows {
            guard Self.wasSeenWithinLastWeek(row) else { continue }
            guard let option = Self.guardrailOption(from: row) else { continue }
            let key = option.approvalKey
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

    /// Collapses duplicate legacy rows by MAC first so the picker keeps the newest and most descriptive record.
    private static func deduplicateLegacyRows(_ rows: [[String: Any]]) -> [[String: Any]] {
        var bestByMAC: [String: [String: Any]] = [:]
        var passthroughRows: [[String: Any]] = []

        for row in rows {
            let mac = normalizedMAC(from: row)
            guard !mac.isEmpty else {
                passthroughRows.append(row)
                continue
            }
            if let existing = bestByMAC[mac] {
                bestByMAC[mac] = preferredLegacyRow(primary: existing, fallback: row)
            } else {
                bestByMAC[mac] = row
            }
        }

        return Array(bestByMAC.values) + passthroughRows
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

    /// Returns the newest meaningful timestamp from a legacy row, preferring last-seen style fields.
    private static func legacyRowRecency(_ row: [String: Any]) -> TimeInterval {
        let lastSeenCandidates: [Any?] = [
            row["last_seen"],
            row["lastSeen"],
            row["disconnect_timestamp"],
            row["disconnectTimestamp"],
            row["first_seen"],
            row["firstSeen"]
        ]

        for value in lastSeenCandidates {
            if let timestamp = unixTimestamp(from: value) {
                return timestamp
            }
        }
        return 0
    }

    /// Chooses the stronger legacy row using recency first, then identity richness as a tiebreaker.
    private static func preferredLegacyRow(primary: [String: Any], fallback: [String: Any]) -> [String: Any] {
        let primaryRecency = legacyRowRecency(primary)
        let fallbackRecency = legacyRowRecency(fallback)
        if primaryRecency != fallbackRecency {
            return primaryRecency >= fallbackRecency ? primary : fallback
        }

        let primaryScore = legacyRowQualityScore(primary)
        let fallbackScore = legacyRowQualityScore(fallback)
        if primaryScore != fallbackScore {
            return primaryScore >= fallbackScore ? primary : fallback
        }
        return primary
    }

    /// Scores a legacy row by how useful it is as a human-readable guardrail entry.
    private static func legacyRowQualityScore(_ row: [String: Any]) -> Int {
        let name = normalizedClientName(from: row)
        let hostname = normalizedHostname(from: row)
        let mac = normalizedMAC(from: row)
        let ip = normalizedIPAddress(from: row)
        let noted = (row["noted"] as? Bool) == true

        var score = 0
        if !name.isEmpty { score += 4 }
        if !hostname.isEmpty { score += 3 }
        if !mac.isEmpty { score += 2 }
        if !ip.isEmpty { score += 1 }
        if noted { score += 2 }
        return score
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
        let activeKeys = Set(options.filter(\.isActive).map(\.approvalKey))

        for option in options {
            let key = option.approvalKey
            guard !key.isEmpty else { continue }
            mergedByKey[key] = mergedApproval(
                for: option,
                previous: existingByKey[key],
                activeKeys: activeKeys
            )
        }

        for previous in existing where mergedByKey[previous.approvalKey] == nil {
            guard let preserved = preservedLegacyApprovalIfNeeded(previous) else { continue }
            mergedByKey[previous.approvalKey] = preserved
        }

        return sortClientModificationApprovals(Array(mergedByKey.values))
    }

    /// Rebuilds one approval entry from the latest resolved option while preserving any
    /// previously granted permissions and richer stored identity fields.
    private func mergedApproval(
        for option: GuardrailClientOption,
        previous: ClientModificationApproval?,
        activeKeys: Set<String>
    ) -> ClientModificationApproval {
        let key = option.approvalKey
        return ClientModificationApproval(
            approvalKey: key,
            clientID: previous?.clientID ?? option.id,
            name: option.title,
            hostname: preferredApprovalField(previous?.hostname, fallback: option.hostname),
            mac: preferredApprovalField(previous?.mac, fallback: option.mac),
            ip: preferredApprovalField(previous?.ip, fallback: option.ip),
            allowClientModifications: previous?.allowClientModifications ?? false,
            allowAppBlocks: previous?.allowClientModifications ?? false,
            isCurrentlyConnected: activeKeys.contains(key),
            isLegacyHistoryEntry: false
        )
    }

    /// Keeps explicitly approved legacy-only entries in the stored set even when they no
    /// longer appear in the current live client catalog.
    private func preservedLegacyApprovalIfNeeded(
        _ approval: ClientModificationApproval
    ) -> ClientModificationApproval? {
        guard approval.isLegacyHistoryEntry, approval.allowClientModifications else {
            return nil
        }
        var preserved = approval
        preserved.isCurrentlyConnected = false
        return preserved
    }

    private func preferredApprovalField(_ current: String?, fallback: String) -> String {
        let cleanedCurrent = current?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cleanedCurrent.isEmpty ? fallback : cleanedCurrent
    }

    /// Returns approvals sorted so enabled and currently connected entries stay near the top.
    private func sortClientModificationApprovals(_ approvals: [ClientModificationApproval]) -> [ClientModificationApproval] {
        approvals.sorted { lhs, rhs in
            if lhs.allowClientModifications != rhs.allowClientModifications {
                return lhs.allowClientModifications && !rhs.allowClientModifications
            }
            if lhs.isCurrentlyConnected != rhs.isCurrentlyConnected {
                return lhs.isCurrentlyConnected && !rhs.isCurrentlyConnected
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    /// Reapplies the standard ordering to the current guardrail approval list.
    private func sortClientModificationApprovals() {
        clientModificationApprovals = sortClientModificationApprovals(clientModificationApprovals)
    }

    /// Re-adds a removed legacy-only approval back into the legacy picker so it can be reselected later.
    private func restoreLegacyGuardrailOption(from approval: ClientModificationApproval) {
        let selector = !approval.mac.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? approval.mac
            : approval.approvalKey
        let option = GuardrailClientOption(
            id: approval.clientID,
            selector: selector,
            title: approval.displayName,
            subtitle: approval.detailLine,
            hostname: approval.hostname,
            mac: approval.mac,
            ip: approval.ip,
            isActive: false
        )
        let key = option.approvalKey
        if let existingIndex = availableLegacyGuardrailClients.firstIndex(where: {
            $0.approvalKey == key
        }) {
            availableLegacyGuardrailClients[existingIndex] = Self.mergeLegacyGuardrailOptions(
                primary: availableLegacyGuardrailClients[existingIndex],
                fallback: option
            )
        } else {
            availableLegacyGuardrailClients.append(option)
        }
        availableLegacyGuardrailClients.sort {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    /// Returns true when disabling this approval should move it back into the legacy history picker.
    private func shouldReturnApprovalToLegacyHistory(_ approval: ClientModificationApproval) -> Bool {
        guard !approval.isCurrentlyConnected else { return false }
        if approval.isLegacyHistoryEntry { return true }
        let key = approval.approvalKey
        let liveKeys = Set(availableGuardrailClients.map(\.approvalKey))
        return !liveKeys.contains(key)
    }

    /// Validates the minimum UniFi settings needed for settings-driven client loads and
    /// builds the API client used by the guardrail pickers.
    private func prepareUniFiSettingsClient(
        errorSink: ReferenceWritableKeyPath<SettingsViewModel, String?>
    ) -> UniFiAPIClient? {
        let normalizedConsoleURL = UniFiAPIClient.normalizeBaseURL(consoleURL)
        guard !normalizedConsoleURL.isEmpty else {
            self[keyPath: errorSink] = "Failed: Console URL is invalid."
            return nil
        }
        guard !normalizedKey(unifiAPIKey).isEmpty || KeychainHelper.exists(key: .unifiAPIKey) else {
            self[keyPath: errorSink] = "Failed: UniFi API key is required."
            return nil
        }

        return UniFiAPIClient(baseURL: normalizedConsoleURL, allowSelfSigned: allowSelfSignedCerts)
    }

    /// Persists a newly typed UniFi API key long enough for async settings calls to use
    /// the normal API client path without duplicating keychain setup/cleanup logic.
    private func withPreparedUniFiAPIKey<T>(
        _ operation: () async throws -> T
    ) async throws -> T {
        let normalizedTypedKey = normalizedKey(unifiAPIKey)
        let hadStoredKey = KeychainHelper.exists(key: .unifiAPIKey)
        if !normalizedTypedKey.isEmpty {
            KeychainHelper.save(key: .unifiAPIKey, string: normalizedTypedKey)
        }
        defer {
            if !hadStoredKey && normalizedTypedKey.isEmpty {
                KeychainHelper.delete(key: .unifiAPIKey)
            }
        }
        return try await operation()
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
        let tokens = option.identityTokens
        for (key, existing) in optionsBySelector {
            let existingTokens = existing.identityTokens
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
        let primaryHasMAC = primary.hasMAC
        let fallbackHasMAC = fallback.hasMAC
        let chosen = (primaryHasMAC && !fallbackHasMAC) ? primary : fallback
        let secondary = (chosen.id == primary.id && chosen.selector == primary.selector) ? fallback : primary
        return GuardrailClientOption(
            id: chosen.id,
            selector: chosen.selector,
            title: chosen.title.isEmpty ? secondary.title : chosen.title,
            subtitle: chosen.subtitle.isEmpty ? secondary.subtitle : chosen.subtitle,
            hostname: chosen.hostname.isEmpty ? secondary.hostname : chosen.hostname,
            mac: chosen.mac.isEmpty ? secondary.mac : chosen.mac,
            ip: chosen.ip.isEmpty ? secondary.ip : chosen.ip,
            isActive: primary.isActive || fallback.isActive
        )
    }

    /// Merges two legacy options for the same approval key while preferring the richer subtitle and human-friendly title.
    private static func mergeLegacyGuardrailOptions(
        primary: GuardrailClientOption,
        fallback: GuardrailClientOption
    ) -> GuardrailClientOption {
        let primaryScore = legacyOptionQualityScore(primary)
        let fallbackScore = legacyOptionQualityScore(fallback)
        let chosen = primaryScore >= fallbackScore ? primary : fallback
        let secondary = (chosen.id == primary.id && chosen.selector == primary.selector) ? fallback : primary
        return GuardrailClientOption(
            id: chosen.id,
            selector: chosen.selector,
            title: chosen.title,
            subtitle: chosen.subtitle.count >= secondary.subtitle.count ? chosen.subtitle : secondary.subtitle,
            hostname: chosen.hostname.isEmpty ? secondary.hostname : chosen.hostname,
            mac: chosen.mac.isEmpty ? secondary.mac : chosen.mac,
            ip: chosen.ip.isEmpty ? secondary.ip : chosen.ip,
            isActive: primary.isActive || fallback.isActive
        )
    }

    /// Scores a legacy option by whether it carries a descriptive title and detailed subtitle.
    private static func legacyOptionQualityScore(_ option: GuardrailClientOption) -> Int {
        var score = 0
        if option.title.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(option.selector) != .orderedSame {
            score += 4
        }
        if option.hasMAC { score += 2 }
        if !option.ip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { score += 1 }
        if !option.hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { score += 1 }
        score += min(option.subtitle.count / 12, 3)
        return score
    }

    /// Returns a normalized MAC string when present in a legacy row.
    private static func normalizedMAC(from row: [String: Any]) -> String {
        ((row["mac"] as? String) ?? (row["macAddress"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    /// Returns a normalized hostname string when present in a legacy row.
    private static func normalizedHostname(from row: [String: Any]) -> String {
        let raw = (
            (row["hostname"] as? String)
                ?? (row["hostName"] as? String)
                ?? (row["dhcpHostname"] as? String)
        ) ?? ""
        return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Returns a normalized client name string when present in a legacy row.
    private static func normalizedClientName(from row: [String: Any]) -> String {
        (
            (row["name"] as? String)
                ?? (row["displayName"] as? String)
                ?? (row["clientName"] as? String)
                ?? (row["user"] as? String)
                ?? ""
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    }

    /// Returns a normalized IPv4-like value when present in a legacy row.
    private static func normalizedIPAddress(from row: [String: Any]) -> String {
        (
            (row["ip"] as? String)
                ?? (row["ipAddress"] as? String)
                ?? (row["last_ip"] as? String)
                ?? (row["lastIp"] as? String)
                ?? ""
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
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
        let apiKey = try requiredAPIKey(claudeAPIKey)
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models")!)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 20
        try await runHTTPValidationRequest(request)
    }

    /// Runs a lightweight LM Studio request to validate the configured endpoint.
    private func testLMStudioKey() async throws {
        let request = try lmStudioRequest(path: "/v1/models")
        _ = try await runLMStudioRequest(request, logName: "models probe")
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
        let request = try lmStudioRequest(path: "/v1/models")
        let data = try await runLMStudioRequest(request, logName: "model list")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawModels = json["data"] as? [[String: Any]] else {
            throw LLMError.invalidResponse("LM Studio models response missing data array")
        }
        let ids = rawModels.compactMap { $0["id"] as? String }.sorted()
        return Array(Set(ids)).sorted()
    }

    /// Validates the currently selected provider and leaves result-string formatting to the caller.
    private func validateSelectedLLMProviderKey() async throws {
        switch selectedProvider {
        case .claude:
            try await testClaudeKey()
        case .openai:
            try await testOpenAIKey()
        case .lmStudio:
            try await testLMStudioKey()
        }
    }

    private func selectedProviderSuccessMessage(_ provider: LLMProvider) -> String {
        switch provider {
        case .claude:
            return "Connected! Claude API key is valid."
        case .openai:
            return "Connected! OpenAI API key is valid."
        case .lmStudio:
            return "Connected! LM Studio API key is valid."
        }
    }

    private func applyLoadedLMStudioModels(_ models: [String]) {
        lmStudioModels = models
        let selected = normalizedKey(lmStudioModel)
        if models.contains(selected), !selected.isEmpty {
            lmStudioModel = selected
        } else if let first = models.first {
            lmStudioModel = first
            UserDefaults.standard.set(first, forKey: Self.lmStudioLastKnownGoodModelKey)
        }
    }

    /// Runs a minimal chat completion against LM Studio and returns the chosen model plus response text.
    private func runLMStudioChatProbe() async throws -> (model: String, content: String) {
        let model = try await resolveLMStudioModelForChat()
        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "user", "content": "reply with ok"],
            ],
        ]
        var request = try lmStudioRequest(path: "/v1/chat/completions")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 25
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let data = try await runLMStudioRequest(request, logName: "chat test", extraLogContext: "model=\(model)")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            throw LLMError.invalidResponse("LM Studio chat test returned an unexpected response format.")
        }
        return (model, content)
    }

    private func requiredAPIKey(_ rawKey: String) throws -> String {
        let apiKey = normalizedKey(rawKey)
        guard !apiKey.isEmpty else {
            throw LLMError.missingAPIKey
        }
        return apiKey
    }

    private func runHTTPValidationRequest(
        _ request: URLRequest,
        session: URLSession = .shared
    ) async throws {
        let (data, response) = try await session.data(for: request)
        try validateHTTP(response: response, data: data)
    }

    /// Creates a standard authenticated LM Studio request against the configured base URL.
    private func lmStudioRequest(path: String) throws -> URLRequest {
        let apiKey = try requiredAPIKey(lmStudioAPIKey)
        let url = try lmStudioURL(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        return request
    }

    /// Executes an LM Studio request with consistent debug logging around start, latency,
    /// and HTTP validation so settings flows report transport issues the same way.
    private func runLMStudioRequest(
        _ request: URLRequest,
        logName: String,
        extraLogContext: String? = nil
    ) async throws -> Data {
        let contextSuffix = extraLogContext.map { ", \($0)" } ?? ""
        debugLog(
            "LM Studio \(logName) request started (url=\(request.url?.absoluteString ?? "<missing>")\(contextSuffix))",
            category: "LLM"
        )
        let startedAt = Date()
        let (data, response) = try await lmStudioSession.data(for: request)
        if let http = response as? HTTPURLResponse {
            let elapsedMS = Int(Date().timeIntervalSince(startedAt) * 1000)
            debugLog(
                "LM Studio \(logName) HTTP \(http.statusCode) in \(elapsedMS)ms (bytes=\(data.count))",
                category: "LLM"
            )
        }
        try validateHTTP(response: response, data: data)
        return data
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

    /// Applies provider-specific transport guidance where needed while leaving other
    /// providers on their standard localized error text.
    private func friendlyProviderError(_ error: Error, provider: LLMProvider) -> String {
        switch provider {
        case .lmStudio:
            return friendlyLMStudioError(error)
        case .claude, .openai:
            return error.localizedDescription
        }
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

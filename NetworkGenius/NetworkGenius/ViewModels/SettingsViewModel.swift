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
    @Published var appBlockAllowedClients: String = ""
    @Published var appBlockAllowedClientSelectors: [String] = []
    @Published var appBlockAllowedClientNameMap: [String: String] = [:]
    @Published var availableGuardrailClients: [GuardrailClientOption] = []
    @Published var guardrailClientSearchText: String = ""
    @Published var isLoadingGuardrailClients = false
    @Published var guardrailClientsLoadResult: String?
    @Published var lmStudioBaseURL: String = ""
    @Published var lmStudioModel: String = ""
    @Published var lmStudioMaxPromptChars: Double = 4098
    @Published var lmStudioAPIKey: String = ""
    @Published var claudeAPIKey: String = ""
    @Published var openaiAPIKey: String = ""
    @Published var allowSelfSignedCerts: Bool = true
    @Published var selectedProvider: LLMProvider = .claude
    @Published var shareDeviceContextWithLLM: Bool = false
    @Published var hideReasoningOutput: Bool = true
    @Published var darkModeEnabled: Bool = true

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

    /// Loads persisted settings from AppState into the editable view-model fields.
    func load(from appState: AppState) {
        consoleURL = appState.consoleURL
        grafanaLokiURL = appState.grafanaLokiURL
        appBlockAllowedClients = appState.appBlockAllowedClients
        appBlockAllowedClientSelectors = parseCSV(appState.appBlockAllowedClients)
        appBlockAllowedClientNameMap = parseNameMapJSON(appState.appBlockAllowedClientNameMap)
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
        selectedProvider = appState.llmProvider
        shareDeviceContextWithLLM = appState.shareDeviceContextWithLLM
        hideReasoningOutput = appState.hideReasoningOutput
        darkModeEnabled = appState.darkModeEnabled
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
    }

    /// Writes the current settings fields back into AppState and persisted storage.
    func save(to appState: AppState) {
        appState.consoleURL = UniFiAPIClient.normalizeBaseURL(consoleURL)
        appState.grafanaLokiURL = UniFiAPIClient.normalizeBaseURL(grafanaLokiURL)
        let selectors = appBlockAllowedClientSelectors.isEmpty
            ? parseCSV(appBlockAllowedClients)
            : appBlockAllowedClientSelectors
        appBlockAllowedClientSelectors = selectors
        appBlockAllowedClients = selectors.joined(separator: ", ")
        appState.appBlockAllowedClients = appBlockAllowedClients
        appState.appBlockAllowedClientNameMap = encodeNameMapJSON(appBlockAllowedClientNameMap)
        appState.lmStudioBaseURL = UniFiAPIClient.normalizeBaseURL(lmStudioBaseURL)
        appState.lmStudioModel = normalizedKey(lmStudioModel)
        appState.lmStudioMaxPromptChars = max(1028, min(Int(lmStudioMaxPromptChars.rounded()), 9026))
        appState.siteID = siteID.trimmingCharacters(in: .whitespacesAndNewlines)
        appState.allowSelfSignedCerts = allowSelfSignedCerts
        appState.llmProvider = selectedProvider
        appState.shareDeviceContextWithLLM = shareDeviceContextWithLLM
        appState.hideReasoningOutput = hideReasoningOutput
        appState.darkModeEnabled = darkModeEnabled

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
                "/proxy/network/api/s/\(siteRefQuery)/stat/alluser",
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
                if let selector = Self.selectorForClientRow(row),
                   let activeRow = activeRowsBySelector[selector.lowercased()]
                {
                    sourceRow = Self.mergeClientRows(primary: activeRow, fallback: row)
                }
                guard let option = Self.guardrailOption(from: sourceRow) else { continue }
                if uniqueBySelector[option.selector] == nil {
                    var resolved = option
                    if activeSelectors.contains(option.selector.lowercased()) {
                        resolved.isActive = true
                    }
                    appBlockAllowedClientNameMap[resolved.selector] = resolved.title
                    uniqueBySelector[option.selector] = resolved
                }
            }
            availableGuardrailClients = Array(uniqueBySelector.values)
                .sorted { lhs, rhs in
                    if lhs.isActive != rhs.isActive {
                        return lhs.isActive && !rhs.isActive
                    }
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
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

    /// Adds a resolved client option to the guardrail allowlist.
    func addGuardrailClient(_ option: GuardrailClientOption) {
        guard !appBlockAllowedClientSelectors.contains(option.selector) else { return }
        appBlockAllowedClientSelectors.append(option.selector)
        appBlockAllowedClientSelectors.sort()
        appBlockAllowedClients = appBlockAllowedClientSelectors.joined(separator: ", ")
        appBlockAllowedClientNameMap[option.selector] = option.title
    }

    /// Removes a client selector from the guardrail allowlist.
    func removeGuardrailClient(selector: String) {
        appBlockAllowedClientSelectors.removeAll { $0 == selector }
        appBlockAllowedClients = appBlockAllowedClientSelectors.joined(separator: ", ")
        appBlockAllowedClientNameMap.removeValue(forKey: selector)
    }

    /// Returns the cached display name for a saved guardrail client selector.
    func cachedGuardrailClientName(for selector: String) -> String? {
        appBlockAllowedClientNameMap[selector]
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

        let selector = !mac.isEmpty ? mac : (!ip.isEmpty ? ip : (!hostname.isEmpty ? hostname : id))
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

    /// Splits a comma-separated settings value into trimmed entries.
    private func parseCSV(_ csv: String) -> [String] {
        csv.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Parses the stored selector-to-name mapping JSON used by guardrail settings.
    private func parseNameMapJSON(_ raw: String) -> [String: String] {
        guard let data = raw.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }
        var map: [String: String] = [:]
        for (key, value) in payload {
            let cleanedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanedValue = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanedKey.isEmpty, !cleanedValue.isEmpty {
                map[cleanedKey] = cleanedValue
            }
        }
        return map
    }

    /// Encodes the selector-to-name mapping JSON used by guardrail settings.
    private func encodeNameMapJSON(_ map: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: map, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else {
            return ""
        }
        return string
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
                guard let selector = Self.selectorForClientRow(row)?.lowercased() else { continue }
                bySelector[selector] = row
            }
            debugLog("Resolved active client selector set (count=\(bySelector.count))", category: "Settings")
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
        let hostname = (
            (row["hostname"] as? String)
                ?? (row["hostName"] as? String)
                ?? (row["dhcpHostname"] as? String)
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let mac = ((row["mac"] as? String) ?? (row["macAddress"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let ip = ((row["ip"] as? String) ?? (row["ipAddress"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let id = ((row["id"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if !mac.isEmpty { return mac }
        if !ip.isEmpty { return ip }
        if !hostname.isEmpty { return hostname }
        if !id.isEmpty { return id }
        return nil
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

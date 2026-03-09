import Foundation
import SwiftUI
import Darwin
import CFNetwork

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

    func save(to appState: AppState) {
        appState.consoleURL = UniFiAPIClient.normalizeBaseURL(consoleURL)
        appState.grafanaLokiURL = UniFiAPIClient.normalizeBaseURL(grafanaLokiURL)
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

    func testLokiConnection() async {
        isTestingLokiConnection = true
        lokiConnectionTestResult = nil
        defer { isTestingLokiConnection = false }

        let normalizedLokiURL = UniFiAPIClient.normalizeBaseURL(grafanaLokiURL)
        guard !normalizedLokiURL.isEmpty else {
            lokiConnectionTestResult = "Failed: Loki Base URL is invalid."
            return
        }
        guard let url = URL(string: "\(normalizedLokiURL)/loki/api/v1/labels") else {
            lokiConnectionTestResult = "Failed: Unable to build Loki labels URL."
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
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                let body = String(data: data, encoding: .utf8) ?? ""
                throw LLMError.httpError(http.statusCode, body)
            }
            guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let labels = payload["data"] as? [String]
            else {
                throw LLMError.invalidResponse("Unexpected Loki labels response format.")
            }
            let elapsedMS = Int(Date().timeIntervalSince(startedAt) * 1000)
            lokiConnectionTestResult = "Connected! Loki reachable in \(elapsedMS)ms (\(labels.count) labels)."
        } catch let error as LLMError {
            lokiConnectionTestResult = "Failed: \(error.localizedDescription)"
        } catch {
            lokiConnectionTestResult = "Failed: \(error.localizedDescription)"
        }
    }

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

    private func looksLikeIPv4(_ host: String) -> Bool {
        host.split(separator: ".").count == 4 && host.allSatisfy { $0.isNumber || $0 == "." }
    }

    private func normalizedKey(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func friendlyLMStudioError(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == URLError.timedOut.rawValue {
            return "LM Studio timed out. Confirm LM Studio is running, listening on 0.0.0.0:1234 (not localhost-only), and that your phone/simulator can reach this host on the same LAN/VPN."
        }
        return error.localizedDescription
    }
}

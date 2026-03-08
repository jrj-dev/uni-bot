import Foundation
import SwiftUI
import UIKit
import SwiftData

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isLoading = false
    @Published var currentToolName: String?
    @Published var conversationSummaries: [ConversationSummary] = []
    @Published var currentConversationID: UUID?

    private var llmMessages: [LLMMessage] = []
    private let maxHistoryMessages = 20

    private var llmService: (any LLMService)?
    private var toolExecutor: ToolExecutor?
    private var networkMonitor: NetworkMonitor?
    private var appState: AppState?
    private var persistenceStore: ChatPersistenceStore?
    private var activeLLMProvider: LLMProvider?
    private var activeLMStudioBaseURL: String = ""
    private var activeLMStudioModel: String = ""
    private var activeLMStudioMaxPromptChars: Int = 4098
    var speechService: SpeechService?
    private var startupValidationAttempted = false

    private let baseSystemPrompt: String = {
        if let url = Bundle.main.url(forResource: "SystemPrompt", withExtension: "txt"),
           let text = try? String(contentsOf: url, encoding: .utf8)
        {
            return text
        }
        return """
        You are Network Genius, a helpful assistant for home network troubleshooting and management. \
        You have access to tools that query a local UniFi Network console. Use them to answer questions \
        about the user's network with real data. When tools are unavailable (off-network), provide \
        general networking advice based on your knowledge.
        """
    }()
    private let agentInstructions: String = {
        guard let url = Bundle.main.url(forResource: "AgentInstructions", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            return ""
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }()

    func configure(appState: AppState, networkMonitor: NetworkMonitor, modelContext: ModelContext) {
        self.appState = appState
        self.networkMonitor = networkMonitor
        debugLog("ChatViewModel configured (provider=\(appState.llmProvider.rawValue), onNetwork=\(networkMonitor.isOnNetwork))", category: "Chat")
        if persistenceStore == nil {
            persistenceStore = ChatPersistenceStore(context: modelContext)
            restoreMostRecentConversation()
        } else {
            refreshConversationSummaries()
        }

        let client = UniFiAPIClient(
            baseURL: UniFiAPIClient.normalizeBaseURL(appState.consoleURL),
            allowSelfSigned: appState.allowSelfSignedCerts
        )
        let configuredSiteID = appState.siteID.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryService = UniFiQueryService(
            client: client,
            siteID: configuredSiteID.isEmpty ? nil : configuredSiteID
        )
        let summaryService = UniFiSummaryService(queryService: queryService)
        self.toolExecutor = ToolExecutor(
            queryService: queryService,
            summaryService: summaryService,
            networkMonitor: networkMonitor,
            lokiBaseURL: appState.grafanaLokiURL
        )

        switch appState.llmProvider {
        case .claude:
            self.llmService = ClaudeLLMService()
        case .openai:
            self.llmService = OpenAILLMService()
        case .lmStudio:
            self.llmService = LMStudioLLMService(
                baseURL: appState.lmStudioBaseURL,
                model: appState.lmStudioModel,
                maxPromptChars: appState.lmStudioMaxPromptChars
            )
        }
        activeLLMProvider = appState.llmProvider
        activeLMStudioBaseURL = UniFiAPIClient.normalizeBaseURL(appState.lmStudioBaseURL)
        activeLMStudioModel = appState.lmStudioModel.trimmingCharacters(in: .whitespacesAndNewlines)
        activeLMStudioMaxPromptChars = appState.lmStudioMaxPromptChars
    }

    func startNewChat() async {
        guard let persistenceStore else { return }
        let thread = persistenceStore.createConversation()
        currentConversationID = thread.id
        messages = []
        llmMessages = []
        isLoading = false
        currentToolName = nil
        startupValidationAttempted = false
        refreshConversationSummaries()
    }

    func loadConversation(id: UUID) async {
        guard let persistenceStore else { return }
        guard let restored = persistenceStore.loadConversation(id: id) else { return }
        currentConversationID = restored.id
        messages = restored.messages
        llmMessages = normalizedLLMHistory(restored.llmMessages)
        startupValidationAttempted = !messages.isEmpty || !llmMessages.isEmpty
        isLoading = false
        currentToolName = nil
        refreshConversationSummaries()
    }

    func sendMessage(_ text: String, retryingMessageID: UUID? = nil) async {
        refreshLLMServiceIfNeeded()
        guard canUseSelectedLLMOnCurrentNetwork() else {
            let msg = "LM Studio is configured as a local provider and is only available on local Wi-Fi or VPN."
            debugLog("LM Studio request blocked: not on local Wi-Fi or VPN", category: "Chat")
            messages.append(ChatMessage(role: .assistant, content: msg))
            return
        }

        let userMessageID: UUID
        if let retryID = retryingMessageID, let index = messages.firstIndex(where: { $0.id == retryID && $0.role == .user }) {
            messages[index].sendFailed = false
            userMessageID = retryID
        } else {
            let userMessage = ChatMessage(role: .user, content: text)
            messages.append(userMessage)
            userMessageID = userMessage.id
        }
        let llmCountBeforeSend = llmMessages.count
        llmMessages.append(LLMMessage(role: .user, content: text))
        trimHistory()
        persistConversationState()
        debugLog("User message queued (\(text.count) chars)", category: "Chat")

        isLoading = true
        defer { isLoading = false; currentToolName = nil }

        guard let llmService else { return }
        let tools = toolsForCurrentState()
        let systemPrompt = buildSystemPrompt()

        do {
            debugLog("Sending initial LLM request", category: "Chat")
            var response = try await llmService.sendMessages(llmMessages, tools: tools, systemPrompt: systemPrompt)
            debugLog("Initial LLM response received (toolCalls=\(response.toolCalls.count))", category: "Chat")

            while !response.toolCalls.isEmpty {
                let assistantToolText = sanitizeAssistantText(response.text ?? "")
                let assistantMsg = LLMMessage(
                    role: .assistant,
                    content: assistantToolText,
                    toolCalls: response.toolCalls
                )
                llmMessages.append(assistantMsg)

                for toolCall in response.toolCalls {
                    currentToolName = toolCall.name
                    messages.append(ChatMessage(role: .toolCall, content: "Querying: \(toolCall.name)...", toolName: toolCall.name))
                    debugLog("Executing tool '\(toolCall.name)'", category: "Chat")

                    let result = await toolExecutor?.execute(toolCall: toolCall) ?? "Tool executor not configured"

                    llmMessages.append(LLMMessage(role: .tool, content: result, toolCallID: toolCall.id))
                }
                currentToolName = nil

                debugLog("Sending follow-up LLM request after tool results", category: "Chat")
                response = try await llmService.sendMessages(llmMessages, tools: tools, systemPrompt: systemPrompt)
                debugLog("Follow-up LLM response received (toolCalls=\(response.toolCalls.count))", category: "Chat")
            }

            let finalText = sanitizeAssistantText(response.text ?? "")
            messages.append(ChatMessage(role: .assistant, content: finalText))
            llmMessages.append(LLMMessage(role: .assistant, content: finalText))
            trimHistory()
            persistConversationState()
            speechService?.speak(finalText)
            debugLog("Assistant response delivered (\(finalText.count) chars)", category: "Chat")

        } catch {
            debugLog("Chat request failed: \(error.localizedDescription)", category: "Chat")
            llmMessages = Array(llmMessages.prefix(llmCountBeforeSend))
            markUserMessageFailed(userMessageID)
            messages.append(ChatMessage(role: .assistant, content: "Error: \(error.localizedDescription)"))
            persistConversationState()
        }
    }

    func retryMessage(_ messageID: UUID) async {
        guard let message = messages.first(where: { $0.id == messageID && $0.role == .user && $0.sendFailed }) else {
            return
        }
        await sendMessage(message.content, retryingMessageID: message.id)
    }

    func showValidatedIntroIfNeeded() async {
        guard !startupValidationAttempted else { return }
        startupValidationAttempted = true

        refreshLLMServiceIfNeeded()
        guard messages.isEmpty, llmMessages.isEmpty else { return }
        guard let llmService else { return }
        guard let appState, appState.hasLLMKey else {
            messages.append(ChatMessage(role: .assistant, content: "I’m not ready yet. Please add a valid AI provider API key in Settings."))
            persistConversationState()
            debugLog("Startup intro skipped: missing LLM key", category: "Chat")
            return
        }

        let systemPrompt = buildSystemPrompt()
        let probeMessage = LLMMessage(
            role: .user,
            content: "Connectivity check. Reply with 'ok'."
        )

        guard canUseSelectedLLMOnCurrentNetwork() else {
            let errorText = "LM Studio is configured as a local provider and is only available on local Wi-Fi or VPN."
            messages.append(ChatMessage(role: .assistant, content: errorText))
            persistConversationState()
            debugLog("Startup intro skipped: LM Studio not on local Wi-Fi or VPN", category: "Chat")
            return
        }

        do {
            _ = try await llmService.sendMessages([probeMessage], tools: [], systemPrompt: systemPrompt)
            let intro = "Hi, I’m NetworkGenius (UniFi WiFi Edition). I can help troubleshoot your UniFi network. What issue are you seeing?"
            messages.append(ChatMessage(role: .assistant, content: intro))
            llmMessages.append(LLMMessage(role: .assistant, content: intro))
            persistConversationState()
            debugLog("Startup LLM connectivity check succeeded; intro shown", category: "Chat")
        } catch {
            let errorText = "I can’t reach the selected AI provider right now. Check your API key, quota, and internet connection, then try again."
            messages.append(ChatMessage(role: .assistant, content: errorText))
            persistConversationState()
            debugLog("Startup LLM connectivity check failed: \(error.localizedDescription)", category: "Chat")
        }
    }

    private func toolsForCurrentState() -> [[String: Any]] {
        guard let networkMonitor, networkMonitor.isOnNetwork else {
            return []
        }
        guard let appState else { return [] }
        switch appState.llmProvider {
        case .claude: return ToolCatalog.claudeToolSchemas()
        case .openai, .lmStudio: return ToolCatalog.openAIToolSchemas()
        }
    }

    private func trimHistory() {
        if llmMessages.count > maxHistoryMessages {
            llmMessages = Array(llmMessages.suffix(maxHistoryMessages))
        }
        llmMessages = normalizedLLMHistory(llmMessages)
    }

    private func canUseSelectedLLMOnCurrentNetwork() -> Bool {
        guard let appState else { return true }
        guard appState.llmProvider == .lmStudio else { return true }
        guard let networkMonitor else { return false }
        return networkMonitor.isWiFiConnected || networkMonitor.isVPNConnected
    }

    private func buildSystemPrompt() -> String {
        let injectedPrefix: String
        if agentInstructions.isEmpty {
            debugLog("No AgentInstructions.txt found; context injection skipped", category: "Prompt")
            injectedPrefix = ""
        } else {
            debugLog("Injecting AgentInstructions.txt (\(agentInstructions.count) chars)", category: "Prompt")
            injectedPrefix = """
            Agent Instructions:
            \(agentInstructions)

            """
        }

        var systemPrompt = injectedPrefix + baseSystemPrompt
        if appState?.llmProvider == .lmStudio, appState?.hideReasoningOutput == true {
            systemPrompt += """

            When solving tasks, reason internally. Do not output internal reasoning, chain-of-thought, scratchpad, or <think> sections. Return only concise final answers and necessary tool results.
            """
        }
        guard appState?.shareDeviceContextWithLLM == true else {
            return systemPrompt
        }
        let context = DeviceContextProvider.snapshot(appState: appState, networkMonitor: networkMonitor)
        systemPrompt += context.promptBlock + "\nUse this context when answering questions about this device."
        return systemPrompt
    }

    private func sanitizeAssistantText(_ text: String) -> String {
        guard appState?.hideReasoningOutput == true else {
            return text
        }
        var cleaned = text
        let patterns: [String] = [
            #"<think\b[^>]*>[\s\S]*?</think>"#,
            #"<reasoning\b[^>]*>[\s\S]*?</reasoning>"#,
            #"<analysis\b[^>]*>[\s\S]*?</analysis>"#,
            #"<thought\b[^>]*>[\s\S]*?</thought>"#,
            #"```thinking[\s\S]*?```"#,
            #"```reasoning[\s\S]*?```"#,
            #"```analysis[\s\S]*?```"#,
            #"```thought[\s\S]*?```"#,
            #"(?is)(^|\n)#{1,6}\s*(reasoning|analysis|chain[- ]of[- ]thought|thought process|deliberation)\s*\n[\s\S]*?(?=\n#{1,6}\s|\z)"#,
            #"(?is)(^|\n)\*\*(reasoning|analysis|chain[- ]of[- ]thought|thought process|deliberation)\*\*\s*:?\n[\s\S]*?(?=\n\*\*|\n#{1,6}\s|\z)"#,
            #"(?im)^\s*(reasoning|analysis|chain[- ]of[- ]thought|thought process|deliberation)\s*:\s*.*$"#,
        ]
        for pattern in patterns {
            cleaned = cleaned.replacingRegex(pattern, with: "")
        }

        // If the model emits hidden reasoning followed by a "Final answer" section, keep only the final section.
        if let markerRange = cleaned.range(
            of: #"(?is)\b(final answer|final|answer)\s*:\s*"#,
            options: .regularExpression
        ) {
            let prefix = cleaned[..<markerRange.lowerBound]
            if prefix.range(of: #"\b(reasoning|analysis|think|thought|chain[- ]of[- ]thought)\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
                cleaned = String(cleaned[markerRange.upperBound...])
            }
        }

        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Done."
        }
        return cleaned
    }

    private func restoreMostRecentConversation() {
        guard let persistenceStore else { return }
        if let restored = persistenceStore.loadMostRecentConversation() {
            currentConversationID = restored.id
            messages = restored.messages
            llmMessages = normalizedLLMHistory(restored.llmMessages)
            startupValidationAttempted = !messages.isEmpty || !llmMessages.isEmpty
        } else {
            let thread = persistenceStore.createConversation()
            currentConversationID = thread.id
            startupValidationAttempted = false
        }
        refreshConversationSummaries()
    }

    private func refreshConversationSummaries() {
        guard let persistenceStore else { return }
        conversationSummaries = persistenceStore.listConversations().map {
            ConversationSummary(id: $0.id, title: $0.title, updatedAt: $0.updatedAt)
        }
    }

    private func persistConversationState() {
        guard let persistenceStore else { return }
        let thread: ConversationThread
        if let id = currentConversationID, let existing = persistenceStore.thread(id: id) {
            thread = existing
        } else {
            thread = persistenceStore.createConversation()
            currentConversationID = thread.id
        }
        persistenceStore.save(thread: thread, messages: messages, llmMessages: llmMessages)
        refreshConversationSummaries()
    }

    private func markUserMessageFailed(_ messageID: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == messageID && $0.role == .user }) else {
            return
        }
        messages[index].sendFailed = true
    }

    private func normalizedLLMHistory(_ input: [LLMMessage]) -> [LLMMessage] {
        var output: [LLMMessage] = []
        var pendingToolCallIDs: Set<String> = []

        for message in input {
            switch message.role {
            case .assistant:
                output.append(message)
                let toolCalls = message.toolCalls ?? []
                if toolCalls.isEmpty {
                    pendingToolCallIDs.removeAll()
                } else {
                    pendingToolCallIDs = Set(toolCalls.map(\.id))
                }
            case .tool:
                guard let id = message.toolCallID,
                      pendingToolCallIDs.contains(id)
                else {
                    continue
                }
                output.append(message)
                pendingToolCallIDs.remove(id)
            case .user:
                pendingToolCallIDs.removeAll()
                output.append(message)
            }
        }
        return output
    }

    private func refreshLLMServiceIfNeeded() {
        guard let appState else { return }
        let providerChanged = activeLLMProvider != appState.llmProvider
        let normalizedLMStudioBaseURL = UniFiAPIClient.normalizeBaseURL(appState.lmStudioBaseURL)
        let normalizedLMStudioModel = appState.lmStudioModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedLMStudioMaxPromptChars = appState.lmStudioMaxPromptChars
        let lmStudioConfigChanged = normalizedLMStudioBaseURL != activeLMStudioBaseURL
            || normalizedLMStudioModel != activeLMStudioModel
            || normalizedLMStudioMaxPromptChars != activeLMStudioMaxPromptChars

        guard providerChanged || (appState.llmProvider == .lmStudio && lmStudioConfigChanged) else {
            return
        }

        switch appState.llmProvider {
        case .claude:
            llmService = ClaudeLLMService()
        case .openai:
            llmService = OpenAILLMService()
        case .lmStudio:
            llmService = LMStudioLLMService(
                baseURL: appState.lmStudioBaseURL,
                model: appState.lmStudioModel,
                maxPromptChars: appState.lmStudioMaxPromptChars
            )
        }

        activeLLMProvider = appState.llmProvider
        activeLMStudioBaseURL = normalizedLMStudioBaseURL
        activeLMStudioModel = normalizedLMStudioModel
        activeLMStudioMaxPromptChars = normalizedLMStudioMaxPromptChars
        debugLog(
            "LLM configuration changed (provider=\(appState.llmProvider.rawValue)); rebuilt service. Next request will include current thread context (\(llmMessages.count) transcript messages).",
            category: "Chat"
        )
    }
}

struct ConversationSummary: Identifiable {
    let id: UUID
    let title: String
    let updatedAt: Date
}

private extension String {
    func replacingRegex(_ pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return self
        }
        let range = NSRange(startIndex..<endIndex, in: self)
        return regex.stringByReplacingMatches(in: self, options: [], range: range, withTemplate: template)
    }
}

@MainActor
private final class ChatPersistenceStore {
    private let context: ModelContext
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(context: ModelContext) {
        self.context = context
    }

    func listConversations() -> [ConversationThread] {
        let descriptor = FetchDescriptor<ConversationThread>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func loadMostRecentConversation() -> RestoredConversation? {
        guard let thread = listConversations().first else { return nil }
        return restoredConversation(from: thread)
    }

    func loadConversation(id: UUID) -> RestoredConversation? {
        guard let thread = thread(id: id) else { return nil }
        return restoredConversation(from: thread)
    }

    func thread(id: UUID) -> ConversationThread? {
        var descriptor = FetchDescriptor<ConversationThread>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    @discardableResult
    func createConversation() -> ConversationThread {
        let thread = ConversationThread()
        context.insert(thread)
        try? context.save()
        return thread
    }

    func save(thread: ConversationThread, messages: [ChatMessage], llmMessages: [LLMMessage]) {
        thread.updatedAt = Date()
        thread.title = title(from: messages)
        thread.llmTranscriptData = try? encoder.encode(llmMessages)

        for existing in thread.messages {
            context.delete(existing)
        }

        let persistentMessages = messages
            .filter { $0.role != .toolCall }
            .map { message in
                PersistedChatMessage(
                    id: message.id,
                    roleRaw: message.role.rawValue,
                    content: message.content,
                    timestamp: message.timestamp,
                    toolName: message.toolName,
                    toolCallID: message.toolCallID,
                    sendFailed: message.sendFailed,
                    thread: thread
                )
            }
        thread.messages = persistentMessages
        try? context.save()
    }

    private func restoredConversation(from thread: ConversationThread) -> RestoredConversation {
        let uiMessages = thread.messages
            .sorted(by: { $0.timestamp < $1.timestamp })
            .compactMap { stored -> ChatMessage? in
                guard let role = MessageRole(rawValue: stored.roleRaw) else { return nil }
                return ChatMessage(
                    id: stored.id,
                    role: role,
                    content: stored.content,
                    timestamp: stored.timestamp,
                    toolName: stored.toolName,
                    toolCallID: stored.toolCallID,
                    sendFailed: stored.sendFailed
                )
            }

        let storedLLMMessages: [LLMMessage]
        if let data = thread.llmTranscriptData,
           let decoded = try? decoder.decode([LLMMessage].self, from: data)
        {
            storedLLMMessages = decoded
        } else {
            storedLLMMessages = uiMessages.compactMap { message -> LLMMessage? in
                switch message.role {
                case .user:
                    return LLMMessage(role: .user, content: message.content)
                case .assistant:
                    return LLMMessage(role: .assistant, content: message.content)
                case .toolResult:
                    return LLMMessage(role: .tool, content: message.content, toolCallID: message.toolCallID)
                case .toolCall:
                    return nil
                }
            }
        }

        return RestoredConversation(
            id: thread.id,
            messages: uiMessages,
            llmMessages: storedLLMMessages
        )
    }

    private func title(from messages: [ChatMessage]) -> String {
        if let firstUser = messages.first(where: { $0.role == .user })?.content.trimmingCharacters(in: .whitespacesAndNewlines),
           !firstUser.isEmpty
        {
            return String(firstUser.prefix(48))
        }
        return "New Chat"
    }
}

private struct RestoredConversation {
    let id: UUID
    let messages: [ChatMessage]
    let llmMessages: [LLMMessage]
}

@MainActor
private struct DeviceContextProvider {
    struct Snapshot {
        let deviceName: String
        let deviceModel: String
        let systemVersion: String
        let hostName: String
        let localIPs: [String]
        let isWiFiConnected: Bool
        let isConsoleReachable: Bool
        let isOnNetwork: Bool
        let consoleHost: String
        let hasConfiguredSiteID: Bool

        var promptBlock: String {
            let ips = localIPs.isEmpty ? "unknown" : localIPs.joined(separator: ", ")
            return """

            Device Context:
            - device_name: \(deviceName)
            - host_name: \(hostName)
            - device_model: \(deviceModel)
            - os_version: iOS \(systemVersion)
            - local_ip_addresses: \(ips)
            - wifi_connected: \(isWiFiConnected)
            - console_reachable: \(isConsoleReachable)
            - on_local_network: \(isOnNetwork)
            - configured_console_host: \(consoleHost)
            - configured_site_id_present: \(hasConfiguredSiteID)
            """
        }
    }

    static func snapshot(
        appState: AppState?,
        networkMonitor: NetworkMonitor?
    ) -> Snapshot {
        let consoleURL = UniFiAPIClient.normalizeBaseURL(appState?.consoleURL ?? "")
        let siteID = (appState?.siteID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return Snapshot(
            deviceName: UIDevice.current.name,
            deviceModel: UIDevice.current.model,
            systemVersion: UIDevice.current.systemVersion,
            hostName: UIDevice.current.name,
            localIPs: localIPAddresses(),
            isWiFiConnected: networkMonitor?.isWiFiConnected ?? false,
            isConsoleReachable: networkMonitor?.isConsoleReachable ?? false,
            isOnNetwork: networkMonitor?.isOnNetwork ?? false,
            consoleHost: maskedConsoleHost(from: consoleURL),
            hasConfiguredSiteID: !siteID.isEmpty
        )
    }

    private static func localIPAddresses() -> [String] {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return addresses }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let flags = Int32(interface.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isRunning = (flags & IFF_RUNNING) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            guard isUp, isRunning, !isLoopback else { continue }
            guard let addr = interface.ifa_addr else { continue }

            let family = addr.pointee.sa_family
            guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { continue }

            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(addr.pointee.sa_len)
            let result = getnameinfo(
                addr,
                length,
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }

            let ip = String(cString: hostBuffer)
            let interfaceName = String(cString: interface.ifa_name)
            addresses.append("\(interfaceName)=\(maskedIP(ip))")
        }

        return Array(Set(addresses)).sorted()
    }

    private static func maskedConsoleHost(from baseURL: String) -> String {
        guard let host = URL(string: baseURL)?.host else { return "unknown" }
        return maskedIP(host)
    }

    private static func maskedIP(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "unknown" }

        let v4Parts = trimmed.split(separator: ".")
        if v4Parts.count == 4 {
            return "\(v4Parts[0]).\(v4Parts[1]).\(v4Parts[2]).x"
        }

        if trimmed.contains(":") {
            let v6Parts = trimmed.split(separator: ":")
            if v6Parts.count >= 2 {
                let prefix = v6Parts.prefix(2).joined(separator: ":")
                return "\(prefix):xxxx"
            }
            return "xxxx"
        }

        return "masked"
    }
}

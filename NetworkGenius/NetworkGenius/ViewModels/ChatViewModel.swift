import Foundation
import SwiftUI
import UIKit
import SwiftData

@MainActor
protocol HapticFeedbackPerforming {
    func prepareForResponseNotification()
    func notifyResponseReturned()
}

@MainActor
final class SystemHapticFeedbackPerformer: HapticFeedbackPerforming {
    private let generator = UINotificationFeedbackGenerator()

    func prepareForResponseNotification() {
        generator.prepare()
    }

    func notifyResponseReturned() {
        generator.notificationOccurred(.success)
    }
}

@MainActor
final class ChatViewModel: ObservableObject {
    private struct RuntimeConfiguration: Equatable {
        let provider: LLMProvider
        let assistantMode: AssistantMode
        let lmStudioBaseURL: String
        let lmStudioModel: String
        let lmStudioMaxPromptChars: Int
    }

    @Published var messages: [ChatMessage] = []
    @Published var isLoading = false
    @Published var currentToolName: String?
    @Published var conversationSummaries: [ConversationSummary] = []
    @Published var currentConversationID: UUID?

    private let maxToolResultCharacters = 8_000
    private var llmMessages: [LLMMessage] = []
    private let maxHistoryMessages = 20

    private var llmService: (any LLMService)?
    private var toolExecutor: ToolExecutor?
    private var networkMonitor: NetworkMonitor?
    private var appState: AppState?
    private var persistenceStore: ChatPersistenceStore?
    private var activeRuntimeConfiguration: RuntimeConfiguration?
    var hapticFeedback: HapticFeedbackPerforming = SystemHapticFeedbackPerformer()
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
        general networking advice based on your knowledge. \
        Prefer compact ranking and resolver tools over raw list tools whenever the user asks for \
        the top, bottom, most, least, slowest, fastest, weakest, busiest, or highest item. \
        For app-block status questions like which clients are blocked, prefer the compact \
        app-block summary tool instead of broad inventory or raw rule listings. \
        Only call broad list tools like list_clients or list_devices when a narrow ranking or \
        targeted lookup tool cannot answer the question.
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

    /// Injects shared app dependencies into the chat view model and restores persisted state.
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

        rebuildRuntimeServices(appState: appState, networkMonitor: networkMonitor)
    }

    /// Creates a new conversation thread and resets the current chat state.
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

    /// Loads a saved conversation into the current chat session.
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

    /// Appends a user message, runs the active LLM flow, and records the assistant response.
    func sendMessage(_ text: String, retryingMessageID: UUID? = nil) async {
        refreshLLMServiceIfNeeded()
        guard ensureSelectedLLMReachableForCurrentNetwork() else { return }

        let sendState = queueUserMessage(text, retryingMessageID: retryingMessageID)
        prepareForSendUI(messageLength: text.count)

        isLoading = true
        defer { isLoading = false; currentToolName = nil }

        guard let llmService else { return }
        let requestContext = makeRequestContext()

        do {
            let response = try await runConversationLoop(llmService: llmService, context: requestContext)
            deliverAssistantResponse(response)

        } catch {
            debugLog("Chat request failed: \(error.localizedDescription)", category: "Chat")
            llmMessages = Array(llmMessages.prefix(sendState.llmCountBeforeSend))
            markUserMessageFailed(sendState.userMessageID)
            messages.append(ChatMessage(role: .assistant, content: userFacingChatErrorMessage(for: error)))
            persistConversationState()
        }
    }

    /// Replays a failed or previous user message through the current LLM flow.
    func retryMessage(_ messageID: UUID) async {
        guard let message = messages.first(where: { $0.id == messageID && $0.role == .user && $0.sendFailed }) else {
            return
        }
        await sendMessage(message.content, retryingMessageID: message.id)
    }

    /// Shows the one-time onboarding intro after settings have been validated.
    func showValidatedIntroIfNeeded() async {
        guard !startupValidationAttempted else { return }
        startupValidationAttempted = true

        refreshLLMServiceIfNeeded()
        guard messages.isEmpty, llmMessages.isEmpty else { return }
        guard let llmService else { return }
        guard hasConfiguredLLMKey() else { return }
        guard canUseSelectedLLMOnCurrentNetwork() else {
            appendStartupAssistantMessage(
                "LM Studio is configured as a local provider and is only available on local Wi-Fi or VPN."
            )
            debugLog("Startup intro skipped: LM Studio not on local Wi-Fi or VPN", category: "Chat")
            return
        }

        do {
            try await runStartupConnectivityCheck(llmService: llmService)
            let intro = "Hi, I’m NetworkGenius (UniFi WiFi Edition). I can help troubleshoot your UniFi network. What issue are you seeing?"
            appendStartupAssistantMessage(intro, addToLLMHistory: true)
            debugLog("Startup LLM connectivity check succeeded; intro shown", category: "Chat")
        } catch {
            appendStartupAssistantMessage(
                "I can’t reach the selected AI provider right now. Check your API key, quota, and internet connection, then try again."
            )
            debugLog("Startup LLM connectivity check failed: \(error.localizedDescription)", category: "Chat")
        }
    }

    /// Returns the tool schema set allowed for the current network and settings state.
    private func toolsForCurrentState() -> [[String: Any]] {
        guard let networkMonitor, networkMonitor.isOnNetwork else {
            return []
        }
        guard let appState else { return [] }
        switch appState.llmProvider {
        case .claude: return ToolCatalog.claudeToolSchemas(for: appState.assistantMode)
        case .openai, .lmStudio: return ToolCatalog.openAIToolSchemas(for: appState.assistantMode)
        }
    }

    /// Trims older conversation history before sending it to the LLM.
    private func trimHistory() {
        if llmMessages.count > maxHistoryMessages {
            llmMessages = Array(llmMessages.suffix(maxHistoryMessages))
        }
        llmMessages = normalizedLLMHistory(llmMessages)
    }

    /// Returns true when the selected LLM can be used from the current network context.
    private func canUseSelectedLLMOnCurrentNetwork() -> Bool {
        guard let appState else { return true }
        guard appState.llmProvider == .lmStudio else { return true }
        guard let networkMonitor else { return false }
        return networkMonitor.isWiFiConnected || networkMonitor.isVPNConnected
    }

    /// Builds the system prompt that describes the current environment and guardrails.
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
        if let appState {
            switch appState.assistantMode {
            case .basic:
                systemPrompt += """

                Persona Mode: Basic
                - Explain issues in plain language for a home user.
                - Avoid advanced operator jargon unless the user asks for technical detail.
                - Prefer the smallest, most relevant tool calls and guide the user step by step.
                - For troubleshooting, prioritize simple checks before advanced diagnostics.
                """
            case .advanced:
                systemPrompt += """

                Persona Mode: Advanced
                - Respond like a concise network technician assistant.
                - Use precise technical terms when they improve clarity.
                - Prefer evidence from targeted tool calls, logs, and scoped diagnostics.
                - Optimize for fast triage and explain uncertainty explicitly.
                """
            }
        }
        if appState?.llmProvider == .lmStudio, appState?.hideReasoningOutput == true {
            systemPrompt += """

            When solving tasks, reason internally. Do not output internal reasoning, chain-of-thought, scratchpad, or <think> sections. Return only concise final answers and necessary tool results.
            """
        }
        if let appState {
            let approvedModificationClients = appState.clientModificationApprovals.filter(\.allowClientModifications)
            if !approvedModificationClients.isEmpty {
                let approvedLabels = approvedModificationClients
                    .prefix(25)
                    .map(\.displayName)
                    .joined(separator: ", ")
                systemPrompt += """

                Approved Client Modification Whitelist:
                - approved_count: \(approvedModificationClients.count)
                - approved_clients: \(approvedLabels)
                - if write-capable tools are enabled, never propose or execute client-specific changes, restarts, or modifications for targets outside this whitelist
                """
            }
        }
        guard appState?.shareDeviceContextWithLLM == true else {
            return systemPrompt
        }
        let context = DeviceContextProvider.snapshot(appState: appState, networkMonitor: networkMonitor)
        systemPrompt += context.promptBlock + "\nUse this context when answering questions about this device."
        return systemPrompt
    }

    /// Cleans assistant output before it is shown in the chat transcript.
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

    /// Restores the most recent saved conversation into the active chat.
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

    /// Reloads the conversation sidebar summaries from persisted storage.
    private func refreshConversationSummaries() {
        guard let persistenceStore else { return }
        conversationSummaries = persistenceStore.listConversations().map {
            ConversationSummary(id: $0.id, title: $0.title, updatedAt: $0.updatedAt)
        }
    }

    /// Persists the current thread, transcript, and LLM history to storage.
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

    /// Marks a user message as failed when the send flow does not complete.
    private func markUserMessageFailed(_ messageID: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == messageID && $0.role == .user }) else {
            return
        }
        messages[index].sendFailed = true
    }

    /// Normalizes stored LLM history before it is sent back to a provider.
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

    /// Rebuilds the active LLM service when provider settings have changed.
    private func refreshLLMServiceIfNeeded() {
        guard let appState else { return }
        let nextConfiguration = runtimeConfiguration(from: appState)
        guard activeRuntimeConfiguration != nextConfiguration else {
            return
        }

        if let networkMonitor {
            rebuildRuntimeServices(appState: appState, networkMonitor: networkMonitor)
        } else {
            llmService = makeLLMService(appState: appState)
            activeRuntimeConfiguration = nextConfiguration
        }
        debugLog(
            "Runtime configuration changed (provider=\(appState.llmProvider.rawValue), mode=\(appState.assistantMode.rawValue)); rebuilt services. Next request will include current thread context (\(llmMessages.count) transcript messages).",
            category: "Chat"
        )
    }

    private struct SendState {
        let userMessageID: UUID
        let llmCountBeforeSend: Int
    }

    private struct RequestContext {
        let tools: [[String: Any]]
        let systemPrompt: String
    }

    /// Builds the runtime configuration key used to decide whether services need rebuilding.
    private func runtimeConfiguration(from appState: AppState) -> RuntimeConfiguration {
        RuntimeConfiguration(
            provider: appState.llmProvider,
            assistantMode: appState.assistantMode,
            lmStudioBaseURL: UniFiAPIClient.normalizeBaseURL(appState.lmStudioBaseURL),
            lmStudioModel: appState.lmStudioModel.trimmingCharacters(in: .whitespacesAndNewlines),
            lmStudioMaxPromptChars: appState.lmStudioMaxPromptChars
        )
    }

    /// Rebuilds the provider client and tool executor together so runtime dependencies stay in sync.
    private func rebuildRuntimeServices(appState: AppState, networkMonitor: NetworkMonitor) {
        toolExecutor = makeToolExecutor(appState: appState, networkMonitor: networkMonitor)
        llmService = makeLLMService(appState: appState)
        activeRuntimeConfiguration = runtimeConfiguration(from: appState)
    }

    /// Creates a tool executor from the current app settings.
    private func makeToolExecutor(appState: AppState, networkMonitor: NetworkMonitor) -> ToolExecutor {
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
        return ToolExecutor(
            apiClient: client,
            queryService: queryService,
            summaryService: summaryService,
            networkMonitor: networkMonitor,
            lokiBaseURL: appState.grafanaLokiURL,
            clientModificationApprovals: appState.clientModificationApprovals,
            assistantMode: appState.assistantMode
        )
    }

    /// Creates the active LLM service from the selected provider settings.
    private func makeLLMService(appState: AppState) -> any LLMService {
        switch appState.llmProvider {
        case .claude:
            return ClaudeLLMService()
        case .openai:
            return OpenAILLMService()
        case .lmStudio:
            return LMStudioLLMService(
                baseURL: appState.lmStudioBaseURL,
                model: appState.lmStudioModel,
                maxPromptChars: appState.lmStudioMaxPromptChars
            )
        }
    }

    /// Rejects local-only provider use when the current network state cannot reach it.
    private func ensureSelectedLLMReachableForCurrentNetwork() -> Bool {
        guard canUseSelectedLLMOnCurrentNetwork() else {
            let msg = "LM Studio is configured as a local provider and is only available on local Wi-Fi or VPN."
            debugLog("LM Studio request blocked: not on local Wi-Fi or VPN", category: "Chat")
            messages.append(ChatMessage(role: .assistant, content: msg))
            return false
        }
        return true
    }

    /// Ensures startup intro flow only runs once a usable provider key exists.
    private func hasConfiguredLLMKey() -> Bool {
        guard let appState, appState.hasLLMKey else {
            appendStartupAssistantMessage("I’m not ready yet. Please add a valid AI provider API key in Settings.")
            debugLog("Startup intro skipped: missing LLM key", category: "Chat")
            return false
        }
        return true
    }

    /// Adds or reuses the outbound user message and records the matching LLM history state.
    private func queueUserMessage(_ text: String, retryingMessageID: UUID?) -> SendState {
        let userMessageID: UUID
        if let retryID = retryingMessageID,
           let index = messages.firstIndex(where: { $0.id == retryID && $0.role == .user })
        {
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
        return SendState(userMessageID: userMessageID, llmCountBeforeSend: llmCountBeforeSend)
    }

    /// Applies the UI-side side effects that happen before an outbound LLM request starts.
    private func prepareForSendUI(messageLength: Int) {
        debugLog("User message queued (\(messageLength) chars)", category: "Chat")
        if appState?.hapticFeedbackEnabled == true {
            hapticFeedback.prepareForResponseNotification()
        }
    }

    /// Captures the tool schema set and system prompt for one request loop.
    private func makeRequestContext() -> RequestContext {
        RequestContext(
            tools: toolsForCurrentState(),
            systemPrompt: buildSystemPrompt()
        )
    }

    /// Runs the lightweight provider probe used before showing the first-run intro message.
    private func runStartupConnectivityCheck(llmService: any LLMService) async throws {
        let probeMessage = LLMMessage(
            role: .user,
            content: "Connectivity check. Reply with 'ok'."
        )
        _ = try await llmService.sendMessages([probeMessage], tools: [], systemPrompt: buildSystemPrompt())
    }

    /// Runs the assistant/tool loop until the provider returns a final assistant response.
    private func runConversationLoop(
        llmService: any LLMService,
        context: RequestContext
    ) async throws -> LLMResponse {
        var response = try await sendLLMRequest(
            llmService: llmService,
            context: context,
            phase: "initial"
        )

        while !response.toolCalls.isEmpty {
            appendAssistantToolRequest(response)
            await executeToolCalls(response.toolCalls)
            response = try await sendLLMRequest(
                llmService: llmService,
                context: context,
                phase: "follow-up"
            )
        }

        return response
    }

    /// Sends one provider request and logs whether it is the initial or follow-up pass.
    private func sendLLMRequest(
        llmService: any LLMService,
        context: RequestContext,
        phase: String
    ) async throws -> LLMResponse {
        debugLog("Sending \(phase) LLM request", category: "Chat")
        let response = try await llmService.sendMessages(
            llmMessages,
            tools: context.tools,
            systemPrompt: context.systemPrompt
        )
        debugLog("\(phase.capitalized) LLM response received (toolCalls=\(response.toolCalls.count))", category: "Chat")
        return response
    }

    /// Persists the assistant tool-call envelope into LLM history before tool execution begins.
    private func appendAssistantToolRequest(_ response: LLMResponse) {
        let assistantToolText = sanitizeAssistantText(response.text ?? "")
        llmMessages.append(
            LLMMessage(
                role: .assistant,
                content: assistantToolText,
                toolCalls: response.toolCalls
            )
        )
    }

    /// Executes the provider-requested tools one by one and appends their outputs to LLM history.
    private func executeToolCalls(_ toolCalls: [LLMToolCall]) async {
        for toolCall in toolCalls {
            currentToolName = toolCall.name
            messages.append(ChatMessage(role: .toolCall, content: "Querying: \(toolCall.name)...", toolName: toolCall.name))
            debugLog("Executing tool '\(toolCall.name)'", category: "Chat")

            let result = await toolExecutor?.execute(toolCall: toolCall) ?? "Tool executor not configured"
            let compactResult = cappedToolResult(result, toolName: toolCall.name)
            llmMessages.append(LLMMessage(role: .tool, content: compactResult, toolCallID: toolCall.id))
        }
        currentToolName = nil
    }

    /// Appends the final assistant reply and performs the normal post-response side effects.
    private func deliverAssistantResponse(_ response: LLMResponse) {
        let finalText = sanitizeAssistantText(response.text ?? "")
        messages.append(ChatMessage(role: .assistant, content: finalText))
        llmMessages.append(LLMMessage(role: .assistant, content: finalText))
        trimHistory()
        persistConversationState()
        speechService?.speak(finalText)
        if appState?.hapticFeedbackEnabled == true {
            hapticFeedback.notifyResponseReturned()
        }
        debugLog("Assistant response delivered (\(finalText.count) chars)", category: "Chat")
    }

    /// Appends a startup/status assistant message and persists it immediately.
    private func appendStartupAssistantMessage(_ text: String, addToLLMHistory: Bool = false) {
        messages.append(ChatMessage(role: .assistant, content: text))
        if addToLLMHistory {
            llmMessages.append(LLMMessage(role: .assistant, content: text))
        }
        persistConversationState()
    }

    /// Converts provider and transport errors into short user-facing chat responses.
    private func userFacingChatErrorMessage(for error: Error) -> String {
        if let llmError = error as? LLMError, llmError.isRequestTooLarge {
            return "I can’t answer that in one pass right now because the request grew too large for the selected model. Please rephrase more narrowly, or ask for a smaller slice such as one client, the top 10 blocked clients, or whether a specific client has a block."
        }
        return "Error: \(error.localizedDescription)"
    }

    /// Caps oversized tool output before it is appended back into LLM history.
    private func cappedToolResult(_ result: String, toolName: String) -> String {
        guard result.count > maxToolResultCharacters else { return result }
        let prefix = String(result.prefix(maxToolResultCharacters))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        debugLog(
            "Tool '\(toolName)' result truncated for LLM history (before=\(result.count), after=\(prefix.count))",
            category: "Chat"
        )
        return """
        TOOL_RESULT_TRUNCATED: \(toolName) returned a large payload, so only the first \(prefix.count) characters are included below. If more detail is needed, ask a narrower follow-up.
        \(prefix)
        """
    }
}

#if DEBUG
extension ChatViewModel {
    func _testOnlyUserFacingChatErrorMessage(for error: Error) -> String {
        userFacingChatErrorMessage(for: error)
    }

    func _testOnlyCappedToolResult(_ result: String, toolName: String) -> String {
        cappedToolResult(result, toolName: toolName)
    }
}
#endif

struct ConversationSummary: Identifiable {
    let id: UUID
    let title: String
    let updatedAt: Date
}

private extension String {
    /// Replaces regex matches in a string while preserving unmatched text.
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

    /// Returns the saved conversation threads ordered for display.
    func listConversations() -> [ConversationThread] {
        let descriptor = FetchDescriptor<ConversationThread>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Loads the most recently updated saved conversation thread.
    func loadMostRecentConversation() -> RestoredConversation? {
        guard let thread = listConversations().first else { return nil }
        return restoredConversation(from: thread)
    }

    /// Loads a saved conversation into the current chat session.
    func loadConversation(id: UUID) -> RestoredConversation? {
        guard let thread = thread(id: id) else { return nil }
        return restoredConversation(from: thread)
    }

    /// Returns the saved conversation thread for the given identifier.
    func thread(id: UUID) -> ConversationThread? {
        var descriptor = FetchDescriptor<ConversationThread>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    @discardableResult
    /// Creates a new empty conversation thread model.
    func createConversation() -> ConversationThread {
        let thread = ConversationThread()
        context.insert(thread)
        try? context.save()
        return thread
    }

    /// Saves a conversation thread together with its chat and LLM message history.
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

    /// Converts a stored thread model back into the active chat view state.
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

    /// Builds a short conversation title from the earliest meaningful chat messages.
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

    /// Builds a serializable snapshot of the current chat state.
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

    /// Returns the device's current local IPv4 interface addresses.
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

    /// Redacts the UniFi console host for inclusion in the system prompt.
    private static func maskedConsoleHost(from baseURL: String) -> String {
        guard let host = URL(string: baseURL)?.host else { return "unknown" }
        return maskedIP(host)
    }

    /// Redacts the host portion of an IP address for prompt-safe display.
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

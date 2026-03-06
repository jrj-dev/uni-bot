import Foundation
import SwiftUI

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isLoading = false
    @Published var currentToolName: String?

    private var llmMessages: [LLMMessage] = []
    private let maxHistoryMessages = 20

    private var llmService: (any LLMService)?
    private var toolExecutor: ToolExecutor?
    private var networkMonitor: NetworkMonitor?
    private var appState: AppState?

    private let systemPrompt: String = {
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

    func configure(appState: AppState, networkMonitor: NetworkMonitor) {
        self.appState = appState
        self.networkMonitor = networkMonitor

        let client = UniFiAPIClient(
            baseURL: appState.consoleURL,
            allowSelfSigned: appState.allowSelfSignedCerts
        )
        let queryService = UniFiQueryService(client: client, siteID: appState.siteID)
        let summaryService = UniFiSummaryService(queryService: queryService)
        self.toolExecutor = ToolExecutor(
            queryService: queryService,
            summaryService: summaryService,
            networkMonitor: networkMonitor
        )

        switch appState.llmProvider {
        case .claude:
            self.llmService = ClaudeLLMService()
        case .openai:
            self.llmService = OpenAILLMService()
        }
    }

    func sendMessage(_ text: String) async {
        let userMessage = ChatMessage(role: .user, content: text)
        messages.append(userMessage)
        llmMessages.append(LLMMessage(role: .user, content: text))
        trimHistory()

        isLoading = true
        defer { isLoading = false; currentToolName = nil }

        guard let llmService else { return }
        let tools = toolsForCurrentState()

        do {
            var response = try await llmService.sendMessages(llmMessages, tools: tools, systemPrompt: systemPrompt)

            while !response.toolCalls.isEmpty {
                let assistantMsg = LLMMessage(
                    role: .assistant,
                    content: response.text ?? "",
                    toolCalls: response.toolCalls
                )
                llmMessages.append(assistantMsg)

                for toolCall in response.toolCalls {
                    currentToolName = toolCall.name
                    messages.append(ChatMessage(role: .toolCall, content: "Querying: \(toolCall.name)...", toolName: toolCall.name))

                    let result = await toolExecutor?.execute(toolCall: toolCall) ?? "Tool executor not configured"

                    llmMessages.append(LLMMessage(role: .tool, content: result, toolCallID: toolCall.id))
                }
                currentToolName = nil

                response = try await llmService.sendMessages(llmMessages, tools: tools, systemPrompt: systemPrompt)
            }

            let finalText = response.text ?? ""
            messages.append(ChatMessage(role: .assistant, content: finalText))
            llmMessages.append(LLMMessage(role: .assistant, content: finalText))
            trimHistory()

        } catch {
            messages.append(ChatMessage(role: .assistant, content: "Error: \(error.localizedDescription)"))
        }
    }

    private func toolsForCurrentState() -> [[String: Any]] {
        guard let networkMonitor, networkMonitor.isOnNetwork else {
            return []
        }
        guard let appState else { return [] }
        switch appState.llmProvider {
        case .claude: return ToolCatalog.claudeToolSchemas()
        case .openai: return ToolCatalog.openAIToolSchemas()
        }
    }

    private func trimHistory() {
        if llmMessages.count > maxHistoryMessages {
            llmMessages = Array(llmMessages.suffix(maxHistoryMessages))
        }
    }
}

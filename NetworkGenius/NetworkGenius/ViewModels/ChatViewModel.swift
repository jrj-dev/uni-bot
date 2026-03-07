import Foundation
import SwiftUI
import UIKit

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
    var speechService: SpeechService?

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

    func configure(appState: AppState, networkMonitor: NetworkMonitor) {
        self.appState = appState
        self.networkMonitor = networkMonitor
        debugLog("ChatViewModel configured (provider=\(appState.llmProvider.rawValue), onNetwork=\(networkMonitor.isOnNetwork))", category: "Chat")

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
                let assistantMsg = LLMMessage(
                    role: .assistant,
                    content: response.text ?? "",
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

            let finalText = response.text ?? ""
            messages.append(ChatMessage(role: .assistant, content: finalText))
            llmMessages.append(LLMMessage(role: .assistant, content: finalText))
            trimHistory()
            speechService?.speak(finalText)
            debugLog("Assistant response delivered (\(finalText.count) chars)", category: "Chat")

        } catch {
            debugLog("Chat request failed: \(error.localizedDescription)", category: "Chat")
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
        guard appState?.shareDeviceContextWithLLM == true else {
            return systemPrompt
        }
        let context = DeviceContextProvider.snapshot(appState: appState, networkMonitor: networkMonitor)
        systemPrompt += context.promptBlock + "\nUse this context when answering questions about this device."
        return systemPrompt
    }
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

import Foundation
import SwiftUI

enum LLMProvider: String, CaseIterable, Identifiable {
    case claude = "Claude"
    case openai = "OpenAI"
    case lmStudio = "LM Studio"
    var id: String { rawValue }
}

@MainActor
final class AppState: ObservableObject {
    @AppStorage("consoleURL") var consoleURL: String = ""
    @AppStorage("siteID") var siteID: String = ""
    @AppStorage("llmProvider") private var llmProviderRaw: String = LLMProvider.claude.rawValue
    @AppStorage("allowSelfSignedCerts") var allowSelfSignedCerts: Bool = true
    @AppStorage("shareDeviceContextWithLLM") var shareDeviceContextWithLLM: Bool = false
    @AppStorage("hideReasoningOutput") var hideReasoningOutput: Bool = true
    @AppStorage("darkModeEnabled") var darkModeEnabled: Bool = true
    @AppStorage("grafanaLokiURL") var grafanaLokiURL: String = ""
    @AppStorage("appBlockAllowedClients") var appBlockAllowedClients: String = ""
    @AppStorage("appBlockAllowedClientNameMap") var appBlockAllowedClientNameMap: String = ""
    @AppStorage("lmStudioBaseURL") var lmStudioBaseURL: String = ""
    @AppStorage("lmStudioModel") var lmStudioModel: String = ""
    @AppStorage("lmStudioMaxPromptChars") var lmStudioMaxPromptChars: Int = 4098

    var llmProvider: LLMProvider {
        get { LLMProvider(rawValue: llmProviderRaw) ?? .claude }
        set { llmProviderRaw = newValue.rawValue }
    }

    var isConfigured: Bool {
        !consoleURL.isEmpty
            && KeychainHelper.exists(key: .unifiAPIKey)
            && hasLLMKey
    }

    var hasLLMKey: Bool {
        switch llmProvider {
        case .claude: return KeychainHelper.exists(key: .claudeAPIKey)
        case .openai: return KeychainHelper.exists(key: .openaiAPIKey)
        case .lmStudio:
            return KeychainHelper.exists(key: .lmStudioAPIKey)
                && !UniFiAPIClient.normalizeBaseURL(lmStudioBaseURL).isEmpty
        }
    }
}

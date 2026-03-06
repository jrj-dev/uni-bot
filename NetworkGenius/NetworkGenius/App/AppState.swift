import Foundation
import SwiftUI

enum LLMProvider: String, CaseIterable, Identifiable {
    case claude = "Claude"
    case openai = "OpenAI"
    var id: String { rawValue }
}

@MainActor
final class AppState: ObservableObject {
    @AppStorage("consoleURL") var consoleURL: String = ""
    @AppStorage("siteID") var siteID: String = ""
    @AppStorage("llmProvider") private var llmProviderRaw: String = LLMProvider.claude.rawValue
    @AppStorage("allowSelfSignedCerts") var allowSelfSignedCerts: Bool = true

    var llmProvider: LLMProvider {
        get { LLMProvider(rawValue: llmProviderRaw) ?? .claude }
        set { llmProviderRaw = newValue.rawValue }
    }

    var isConfigured: Bool {
        !consoleURL.isEmpty
            && !siteID.isEmpty
            && KeychainHelper.exists(key: .unifiAPIKey)
            && hasLLMKey
    }

    var hasLLMKey: Bool {
        switch llmProvider {
        case .claude: return KeychainHelper.exists(key: .claudeAPIKey)
        case .openai: return KeychainHelper.exists(key: .openaiAPIKey)
        }
    }
}

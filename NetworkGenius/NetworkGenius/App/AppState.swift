import Foundation
import SwiftUI

enum LLMProvider: String, CaseIterable, Identifiable {
    case claude = "Claude"
    case openai = "OpenAI"
    case lmStudio = "LM Studio"
    var id: String { rawValue }
}

enum AssistantMode: String, CaseIterable, Identifiable {
    case basic = "Basic"
    case advanced = "Advanced"

    var id: String { rawValue }
}

@MainActor
final class AppState: ObservableObject {
    @AppStorage("consoleURL") var consoleURL: String = ""
    @AppStorage("siteID") var siteID: String = ""
    @AppStorage("llmProvider") private var llmProviderRaw: String = LLMProvider.claude.rawValue
    @AppStorage("assistantMode") private var assistantModeRaw: String = AssistantMode.basic.rawValue
    @AppStorage("allowSelfSignedCerts") var allowSelfSignedCerts: Bool = true
    @AppStorage("shareDeviceContextWithLLM") var shareDeviceContextWithLLM: Bool = false
    @AppStorage("hideReasoningOutput") var hideReasoningOutput: Bool = true
    @AppStorage("darkModeEnabled") var darkModeEnabled: Bool = true
    @AppStorage("hapticFeedbackEnabled") var hapticFeedbackEnabled: Bool = true
    @AppStorage("grafanaLokiURL") var grafanaLokiURL: String = ""
    @AppStorage("appBlockAllowedClients") var appBlockAllowedClients: String = ""
    @AppStorage("appBlockAllowedClientNameMap") var appBlockAllowedClientNameMap: String = ""
    @AppStorage("clientModificationApprovals") private var clientModificationApprovalsRaw: String = "[]"
    @AppStorage("lmStudioBaseURL") var lmStudioBaseURL: String = ""
    @AppStorage("lmStudioModel") var lmStudioModel: String = ""
    @AppStorage("lmStudioMaxPromptChars") var lmStudioMaxPromptChars: Int = 4098

    var llmProvider: LLMProvider {
        get { LLMProvider(rawValue: llmProviderRaw) ?? .claude }
        set { llmProviderRaw = newValue.rawValue }
    }

    var assistantMode: AssistantMode {
        get { AssistantMode(rawValue: assistantModeRaw) ?? .basic }
        set { assistantModeRaw = newValue.rawValue }
    }

    var isAdvancedMode: Bool {
        assistantMode == .advanced
    }

    var clientModificationApprovals: [ClientModificationApproval] {
        get {
            guard let data = clientModificationApprovalsRaw.data(using: .utf8),
                  let decodedApprovals = try? JSONDecoder().decode([ClientModificationApproval].self, from: data)
            else {
                let legacySelectors = parseCSV(appBlockAllowedClients)
                let legacyNameMap = parseNameMapJSON(appBlockAllowedClientNameMap)
                return ClientModificationApproval.mergeLegacyAppBlockSelectors(
                    existing: [],
                    selectors: legacySelectors,
                    nameMap: legacyNameMap
                )
            }
            return ClientModificationApproval.mergeLegacyAppBlockSelectors(
                existing: decodedApprovals,
                selectors: parseCSV(appBlockAllowedClients),
                nameMap: parseNameMapJSON(appBlockAllowedClientNameMap)
            )
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue),
                  let encoded = String(data: data, encoding: .utf8)
            else {
                clientModificationApprovalsRaw = "[]"
                return
            }
            clientModificationApprovalsRaw = encoded
        }
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

    /// Splits a stored CSV into trimmed selectors used by legacy guardrail migration.
    private func parseCSV(_ csv: String) -> [String] {
        csv.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Parses the legacy selector-to-name mapping JSON used to migrate app-block approvals.
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
}

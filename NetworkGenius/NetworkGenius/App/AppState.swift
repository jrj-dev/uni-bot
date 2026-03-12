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
    private struct ClientModificationApprovalStorage {
        let rawApprovals: String
        let legacySelectorsCSV: String
        let legacyNameMapJSON: String

        /// Decodes current approval storage and folds in any legacy app-block allowlist data.
        func decodeApprovals() -> [ClientModificationApproval] {
            let decodedApprovals = decodedCurrentApprovals()
            return ClientModificationApproval.mergeLegacyAppBlockSelectors(
                existing: decodedApprovals,
                selectors: legacySelectors(),
                nameMap: legacyNameMap()
            )
        }

        /// Encodes approvals for persisted AppStorage, falling back to an empty JSON array on failure.
        func encodeApprovals(_ approvals: [ClientModificationApproval]) -> String {
            guard let data = try? JSONEncoder().encode(approvals),
                  let encoded = String(data: data, encoding: .utf8)
            else {
                return "[]"
            }
            return encoded
        }

        private func decodedCurrentApprovals() -> [ClientModificationApproval] {
            guard let data = rawApprovals.data(using: .utf8),
                  let decodedApprovals = try? JSONDecoder().decode([ClientModificationApproval].self, from: data)
            else {
                return []
            }
            return decodedApprovals
        }

        /// Splits the legacy CSV storage into normalized selectors for migration.
        private func legacySelectors() -> [String] {
            legacySelectorsCSV.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }

        /// Parses the legacy selector-to-name mapping JSON used by app-block migration.
        private func legacyNameMap() -> [String: String] {
            guard let data = legacyNameMapJSON.data(using: .utf8),
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
            approvalStorage.decodeApprovals()
        }
        set {
            clientModificationApprovalsRaw = approvalStorage.encodeApprovals(newValue)
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

    /// Centralizes current and legacy approval persistence details so the public property
    /// stays focused on app behavior instead of storage mechanics.
    private var approvalStorage: ClientModificationApprovalStorage {
        ClientModificationApprovalStorage(
            rawApprovals: clientModificationApprovalsRaw,
            legacySelectorsCSV: appBlockAllowedClients,
            legacyNameMapJSON: appBlockAllowedClientNameMap
        )
    }
}

import Foundation

protocol LLMService {
    /// Sends messages.
    func sendMessages(_ messages: [LLMMessage], tools: [[String: Any]], systemPrompt: String) async throws -> LLMResponse
}

enum LLMError: LocalizedError {
    case missingAPIKey
    case invalidResponse(String)
    case httpError(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "LLM API key not found in Keychain."
        case .invalidResponse(let msg): return "Invalid response: \(msg)"
        case .httpError(let code, let body): return "HTTP \(code): \(LogSanitizer.sanitize(body))"
        }
    }

    var isRequestTooLarge: Bool {
        switch self {
        case .httpError(let code, let body):
            let normalized = body.lowercased()
            if code == 413 { return true }
            guard code == 400 else { return false }
            return normalized.contains("request too large")
                || normalized.contains("context_length_exceeded")
                || normalized.contains("maximum context length")
                || normalized.contains("too many tokens")
                || normalized.contains("prompt is too long")
                || normalized.contains("input is too long")
        case .invalidResponse(let message):
            let normalized = message.lowercased()
            return normalized.contains("request too large")
                || normalized.contains("context length")
                || normalized.contains("too many tokens")
                || normalized.contains("prompt is too long")
        default:
            return false
        }
    }
}

struct DebugLogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let category: String
    let message: String
}

final class DebugLogStore: ObservableObject {
    static let shared = DebugLogStore()

    @Published private(set) var entries: [DebugLogEntry] = []

    private init() {}

    /// Appends a sanitized debug log entry to the in-memory log buffer.
    func add(_ message: String, category: String) {
        let entry = DebugLogEntry(timestamp: Date(), category: category, message: message)
        DispatchQueue.main.async {
            self.entries.append(entry)
            if self.entries.count > 500 {
                self.entries.removeFirst(self.entries.count - 500)
            }
        }
    }

    /// Clears all buffered debug log entries.
    func clear() {
        DispatchQueue.main.async {
            self.entries.removeAll()
        }
    }
}

/// Writes a sanitized debug message to the shared in-memory logger.
func debugLog(_ message: String, category: String = "App") {
    let sanitized = LogSanitizer.sanitize(message)
    DebugLogStore.shared.add(sanitized, category: category)
    #if DEBUG
    print("[\(category)] \(sanitized)")
    #endif
}

private enum LogSanitizer {
    /// Redacts secrets and sensitive headers from debug log text.
    static func sanitize(_ text: String) -> String {
        var output = text
        let patterns: [(String, String)] = [
            (#"(?i)(authorization\s*[:=]\s*bearer\s+)[^\s,;]+"#, "$1<redacted>"),
            (#"(?i)(x-api-key\s*[:=]\s*)[^\s,;]+"#, "$1<redacted>"),
            (#"(?i)(api[_-]?key\s*[:=]\s*)[^\s,;]+"#, "$1<redacted>"),
            (#"\bsk-ant-[A-Za-z0-9_\-]{8,}\b"#, "<redacted-anthropic-key>"),
            (#"\bsk-[A-Za-z0-9_\-]{8,}\b"#, "<redacted-openai-key>")
        ]

        for (pattern, template) in patterns {
            output = replacingRegexMatches(in: output, pattern: pattern, with: template)
        }
        return output
    }

    /// Replaces regex matches in a string while preserving unmatched text.
    private static func replacingRegexMatches(
        in text: String,
        pattern: String,
        with template: String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let fullRange = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: fullRange, withTemplate: template)
    }
}

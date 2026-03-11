import Foundation
import Security

enum KeychainHelper {
    enum Key: String {
        case unifiAPIKey = "unifi_api_key"
        case unifiSSHUsername = "unifi_ssh_username"
        case unifiSSHPrivateKey = "unifi_ssh_private_key"
        case unifiSSHPassword = "unifi_ssh_password"
        case claudeAPIKey = "claude_api_key"
        case openaiAPIKey = "openai_api_key"
        case grafanaLokiAPIKey = "grafana_loki_api_key"
        case lmStudioAPIKey = "lmstudio_api_key"
    }

    @discardableResult
    /// Stores a value in the iOS Keychain under the provided application key.
    static func save(key: Key, data: Data) -> Bool {
        delete(key: key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    /// Stores a value in the iOS Keychain under the provided application key.
    static func save(key: Key, string: String) -> Bool {
        guard let data = string.data(using: .utf8) else { return false }
        return save(key: key, data: data)
    }

    /// Loads raw data from the iOS Keychain for the provided application key.
    static func load(key: Key) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    /// Loads a UTF-8 string value from the iOS Keychain.
    static func loadString(key: Key) -> String? {
        guard let data = load(key: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    /// Deletes a stored Keychain item for the provided application key.
    static func delete(key: Key) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }

    /// Returns true when a Keychain item exists for the provided application key.
    static func exists(key: Key) -> Bool {
        load(key: key) != nil
    }
}

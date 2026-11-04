import Foundation
import Security

enum KeychainError: LocalizedError {
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
            return "The Keychain refused the request: \(detail)."
        }
    }
}

/// The Anthropic API key, kept as a generic password in the login Keychain. It is never
/// written anywhere else: not to disk, logs, UserDefaults, prompts or tool results.
enum KeychainStore {
    static let service = "dev.cldixon.AutomationAgent"
    static let account = "anthropic-api-key"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    static func readAPIKey() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        let key = String(data: data, encoding: .utf8)
        return key?.isEmpty == false ? key : nil
    }

    static func saveAPIKey(_ key: String) throws {
        try deleteAPIKey()
        var attributes = baseQuery
        attributes[kSecValueData as String] = Data(key.utf8)
        attributes[kSecAttrLabel as String] = "Automation Agent: Anthropic API key"
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    static func deleteAPIKey() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}

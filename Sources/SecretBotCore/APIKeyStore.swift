import Foundation
import Security

/// API anahtarlarını macOS Keychain'de tutar (her sağlayıcı ayrı hesap adıyla).
public enum APIKeyStore {
    static let service = "SecretBot"
    public static let anthropic = "anthropic-api-key"
    public static let openai = "openai-api-key"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public static func read(_ account: String = anthropic) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let s = String(data: data, encoding: .utf8) else { return nil }
        let key = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    @discardableResult
    public static func save(_ key: String, account: String = anthropic) -> Bool {
        SecItemDelete(query(account) as CFDictionary)
        var q = query(account)
        q[kSecValueData as String] = Data(key.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    public static func delete(_ account: String = anthropic) {
        SecItemDelete(query(account) as CFDictionary)
    }
}

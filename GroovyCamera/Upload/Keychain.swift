import Foundation
import Security

/// Keeps the R2 credentials in the Keychain. Readable after the phone's first unlock, so
/// background uploads can re-sign on a locked phone, and this device only, so they never sync or
/// move to another phone.
enum CredentialStore {
    private static let service = "groovycamera.r2"
    private static let account = "credentials"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func load() -> R2Credentials? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(R2Credentials.self, from: data)
    }

    @discardableResult
    static func save(_ credentials: R2Credentials) -> Bool {
        guard let data = try? JSONEncoder().encode(credentials) else { return false }
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}

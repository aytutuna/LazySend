#if os(macOS)
import Foundation
import LazySendKit
import Security

struct KeychainError: Error, Equatable, LocalizedError {
    let status: OSStatus

    var errorDescription: String? { SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)." }
}

/// The secrets the paired computers gave this Mac, as generic passwords in the login keychain beside the
/// certificate's key. They never leave this Mac.
struct KeychainSecrets: SecretStore {
    static let service = "com.lazysend.hosts"

    func save(_ data: Data, for key: String) throws {
        let deleted = SecItemDelete(query(key) as CFDictionary)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else { throw KeychainError(status: deleted) }
        var item = query(key)
        item[kSecValueData as String] = data
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func load(for key: String) throws -> Data? {
        var search = query(key)
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return result as? Data
    }

    func delete(for key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    private func query(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainSecrets.service,
            kSecAttrAccount as String: key,
        ]
    }
}
#endif

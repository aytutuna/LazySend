#if os(iOS)
import Foundation
import LazySendKit
import Security

struct KeychainError: Error, Equatable, LocalizedError {
    let status: OSStatus

    var errorDescription: String? { "The pairing could not be saved on this phone." }
}

/// Generic passwords in the app's default keychain group. They stay readable after the first unlock so the
/// background check works while the phone is locked, and never leave this device.
struct KeychainSecrets: SecretStore {
    static let service = "com.lazysend.secrets"

    func save(_ data: Data, for key: String) throws {
        let deleted = SecItemDelete(query(key) as CFDictionary)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else { throw KeychainError(status: deleted) }
        var item = query(key)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
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
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}

final class MemorySecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    func save(_ data: Data, for key: String) throws {
        lock.lock()
        items[key] = data
        lock.unlock()
    }

    func load(for key: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return items[key]
    }

    func delete(for key: String) throws {
        lock.lock()
        items[key] = nil
        lock.unlock()
    }
}
#endif

import Foundation
import LazySendKit
import Security

// A copy of KeychainSecrets in Sources/LazySendIOS/Secrets.swift: the extension links LazySendKit only and cannot
// import the app's module. Same service and attributes, so both read the same items.
struct ShareSecrets: SecretStore {
    static let service = "com.lazysend.secrets"

    func save(_ data: Data, for key: String) throws {
        let deleted = SecItemDelete(query(key) as CFDictionary)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else { throw KeychainFailure(status: deleted) }
        var item = query(key)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainFailure(status: status) }
    }

    func load(for key: String) throws -> Data? {
        var search = query(key)
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainFailure(status: status) }
        return result as? Data
    }

    func delete(for key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainFailure(status: status) }
    }

    private func query(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: ShareSecrets.service,
            kSecAttrAccount as String: key,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}

struct KeychainFailure: Error {
    let status: OSStatus
}

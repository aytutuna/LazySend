#if os(iOS)
import Foundation
import LazySendServer
import Security

/// The phone's own certificate for hosting: a permanent P-256 key and a self-signed certificate in the Keychain,
/// this device only. Guests pin the key, so a certificate that is about to end is renewed on the same key.
struct HostCertificate {
    static let label = "Lazy Send"
    static let keyTag = Data("com.lazysend.identity".utf8)
    static let renewBefore: TimeInterval = 60 * 24 * 60 * 60

    let hostName: String

    func current(now: Date = Date()) throws -> SecIdentity {
        guard let key = try existingKey() else {
            return try makeIdentity(now: now)
        }
        if let der = try existingCertificate(), let notAfter = SelfSignedCertificate.notAfter(der),
           notAfter > now.addingTimeInterval(HostCertificate.renewBefore), let identity = HostCertificate.identity() {
            return identity
        }
        return try addCertificate(for: key, now: now)
    }

    private func existingKey() throws -> SecKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: HostCertificate.keyTag,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let key = result else { throw HostCertificate.failure("The key could not be read", status) }
        return (key as! SecKey)
    }

    private func existingCertificate() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: HostCertificate.label,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let found = result else {
            throw HostCertificate.failure("The certificate could not be read", status)
        }
        return SecCertificateCopyData(found as! SecCertificate) as Data
    }

    private func makeIdentity(now: Date) throws -> SecIdentity {
        let privateAttributes: [String: Any] = [
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: HostCertificate.keyTag,
            kSecAttrLabel as String: HostCertificate.label,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: privateAttributes,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            let reason = error?.takeRetainedValue().localizedDescription ?? "unknown error"
            throw SelfSignedCertificateError("The key could not be made: \(reason)")
        }
        do {
            return try addCertificate(for: key, now: now)
        } catch {
            HostCertificate.deleteKeys()
            throw error
        }
    }

    // The old certificate goes first, so the identity query finds one certificate for the key.
    private func addCertificate(for key: SecKey, now: Date) throws -> SecIdentity {
        let der = try SelfSignedCertificate.make(hostName: hostName, key: key, now: now)
        guard let certificate = SelfSignedCertificate.certificate(der) else {
            throw SelfSignedCertificateError("The certificate that was made does not read.")
        }
        HostCertificate.deleteCertificates()
        let item: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrLabel as String: HostCertificate.label,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw HostCertificate.failure("The certificate could not be added to the keychain", added) }
        guard let identity = HostCertificate.identity() else {
            HostCertificate.deleteCertificates()
            throw SelfSignedCertificateError("The keychain did not pair the key with its certificate.")
        }
        return identity
    }

    private static func identity() -> SecIdentity? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: label,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let found = result else { return nil }
        return (found as! SecIdentity)
    }

    private static func deleteCertificates() {
        SecItemDelete([kSecClass as String: kSecClassCertificate, kSecAttrLabel as String: label] as CFDictionary)
    }

    private static func deleteKeys() {
        SecItemDelete([kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: keyTag] as CFDictionary)
    }

    private static func failure(_ what: String, _ status: OSStatus) -> SelfSignedCertificateError {
        let reason = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
        return SelfSignedCertificateError("\(what): \(reason)")
    }
}
#endif

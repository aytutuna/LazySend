#if os(macOS)
import LazySendKit
import LazySendServer
import Foundation
import Security

final class CertificateStore {
    static let appLabel = "Lazy Send"
    static let appKeyTag = Data("com.lazysend.identity".utf8)
    static let renewBefore: TimeInterval = 60 * 24 * 60 * 60

    private let hostName: String
    private let label: String
    private let keyTag: Data
    private let lock = NSLock()

    init(hostName: String, label: String = CertificateStore.appLabel, keyTag: Data = CertificateStore.appKeyTag) {
        self.hostName = hostName
        self.label = label
        self.keyTag = keyTag
    }

    func current(now: Date) throws -> SecIdentity {
        lock.lock()
        defer { lock.unlock() }
        for entry in try certificates() {
            // A certificate whose key was deleted pairs into no identity.
            guard let identity = CertificateStore.identity(for: entry.certificate) else { continue }
            if entry.notAfter > now.addingTimeInterval(CertificateStore.renewBefore) {
                removeOthers(keeping: entry.der)
                return identity
            }
            guard let key = CertificateStore.privateKey(of: identity) else { continue }
            let renewed = try addCertificate(for: key, now: now)
            removeOthers(keeping: renewed.der)
            return renewed.identity
        }
        let made = try makeIdentity(now: now)
        removeOthers(keeping: made.der)
        return made.identity
    }

    func renew(now: Date) throws -> SecIdentity {
        lock.lock()
        defer { lock.unlock() }
        let made = try makeIdentity(now: now)
        removeOthers(keeping: made.der)
        return made.identity
    }

    private func certificates() throws -> [(certificate: SecCertificate, der: Data, notAfter: Date)] {
        var found: [(certificate: SecCertificate, der: Data, notAfter: Date)] = []
        for hash in try keyHashes() {
            let query: [String: Any] = [
                kSecClass as String: kSecClassCertificate,
                kSecAttrPublicKeyHash as String: hash,
                kSecReturnRef as String: true,
                kSecMatchLimit as String: kSecMatchLimitAll,
            ]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { continue }
            guard status == errSecSuccess, let items = result as? [Any] else {
                throw CertificateStore.failure("The keychain could not be read", status)
            }
            for item in items {
                let certificate = item as! SecCertificate
                let der = SecCertificateCopyData(certificate) as Data
                guard let notAfter = SelfSignedCertificate.notAfter(der) else { continue }
                found.append((certificate, der, notAfter))
            }
        }
        found.sort { $0.notAfter > $1.notAfter }
        return found
    }

    private func keyHashes() throws -> [Data] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            throw CertificateStore.failure("The keychain could not be read", status)
        }
        return items.compactMap { $0[kSecAttrApplicationLabel as String] as? Data }
    }

    private func makeIdentity(now: Date) throws -> (identity: SecIdentity, der: Data) {
        let privateAttributes: [String: Any] = [
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: keyTag,
            kSecAttrLabel as String: label,
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
            CertificateStore.delete(key)
            throw error
        }
    }

    private func addCertificate(for key: SecKey, now: Date) throws -> (identity: SecIdentity, der: Data) {
        let der = try SelfSignedCertificate.make(hostName: hostName, key: key, now: now)
        guard let certificate = SelfSignedCertificate.certificate(der) else {
            throw SelfSignedCertificateError("The certificate that was made does not read.")
        }
        let item: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
        ]
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else {
            throw CertificateStore.failure("The certificate could not be added to the keychain", added)
        }
        guard let identity = CertificateStore.identity(for: certificate) else {
            CertificateStore.delete(certificate)
            throw SelfSignedCertificateError("The keychain did not pair the key with its certificate.")
        }
        return (identity, der)
    }

    private func removeOthers(keeping der: Data) {
        guard let others = try? certificates() else { return }
        let pin = SpkiFingerprint.of(der)
        for entry in others where entry.der != der {
            if SpkiFingerprint.of(entry.der) != pin, let identity = CertificateStore.identity(for: entry.certificate),
               let key = CertificateStore.privateKey(of: identity) {
                CertificateStore.delete(key)
            }
            CertificateStore.delete(entry.certificate)
        }
    }

    private static func identity(for certificate: SecCertificate) -> SecIdentity? {
        var identity: SecIdentity?
        guard SecIdentityCreateWithCertificate(nil, certificate, &identity) == errSecSuccess else { return nil }
        return identity
    }

    private static func privateKey(of identity: SecIdentity) -> SecKey? {
        var key: SecKey?
        guard SecIdentityCopyPrivateKey(identity, &key) == errSecSuccess else { return nil }
        return key
    }

    private static func delete(_ key: SecKey) {
        let query: [String: Any] = [kSecClass as String: kSecClassKey, kSecValueRef as String: key]
        SecItemDelete(query as CFDictionary)
    }

    private static func delete(_ certificate: SecCertificate) {
        let query: [String: Any] = [kSecClass as String: kSecClassCertificate, kSecValueRef as String: certificate]
        SecItemDelete(query as CFDictionary)
    }

    private static func failure(_ what: String, _ status: OSStatus) -> SelfSignedCertificateError {
        let reason = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
        return SelfSignedCertificateError("\(what): \(reason)")
    }
}
#endif

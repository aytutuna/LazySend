#if os(iOS)
import Security
import XCTest
@testable import LazySendIOS
@testable import LazySendKit
@testable import LazySendServer

// These need a keychain, which a test bundle without a host app may not have; the error is the reason for the skip.
final class HostCertificateTests: XCTestCase {
    private func certificate() -> HostCertificate {
        HostCertificate(hostName: "Test phone", label: "Lazy Send test " + UUID().uuidString, keyTag: Data(UUID().uuidString.utf8))
    }

    private func identity(_ certificate: HostCertificate, now: Date = Date()) throws -> (identity: SecIdentity, der: Data) {
        do {
            let identity = try certificate.current(now: now)
            return (identity, try XCTUnwrap(SelfSignedCertificate.der(of: identity)))
        } catch let error as SelfSignedCertificateError {
            throw XCTSkip("The keychain cannot be used here: \(error.message)")
        }
    }

    func testTheSameIdentityComesBackOnTheNextCall() throws {
        let certificate = certificate()
        let first = try identity(certificate)
        let second = try identity(certificate)
        XCTAssertEqual(first.der, second.der)
        XCTAssertEqual(SpkiFingerprint.of(first.der)?.count, 32)
    }

    func testACertificateThatIsAboutToEndIsRenewedOnTheSameKey() throws {
        let certificate = certificate()
        let first = try identity(certificate)
        let later = Date().addingTimeInterval(800 * 24 * 60 * 60)
        let renewed = try identity(certificate, now: later)
        XCTAssertNotEqual(first.der, renewed.der)
        XCTAssertEqual(SpkiFingerprint.of(first.der), SpkiFingerprint.of(renewed.der))
    }
}
#endif

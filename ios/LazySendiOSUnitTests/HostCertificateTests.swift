import LazySendKit
import LazySendServer
import Security
import XCTest
@testable import LazySendIOS

// Run inside the app, which is what gives them a Keychain.
final class HostCertificateTests: XCTestCase {
    private func certificate() -> HostCertificate {
        HostCertificate(hostName: "Test phone", label: "Lazy Send test " + UUID().uuidString, keyTag: Data(UUID().uuidString.utf8))
    }

    private func identity(_ certificate: HostCertificate, now: Date = Date()) throws -> (identity: SecIdentity, der: Data) {
        let identity = try certificate.current(now: now)
        return (identity, try XCTUnwrap(SelfSignedCertificate.der(of: identity)))
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
        let again = try identity(certificate, now: later)
        XCTAssertEqual(again.der, renewed.der)
    }

    func testTheLinkServiceTakesTheIdentityAndReportsItsFingerprint() throws {
        let made = try identity(certificate())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lazysend-cert-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try LinkService(paths: SendPaths(root: root.appendingPathComponent("state"), defaultReceiveRoot: root),
                                      identity: made.identity)
        XCTAssertEqual(service.fingerprint, SpkiFingerprint.of(made.der))
    }
}

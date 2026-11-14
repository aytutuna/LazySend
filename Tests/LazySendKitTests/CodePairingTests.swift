import XCTest
@testable import LazySendKit

final class CodePairingTests: XCTestCase {
    func testTheMatchCodeVector() {
        let fingerprint = Data((0..<32).map { UInt8($0) })
        XCTAssertEqual(SpkiFingerprint.checkCode(fingerprint), "066 051")
        XCTAssertEqual(SpkiFingerprint.matchCode(fingerprint, shortCode: "7KQ2M9XD"), "987 292")
        XCTAssertEqual(SpkiFingerprint.matchCode(Data(count: 5), shortCode: "7KQ2M9XD"), "")
    }

    func testShortCodesAreTypedInAnyShape() {
        XCTAssertEqual(ShortCode.normalize("7kq2-m9xd"), "7KQ2M9XD")
        XCTAssertEqual(ShortCode.normalize(" 7KQ2 M9XD "), "7KQ2M9XD")
        XCTAssertNil(ShortCode.normalize("7KQ2-M9X"))
        XCTAssertNil(ShortCode.normalize("7KQ2-M9XI"))
        XCTAssertNil(ShortCode.normalize(Base64Url.encode(Data(repeating: 1, count: 16))))
        XCTAssertNil(ShortCode.normalize(nil))
    }

    func testNamesLoseControlCharactersAndAreCutOnACharacterBoundary() {
        XCTAssertEqual(DisplayName.clean("  Aytu\u{7}'s\nMac "), "Aytu'sMac")
        XCTAssertEqual(DisplayName.clean(nil), "")
        let cut = DisplayName.clean(String(repeating: "é", count: 40), maxBytes: LinkProtocol.maxTxtNameBytes)
        XCTAssertEqual(cut.utf8.count, 64)
        XCTAssertEqual(cut.count, 32)
    }

    func testABrowsedNameFallsBackToTheInstanceThenToComputer() {
        XCTAssertEqual(ServiceBrowser.nameOf("Büro Mac", label: "ignored"), "Büro Mac")
        XCTAssertEqual(ServiceBrowser.nameOf(nil, label: "Kitchen iMac"), "Kitchen iMac")
        XCTAssertEqual(ServiceBrowser.nameOf(" \u{1} ", label: ""), "Computer")
    }

    func testAKeylessSessionLearnsTheCertificateItMet() async throws {
        let pc = try FakePc()
        let session = PinnedSession()
        XCTAssertNil(session.seen)
        let client = LinkClient(endpoint: pc.endpoint, session: session, credentials: nil)
        let health = try await client.health()
        XCTAssertEqual(health.service, "lazysend")
        XCTAssertEqual(session.seen, pc.pin)
        XCTAssertEqual(client.seen, pc.pin)
    }

    func testASessionWithAKeyStillRefusesAnotherCertificate() async throws {
        let pc = try FakePc()
        let other = SpkiFingerprint.of(try TestServer.fixture("test-other", "der"))!
        let client = LinkClient(endpoint: pc.endpoint, pin: other)
        do {
            _ = try await client.health()
            XCTFail("Expected the certificate to be refused")
        } catch {
            XCTAssertEqual(error as? LinkError, .wrongCertificate)
        }
        XCTAssertNil(client.seen)
    }

    func testReachingAnUnpinnedComputerGivesItsFingerprint() async throws {
        let pc = try FakePc()
        let discovery = Discovery(announced: { _ in [:] }, subnets: { [] }, probe: { _, _ in [] })
        let store = PcStore(file: try temporaryFolder().appendingPathComponent("pcs.json"), secrets: MemorySecrets())
        let connector = PcConnector(store: store, discovery: discovery)
        let met = await connector.reachUnpinned(addresses: ["10.255.255.1", "127.0.0.1"], port: pc.server.port)
        XCTAssertEqual(met?.reached.host, "127.0.0.1")
        XCTAssertEqual(met?.fingerprint, pc.pin)
        let nothing = await connector.reachUnpinned(addresses: [], port: pc.server.port)
        XCTAssertNil(nothing)
    }

    func testAComputersOwnIdIsItsPhoneIdAndNoSecretCostsAPairing() throws {
        let secrets = MemorySecrets()
        let file = try temporaryFolder().appendingPathComponent("hosts.json")
        let pc = PairedPc(id: "host-0001", name: "Studio", fingerprint: Base64Url.encode(Data(repeating: 3, count: 32)), addresses: ["10.0.0.4"], port: 52734)
        let store = PcStore(file: file, secrets: secrets, phoneId: "this-computer")
        try store.put(pc, secret: "secret")
        XCTAssertEqual(store.phoneId, "this-computer")
        XCTAssertNil(try secrets.load(for: "phone-id"))

        try secrets.delete(for: pc.id)
        let again = PcStore(file: file, secrets: secrets, phoneId: "this-computer")
        XCTAssertEqual(again.pcs, [pc])
        XCTAssertNil(again.secret(for: pc.id))
        secrets.failsLoads = true
        XCTAssertEqual(PcStore(file: file, secrets: secrets, phoneId: "this-computer").pcs, [pc])
    }
}

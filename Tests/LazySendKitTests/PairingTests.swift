import XCTest
@testable import LazySendKit

final class PairingCodeTests: XCTestCase {
    private let fp = Base64Url.encode(Data(repeating: 0xAB, count: 32))
    private let token = Base64Url.encode(Data(repeating: 1, count: 16))

    private func code(_ extra: String = "", v: Int = 1) -> String {
        "lazysend://pair?v=\(v)&id=pc-12345678&n=My%20PC&fp=\(fp)&a=192.168.1.5,172.20.10.2&p=52734&t=\(token)\(extra)"
    }

    func testParsesACode() throws {
        let parsed = try PairingCode.parse(code())
        XCTAssertEqual(parsed.desktopId, "pc-12345678")
        XCTAssertEqual(parsed.name, "My PC")
        XCTAssertEqual(parsed.addresses, ["192.168.1.5", "172.20.10.2"])
        XCTAssertEqual(parsed.port, 52734)
        XCTAssertEqual(parsed.fingerprint, fp)
        XCTAssertEqual(parsed.pin, Data(repeating: 0xAB, count: 32))
    }

    func testIgnoresUnknownParametersAndSurroundingSpace() throws {
        XCTAssertEqual(try PairingCode.parse("  " + code("&x=1") + "\n").port, 52734)
    }

    func testDecodesPercentEncodedUtf8Names() throws {
        let text = code().replacingOccurrences(of: "My%20PC", with: "B%C3%BCro%20PC")
        XCTAssertEqual(try PairingCode.parse(text).name, "Büro PC")
    }

    func testNoAddressesIsAnEmptyList() throws {
        let text = "lazysend://pair?v=1&id=pc-12345678&n=x&fp=\(fp)&a=&p=1&t=\(token)"
        XCTAssertEqual(try PairingCode.parse(text).addresses, [])
    }

    func testRefusesANewerVersion() {
        XCTAssertThrowsError(try PairingCode.parse(code(v: 2))) { XCTAssertEqual($0 as? PairingCodeError, .newerVersion) }
    }

    func testRefusesOtherText() {
        XCTAssertThrowsError(try PairingCode.parse("https://example.com")) { XCTAssertEqual($0 as? PairingCodeError, .notPairingCode) }
        XCTAssertThrowsError(try PairingCode.parse("lazyprint://pair?v=1")) { XCTAssertEqual($0 as? PairingCodeError, .notPairingCode) }
    }

    func testRefusesDamagedCodes() {
        let broken = [
            code("&p=70000"),
            code("&id=again"),
            code().replacingOccurrences(of: "&t=\(token)", with: ""),
            code().replacingOccurrences(of: fp, with: "short"),
            code().replacingOccurrences(of: token, with: Base64Url.encode(Data(count: 8))),
            code() + "#frag",
            code() + " space",
            code().replacingOccurrences(of: "My%20PC", with: "bad%zz"),
            "lazysend://pair?v=x&id=pc-12345678",
        ]
        for text in broken {
            XCTAssertThrowsError(try PairingCode.parse(text), text) { XCTAssertEqual(($0 as? PairingCodeError)?.problem, .damaged, text) }
        }
    }

    func testCheckCodeIsTheFirstFourBytesModuloAMillion() throws {
        let parsed = try PairingCode.parse(code())
        let value = UInt32(0xABABABAB) % 1_000_000
        let digits = String(format: "%06d", value)
        XCTAssertEqual(parsed.checkCode, "\(digits.prefix(3)) \(digits.suffix(3))")
    }

    func testBase64UrlOnlyAcceptsWhatItWrites() {
        XCTAssertNil(Base64Url.decode("AAAA="))
        XCTAssertNil(Base64Url.decode("AA+A"))
        XCTAssertEqual(Base64Url.decode(Base64Url.encode(Data([251, 255, 254]))), Data([251, 255, 254]))
    }
}

final class SpkiTests: XCTestCase {
    func testFingerprintOfTheTestCertificate() throws {
        let der = try TestServer.fixture("test-server", "der")
        let expected = Data(hex: "aeb46a0170418fcfc690b2a626f9f9ff8b866129809d372c8eac79d997a28ec3")
        XCTAssertEqual(SpkiFingerprint.of(der), expected)
        XCTAssertEqual(try TestServer.pin(), expected)
    }

    func testPinAcceptsItsOwnCertificateOnly() throws {
        let server = try TestServer.fixture("test-server", "der")
        let other = try TestServer.fixture("test-other", "der")
        let pin = SpkiFingerprint.of(server)!
        XCTAssertTrue(PinnedSession.accepts(server, pin: pin))
        XCTAssertFalse(PinnedSession.accepts(other, pin: pin))
        XCTAssertFalse(PinnedSession.accepts(nil, pin: pin))
        XCTAssertFalse(PinnedSession.accepts(Data([1, 2, 3]), pin: pin))
        XCTAssertFalse(PinnedSession.accepts(server, pin: Data(pin.prefix(31))))
    }

    func testTruncatedCertificateIsNotOne() throws {
        let der = try TestServer.fixture("test-server", "der")
        XCTAssertNil(SpkiFingerprint.of(der.prefix(der.count - 1)))
        XCTAssertNil(SpkiFingerprint.of(Data()))
    }

    func testMatchesNeedsEqualLengthKeys() {
        XCTAssertTrue(SpkiFingerprint.matches(Data(repeating: 1, count: 32), Data(repeating: 1, count: 32)))
        XCTAssertFalse(SpkiFingerprint.matches(Data(repeating: 1, count: 32), Data(repeating: 2, count: 32)))
        XCTAssertFalse(SpkiFingerprint.matches(Data(repeating: 1, count: 31), Data(repeating: 1, count: 31)))
    }
}

extension Data {
    init(hex: String) {
        self.init(stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        })
    }
}

final class PairFlowTests: XCTestCase {
    private func setUpPairing() throws -> (FakePc, PcStore, PcConnector, PairingCode, MemorySecrets) {
        let pc = try FakePc()
        let secrets = MemorySecrets()
        let store = PcStore(file: try temporaryFolder().appendingPathComponent("pcs.json"), secrets: secrets)
        let discovery = Discovery(announced: { _ in [:] }, subnets: { [] }, probe: { _, _ in [] })
        let text = "lazysend://pair?v=1&id=\(pc.desktopId)&n=Test%20PC&fp=\(Base64Url.encode(pc.pin))&a=10.255.255.1,127.0.0.1&p=\(pc.server.port)&t=\(pc.token)"
        return (pc, store, PcConnector(store: store, discovery: discovery), try PairingCode.parse(text), secrets)
    }

    func testPairsAndKeepsTheSecret() async throws {
        let (pc, store, connector, code, secrets) = try setUpPairing()
        let paired = try await Pairing.pair(code, phoneName: "Test iPhone", appVersion: "1.0", connector: connector, store: store)
        XCTAssertEqual(paired.id, pc.desktopId)
        XCTAssertEqual(paired.lastAddress, "127.0.0.1")
        XCTAssertEqual(paired.addresses.first, "127.0.0.1")
        XCTAssertEqual(store.pcs, [paired])
        XCTAssertEqual(store.secret(for: pc.desktopId), pc.secret)
        XCTAssertNotNil(try secrets.load(for: pc.desktopId))
    }

    func testDeclinedIsNotKept() async throws {
        let (pc, store, connector, code, _) = try setUpPairing()
        pc.approves = false
        do {
            _ = try await Pairing.pair(code, phoneName: "Test iPhone", appVersion: "1.0", connector: connector, store: store)
            XCTFail("Expected a refusal")
        } catch {
            XCTAssertEqual(error as? PairingError, .refused("declined happened"))
        }
        XCTAssertTrue(store.pcs.isEmpty)
    }

    func testAnUnsavableSecretMakesThePcForgetThePhone() async throws {
        let (pc, store, connector, code, secrets) = try setUpPairing()
        secrets.failsSaves = true
        do {
            _ = try await Pairing.pair(code, phoneName: "Test iPhone", appVersion: "1.0", connector: connector, store: store)
            XCTFail("Expected the pairing to fail")
        } catch {
            XCTAssertEqual(error as? PairingError, .notKept)
        }
        XCTAssertTrue(store.pcs.isEmpty)
        XCTAssertFalse(pc.knowsPhone)
    }

    func testWrongKeyInTheCodeIsUnreachable() async throws {
        let (_, store, connector, _, _) = try setUpPairing()
        let other = Base64Url.encode(SpkiFingerprint.of(try TestServer.fixture("test-other", "der"))!)
        let pc = try FakePc()
        let text = "lazysend://pair?v=1&id=x1234567&n=x&fp=\(other)&a=127.0.0.1&p=\(pc.server.port)&t=\(pc.token)"
        do {
            _ = try await Pairing.pair(try PairingCode.parse(text), phoneName: "p", appVersion: "1", connector: connector, store: store)
            XCTFail("Expected the pairing to fail")
        } catch {
            XCTAssertEqual(error as? PairingError, .unreachable)
        }
    }
}

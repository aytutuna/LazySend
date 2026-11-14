import Foundation
import XCTest
@testable import LazySendKit
@testable import LazySendServer

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

final class DigitLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    func add(_ item: String) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

// A computer pairing with the real server as a guest: by the short code its screen shows, and by its link.
final class CodePairingLinkTests: XCTestCase {
    private var harness: Harness!
    private var store: PcStore!
    private var connector: PcConnector!
    private let guestId = "guest-computer-0001"

    override func setUp() async throws {
        harness = try await Harness()
        store = PcStore(file: harness.root.appendingPathComponent("guest/hosts.json"), secrets: MemorySecrets(), phoneId: guestId)
        let quiet = Discovery(announced: { _ in [:] }, subnets: { [] }, probe: { _, _ in [] })
        connector = PcConnector(store: store, discovery: quiet)
    }

    override func tearDown() async throws {
        await harness.tearDown()
    }

    private func nearby(addresses: [String] = ["10.255.255.1", "127.0.0.1"]) -> NearbyHost {
        NearbyHost(id: harness.service.devices.desktopId, name: "Test Mac", addresses: addresses, port: harness.port)
    }

    func testTheDigitsAreShownBeforeAnythingIsSentAndYesPairs() async throws {
        let asked = DigitLog()
        harness.service.router.approvePairingMatching = { _, match in
            asked.add(match)
            return true
        }
        _ = harness.service.openPairing(addresses: ["127.0.0.1"])
        let session = try XCTUnwrap(harness.service.pairing)
        let shown = DigitLog()
        let service = harness.service
        let pc = try await Pairing.pair(code: session.shortCodeText.lowercased(), with: nearby(), phoneName: "Guest Mac", appVersion: "1.0",
                                        platform: "mac", confirm: { digits in
            shown.add(digits)
            XCTAssertEqual(session.state(at: harness.clock.now), .open)
            XCTAssertEqual(session.failedAttempts, 0)
            XCTAssertTrue(asked.all.isEmpty)
            XCTAssertTrue(service.devices.devices.isEmpty)
            return true
        }, connector: connector, store: store)

        let expected = SpkiFingerprint.matchCode(harness.service.fingerprint, shortCode: session.shortCode)
        XCTAssertEqual(shown.all, [expected])
        XCTAssertEqual(asked.all, [expected])
        XCTAssertEqual(pc.id, harness.service.devices.desktopId)
        XCTAssertEqual(pc.port, harness.port)
        XCTAssertEqual(pc.lastAddress, "127.0.0.1")
        XCTAssertEqual(pc.pin, harness.service.fingerprint)
        XCTAssertEqual(store.pcs, [pc])
        XCTAssertNotNil(store.secret(for: pc.id))
        let device = try XCTUnwrap(harness.service.devices.devices.first)
        XCTAssertEqual(device.id, guestId)
        XCTAssertEqual(device.name, "Guest Mac")
        XCTAssertEqual(device.platform, "mac")
        let reach = await connector.connect(pc, search: false)
        XCTAssertEqual(reach.reached?.host, "127.0.0.1")
    }

    func testNoSendsNothingAndLeavesTheCodeUnused() async throws {
        let asked = DigitLog()
        harness.service.router.approvePairingMatching = { _, match in
            asked.add(match)
            return true
        }
        _ = harness.service.openPairing(addresses: ["127.0.0.1"])
        let session = try XCTUnwrap(harness.service.pairing)
        do {
            _ = try await Pairing.pair(code: session.shortCodeText, with: nearby(), phoneName: "Guest Mac", appVersion: "1.0",
                                       platform: "mac", confirm: { _ in false }, connector: connector, store: store)
            XCTFail("Expected the pairing to stop")
        } catch {
            XCTAssertEqual(error as? PairingError, .notConfirmed)
        }
        XCTAssertTrue(asked.all.isEmpty)
        XCTAssertEqual(session.state(at: harness.clock.now), .open)
        XCTAssertEqual(session.failedAttempts, 0)
        XCTAssertTrue(harness.service.devices.devices.isEmpty)
        XCTAssertTrue(store.pcs.isEmpty)

        // The same code still pairs once the user looks again and says yes.
        let pc = try await Pairing.pair(code: session.shortCodeText, with: nearby(), phoneName: "Guest Mac", appVersion: "1.0",
                                        platform: "mac", confirm: { _ in true }, connector: connector, store: store)
        XCTAssertEqual(store.pcs, [pc])
    }

    func testAHostThatDeclinesLeavesNothingKept() async throws {
        harness.service.router.approvePairingMatching = { _, _ in false }
        _ = harness.service.openPairing(addresses: ["127.0.0.1"])
        let session = try XCTUnwrap(harness.service.pairing)
        do {
            _ = try await Pairing.pair(code: session.shortCodeText, with: nearby(), phoneName: "Guest Mac", appVersion: "1.0",
                                       platform: "mac", confirm: { _ in true }, connector: connector, store: store)
            XCTFail("Expected a refusal")
        } catch {
            guard case .refused? = error as? PairingError else { return XCTFail("Unexpected \(error)") }
        }
        XCTAssertTrue(store.pcs.isEmpty)
        XCTAssertTrue(harness.service.devices.devices.isEmpty)
    }

    func testAWrongCodeIsRefusedByTheHost() async throws {
        _ = harness.service.openPairing(addresses: ["127.0.0.1"])
        let session = try XCTUnwrap(harness.service.pairing)
        let wrong = session.shortCode == "00000000" ? "11111111" : "00000000"
        do {
            _ = try await Pairing.pair(code: wrong, with: nearby(), phoneName: "Guest Mac", appVersion: "1.0",
                                       platform: "mac", confirm: { _ in true }, connector: connector, store: store)
            XCTFail("Expected a refusal")
        } catch {
            guard case .refused? = error as? PairingError else { return XCTFail("Unexpected \(error)") }
        }
        XCTAssertEqual(session.failedAttempts, 1)
        XCTAssertTrue(store.pcs.isEmpty)
    }

    func testATypoIsCaughtBeforeAnyConnection() async throws {
        do {
            _ = try await Pairing.pair(code: "ABC", with: nearby(), phoneName: "Guest Mac", appVersion: "1.0", platform: "mac",
                                       confirm: { _ in
                XCTFail("No digits for a typo")
                return true
            }, connector: connector, store: store)
            XCTFail("Expected a refusal")
        } catch {
            guard case .refused? = error as? PairingError else { return XCTFail("Unexpected \(error)") }
        }
    }

    func testAHostNobodyAnswersForIsUnreachable() async throws {
        _ = harness.service.openPairing(addresses: ["127.0.0.1"])
        let session = try XCTUnwrap(harness.service.pairing)
        do {
            _ = try await Pairing.pair(code: session.shortCodeText, with: nearby(addresses: []), phoneName: "Guest Mac", appVersion: "1.0",
                                       platform: "mac", confirm: { _ in true }, connector: connector, store: store)
            XCTFail("Expected the host to be unreachable")
        } catch {
            XCTAssertEqual(error as? PairingError, .unreachable)
        }
    }

    func testALinkPairsAsAMac() async throws {
        let asked = DigitLog()
        harness.service.router.approvePairingMatching = { _, match in
            asked.add(match)
            return true
        }
        let code = harness.service.openPairing(addresses: ["127.0.0.1"])
        let pc = try await Pairing.pair(try PairingCode.parse(code.uri), phoneName: "Guest Mac", appVersion: "1.0", platform: "mac",
                                        connector: connector, store: store)
        XCTAssertEqual(asked.all, [code.checkCode])
        XCTAssertEqual(store.pcs, [pc])
        XCTAssertEqual(harness.service.devices.devices.first?.platform, "mac")
        XCTAssertEqual(harness.service.devices.devices.first?.id, guestId)
    }
}

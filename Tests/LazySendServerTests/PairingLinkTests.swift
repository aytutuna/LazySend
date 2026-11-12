import Foundation
import XCTest
@testable import LazySendKit
@testable import LazySendServer

final class PairingLinkTests: XCTestCase {
    private var harness: Harness!

    override func setUp() async throws {
        harness = try await Harness()
    }

    override func tearDown() async throws {
        await harness.tearDown()
    }

    func testApprovedPairingGivesTheSecretAndAuthenticatesTheNextCalls() async throws {
        let phone = try await harness.pair(name: "Aytu's iPhone")
        XCTAssertFalse(phone.secret.isEmpty)
        let hello = try await phone.client.hello()
        XCTAssertEqual(hello.desktopName, "Test Mac")
        XCTAssertEqual(hello.desktopId, harness.service.devices.desktopId)
        XCTAssertEqual(hello.maxChunkBytes, 64 * 1024 * 1024)
        let health = try await phone.client.health()
        XCTAssertEqual(health.service, "lazysend")
        XCTAssertEqual(health.paired, true)
        let device = try XCTUnwrap(harness.service.devices.devices.first)
        XCTAssertEqual(device.name, "Aytu's iPhone")
        XCTAssertEqual(device.platform, "ios")
    }

    func testOnlyTheHashOfTheSecretIsStored() async throws {
        let phone = try await harness.pair()
        let text = try String(contentsOf: harness.paths.devicesFile, encoding: .utf8)
        XCTAssertFalse(text.contains(phone.secret))
        let device = try XCTUnwrap(harness.service.devices.devices.first)
        XCTAssertEqual(device.secretHash.count, 64)
    }

    func testHelloListsTheComputersAddressesAsTheyAreNow() async throws {
        let phone = try await harness.pair()
        harness.service.router.addresses = { ["192.168.1.5", "172.20.10.2"] }
        let hello = try await phone.client.hello()
        XCTAssertEqual(hello.addresses, ["192.168.1.5", "172.20.10.2"])
    }

    func testHealthWithoutCredentialsSaysNotPaired() async throws {
        let health = try await LinkClient(endpoint: harness.endpoint, pin: harness.service.fingerprint).health()
        XCTAssertEqual(health.service, "lazysend")
        XCTAssertEqual(health.paired, false)
    }

    func testDeclinedPairingStoresNothing() async throws {
        harness.service.router.approvePairing = { _ in false }
        let code = harness.service.openPairing(addresses: ["127.0.0.1"])
        let client = LinkClient(endpoint: harness.endpoint, pin: harness.service.fingerprint)
        await expectRefused(403, "declined") {
            _ = try await client.pair(token: code.token, phoneId: newId(), phoneName: "Phone", appVersion: "1")
        }
        XCTAssertTrue(harness.service.devices.devices.isEmpty)
    }

    func testNoAnswerWithinTheTimeoutDeclines() async throws {
        harness.service.router.approvalTimeout = 0.3
        harness.service.router.approvePairing = { _ in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            return true
        }
        let code = harness.service.openPairing(addresses: ["127.0.0.1"])
        let client = LinkClient(endpoint: harness.endpoint, pin: harness.service.fingerprint)
        let started = Date()
        await expectRefused(403, "declined") {
            _ = try await client.pair(token: code.token, phoneId: newId(), phoneName: "Phone", appVersion: "1")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertTrue(harness.service.devices.devices.isEmpty)
    }

    func testWrongTokenIsRefusedAndTheRightOneStillWorks() async throws {
        let code = harness.service.openPairing(addresses: ["127.0.0.1"])
        let client = LinkClient(endpoint: harness.endpoint, pin: harness.service.fingerprint)
        let wrong = Base64Url.encode(Data(repeating: 9, count: 16))
        await expectRefused(403, "tokenInvalid") {
            _ = try await client.pair(token: wrong, phoneId: newId(), phoneName: "Phone", appVersion: "1")
        }
        let answer = try await client.pair(token: code.token, phoneId: newId(), phoneName: "Phone", appVersion: "1")
        XCTAssertFalse(answer.deviceSecret.isEmpty)
    }

    func testExpiredTokenIsRefused() async throws {
        let code = harness.service.openPairing(addresses: ["127.0.0.1"])
        harness.clock.now = harness.clock.now.addingTimeInterval(PairingSession.lifetime + 1)
        let client = LinkClient(endpoint: harness.endpoint, pin: harness.service.fingerprint)
        // The service closes a session that is no longer open, so the answer is pairingClosed.
        await expectRefused(403, "pairingClosed") {
            _ = try await client.pair(token: code.token, phoneId: newId(), phoneName: "Phone", appVersion: "1")
        }
    }

    func testTokenWorksOnce() async throws {
        let code = harness.service.openPairing(addresses: ["127.0.0.1"])
        let client = LinkClient(endpoint: harness.endpoint, pin: harness.service.fingerprint)
        _ = try await client.pair(token: code.token, phoneId: newId(), phoneName: "One", appVersion: "1")
        await expectRefused(403, "pairingClosed") {
            _ = try await client.pair(token: code.token, phoneId: newId(), phoneName: "Two", appVersion: "1")
        }
        XCTAssertEqual(harness.service.devices.devices.count, 1)
    }

    func testPairingNeedsAnOpenSession() async throws {
        let client = LinkClient(endpoint: harness.endpoint, pin: harness.service.fingerprint)
        await expectRefused(403, "pairingClosed") {
            _ = try await client.pair(token: Base64Url.encode(Data(repeating: 1, count: 16)), phoneId: newId(), phoneName: "Phone", appVersion: "1")
        }
        let code = harness.service.openPairing(addresses: ["127.0.0.1"])
        harness.service.closePairing()
        await expectRefused(403, "pairingClosed") {
            _ = try await client.pair(token: code.token, phoneId: newId(), phoneName: "Phone", appVersion: "1")
        }
    }

    func testAnotherCertificateIsNotTrusted() async throws {
        let other = try XCTUnwrap(SpkiFingerprint.of(try Harness.fixture("test-other", "der")))
        let client = LinkClient(endpoint: harness.endpoint, pin: other)
        do {
            _ = try await client.health()
            XCTFail("The pin should not match")
        } catch {
            XCTAssertNotNil(error as? LinkError)
        }
    }

    func testCallsNeedAPairedPhone() async throws {
        let phone = try await harness.pair()
        let stranger = LinkClient(endpoint: harness.endpoint, pin: harness.service.fingerprint,
                                  credentials: Credentials(deviceId: newId(), secret: phone.secret))
        await expectRefused(401, "unauthorized") { _ = try await stranger.hello() }
        let wrong = LinkClient(endpoint: harness.endpoint, pin: harness.service.fingerprint,
                               credentials: Credentials(deviceId: phone.id, secret: Base64Url.encode(Data(repeating: 3, count: 32))))
        await expectRefused(401, "unauthorized") { _ = try await wrong.hello() }
        await expectRefused(401, "unauthorized") { _ = try await wrong.health() }
        let bare = try await phone.raw("GET", "/v1/outbox?wait=0", authenticated: false)
        XCTAssertEqual(bare.status, 401)
        XCTAssertEqual(bare.header("WWW-Authenticate"), "Bearer")
    }

    func testRemovingSelfForgetsThePhoneAndWhatWaitsForIt() async throws {
        let phone = try await harness.pair()
        try harness.service.outbox.queueText(phone.id, "waiting")
        let partial = try await phone.beginFile("half.bin", bytes(5000))
        try await phone.client.forgetSelf()
        XCTAssertTrue(harness.service.devices.devices.isEmpty)
        XCTAssertTrue(harness.service.outbox.pending(phone.id).isEmpty)
        XCTAssertNil(harness.service.inbox.state(phone.id, partial.id))
        await expectRefused(401, "unauthorized") { _ = try await phone.client.hello() }
    }

    func testPairingAgainWithTheSamePhoneIdReplacesTheSecret() async throws {
        let id = newId()
        let first = try await harness.pair(id: id)
        let second = try await harness.pair(id: id)
        XCTAssertNotEqual(first.secret, second.secret)
        XCTAssertEqual(harness.service.devices.devices.count, 1)
        await expectRefused(401, "unauthorized") { _ = try await first.client.hello() }
        _ = try await second.client.hello()
    }

    func testASeventeenthPhoneIsRefused() async throws {
        for index in 0..<16 { _ = try await harness.pair(name: "Phone \(index)") }
        let code = harness.service.openPairing(addresses: ["127.0.0.1"])
        let client = LinkClient(endpoint: harness.endpoint, pin: harness.service.fingerprint)
        await expectRefused(409, "tooManyDevices") {
            _ = try await client.pair(token: code.token, phoneId: newId(), phoneName: "One more", appVersion: "1")
        }
    }

    func testPairedPhoneSurvivesARestart() async throws {
        let phone = try await harness.pair()
        let desktopId = harness.service.devices.desktopId
        try await harness.restart()
        let hello = try await phone.client.hello()
        XCTAssertEqual(hello.desktopId, desktopId)
    }

    func testTooManyFailuresBlockThePeer() async throws {
        let phone = try await harness.pair()
        let wrong = LinkClient(endpoint: harness.endpoint, pin: harness.service.fingerprint,
                               credentials: Credentials(deviceId: phone.id, secret: Base64Url.encode(Data(repeating: 3, count: 32))))
        for _ in 0..<LinkRateLimiter.maxFailures {
            await expectRefused(401, "unauthorized") { _ = try await wrong.hello() }
        }
        do {
            _ = try await phone.client.hello()
            XCTFail("The address should be blocked")
        } catch {
            XCTAssertNotNil(error as? LinkError)
        }
    }

    func testPairingCodeCarriesWhatThePhoneNeeds() async throws {
        let code = harness.service.openPairing(addresses: ["192.168.1.5", "172.20.10.2"])
        let parsed = try PairingCode.parse(code.uri)
        XCTAssertEqual(parsed.desktopId, harness.service.devices.desktopId)
        XCTAssertEqual(parsed.name, "Test Mac")
        XCTAssertEqual(parsed.addresses, ["192.168.1.5", "172.20.10.2"])
        XCTAssertEqual(parsed.port, harness.port)
        XCTAssertEqual(parsed.pin, harness.service.fingerprint)
        XCTAssertEqual(parsed.token, code.token)
    }
}

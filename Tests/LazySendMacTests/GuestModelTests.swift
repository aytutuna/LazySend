#if os(macOS)
import AppKit
import XCTest
@testable import LazySendKit
@testable import LazySendMac
@testable import LazySendServer

private final class MemorySecrets: SecretStore, @unchecked Sendable {
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

/// This Mac's model as a guest, and another computer's service as the host it connects to.
@MainActor
final class GuestModelFixture {
    let root: URL
    let host: LinkService
    let own: LinkService
    let guest: GuestService
    let model: AppModel
    let port: Int

    init() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lazysend-guest-" + UUID().uuidString, isDirectory: true)
        let identity = try ModelFixture.identity()
        let host = try LinkService(paths: SendPaths(root: root.appendingPathComponent("host-state"), defaultReceiveRoot: root.appendingPathComponent("host-received")),
                                   identity: identity)
        host.router.desktopName = { "Studio Mac" }
        host.router.approvePairingMatching = { _, _ in true }
        let port = try await host.start(port: 0)
        let paths = SendPaths(root: root.appendingPathComponent("state"), defaultReceiveRoot: root.appendingPathComponent("received"))
        let own = try LinkService(paths: paths, identity: identity)
        let hosts = PcStore(file: paths.root.appendingPathComponent("hosts.json"), secrets: MemorySecrets(), phoneId: own.devices.desktopId)
        let quiet = Discovery(announced: { _ in [:] }, subnets: { [] }, probe: { _, _ in [] })
        let guest = GuestService(hosts: hosts, connector: PcConnector(store: hosts, discovery: quiet), history: own.history, settings: own.settings,
                                 guestName: "Test Mac", appVersion: "1.0", firstRetry: 0.2, lastRetry: 0.5)
        self.root = root
        self.host = host
        self.port = port
        self.own = own
        self.guest = guest
        model = AppModel(service: own, guest: guest, pasteboard: NSPasteboard(name: NSPasteboard.Name("lazysend-test-" + UUID().uuidString)),
                         scratch: root.appendingPathComponent("scratch"))
    }

    var nearby: NearbyHost {
        NearbyHost(id: host.devices.desktopId, name: "Studio Mac", addresses: ["127.0.0.1"], port: port)
    }

    func connecting(find: [NearbyHost]? = nil) -> ConnectModel {
        let list = find ?? [nearby]
        return ConnectModel(guest: guest, ownId: own.devices.desktopId, find: { list })
    }

    /// Pairs by link and waits until the model lists the computer.
    @discardableResult
    func pairByLink() async throws -> PairedPc {
        let code = host.openPairing(addresses: ["127.0.0.1"])
        let pc = try await guest.pair(try PairingCode.parse(code.uri))
        await assertEventually { self.model.phones.contains { $0.id == pc.id } }
        return pc
    }

    func file(_ name: String, bytes: Int = 1000) throws -> URL {
        let folder = root.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data(count: bytes).write(to: url)
        return url
    }

    func tearDown() async {
        await model.stop()
        await host.stop()
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
final class GuestModelTests: XCTestCase {
    private var fixture: GuestModelFixture!
    private var model: AppModel { fixture.model }

    override func setUp() async throws {
        fixture = try await GuestModelFixture()
    }

    override func tearDown() async throws {
        await fixture.tearDown()
    }

    func testAPastedLinkConnectsAndSelectsTheComputer() async throws {
        model.beginConnecting()
        let connecting = try XCTUnwrap(model.connecting)
        let code = fixture.host.openPairing(addresses: ["127.0.0.1"])
        connecting.input = code.uri
        connecting.connect()
        XCTAssertEqual(connecting.step, .waiting(digits: code.checkCode))
        await assertEventually { connecting.step == .connected("Studio Mac") }
        await assertEventually { model.phones.count == 1 }
        let row = try XCTUnwrap(model.phones.first)
        XCTAssertTrue(row.computer)
        XCTAssertEqual(row.name, "Studio Mac")
        XCTAssertEqual(model.selectedPhoneId, row.id)
        XCTAssertEqual(model.targetTitle, "Send to Studio Mac")
        XCTAssertEqual(fixture.host.devices.devices.first?.platform, "mac")
        XCTAssertEqual(fixture.host.devices.devices.first?.id, fixture.own.devices.desktopId)
        model.closeConnecting()
        XCTAssertNil(model.connecting)
    }

    func testABadLinkIsReportedAndNothingStarts() async throws {
        let connecting = fixture.connecting()
        connecting.input = "lazysend://pair?v=1&id=x"
        connecting.connect()
        XCTAssertEqual(connecting.step, .entering)
        XCTAssertFalse(connecting.message.isEmpty)
        connecting.input = "lazysend:open?file=x"
        connecting.connect()
        XCTAssertTrue(connecting.message.hasPrefix("This pairing code could not be read"), connecting.message)
    }

    func testTheNearbyListLeavesOutThisMacAndPicksTheOnlyOne() async throws {
        let own = NearbyHost(id: fixture.own.devices.desktopId, name: "This Mac", addresses: ["127.0.0.1"], port: 1)
        let odd = NearbyHost(id: "x", name: "Bad id", addresses: [], port: 1)
        let connecting = fixture.connecting(find: [own, fixture.nearby, odd])
        await connecting.look()
        XCTAssertEqual(connecting.nearby, [fixture.nearby])
        XCTAssertEqual(connecting.selected, fixture.nearby.id)
        XCTAssertFalse(connecting.looking)
    }

    func testACodeNeedsAComputerAndEightCharacters() async throws {
        let connecting = fixture.connecting()
        connecting.input = "7KQ2-M9XD"
        connecting.connect()
        XCTAssertEqual(connecting.message, "Choose the computer above, or paste its link.")
        await connecting.look()
        connecting.input = "7KQ2"
        connecting.connect()
        XCTAssertEqual(connecting.message, "The code is 8 letters and digits, like 7KQ2-M9XD.")
        XCTAssertEqual(connecting.step, .entering)
    }

    func testTheCodeIsSentOnlyAfterTheUserSaysTheDigitsMatch() async throws {
        let asked = Asked()
        fixture.host.router.approvePairingMatching = { _, match in
            asked.add(match)
            return true
        }
        _ = fixture.host.openPairing(addresses: ["127.0.0.1"])
        let session = try XCTUnwrap(fixture.host.pairing)
        let expected = SpkiFingerprint.matchCode(fixture.host.fingerprint, shortCode: session.shortCode)
        let connecting = fixture.connecting()
        await connecting.look()
        connecting.input = session.shortCodeText
        connecting.connect()
        await assertEventually { connecting.step == .comparing(expected) }
        XCTAssertTrue(asked.all.isEmpty)
        XCTAssertTrue(fixture.host.devices.devices.isEmpty)

        connecting.answer(matches: false)
        await assertEventually { connecting.step == .entering && !connecting.message.isEmpty }
        XCTAssertEqual(connecting.message, "Cancelled: the digits did not match, so nothing was sent.")
        XCTAssertTrue(asked.all.isEmpty)
        XCTAssertEqual(session.failedAttempts, 0)
        XCTAssertEqual(session.state(at: Date()), .open)
        XCTAssertTrue(fixture.guest.hosts.pcs.isEmpty)

        connecting.connect()
        await assertEventually { connecting.step == .comparing(expected) }
        connecting.answer(matches: true)
        XCTAssertEqual(connecting.step, .waiting(digits: expected))
        await assertEventually { connecting.step == .connected("Studio Mac") }
        XCTAssertEqual(asked.all, [expected])
        XCTAssertEqual(fixture.guest.hosts.pcs.map(\.name), ["Studio Mac"])
    }

    func testGivingUpWhileComparingSendsNothing() async throws {
        _ = fixture.host.openPairing(addresses: ["127.0.0.1"])
        let session = try XCTUnwrap(fixture.host.pairing)
        let connecting = fixture.connecting()
        await connecting.look()
        connecting.input = session.shortCodeText
        connecting.connect()
        await assertEventually {
            if case .comparing = connecting.step { return true }
            return false
        }
        connecting.cancel()
        await assertEventually { connecting.step == .entering }
        XCTAssertEqual(session.failedAttempts, 0)
        XCTAssertTrue(fixture.guest.hosts.pcs.isEmpty)
    }

    func testTextAndFilesGoToTheSelectedComputerAndTheRowsSayHowItWent() async throws {
        let pc = try await fixture.pairByLink()
        XCTAssertEqual(model.selectedPhoneId, pc.id)
        XCTAssertTrue(model.sendText("hello studio"))
        let row = try XCTUnwrap(model.timeline.first)
        XCTAssertEqual(row.heading, "Text to Studio Mac")
        await assertEventually { model.timeline.first?.canCancel == false }
        XCTAssertTrue(model.timeline.first?.detail.hasPrefix("Sent to Studio Mac") == true, model.timeline.first?.detail ?? "")
        XCTAssertEqual(fixture.host.history.items.first?.text, "hello studio")

        XCTAssertTrue(model.sendText("https://example.com/a"))
        XCTAssertEqual(model.timeline.first?.heading, "Link to Studio Mac")
        await assertEventually { model.timeline.first?.canCancel == false }
        XCTAssertEqual(fixture.host.history.items.first?.url, "https://example.com/a")

        XCTAssertEqual(model.sendFiles([try fixture.file("notes.txt", bytes: 5000)]), 1)
        await assertEventually { model.timeline.first?.canCancel == false }
        let landed = fixture.root.appendingPathComponent("host-received/Test Mac/notes.txt")
        XCTAssertEqual(try Data(contentsOf: landed).count, 5000)
        XCTAssertTrue(model.timeline.first?.detail.contains("Sent to Studio Mac") == true)
        XCTAssertNil(model.notice)
    }

    func testFoldersAreRefusedForAComputerToo() async throws {
        try await fixture.pairByLink()
        _ = try fixture.file("inside.txt")
        XCTAssertEqual(model.sendFiles([fixture.root.appendingPathComponent("files", isDirectory: true)]), 0)
        XCTAssertEqual(model.notice, "Folders cannot be sent yet. Send the files in them, or zip the folder first.")
        XCTAssertTrue(model.timeline.isEmpty)
    }

    func testASendCanBeCancelledBeforeItStarts() async throws {
        try await fixture.pairByLink()
        let one = try fixture.file("one.bin", bytes: 20_000_000)
        let two = try fixture.file("two.bin", bytes: 20_000_000)
        let three = try fixture.file("three.bin", bytes: 1000)
        XCTAssertEqual(model.sendFiles([one, two, three]), 3)
        let last = try XCTUnwrap(model.timeline.first)
        XCTAssertEqual(last.heading, "three.bin")
        model.cancel(last)
        XCTAssertFalse(model.timeline.first?.canCancel ?? true)
        XCTAssertTrue(model.timeline.first?.detail.contains("Cancelled") == true)
        await assertEventually { model.timeline.allSatisfy { !$0.canCancel } }
        XCTAssertTrue(model.timeline.first?.detail.contains("Cancelled") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("host-received/Test Mac/three.bin").path))
    }

    func testWhatTheComputerSendsLandsInTheTimelineLikeWhatAPhoneSends() async throws {
        let pc = try await fixture.pairByLink()
        model.start()
        let own = fixture.own.devices.desktopId
        _ = try fixture.host.outbox.queueText(own, "hello mac")
        await assertEventually { model.timeline.first?.heading == "Text from Studio Mac" }
        XCTAssertEqual(model.timeline.first?.text, "hello mac")
        XCTAssertEqual(model.timeline.first?.deviceId, pc.id)
        await assertEventually { model.phones.first?.lastSeen == "Connected" }

        let url = try fixture.file("from-host.txt", bytes: 3000)
        _ = fixture.host.outbox.queueFiles(own, [(url: url, bookmark: nil, mime: "text/plain")])
        await assertEventually { model.timeline.first?.heading == "from-host.txt" }
        let row = try XCTUnwrap(model.timeline.first)
        XCTAssertTrue(row.detail.contains("from Studio Mac"))
        XCTAssertEqual(row.fileURL?.deletingLastPathComponent().lastPathComponent, "Studio Mac")
        XCTAssertTrue(row.canShowInFinder)
    }

    func testRemovingAComputerForgetsItOnBothSides() async throws {
        let pc = try await fixture.pairByLink()
        model.remove(phone: pc.id)
        await assertEventually { model.phones.isEmpty }
        XCTAssertTrue(fixture.host.devices.devices.isEmpty)
        XCTAssertNil(model.selectedPhoneId)
    }

    func testAComputerThatDroppedThisMacIsRemovedWithANotice() async throws {
        let pc = try await fixture.pairByLink()
        fixture.host.devices.remove(fixture.own.devices.desktopId)
        model.start()
        await assertEventually { model.phones.isEmpty && model.notice != nil }
        XCTAssertEqual(model.notice, "\(pc.name) no longer recognizes this Mac. Connect to it again to send to it.")
    }

    func testPhonesAndComputersShareTheDeviceList() async throws {
        let phoneId = newId()
        _ = try fixture.own.devices.pair(id: phoneId, name: "Pixel", platform: "android", appVersion: "1", now: Date())
        let pc = try await fixture.pairByLink()
        await assertEventually { model.phones.count == 2 }
        XCTAssertEqual(model.phones.map(\.computer), [false, true])
        XCTAssertEqual(model.selectedPhoneId, phoneId)
        model.selectedPhoneId = pc.id
        XCTAssertEqual(model.targetTitle, "Send to Studio Mac")
    }

    func testTheDiscoveryRecordCarriesTheCutNameAndLeavesItOutWhenEmpty() {
        func entries(_ record: [UInt8]) -> [String] {
            var out: [String] = []
            var index = 0
            while index < record.count {
                let length = Int(record[index])
                out.append(String(decoding: record[(index + 1)..<(index + 1 + length)], as: UTF8.self))
                index += 1 + length
            }
            return out
        }
        let plain = entries(Advertiser.txtRecord(desktopId: "0123456789abcdef", name: "Aytu's Mac"))
        XCTAssertEqual(plain, ["v=1", "id=0123456789abcdef", "n=Aytu's Mac"])
        XCTAssertEqual(entries(Advertiser.txtRecord(desktopId: "0123456789abcdef", name: " \n ")), ["v=1", "id=0123456789abcdef"])
        let long = entries(Advertiser.txtRecord(desktopId: "0123456789abcdef", name: String(repeating: "é", count: 60)))
        XCTAssertEqual(long.last?.dropFirst(2).utf8.count, 64)
    }
}

private final class Asked: @unchecked Sendable {
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
#endif

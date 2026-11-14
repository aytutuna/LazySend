import Foundation
import XCTest
@testable import LazySendKit
@testable import LazySendServer

private final class Events<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []

    func add(_ item: T) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }

    var all: [T] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

// The computer side of a guest on its own folders, as the Mac app builds it, talking to the real server.
private final class GuestFixture {
    let paths: SendPaths
    let secrets = MemorySecrets()
    let hosts: PcStore
    let settings: SendSettings
    let guest: GuestService
    let texts = Events<ReceivedItem>()
    let files = Events<ReceivedFile>()
    let failures = Events<String>()
    let forgotten = Events<String>()
    let changes = Events<Void>()

    var received: URL { paths.defaultReceiveRoot }

    init(root: URL, guestId: String) {
        paths = SendPaths(root: root.appendingPathComponent("guest-state"), defaultReceiveRoot: root.appendingPathComponent("guest-received"))
        hosts = PcStore(file: paths.root.appendingPathComponent("hosts.json"), secrets: secrets, phoneId: guestId)
        settings = SendSettings(paths: paths)
        let quiet = Discovery(announced: { _ in [:] }, subnets: { [] }, probe: { _, _ in [] })
        guest = GuestService(hosts: hosts, connector: PcConnector(store: hosts, discovery: quiet), history: ReceivedHistory(url: paths.historyFile),
                             settings: settings, guestName: "Guest Mac", appVersion: "1.0", firstRetry: 0.2, lastRetry: 0.5)
        let texts = self.texts, files = self.files, failures = self.failures, forgotten = self.forgotten, changes = self.changes
        guest.onTextReceived = { texts.add($0) }
        guest.onFileReceived = { files.add($0) }
        guest.onFailed = { failures.add($0) }
        guest.onForgotten = { forgotten.add($0) }
        guest.onChange = { changes.add(()) }
    }
}

final class GuestServiceTests: XCTestCase {
    private var harness: Harness!
    private var fixture: GuestFixture!
    private let guestId = "guest-computer-0002"

    private var outbox: Outbox { harness.service.outbox }
    private var hostFolder: URL { fixture.received.appendingPathComponent("Test Mac", isDirectory: true) }

    override func setUp() async throws {
        harness = try await Harness()
        fixture = GuestFixture(root: harness.root, guestId: guestId)
    }

    override func tearDown() async throws {
        fixture.guest.stop()
        await harness.tearDown()
    }

    private func pairGuest() async throws -> PairedPc {
        let code = harness.service.openPairing(addresses: ["127.0.0.1"])
        return try await fixture.guest.pair(try PairingCode.parse(code.uri))
    }

    private func queueFile(_ name: String, _ content: Data) throws -> OutboxItem {
        let folder = harness.root.appendingPathComponent("outgoing", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try content.write(to: url)
        return try XCTUnwrap(outbox.queueFiles(guestId, [(url: url, bookmark: nil, mime: nil)]).first)
    }

    private func quarantined(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0) > 0
    }

    func testPairingListsTheHostAndTellsTheApp() async throws {
        let pc = try await pairGuest()
        XCTAssertEqual(fixture.hosts.pcs, [pc])
        XCTAssertEqual(pc.name, "Test Mac")
        XCTAssertFalse(fixture.changes.all.isEmpty)
        XCTAssertEqual(harness.service.devices.devices.first?.id, guestId)
    }

    func testTextAndLinksGoToTheHostLikeThoseOfAPhone() async throws {
        let pc = try await pairGuest()
        try await fixture.guest.send(try ItemRequest.note("hello there"), to: pc.id)
        try await fixture.guest.send(try ItemRequest.note("https://example.com/page"), to: pc.id)
        let items = harness.service.history.items
        XCTAssertEqual(items.map(\.kind), ["link", "text"])
        XCTAssertEqual(items[0].url, "https://example.com/page")
        XCTAssertEqual(items[1].text, "hello there")
        XCTAssertEqual(items[1].deviceId, guestId)
        XCTAssertEqual(items[1].deviceName, "Guest Mac")
    }

    func testAFileGoesUpInChunksAndLandsInTheHostsFolderForThisComputer() async throws {
        let pc = try await pairGuest()
        let content = bytes(9_500_000)
        let url = harness.root.appendingPathComponent("payload.bin")
        try content.write(to: url)
        let progress = Events<Int64>()
        try await fixture.guest.sendFile(at: url, to: pc.id, onProgress: { progress.add($0) })
        let landed = harness.received.appendingPathComponent("Guest Mac/payload.bin")
        XCTAssertEqual(try Data(contentsOf: landed), content)
        XCTAssertEqual(progress.all.last, Int64(content.count))
        XCTAssertGreaterThanOrEqual(progress.all.count, 3)
    }

    func testAnEmptyFileIsSentToo() async throws {
        let pc = try await pairGuest()
        let url = harness.root.appendingPathComponent("empty.txt")
        try Data().write(to: url)
        try await fixture.guest.sendFile(at: url, to: pc.id)
        let landed = harness.received.appendingPathComponent("Guest Mac/empty.txt")
        XCTAssertEqual(try Data(contentsOf: landed).count, 0)
    }

    func testTextAndLinksFromTheHostGoIntoTheHistoryUnderTheirOwnIds() async throws {
        let pc = try await pairGuest()
        fixture.guest.start()
        let text = try outbox.queueText(guestId, "from the host")
        let link = try outbox.queueLink(guestId, "https://example.com/x")
        let arrived = await waitUntil { fixture.texts.all.count == 2 }
        XCTAssertTrue(arrived)
        let received = fixture.texts.all
        XCTAssertEqual(Set(received.map(\.id)), [text.id, link.id])
        XCTAssertEqual(received.first { $0.id == text.id }?.text, "from the host")
        XCTAssertEqual(received.first { $0.id == link.id }?.url, "https://example.com/x")
        XCTAssertEqual(received.first?.deviceName, "Test Mac")
        XCTAssertEqual(received.first?.deviceId, pc.id)
        let acknowledged = await waitUntil { outbox.pending(guestId).isEmpty }
        XCTAssertTrue(acknowledged)
        XCTAssertEqual(Set(fixture.guestHistory.map(\.id)), [text.id, link.id])
        let reachable = await waitUntil { fixture.guest.isReachable(pc.id) }
        XCTAssertTrue(reachable)
    }

    func testAFileFromTheHostIsMarkedAsDownloadedAndNamedAfterTheHost() async throws {
        _ = try await pairGuest()
        let content = bytes(700_000)
        _ = try queueFile("report.pdf", content)
        fixture.guest.start()
        let arrived = await waitUntil { !fixture.files.all.isEmpty }
        XCTAssertTrue(arrived)
        let file = try XCTUnwrap(fixture.files.all.first)
        XCTAssertEqual(file.url, hostFolder.appendingPathComponent("report.pdf"))
        XCTAssertEqual(file.deviceName, "Test Mac")
        XCTAssertEqual(file.size, Int64(content.count))
        XCTAssertEqual(try Data(contentsOf: file.url), content)
#if os(macOS)
        XCTAssertTrue(quarantined(file.url))
#endif
        let acknowledged = await waitUntil { outbox.pending(guestId).isEmpty }
        XCTAssertTrue(acknowledged)
        let names = try FileManager.default.contentsOfDirectory(atPath: hostFolder.path)
        XCTAssertEqual(names, ["report.pdf"])
    }

    func testAnEmptyFileFromTheHostArrives() async throws {
        _ = try await pairGuest()
        _ = try queueFile("nothing.txt", Data())
        fixture.guest.start()
        let arrived = await waitUntil { !fixture.files.all.isEmpty }
        XCTAssertTrue(arrived)
        let file = try XCTUnwrap(fixture.files.all.first)
        XCTAssertEqual(file.size, 0)
        XCTAssertEqual(try Data(contentsOf: file.url).count, 0)
    }

    func testADownloadThatWasCutContinuesWhereItStopped() async throws {
        _ = try await pairGuest()
        let content = bytes(400_000)
        let item = try queueFile("big.bin", content)
        try FileManager.default.createDirectory(at: hostFolder, withIntermediateDirectories: true)
        // What an earlier try left is not the file's own start, so the bytes show whether the rest was asked for or all of it again.
        let half = 150_000
        let left = Data(repeating: 0xEE, count: half)
        try left.write(to: hostFolder.appendingPathComponent(item.id + ".part"))
        fixture.guest.start()
        let arrived = await waitUntil { !fixture.files.all.isEmpty }
        XCTAssertTrue(arrived)
        let result = try Data(contentsOf: hostFolder.appendingPathComponent("big.bin"))
        XCTAssertEqual(result.count, content.count)
        XCTAssertEqual(result.prefix(half), left)
        XCTAssertEqual(result.suffix(from: half), content.suffix(from: half))
    }

    func testAPartFileLongerThanTheItemStartsAgain() async throws {
        _ = try await pairGuest()
        let content = bytes(1000)
        let item = try queueFile("small.bin", content)
        try FileManager.default.createDirectory(at: hostFolder, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 5000).write(to: hostFolder.appendingPathComponent(item.id + ".part"))
        fixture.guest.start()
        let arrived = await waitUntil { !fixture.files.all.isEmpty }
        XCTAssertTrue(arrived)
        XCTAssertEqual(try Data(contentsOf: hostFolder.appendingPathComponent("small.bin")), content)
    }

    func testAHostThatDroppedThisComputerIsForgottenHere() async throws {
        let pc = try await pairGuest()
        harness.service.devices.remove(guestId)
        fixture.guest.start()
        let dropped = await waitUntil { fixture.hosts.pcs.isEmpty }
        XCTAssertTrue(dropped)
        let told = await waitUntil { !fixture.forgotten.all.isEmpty }
        XCTAssertTrue(told)
        XCTAssertEqual(fixture.forgotten.all, [pc.name])
        XCTAssertNil(fixture.hosts.secret(for: pc.id))
    }

    func testSendingToAHostThatDroppedThisComputerForgetsItAndSaysSo() async throws {
        let pc = try await pairGuest()
        harness.service.devices.remove(guestId)
        do {
            try await fixture.guest.send(try ItemRequest.note("anyone there"), to: pc.id)
            XCTFail("Expected a refusal")
        } catch {
            XCTAssertEqual((error as? LinkError)?.status, 401)
        }
        XCTAssertTrue(fixture.hosts.pcs.isEmpty)
        XCTAssertEqual(fixture.forgotten.all, [pc.name])
    }

    func testASecretThatCannotBeReadDoesNotForgetTheHost() async throws {
        let pc = try await pairGuest()
        try fixture.secrets.delete(for: pc.id)
        fixture.guest.start()
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(fixture.hosts.pcs.count, 1)
        XCTAssertFalse(fixture.guest.isReachable(pc.id))
        XCTAssertTrue(fixture.forgotten.all.isEmpty)
        do {
            try await fixture.guest.send(try ItemRequest.note("hello"), to: pc.id)
            XCTFail("Expected the key to be unreadable")
        } catch {
            XCTAssertTrue(error is HostKeyUnreadable)
        }
        XCTAssertEqual(fixture.hosts.pcs.count, 1)
    }

    func testPairingAgainKeepsWatchingWithTheNewSecret() async throws {
        let first = try await pairGuest()
        fixture.guest.start()
        let reachable = await waitUntil { fixture.guest.isReachable(first.id) }
        XCTAssertTrue(reachable)
        let before = fixture.hosts.secret(for: first.id)
        let second = try await pairGuest()
        XCTAssertNotEqual(fixture.hosts.secret(for: second.id), before)
        _ = try outbox.queueText(guestId, "after the second pairing")
        let arrived = await waitUntil { !fixture.texts.all.isEmpty }
        XCTAssertTrue(arrived)
        // A watcher still polling with the old secret would be refused by now and would drop the new entry.
        try await Task.sleep(nanoseconds: 3_000_000_000)
        XCTAssertEqual(fixture.hosts.pcs.count, 1)
        XCTAssertTrue(fixture.forgotten.all.isEmpty)
        XCTAssertNotNil(fixture.hosts.secret(for: second.id))
    }

    func testAnUnusableReceiveFolderLeavesTheItemQueuedUntilItWorks() async throws {
        _ = try await pairGuest()
        let blocker = harness.root.appendingPathComponent("not-a-folder")
        try Data().write(to: blocker)
        fixture.settings.setReceiveRoot(blocker)
        _ = try queueFile("kept.txt", bytes(2000))
        fixture.guest.start()
        let told = await waitUntil { !fixture.failures.all.isEmpty }
        XCTAssertTrue(told)
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(outbox.pending(guestId).count, 1)
        XCTAssertTrue(fixture.files.all.isEmpty)
        XCTAssertEqual(fixture.failures.all.count, 1)
        fixture.settings.setReceiveRoot(nil)
        let arrived = await waitUntil { !fixture.files.all.isEmpty }
        XCTAssertTrue(arrived)
        let acknowledged = await waitUntil { outbox.pending(guestId).isEmpty }
        XCTAssertTrue(acknowledged)
    }

    func testAFinishedFileListedAgainIsOnlyAcknowledged() async throws {
        let pc = try await pairGuest()
        let receiver = GuestReceiver(hostId: pc.id, guest: fixture.guest)
        let item = OutboxEntry(id: "item-0001-abcdef", kind: "file", name: "a.txt", size: 3)
        let before = await receiver.isDone(item)
        XCTAssertFalse(before)
        let have = try await receiver.prepareFile(item)
        XCTAssertEqual(have, 0)
        try receiver.write(Data([1, 2, 3]), for: item)
        try await receiver.finishFile(item)
        let after = await receiver.isDone(item)
        XCTAssertTrue(after)
        XCTAssertEqual(fixture.files.all.count, 1)
    }

    func testRemovingAHostDeletesWhatItHadBegun() async throws {
        let pc = try await pairGuest()
        let receiver = GuestReceiver(hostId: pc.id, guest: fixture.guest)
        let item = OutboxEntry(id: "item-0002-abcdef", kind: "file", name: "b.txt", size: 10)
        _ = try await receiver.prepareFile(item)
        try receiver.write(Data([1, 2, 3]), for: item)
        let part = hostFolder.appendingPathComponent(item.id + ".part")
        XCTAssertTrue(FileManager.default.fileExists(atPath: part.path))
        receiver.discardParts()
        XCTAssertFalse(FileManager.default.fileExists(atPath: part.path))
    }

    func testOldPartFilesNoItemWillContinueAreCleanedWhenWatchingStarts() async throws {
        _ = try await pairGuest()
        try FileManager.default.createDirectory(at: hostFolder, withIntermediateDirectories: true)
        let stale = hostFolder.appendingPathComponent("stale-part-0001.part")
        let fresh = hostFolder.appendingPathComponent("fresh-part-0001.part")
        try Data([1]).write(to: stale)
        try Data([1]).write(to: fresh)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3 * 24 * 3600)], ofItemAtPath: stale.path)
        fixture.guest.start()
        let cleaned = await waitUntil { !FileManager.default.fileExists(atPath: stale.path) }
        XCTAssertTrue(cleaned)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }

    func testForgettingAHostTellsItAndDropsItHere() async throws {
        let pc = try await pairGuest()
        await fixture.guest.forget(pc.id)
        XCTAssertTrue(fixture.hosts.pcs.isEmpty)
        XCTAssertTrue(harness.service.devices.devices.isEmpty)
    }

    func testNoMoreThanSixteenComputersAreKept() async throws {
        for index in 0..<GuestService.maxHosts {
            let pc = PairedPc(id: String(format: "other-host-%04d", index), name: "Host \(index)",
                              fingerprint: Base64Url.encode(Data(repeating: 4, count: 32)), addresses: [], port: 1)
            try fixture.hosts.put(pc, secret: "secret")
        }
        let code = harness.service.openPairing(addresses: ["127.0.0.1"])
        do {
            _ = try await fixture.guest.pair(try PairingCode.parse(code.uri))
            XCTFail("Expected a refusal")
        } catch {
            guard case .refused? = error as? PairingError else { return XCTFail("Unexpected \(error)") }
        }
        XCTAssertTrue(harness.service.devices.devices.isEmpty)
    }
}

private extension GuestFixture {
    var guestHistory: [ReceivedItem] { guest.history.items }
}

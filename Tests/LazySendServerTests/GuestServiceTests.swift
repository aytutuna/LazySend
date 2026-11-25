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
    let secrets: MemorySecrets
    let hosts: PcStore
    let pending: PendingSends
    let settings: SendSettings
    let guest: GuestService
    let texts = Events<ReceivedItem>()
    let files = Events<ReceivedFile>()
    let failures = Events<String>()
    let forgotten = Events<String>()
    let changes = Events<Void>()
    let resumed = Events<ResumedSend>()

    var received: URL { paths.defaultReceiveRoot }

    init(root: URL, guestId: String, secrets: MemorySecrets = MemorySecrets()) {
        self.secrets = secrets
        paths = SendPaths(root: root.appendingPathComponent("guest-state"), defaultReceiveRoot: root.appendingPathComponent("guest-received"))
        hosts = PcStore(file: paths.root.appendingPathComponent("hosts.json"), secrets: secrets, phoneId: guestId)
        settings = SendSettings(paths: paths)
        pending = PendingSends(url: paths.root.appendingPathComponent("pending.json"))
        let quiet = Discovery(announced: { _ in [:] }, subnets: { [] }, probe: { _, _ in [] })
        guest = GuestService(hosts: hosts, connector: PcConnector(store: hosts, discovery: quiet), history: ReceivedHistory(url: paths.historyFile),
                             settings: settings, pending: pending, guestName: "Guest Mac", appVersion: "1.0", firstRetry: 0.2, lastRetry: 0.5)
        let texts = self.texts, files = self.files, failures = self.failures, forgotten = self.forgotten, changes = self.changes, resumed = self.resumed
        guest.onTextReceived = { texts.add($0) }
        guest.onFileReceived = { files.add($0) }
        guest.onFailed = { failures.add($0) }
        guest.onForgotten = { forgotten.add($0) }
        guest.onChange = { changes.add(()) }
        guest.onSendResumed = { resumed.add($0) }
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

    func testClipOfWhatTheHostQueuesIsCarriedIntoTheGuestsEvents() async throws {
        _ = try await pairGuest()
        try outbox.queueText(guestId, "plain")
        try outbox.queueText(guestId, "copy me", clip: true)
        let url = harness.root.appendingPathComponent("clip.bin")
        try bytes(2000).write(to: url)
        outbox.queueFiles(guestId, [(url: url, bookmark: nil, mime: nil)], clip: true)
        fixture.guest.start()
        let arrived = await waitUntil { fixture.texts.all.count == 2 && fixture.files.all.count == 1 }
        XCTAssertTrue(arrived)
        XCTAssertEqual(fixture.texts.all.first { $0.text == "plain" }?.clip, nil)
        XCTAssertEqual(fixture.texts.all.first { $0.text == "copy me" }?.clip, true)
        XCTAssertEqual(fixture.files.all.first?.clip, true)
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
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(fixture.hosts.pcs.count, 1)
        XCTAssertTrue(fixture.forgotten.all.isEmpty)
        XCTAssertNotNil(fixture.hosts.secret(for: second.id))
    }

    func testPairingAgainOneHundredTimesNeverDropsTheHost() async throws {
        let first = try await pairGuest()
        fixture.guest.start()
        let reachable = await waitUntil { fixture.guest.isReachable(first.id) }
        XCTAssertTrue(reachable)
        for round in 1...100 {
            let again = try await pairGuest()
            XCTAssertEqual(fixture.hosts.pcs.count, 1, "round \(round)")
            XCTAssertNotNil(fixture.hosts.secret(for: again.id), "round \(round)")
            XCTAssertTrue(fixture.forgotten.all.isEmpty, "round \(round)")
        }
        let watching = await waitUntil { fixture.guest.isReachable(first.id) }
        XCTAssertTrue(watching)
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

    // What an earlier run of the app leaves: the host has the first `sent` bytes and the guest has the entry.
    private func leaveUnfinished(_ pc: PairedPc, _ name: String, _ content: Data, sent: Int) async throws -> PendingSend {
        let url = harness.root.appendingPathComponent(name)
        try content.write(to: url)
        let modified = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        let sendId = newSendId()
        let request = try ItemRequest.file(at: url, name: name, mime: nil, modified: modified, sendId: sendId)
        let reached = await fixture.guest.connector.connect(pc, search: false).reached
        let client = try XCTUnwrap(reached).client
        let state = try await client.postItem(request)
        _ = try await client.putChunk(id: state.id, offset: 0, data: content.prefix(sent), onBytes: { _ in })
        let send = PendingSend(hostId: pc.id, sendId: sendId, path: url.path, size: Int64(content.count),
                               modified: PendingSend.seconds(modified), sha256: sha256(content))
        fixture.pending.add(send)
        return send
    }

    // The app closed and opened again on the same folders.
    private func restartGuest() {
        fixture.guest.stop()
        fixture = GuestFixture(root: harness.root, guestId: guestId, secrets: fixture.secrets)
    }

    func testAFinishedSendLeavesNoEntryAndAFailedOneNeither() async throws {
        let pc = try await pairGuest()
        let url = harness.root.appendingPathComponent("done.bin")
        try bytes(5000).write(to: url)
        try await fixture.guest.sendFile(at: url, to: pc.id)
        XCTAssertTrue(fixture.pending.sends.isEmpty)
        harness.service.devices.remove(guestId)
        do {
            try await fixture.guest.sendFile(at: url, to: pc.id)
            XCTFail("Expected a refusal")
        } catch {
            XCTAssertEqual((error as? LinkError)?.status, 401)
        }
        XCTAssertTrue(fixture.pending.sends.isEmpty)
    }

    func testAnUnfinishedFileCarriesOnFromTheHostsOffsetAfterARestart() async throws {
        let pc = try await pairGuest()
        let content = bytes(300_000)
        _ = try await leaveUnfinished(pc, "resume.bin", content, sent: 100_000)
        restartGuest()
        fixture.guest.start()
        let resumed = try XCTUnwrap(fixture.resumed.all.first)
        XCTAssertEqual(resumed.send.path, harness.root.appendingPathComponent("resume.bin").path)
        let progress = Events<Int64>()
        try await resumed.run { progress.add($0) }
        XCTAssertEqual(progress.all.first, 100_000)
        XCTAssertEqual(progress.all.last, 300_000)
        let folder = harness.received.appendingPathComponent("Guest Mac")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["resume.bin"])
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("resume.bin")), content)
        XCTAssertTrue(fixture.pending.sends.isEmpty)
    }

    func testAFileThatChangedOrWentIsDroppedAndFailsTheSend() async throws {
        let pc = try await pairGuest()
        let changed = try await leaveUnfinished(pc, "changed.bin", bytes(10_000), sent: 1000)
        try bytes(10_001).write(to: URL(fileURLWithPath: changed.path))
        restartGuest()
        fixture.guest.start()
        let resumed = try XCTUnwrap(fixture.resumed.all.first)
        do {
            try await resumed.run { _ in }
            XCTFail("Expected the send to fail")
        } catch {
            XCTAssertTrue(error is ResumeError)
        }
        XCTAssertTrue(fixture.pending.sends.isEmpty)

        let gone = try await leaveUnfinished(pc, "gone.bin", bytes(10_000), sent: 1000)
        try FileManager.default.removeItem(atPath: gone.path)
        restartGuest()
        fixture.guest.start()
        let again = try XCTUnwrap(fixture.resumed.all.first)
        do {
            try await again.run { _ in }
            XCTFail("Expected the send to fail")
        } catch {
            XCTAssertTrue(error is ResumeError)
        }
        XCTAssertTrue(fixture.pending.sends.isEmpty)
    }

    func testAResumedSendWaitsForTheHostAndDropForgetsItsEntry() async throws {
        let pc = try await pairGuest()
        _ = try await leaveUnfinished(pc, "waiting.bin", bytes(10_000), sent: 1000)
        restartGuest()
        fixture.guest.start()
        let resumed = try XCTUnwrap(fixture.resumed.all.first)
        try await resumed.wait()
        XCTAssertTrue(fixture.guest.isReachable(pc.id))
        XCTAssertEqual(fixture.pending.sends.count, 1)
        resumed.drop()
        XCTAssertTrue(fixture.pending.sends.isEmpty)
    }

    func testAnEntryWithoutABookmarkStillDecodes() throws {
        let old = #"{"hostId":"h","sendId":"s","path":"/tmp/a","size":5,"modified":7,"sha256":"x"}"#
        let send = try JSONDecoder().decode(PendingSend.self, from: Data(old.utf8))
        XCTAssertEqual(send.path, "/tmp/a")
        XCTAssertNil(send.bookmark)
    }

    #if os(macOS)
    func testAResumedSendOpensTheFileByItsBookmarkWhenThePathIsGone() async throws {
        let pc = try await pairGuest()
        let content = bytes(50_000)
        let left = try await leaveUnfinished(pc, "moved.bin", content, sent: 10_000)
        var send = left
        send.bookmark = try URL(fileURLWithPath: left.path).bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        send.path = "/nonexistent/moved.bin"
        fixture.pending.add(send)
        restartGuest()
        fixture.guest.start()
        let resumed = try XCTUnwrap(fixture.resumed.all.first)
        try await resumed.run { _ in }
        let landed = harness.received.appendingPathComponent("Guest Mac/moved.bin")
        XCTAssertEqual(try Data(contentsOf: landed), content)
        XCTAssertTrue(fixture.pending.sends.isEmpty)
    }
    #endif

    func testForgettingAHostDropsItsPendingSends() async throws {
        let pc = try await pairGuest()
        _ = try await leaveUnfinished(pc, "left.bin", bytes(10_000), sent: 1000)
        XCTAssertEqual(fixture.pending.sends.count, 1)
        await fixture.guest.forget(pc.id)
        XCTAssertTrue(fixture.pending.sends.isEmpty)
    }

    func testAPendingSendOfAnUnknownHostIsDroppedAtStart() async throws {
        fixture.pending.add(PendingSend(hostId: "nobody-0001", sendId: newSendId(), path: "/tmp/none", size: 1, modified: 0, sha256: sha256(Data([1]))))
        fixture.guest.start()
        XCTAssertTrue(fixture.resumed.all.isEmpty)
        XCTAssertTrue(fixture.pending.sends.isEmpty)
    }

    func testARepeatedTextFromTheGuestIsStoredOnce() async throws {
        let pc = try await pairGuest()
        var note = try ItemRequest.note("said once")
        note.sendId = newSendId()
        try await fixture.guest.send(note, to: pc.id)
        try await fixture.guest.send(note, to: pc.id)
        XCTAssertEqual(harness.service.history.items.map(\.text), ["said once"])
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

    private func finish(_ item: OutboxEntry, _ content: Data, with receiver: GuestReceiver) async throws {
        _ = try await receiver.prepareFile(item)
        try receiver.write(content, for: item)
        try await receiver.finishFile(item)
    }

    func testAGalleryFileIsFiledByTheMonthItWasTaken() async throws {
        let pc = try await pairGuest()
        let receiver = GuestReceiver(hostId: pc.id, guest: fixture.guest)
        let item = OutboxEntry(id: "item-0003-abcdef", kind: "file", name: "IMG_1.jpg", size: 3, sourceId: "asset-1#photo",
                               taken: "2021-03-15T12:00:00Z")
        try await finish(item, Data([1, 2, 3]), with: receiver)
        let month = Inbox.month(Date(timeIntervalSince1970: 1_615_809_600))
        let placed = hostFolder.appendingPathComponent("Gallery/\(month)/IMG_1.jpg")
        XCTAssertEqual(try Data(contentsOf: placed), Data([1, 2, 3]))
        let modified = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: placed.path)[.modificationDate] as? Date)
        XCTAssertEqual(modified.timeIntervalSince1970, 1_615_809_600, accuracy: 1)
        XCTAssertEqual(fixture.files.all.first?.sourceId, "asset-1#photo")
        XCTAssertFalse(FileManager.default.fileExists(atPath: hostFolder.appendingPathComponent(item.id + ".part").path))
    }

    func testAGalleryFileAlreadyInTheMonthFolderIsDoneUnderANewId() async throws {
        let pc = try await pairGuest()
        let receiver = GuestReceiver(hostId: pc.id, guest: fixture.guest)
        let item = OutboxEntry(id: "item-0003-abcdef", kind: "file", name: "IMG_1.jpg", size: 3, sourceId: "asset-1#photo",
                               taken: "2021-03-15T12:00:00Z")
        try await finish(item, Data([1, 2, 3]), with: receiver)
        let again = OutboxEntry(id: "item-0004-abcdef", kind: "file", name: "IMG_1.jpg", size: 3, sourceId: "asset-9#photo",
                                taken: "2021-03-15T12:00:00Z")
        let other = OutboxEntry(id: "item-0005-abcdef", kind: "file", name: "IMG_1.jpg", size: 4, sourceId: "asset-8#photo",
                                taken: "2021-03-15T12:00:00Z")

        let doneAgain = await receiver.isDone(again)
        let doneOther = await receiver.isDone(other)

        XCTAssertTrue(doneAgain)
        XCTAssertFalse(doneOther)
    }

    func testAGalleryFileWithoutADateIsFiledByTheDayItArrived() async throws {
        let pc = try await pairGuest()
        let receiver = GuestReceiver(hostId: pc.id, guest: fixture.guest)
        let item = OutboxEntry(id: "item-0004-abcdef", kind: "file", name: "clip.mov", size: 2, sourceId: "asset-2#video")
        try await finish(item, Data([9, 9]), with: receiver)
        let placed = hostFolder.appendingPathComponent("Gallery/\(Inbox.month(Date()))/clip.mov")
        XCTAssertTrue(FileManager.default.fileExists(atPath: placed.path))
    }

    func testAFileWithAnUnusableSourceIdIsFiledAsAnOrdinaryFile() async throws {
        let pc = try await pairGuest()
        let receiver = GuestReceiver(hostId: pc.id, guest: fixture.guest)
        let item = OutboxEntry(id: "item-0005-abcdef", kind: "file", name: "plain.txt", size: 1, sourceId: "")
        try await finish(item, Data([7]), with: receiver)
        XCTAssertTrue(FileManager.default.fileExists(atPath: hostFolder.appendingPathComponent("plain.txt").path))
        XCTAssertNil(fixture.files.all.first?.sourceId)
    }

    func testAnAssetReceivedBeforeIsOnlyAcknowledgedEvenUnderANewItemId() async throws {
        let pc = try await pairGuest()
        let collector = OutboxCollector(handler: GuestReceiver(hostId: pc.id, guest: fixture.guest))
        let first = OutboxEntry(id: "item-0007-abcdef", kind: "file", name: "IMG_3.jpg", size: 2, sourceId: "asset-7#photo")
        let again = OutboxEntry(id: "item-0008-abcdef", kind: "file", name: "IMG_3.jpg", size: 2, sourceId: "asset-7#photo")
        _ = try await collector.collect(api: ScriptedOutbox(items: [first], files: [first.id: Data([1, 2])]), wait: 0)
        let api = ScriptedOutbox(items: [again], files: [:])
        _ = try await collector.collect(api: api, wait: 0)
        XCTAssertEqual(api.acknowledged, [again.id])
        XCTAssertEqual(fixture.files.all.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: hostFolder.appendingPathComponent("Gallery/\(Inbox.month(Date()))").path), ["IMG_3.jpg"])
    }

    func testForgettingAHostDropsItsReceivedAssets() async throws {
        let pc = try await pairGuest()
        fixture.guest.gallery.add(pc.id, "asset-8#photo")
        await fixture.guest.forget(pc.id)
        XCTAssertFalse(fixture.guest.gallery.contains(pc.id, "asset-8#photo"))
    }

    func testAGalleryFileInProgressKeepsItsHostBusy() async throws {
        let pc = try await pairGuest()
        let receiver = GuestReceiver(hostId: pc.id, guest: fixture.guest)
        let item = OutboxEntry(id: "item-0009-abcdef", kind: "file", name: "IMG_9.jpg", size: 2, sourceId: "asset-9#photo")
        _ = try await receiver.prepareFile(item)
        XCTAssertTrue(receiver.isReceivingGallery)
        try receiver.write(Data([1, 2]), for: item)
        try await receiver.finishFile(item)
        XCTAssertFalse(receiver.isReceivingGallery)
    }

    func testATakenDateWithSevenFractionDigitsIsRead() {
        let item = OutboxEntry(id: "item-0010-abcdef", kind: "file", name: "a.jpg", size: 1, sourceId: "asset-10", taken: "2021-03-15T12:00:00.1234567+00:00")
        XCTAssertEqual(try XCTUnwrap(item.takenDate).timeIntervalSince1970, 1_615_809_600.123, accuracy: 0.01)
        let plain = OutboxEntry(id: "item-0011-abcdef", kind: "file", sourceId: "asset-11", taken: "2021-03-15T12:00:00Z")
        XCTAssertNotNil(plain.takenDate)
    }

    func testOnlyAFullDiskIsToldApart() {
        XCTAssertTrue(CocoaError(.fileWriteOutOfSpace).isOutOfSpace)
        XCTAssertTrue(POSIXError(.ENOSPC).isOutOfSpace)
        XCTAssertFalse(CocoaError(.fileWriteNoPermission).isOutOfSpace)
        XCTAssertFalse(POSIXError(.EACCES).isOutOfSpace)
    }

    func testAGalleryFileIsAcknowledgedAfterTheDownload() async throws {
        let pc = try await pairGuest()
        let collector = OutboxCollector(handler: GuestReceiver(hostId: pc.id, guest: fixture.guest))
        let item = OutboxEntry(id: "item-0006-abcdef", kind: "file", name: "IMG_2.jpg", size: 4, sourceId: "asset-3#photo",
                               taken: "2022-07-01T09:30:00+02:00")
        let api = ScriptedOutbox(items: [item], files: [item.id: Data([1, 2, 3, 4])])
        let taken = try await collector.collect(api: api, wait: 0)
        XCTAssertEqual(taken, 1)
        XCTAssertEqual(api.acknowledged, [item.id])
        XCTAssertEqual(fixture.files.all.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: hostFolder.appendingPathComponent("Gallery").path))
    }

    @MainActor
    func testAGalleryItemFromARealHostIsFiledByMonthAndAcknowledged() async throws {
        _ = try await pairGuest()
        fixture.guest.start()
        let library = FakeLibrary(folder: harness.root, count: 3)
        let feed = GalleryFeed(outbox: outbox, indexDirectory: harness.root.appendingPathComponent("feed-index"),
                               stateURL: harness.root.appendingPathComponent("feeds.json"),
                               outgoing: harness.root.appendingPathComponent("feed-out"), library: { library.items() })
        await feed.start(guestId)
        let month = Inbox.month(Date(timeIntervalSince1970: 1_615_809_601))
        let landed = await waitUntil { feed.progress(self.guestId)?.done == true }
        XCTAssertTrue(landed)
        for number in 1...3 {
            let placed = hostFolder.appendingPathComponent("Gallery/\(month)/IMG_\(number).jpg")
            XCTAssertEqual(try Data(contentsOf: placed), Data(repeating: 1, count: 3))
        }
        XCTAssertEqual(fixture.files.all.compactMap(\.sourceId).sorted(), ["asset-1#photo", "asset-2#photo", "asset-3#photo"])
        XCTAssertTrue(outbox.pending(guestId).isEmpty)
        XCTAssertEqual(feed.progress(guestId), GalleryFeedProgress(sent: 3, total: 3, done: true))
    }
}

private final class ScriptedOutbox: OutboxAPI, @unchecked Sendable {
    private let items: [OutboxEntry]
    private let files: [String: Data]
    private let lock = NSLock()
    private var done: [String] = []

    init(items: [OutboxEntry], files: [String: Data]) {
        self.items = items
        self.files = files
    }

    var acknowledged: [String] {
        lock.lock()
        defer { lock.unlock() }
        return done
    }

    func outbox(wait: Int) async throws -> OutboxReply {
        OutboxReply(items: items, more: false)
    }

    func download(id: String, from: Int64, onStart: @escaping (Int, Int64) throws -> Void, sink: @escaping (Data) throws -> Void) async throws {
        let data = files[id] ?? Data()
        try onStart(from > 0 ? 206 : 200, Int64(data.count))
        try sink(Data(data.dropFirst(Int(from))))
    }

    func acknowledge(_ id: String) async throws {
        lock.lock()
        done.append(id)
        lock.unlock()
    }
}

private extension GuestFixture {
    var guestHistory: [ReceivedItem] { guest.history.items }
}

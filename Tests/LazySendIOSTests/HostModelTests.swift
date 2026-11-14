#if os(iOS)
@testable import LazySendKit
import Security
import XCTest
@testable import LazySendIOS
@testable import LazySendServer

/// The phone as a host, with guests that talk to it over loopback through the LazySendKit client. Its certificate is
/// the test-only PKCS#12 in Fixtures (password "test").
@MainActor
final class HostFixture {
    let env: AppEnvironment
    let model: AppModel
    var host: HostModel { model.host }

    init() throws {
        var env = AppEnvironment.temporary()
        let identity = try HostFixture.identity()
        env.identity = { identity }
        env.addresses = { ["127.0.0.1"] }
        self.env = env
        model = AppModel(env: env)
    }

    static func identity() throws -> SecIdentity {
        guard let url = Bundle.module.url(forResource: "test-server", withExtension: "p12", subdirectory: "Fixtures") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let options: [String: Any] = [kSecImportExportPassphrase as String: "test", kSecImportToMemoryOnly as String: true]
        var items: CFArray?
        let status = SecPKCS12Import(try Data(contentsOf: url) as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let first = (items as? [[String: Any]])?.first,
              let identity = first[kSecImportItemIdentity as String] else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return identity as! SecIdentity
    }

    func startReceiving() async {
        host.sceneChanged(active: true)
        host.beginReceiving()
        await host.settle()
    }

    /// Pairs a guest phone through the open pairing code and the approval prompt.
    func pair(_ name: String = "Pixel", id: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
              allow: Bool = true) async throws -> Guest {
        let code = try PairingCode.parse(try XCTUnwrap(host.pairing).link)
        let client = LinkClient(endpoint: Endpoint(host: "127.0.0.1", port: code.port), pin: code.pin)
        let answer = Task { try await client.pair(token: code.token, phoneId: id, phoneName: name, appVersion: "1.0", platform: "android") }
        let asked = await until { self.host.approval != nil }
        XCTAssertTrue(asked)
        host.answerApproval(allow)
        let response = try await answer.value
        return Guest(id: id, hostId: response.desktopId,
                     client: LinkClient(endpoint: client.endpoint, pin: code.pin, credentials: Credentials(deviceId: id, secret: response.deviceSecret)))
    }

    func until(timeout: TimeInterval = 10, _ condition: @MainActor () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    var outgoing: URL {
        env.folder.appendingPathComponent("Host/Outgoing", isDirectory: true)
    }

    func staged() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: outgoing.path)) ?? []
    }

    func tearDown() async {
        host.sceneChanged(active: false)
        host.endReceiving()
        await host.settle()
    }
}

struct Guest {
    var id: String
    var hostId: String
    var client: LinkClient
}

@MainActor
final class HostModelTests: XCTestCase {
    private var fixture: HostFixture!
    private var model: AppModel { fixture.model }
    private var host: HostModel { fixture.host }

    override func setUp() async throws {
        fixture = try HostFixture()
    }

    override func tearDown() async throws {
        await fixture.tearDown()
    }

    func testListensOnlyWhileTheAppIsInFrontAndTheScreenIsOpen() async throws {
        host.sceneChanged(active: true)
        await host.settle()
        XCTAssertFalse(host.listening)
        host.beginReceiving()
        await host.settle()
        XCTAssertTrue(host.listening)
        XCTAssertNotNil(host.pairing)
        host.sceneChanged(active: false)
        await host.settle()
        XCTAssertFalse(host.listening)
        XCTAssertNil(host.pairing)
        host.sceneChanged(active: true)
        await host.settle()
        XCTAssertTrue(host.listening)
        XCTAssertNotNil(host.pairing)
        host.endReceiving()
        await host.settle()
        XCTAssertFalse(host.listening)
    }

    func testTheCodeShowsTheShortCodeAndItsMatchDigits() async throws {
        await fixture.startReceiving()
        let pairing = try XCTUnwrap(host.pairing)
        XCTAssertTrue(pairing.link.hasPrefix("lazysend://pair?"))
        XCTAssertNotNil(ShortCode.normalize(pairing.shortCode))
        XCTAssertEqual(pairing.match, SpkiFingerprint.matchCode(host.fingerprint, shortCode: try XCTUnwrap(ShortCode.normalize(pairing.shortCode))))
        XCTAssertEqual(pairing.check, SpkiFingerprint.checkCode(host.fingerprint))
        let code = try PairingCode.parse(pairing.link)
        XCTAssertEqual(code.port, host.port)
        XCTAssertEqual(code.desktopId, model.store.phoneId)
    }

    func testAnApprovedPhoneIsPairedAndListed() async throws {
        await fixture.startReceiving()
        let guest = try await fixture.pair("Pixel")
        XCTAssertEqual(guest.hostId, model.store.phoneId)
        XCTAssertEqual(host.devices.map(\.name), ["Pixel"])
        XCTAssertEqual(model.phones.map(\.id), [guest.id])
        XCTAssertEqual(host.pairing?.pairedName, "Pixel")
        XCTAssertNil(host.approval)
        XCTAssertTrue(model.targets.contains { $0.id == HostedPhones.target(guest.id) && $0.phone })
    }

    func testTheApprovalShowsTheMatchDigitsOfTheWayItCameIn() async throws {
        await fixture.startReceiving()
        let code = try PairingCode.parse(try XCTUnwrap(host.pairing).link)
        let client = LinkClient(endpoint: Endpoint(host: "127.0.0.1", port: code.port), pin: code.pin)
        let answer = Task { try await client.pair(token: code.token, phoneId: "phone-0001", phoneName: "Pixel", appVersion: "1.0") }
        let asked = await fixture.until { host.approval != nil }
        XCTAssertTrue(asked)
        XCTAssertEqual(host.approval?.name, "Pixel")
        XCTAssertEqual(host.approval?.match, code.checkCode)
        host.answerApproval(false)
        _ = try? await answer.value
    }

    func testADeclinedPhoneIsNotPaired() async throws {
        await fixture.startReceiving()
        do {
            _ = try await fixture.pair("Pixel", allow: false)
            XCTFail("The pairing should have been declined")
        } catch let error as LinkError {
            XCTAssertEqual(error.code, "declined")
        }
        XCTAssertTrue(host.devices.isEmpty)
        XCTAssertTrue(model.phones.isEmpty)
    }

    func testAPairingWithoutAnAnswerIsDeclined() async throws {
        await fixture.startReceiving()
        let code = try PairingCode.parse(try XCTUnwrap(host.pairing).link)
        let client = LinkClient(endpoint: Endpoint(host: "127.0.0.1", port: code.port), pin: code.pin)
        let answer = Task { try await client.pair(token: code.token, phoneId: "phone-0002", phoneName: "Pixel", appVersion: "1.0") }
        let asked = await fixture.until { host.approval != nil }
        XCTAssertTrue(asked)
        // Leaving the screen is the same as not answering.
        host.endReceiving()
        do {
            _ = try await answer.value
            XCTFail("The pairing should have been declined")
        } catch let error as LinkError {
            XCTAssertEqual(error.code, "declined")
        }
        XCTAssertNil(host.approval)
        XCTAssertTrue(host.devices.isEmpty)
    }

    func testTextAndLinksGoIntoTheTimeline() async throws {
        await fixture.startReceiving()
        let guest = try await fixture.pair("Pixel")
        _ = try await guest.client.postItem(try ItemRequest.note("see you at five"))
        _ = try await guest.client.postItem(try ItemRequest.note("https://alazy.app/send/"))
        let arrived = await fixture.until { model.timeline.entries.filter { $0.direction == .received }.count == 2 }
        XCTAssertTrue(arrived)
        let text = try XCTUnwrap(model.timeline.entries.first { $0.kind == .text })
        let link = try XCTUnwrap(model.timeline.entries.first { $0.kind == .link })
        XCTAssertEqual(text.title, "see you at five")
        XCTAssertEqual(text.pcName, "Pixel")
        XCTAssertEqual(link.title, "https://alazy.app/send/")
        XCTAssertEqual(text.state, .done)
    }

    func testAFileLandsInTheDocumentsFolderOfThePhoneThatSentIt() async throws {
        await fixture.startReceiving()
        let guest = try await fixture.pair("Pixel")
        let content = Data((0..<5000).map { UInt8(truncatingIfNeeded: $0) })
        let state = try await guest.client.postItem(ItemRequest(kind: "file", name: "report.pdf", size: Int64(content.count)))
        _ = try await guest.client.putChunk(id: state.id, offset: 0, data: content, onBytes: { _ in })
        let arrived = await fixture.until { model.timeline.entries.contains { $0.kind == .file && $0.direction == .received } }
        XCTAssertTrue(arrived)
        let url = fixture.env.documents.appendingPathComponent("Pixel/report.pdf")
        XCTAssertEqual(try Data(contentsOf: url), content)
        let entry = try XCTUnwrap(model.timeline.entries.first { $0.kind == .file })
        XCTAssertEqual(entry.fileName, "Pixel/report.pdf")
        XCTAssertEqual(model.documentURL(try XCTUnwrap(entry.fileName)).resolvingSymlinksInPath(), url.resolvingSymlinksInPath())
    }

    func testGalleryFilesGoUnderTheGalleryFolderAndAreIndexedPerPhone() async throws {
        await fixture.startReceiving()
        let guest = try await fixture.pair("Pixel")
        let content = Data(repeating: 9, count: 2000)
        for index in 1...2 {
            let request = ItemRequest(kind: "file", name: "IMG_\(index).jpg", size: Int64(content.count), modified: "2025-03-14T12:00:00Z",
                                      sourceId: "asset-\(index)")
            let state = try await guest.client.postItem(request)
            _ = try await guest.client.putChunk(id: state.id, offset: 0, data: content, onBytes: { _ in })
        }
        let arrived = await fixture.until { model.timeline.get("in-gallery-" + guest.id)?.count == 2 }
        XCTAssertTrue(arrived)
        let entry = try XCTUnwrap(model.timeline.get("in-gallery-" + guest.id))
        XCTAssertEqual(entry.kind, .gallery)
        XCTAssertEqual(entry.pcName, "Pixel")
        let folder = fixture.env.documents.appendingPathComponent("Pixel/Gallery", isDirectory: true)
        let months = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(months.count, 1)
        let missing = try await guest.client.galleryMissing(["asset-1", "asset-2", "asset-3"])
        XCTAssertEqual(missing, ["asset-3"])
    }

    func testANoteForAGuestPhoneWaitsInTheOutboxUntilItIsAcknowledged() async throws {
        await fixture.startReceiving()
        let guest = try await fixture.pair("Pixel")
        let target = try XCTUnwrap(model.targets.first { $0.phone })
        try model.sendNote("https://alazy.app/send/", to: target)
        try model.sendNote("the door code is 4821", to: target)
        let waiting = model.timeline.entries.filter { $0.direction == .sent }
        XCTAssertEqual(waiting.count, 2)
        XCTAssertTrue(waiting.allSatisfy { $0.state == .active && $0.pcName == "Pixel" })
        let reply = try await guest.client.outbox(wait: 0)
        XCTAssertEqual(reply.items.map(\.kind), ["link", "text"])
        XCTAssertEqual(reply.items.map { $0.url ?? $0.text }, ["https://alazy.app/send/", "the door code is 4821"])
        for item in reply.items { try await guest.client.acknowledge(item.id) }
        let delivered = await fixture.until { model.timeline.entries.filter { $0.direction == .sent }.allSatisfy { $0.state == .done } }
        XCTAssertTrue(delivered)
    }

    func testAnEmptyNoteIsRefused() async throws {
        await fixture.startReceiving()
        _ = try await fixture.pair("Pixel")
        let target = try XCTUnwrap(model.targets.first { $0.phone })
        XCTAssertThrowsError(try model.sendNote("  \n", to: target)) { XCTAssertEqual($0 as? NoteError, .empty) }
    }

    func testAFileForAGuestPhoneIsCopiedAndTheCopyGoesWhenItIsAcknowledged() async throws {
        await fixture.startReceiving()
        let guest = try await fixture.pair("Pixel")
        let source = fixture.env.documents.appendingPathComponent("holiday.mp4")
        let content = Data((0..<8000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        try content.write(to: source)
        let queued = try await host.sendFiles([source], to: guest.id, scoped: true)
        XCTAssertEqual(queued, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(fixture.staged().count, 1)
        let pending = try await guest.client.outbox(wait: 0).items
        let item = try XCTUnwrap(pending.first)
        XCTAssertEqual(item.name, "holiday.mp4")
        XCTAssertEqual(item.size, Int64(content.count))
        var received = Data()
        try await guest.client.download(id: item.id, from: 0, onStart: { _, _ in }, sink: { received.append($0) })
        XCTAssertEqual(received, content)
        XCTAssertEqual(fixture.staged().count, 1)
        try await guest.client.acknowledge(item.id)
        let cleaned = await fixture.until { fixture.staged().isEmpty }
        XCTAssertTrue(cleaned)
        let done = await fixture.until { model.timeline.entries.first { $0.kind == .file }?.state == .done }
        XCTAssertTrue(done)
    }

    func testAPickedFileIsMovedNotCopied() async throws {
        await fixture.startReceiving()
        let guest = try await fixture.pair("Pixel")
        let folder = fixture.env.documents.appendingPathComponent("picked-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = folder.appendingPathComponent("picked.jpg")
        try Data(repeating: 1, count: 100).write(to: source)
        try await host.sendFiles([source], to: guest.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(fixture.staged().count, 1)
    }

    func testRemovingAGuestDropsWhatWaitsForItAndTheCopies() async throws {
        await fixture.startReceiving()
        let guest = try await fixture.pair("Pixel")
        let source = fixture.env.documents.appendingPathComponent("big.bin")
        try Data(repeating: 3, count: 100).write(to: source)
        try await host.sendFiles([source], to: guest.id, scoped: true)
        try model.sendNote("hello", to: try XCTUnwrap(model.targets.first { $0.phone }))
        XCTAssertEqual(fixture.staged().count, 1)
        model.remove(phone: try XCTUnwrap(model.phones.first))
        let gone = await fixture.until { model.phones.isEmpty && fixture.staged().isEmpty }
        XCTAssertTrue(gone)
        XCTAssertTrue(host.devices.isEmpty)
        XCTAssertTrue(model.timeline.entries.filter { $0.direction == .sent }.allSatisfy { $0.state == .failed })
    }

    func testAPeerThatIsHostAndGuestHasTwoRows() async throws {
        let peer = "peer00000000000000000000000000001"
        try model.store.put(PairedPc(id: peer, name: "Pixel", fingerprint: Base64Url.encode(Data(repeating: 3, count: 32)),
                                     addresses: [], port: 52734), secret: "secret")
        model.refreshPcs()
        await fixture.startReceiving()
        _ = try await fixture.pair("Pixel", id: peer)
        XCTAssertEqual(model.pcs.map(\.id), [peer])
        XCTAssertEqual(model.phones.map(\.id), [peer])
        XCTAssertEqual(model.targets.map(\.id), [peer, HostedPhones.target(peer)])
        XCTAssertEqual(model.targets.map(\.phone), [false, true])
        model.select(HostedPhones.target(peer))
        XCTAssertEqual(model.selectedTarget?.phone, true)
        XCTAssertNil(model.selected)
    }

    func testTheShareSheetQueueReachesAGuestPhoneAsTextAndAsAFile() async throws {
        await fixture.startReceiving()
        let guest = try await fixture.pair("Pixel")
        let target = HostedPhones.target(guest.id)
        try model.queue.add(QueuedItem(id: "share-0001", pcId: target, kind: "text", text: "from the share sheet"))
        let file = fixture.env.documents.appendingPathComponent("data")
        try Data(repeating: 5, count: 300).write(to: file)
        try model.queue.add(QueuedItem(id: "share-0002", pcId: target, kind: "file", name: "photo.jpg", mime: "image/jpeg"), file: file, move: true)
        model.drainShareQueue()
        let queued = await fixture.until { model.queue.items().isEmpty }
        XCTAssertTrue(queued)
        let items = try await guest.client.outbox(wait: 0).items
        XCTAssertEqual(Set(items.map(\.kind)), ["text", "file"])
        XCTAssertEqual(items.first { $0.kind == "file" }?.name, "photo.jpg")
        XCTAssertEqual(items.first { $0.kind == "text" }?.text, "from the share sheet")
    }

    func testAShareForAPhoneThatWasRemovedIsDropped() async throws {
        try model.queue.add(QueuedItem(id: "share-0003", pcId: HostedPhones.target("gone00000000"), kind: "text", text: "late"))
        model.drainShareQueue()
        XCTAssertTrue(model.queue.items().isEmpty)
    }

    func testThePairingsOutliveARestart() async throws {
        await fixture.startReceiving()
        let guest = try await fixture.pair("Pixel")
        await fixture.tearDown()
        let again = AppModel(env: fixture.env)
        await again.host.settle()
        XCTAssertEqual(again.phones.map(\.id), [guest.id])
        XCTAssertEqual(again.host.devices.map(\.name), ["Pixel"])
    }

    private func queuedShare(_ model: AppModel, target: String, name: String = "photo.jpg") throws {
        let file = fixture.env.documents.appendingPathComponent("data-" + UUID().uuidString)
        try Data(repeating: 5, count: 300).write(to: file)
        try model.queue.add(QueuedItem(id: "share-" + UUID().uuidString.prefix(8).lowercased(), pcId: target, kind: "file", name: name,
                                       mime: "image/jpeg"), file: file, move: true)
    }

    func testAShareStaysQueuedWhileTheHostIsNotReady() async throws {
        var env = AppEnvironment.temporary()
        env.identity = { throw SelfSignedCertificateError("No certificate here.") }
        let hostFolder = env.folder.appendingPathComponent("Host", isDirectory: true)
        try FileManager.default.createDirectory(at: hostFolder, withIntermediateDirectories: true)
        let saved = #"{"desktopId":"abc12345","devices":[{"id":"phone-0001","name":"Pixel"}]}"#
        try Data(saved.utf8).write(to: hostFolder.appendingPathComponent("devices.json"))
        let model = AppModel(env: env)
        await model.host.settle()
        XCTAssertNotNil(model.host.problem)
        try model.queue.add(QueuedItem(id: "share-0010", pcId: HostedPhones.target("phone-0001"), kind: "text", text: "wait for me"))
        model.drainShareQueue()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(model.queue.items().map(\.id), ["share-0010"])
    }

    func testAShareStaysQueuedWhenItsCopyFails() async throws {
        await fixture.startReceiving()
        let guest = try await fixture.pair("Pixel")
        // A file where the folder for the copies should be makes every copy fail.
        try FileManager.default.createDirectory(at: fixture.outgoing.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: fixture.outgoing)
        try queuedShare(model, target: HostedPhones.target(guest.id))
        model.drainShareQueue()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(model.queue.items().count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.queue.dataURL(try XCTUnwrap(model.queue.items().first).id).path))
        let pending = try await guest.client.outbox(wait: 0).items
        XCTAssertTrue(pending.isEmpty)
    }

    func testTheNameOfAFileFromTheShareSheetIsMadeSafe() async throws {
        await fixture.startReceiving()
        let guest = try await fixture.pair("Pixel")
        try queuedShare(model, target: HostedPhones.target(guest.id), name: "../evil:name.jpg")
        model.drainShareQueue()
        let queued = await fixture.until { model.queue.items().isEmpty }
        XCTAssertTrue(queued)
        let pending = try await guest.client.outbox(wait: 0).items
        XCTAssertEqual(pending.first?.name, "_evil_name.jpg")
        XCTAssertEqual(fixture.staged().count, 1)
    }

    func testAKeyThatChangedDropsTheHostedPairingsAndTheirQueue() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lazysend-host-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let copy = root.appendingPathComponent("Outgoing/one", isDirectory: true)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: copy.appendingPathComponent("a.bin"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("devices.json"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("outbox.json"))
        try Data("old".utf8).write(to: root.appendingPathComponent("fingerprint.txt"))
        XCTAssertFalse(HostModel.forgetPairingsIfKeyChanged(in: root, fingerprint: "old"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("devices.json").path))
        XCTAssertTrue(HostModel.forgetPairingsIfKeyChanged(in: root, fingerprint: "new"))
        for name in ["devices.json", "outbox.json", "Outgoing"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path), name)
        }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("fingerprint.txt"), encoding: .utf8), "new")
    }

    func testPairingsFromAnotherKeyAreNotKeptAtLaunch() async throws {
        await fixture.startReceiving()
        _ = try await fixture.pair("Pixel")
        await fixture.tearDown()
        try Data("another-key".utf8).write(to: fixture.env.folder.appendingPathComponent("Host/fingerprint.txt"))
        let again = AppModel(env: fixture.env)
        await again.host.settle()
        XCTAssertTrue(again.phones.isEmpty)
        XCTAssertTrue(again.host.devices.isEmpty)
    }
}
#endif

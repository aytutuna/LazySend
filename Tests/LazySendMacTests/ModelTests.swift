#if os(macOS)
import AppKit
import CoreImage
import Security
import XCTest
@testable import LazySendKit
@testable import LazySendMac
@testable import LazySendServer

@MainActor
final class ModelFixture {
    let root: URL
    let service: LinkService
    let model: AppModel
    let pasteboard: NSPasteboard

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lazysend-mac-" + UUID().uuidString, isDirectory: true)
        service = try LinkService(paths: SendPaths(root: root.appendingPathComponent("state"),
                                                   defaultReceiveRoot: root.appendingPathComponent("received")),
                                  identity: try ModelFixture.identity())
        pasteboard = NSPasteboard(name: NSPasteboard.Name("lazysend-test-" + UUID().uuidString))
        model = AppModel(service: service, pasteboard: pasteboard, scratch: root.appendingPathComponent("scratch"))
    }

    static func identity() throws -> SecIdentity {
        guard let url = Bundle.module.url(forResource: "test-server", withExtension: "p12", subdirectory: "Fixtures") else {
            throw CocoaError(.fileNoSuchFile)
        }
        var options: [String: Any] = [kSecImportExportPassphrase as String: "test"]
        if #available(macOS 15.0, *) { options[kSecImportToMemoryOnly as String] = true }
        var items: CFArray?
        let status = SecPKCS12Import(try Data(contentsOf: url) as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let first = (items as? [[String: Any]])?.first,
              let identity = first[kSecImportItemIdentity as String] else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return identity as! SecIdentity
    }

    /// Pairs a phone in the store and lets the model see it.
    @discardableResult
    func pair(_ name: String = "Aytu's iPhone") async throws -> PairedDevice {
        let id = newId()
        _ = try service.devices.pair(id: id, name: name, platform: "ios", appVersion: "1.0", now: Date())
        await settle()
        return try XCTUnwrap(service.devices.devices.first { $0.id == id })
    }

    func file(_ name: String, bytes: Int = 1000) throws -> URL {
        let folder = root.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data(count: bytes).write(to: url)
        return url
    }

    func settle() async {
        try? await Task.sleep(nanoseconds: 150_000_000)
    }

    func tearDown() async {
        await model.stop()
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
final class ModelTests: XCTestCase {
    private var fixture: ModelFixture!
    private var model: AppModel { fixture.model }

    override func setUp() async throws {
        fixture = try ModelFixture()
    }

    override func tearDown() async throws {
        await fixture.tearDown()
    }

    func testTextGoesToTheSelectedPhoneAndWaitsThere() async throws {
        let phone = try await fixture.pair()
        XCTAssertEqual(model.selectedPhoneId, phone.id)
        XCTAssertEqual(model.targetTitle, "Send to Aytu's iPhone")
        XCTAssertTrue(model.sendText("hello there  \n"))
        let waiting = fixture.service.outbox.pending(phone.id)
        XCTAssertEqual(waiting.map(\.text), ["hello there"])
        let row = try XCTUnwrap(model.timeline.first)
        XCTAssertEqual(row.heading, "Text to Aytu's iPhone")
        XCTAssertTrue(row.canCancel)
        XCTAssertTrue(row.detail.hasPrefix("Waiting for Aytu's iPhone"))
    }

    func testALoneLinkIsSentAsALink() async throws {
        let phone = try await fixture.pair()
        XCTAssertTrue(model.sendText("  https://example.com/page?x=1 \n"))
        let item = try XCTUnwrap(fixture.service.outbox.pending(phone.id).first)
        XCTAssertEqual(item.kind, "link")
        XCTAssertEqual(item.url, "https://example.com/page?x=1")
        XCTAssertEqual(model.timeline.first?.heading, "Link to Aytu's iPhone")
        XCTAssertTrue(model.sendText("see https://example.com for more"))
        XCTAssertEqual(fixture.service.outbox.pending(phone.id).last?.kind, "text")
    }

    func testNothingIsSentWithoutAPhoneOrWithoutText() async throws {
        XCTAssertFalse(model.sendText("hello"))
        XCTAssertEqual(model.notice, "Pair a phone first.")
        XCTAssertEqual(model.sendFiles([try fixture.file("a.txt")]), 0)
        try await fixture.pair()
        XCTAssertFalse(model.sendText("  \n "))
        XCTAssertTrue(model.timeline.isEmpty)
    }

    func testTextOverAMebibyteIsRefusedWithAMessage() async throws {
        try await fixture.pair()
        XCTAssertFalse(model.sendText(String(repeating: "a", count: 1024 * 1024 + 1)))
        XCTAssertEqual(model.notice, "That text is too long to send (the limit is 1 MiB).")
    }

    func testFilesAreQueuedWithTheirSizeAndFoldersAreRefused() async throws {
        let phone = try await fixture.pair()
        let a = try fixture.file("a.txt", bytes: 2000)
        let b = try fixture.file("b.png", bytes: 10)
        XCTAssertEqual(model.sendFiles([a, b, fixture.root.appendingPathComponent("files")]), 2)
        XCTAssertEqual(model.notice, "Folders cannot be sent yet. Send the files in them, or zip the folder first.")
        let waiting = fixture.service.outbox.pending(phone.id)
        XCTAssertEqual(waiting.map(\.name), ["a.txt", "b.png"])
        XCTAssertEqual(waiting.first?.size, 2000)
        XCTAssertEqual(waiting.last?.mime, "image/png")
        XCTAssertEqual(model.timeline.count, 2)
        XCTAssertTrue(model.timeline.allSatisfy { $0.kind == .file && $0.sent })
    }

    func testAMissingFileIsReported() async throws {
        try await fixture.pair()
        XCTAssertEqual(model.sendFiles([fixture.root.appendingPathComponent("nothing.txt")]), 0)
        XCTAssertTrue(model.notice?.contains("nothing.txt") == true)
    }

    func testCancellingWithdrawsTheItem() async throws {
        let phone = try await fixture.pair()
        model.sendText("never mind")
        let row = try XCTUnwrap(model.timeline.first)
        model.cancel(row)
        await fixture.settle()
        XCTAssertTrue(fixture.service.outbox.pending(phone.id).isEmpty)
        let after = try XCTUnwrap(model.timeline.first)
        XCTAssertFalse(after.canCancel)
        XCTAssertTrue(after.detail.hasPrefix("Cancelled"))
    }

    func testAnItemThePhoneTookIsMarkedDelivered() async throws {
        let phone = try await fixture.pair()
        model.sendText("take this")
        let item = try XCTUnwrap(fixture.service.outbox.pending(phone.id).first)
        fixture.service.outbox.acknowledge(phone.id, item.id)
        await fixture.settle()
        let row = try XCTUnwrap(model.timeline.first)
        XCTAssertFalse(row.canCancel)
        XCTAssertTrue(row.detail.hasPrefix("Delivered"))
    }

    func testRemovingAPhoneCancelsWhatWaitedForIt() async throws {
        let phone = try await fixture.pair()
        model.sendText("lost")
        model.remove(phone: phone.id)
        await fixture.settle()
        XCTAssertTrue(model.phones.isEmpty)
        XCTAssertNil(model.selectedPhoneId)
        XCTAssertTrue(model.timeline.first?.detail.hasPrefix("Cancelled") == true)
    }

    func testReceivedTextShowsInTheTimelineAndCanBeCopied() async throws {
        let phone = try await fixture.pair()
        model.copyReceivedText = true
        let item = fixture.service.history.add(phone, kind: "text", text: "from the phone", url: nil, now: Date())
        model.addText(item, arrived: true)
        let row = try XCTUnwrap(model.timeline.first)
        XCTAssertEqual(row.heading, "Text from Aytu's iPhone")
        XCTAssertEqual(row.text, "from the phone")
        XCTAssertTrue(row.canCopy)
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "from the phone")
        XCTAssertTrue(fixture.service.settings.copyTextToClipboard)
    }

    func testReceivedTextIsNotCopiedUnlessAsked() async throws {
        let phone = try await fixture.pair()
        let item = fixture.service.history.add(phone, kind: "text", text: "private", url: nil, now: Date())
        model.addText(item, arrived: true)
        XCTAssertNil(fixture.pasteboard.string(forType: .string))
        let link = fixture.service.history.add(phone, kind: "link", text: nil, url: "https://example.com", now: Date())
        model.addText(link, arrived: true)
        XCTAssertEqual(model.timeline.first?.heading, "Link from Aytu's iPhone")
        XCTAssertTrue(model.timeline.first?.canOpen == true)
    }

    func testTheHistoryComesBackWhenTheAppStarts() async throws {
        let phone = try await fixture.pair()
        _ = fixture.service.history.add(phone, kind: "text", text: "one", url: nil, now: Date())
        _ = fixture.service.history.add(phone, kind: "link", text: nil, url: "https://example.com", now: Date())
        let again = AppModel(service: fixture.service, pasteboard: fixture.pasteboard, scratch: fixture.root.appendingPathComponent("scratch"))
        XCTAssertEqual(again.timeline.map(\.kind), [.link, .text])
    }

    func testAGalleryIsOneRowThatFinishesWhenTheFilesStop() async throws {
        let phone = try await fixture.pair()
        for index in 0..<5 {
            let url = fixture.root.appendingPathComponent("received/Aytu's iPhone/Gallery/2026-11/IMG_\(index).jpg")
            model.addFile(ReceivedFile(deviceId: phone.id, deviceName: phone.name, url: url, size: 100, sourceId: "asset-\(index)"))
        }
        XCTAssertEqual(model.timeline.count, 1)
        var row = try XCTUnwrap(model.timeline.first)
        XCTAssertEqual(row.kind, .gallery)
        XCTAssertEqual(row.count, 5)
        XCTAssertTrue(row.active)
        XCTAssertEqual(row.heading, "Receiving photos from Aytu's iPhone: 5 so far")
        XCTAssertEqual(row.fileURL?.lastPathComponent, "Gallery")
        model.finishGalleries(now: Date().addingTimeInterval(AppModel.galleryIdle + 1))
        row = try XCTUnwrap(model.timeline.first)
        XCTAssertFalse(row.active)
        XCTAssertEqual(row.heading, "Received 5 photos and videos from Aytu's iPhone")
        model.addFile(ReceivedFile(deviceId: phone.id, deviceName: phone.name, url: fixture.root.appendingPathComponent("x/y/z.jpg"),
                                   size: 1, sourceId: "again"))
        XCTAssertEqual(model.timeline.count, 2)
    }

    func testAReceivedFileGetsItsOwnRow() async throws {
        let phone = try await fixture.pair()
        let url = try fixture.file("report.pdf", bytes: 3_000_000)
        model.addFile(ReceivedFile(deviceId: phone.id, deviceName: phone.name, url: url, size: 3_000_000, sourceId: nil))
        let row = try XCTUnwrap(model.timeline.first)
        XCTAssertEqual(row.heading, "report.pdf")
        XCTAssertTrue(row.detail.contains("from Aytu's iPhone"))
        XCTAssertTrue(row.canShowInFinder)
    }

    func testTheTimelineKeepsFiveHundredRowsAndEverythingStillWaiting() async throws {
        let phone = try await fixture.pair()
        model.sendText("waiting one")
        model.sendText("waiting two")
        for index in 0..<600 {
            let item = fixture.service.history.add(phone, kind: "text", text: "item \(index)", url: nil, now: Date())
            model.addText(item, arrived: false)
        }
        XCTAssertEqual(model.timeline.count, 500)
        XCTAssertEqual(model.timeline.filter(\.canCancel).count, 2)
        XCTAssertEqual(model.timeline.first?.text, "item 599")
    }

    func testThePasteboardSendsTextFilesAndPictures() async throws {
        let phone = try await fixture.pair()
        fixture.pasteboard.clearContents()
        fixture.pasteboard.setString("pasted words", forType: .string)
        XCTAssertTrue(model.sendPasteboard())
        XCTAssertEqual(fixture.service.outbox.pending(phone.id).last?.text, "pasted words")

        fixture.pasteboard.clearContents()
        fixture.pasteboard.writeObjects([try fixture.file("clip.txt") as NSURL])
        XCTAssertTrue(model.sendPasteboard())
        XCTAssertEqual(fixture.service.outbox.pending(phone.id).last?.name, "clip.txt")

        fixture.pasteboard.clearContents()
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        fixture.pasteboard.writeObjects([image])
        XCTAssertTrue(model.sendPasteboard())
        let sent = try XCTUnwrap(fixture.service.outbox.pending(phone.id).last)
        XCTAssertTrue(sent.name?.hasSuffix(".png") == true)
        XCTAssertEqual(sent.mime, "image/png")
        let header = try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(sent.path))).prefix(4)
        XCTAssertEqual([UInt8](header), [0x89, 0x50, 0x4E, 0x47])
    }

    func testAnEmptyPasteboardSendsNothing() async throws {
        try await fixture.pair()
        fixture.pasteboard.clearContents()
        XCTAssertFalse(model.sendPasteboard())
    }

    func testOpenWithQueuesTheFilesForThePhone() async throws {
        let phone = try await fixture.pair()
        model.open([try fixture.file("opened.txt")])
        XCTAssertEqual(fixture.service.outbox.pending(phone.id).map(\.name), ["opened.txt"])
    }

    func testTheHandOffAddressNamesAbsoluteFiles() {
        let url = URL(string: "lazysend:open?file=%2Ftmp%2Fa%20b.txt&file=%2Ftmp%2Fc.txt&file=relative.txt")!
        XCTAssertEqual(HandOff.files(in: url).map(\.path), ["/tmp/a b.txt", "/tmp/c.txt"])
        XCTAssertEqual(HandOff.files(in: URL(string: "lazysend://open?file=%2Ftmp%2Fd.txt")!).map(\.path), ["/tmp/d.txt"])
        XCTAssertTrue(HandOff.files(in: URL(string: "lazysend://pair?v=1&file=%2Ftmp%2Fe.txt")!).isEmpty)
        XCTAssertTrue(HandOff.files(in: URL(string: "https://example.com/open?file=%2Ftmp%2Ff.txt")!).isEmpty)
    }

    func testTheApprovalPromptWaitsForTheUsersAnswer() async throws {
        let request = PairRequest(token: "x", phoneId: newId(), phoneName: "Pixel", platform: "android", appVersion: "1")
        let answer = Task { await model.ask(request) }
        await assertEventually { model.approval != nil }
        XCTAssertEqual(model.approval, PairApproval(name: "Pixel", platform: "android"))
        model.answerApproval(true)
        let allowed = await answer.value
        XCTAssertTrue(allowed)
        XCTAssertNil(model.approval)

        let second = Task { await model.ask(request) }
        await assertEventually { model.approval != nil }
        model.answerApproval(false)
        let refused = await second.value
        XCTAssertFalse(refused)
    }

    func testAnApprovalThatIsCancelledDeclines() async throws {
        let request = PairRequest(token: "x", phoneId: newId(), phoneName: "Pixel", platform: "android", appVersion: "1")
        let answer = Task { await model.ask(request) }
        await assertEventually { model.approval != nil }
        answer.cancel()
        let allowed = await answer.value
        XCTAssertFalse(allowed)
        XCTAssertNil(model.approval)
    }

    func testPairingOpensTheServerAndACodeThatCarriesTheMacsAddresses() async throws {
        await model.beginPairing()
        let state = try XCTUnwrap(model.pairing)
        XCTAssertTrue(fixture.service.server.isRunning)
        XCTAssertEqual(state.code.port, fixture.service.server.port)
        XCTAssertEqual(state.code.addresses, Peers.pairingAddresses())
        XCTAssertEqual(state.remaining, 300)
        XCTAssertTrue(model.status.hasPrefix("Listening for phones on port"))
        let parsed = try PairingCode.parse(state.code.uri)
        XCTAssertEqual(parsed.token, state.code.token)
        model.closePairing()
        XCTAssertNil(model.pairing)
        XCTAssertNil(fixture.service.pairing)
    }

    func testAPhonePairsThroughTheModelsPrompt() async throws {
        await model.beginPairing()
        let state = try XCTUnwrap(model.pairing)
        let client = LinkClient(endpoint: Endpoint(host: "127.0.0.1", port: state.code.port), pin: fixture.service.fingerprint)
        let id = newId()
        let pairing = Task { try await client.pair(token: state.code.token, phoneId: id, phoneName: "Pixel 9", appVersion: "1") }
        await assertEventually { model.approval != nil }
        model.answerApproval(true)
        let answer = try await pairing.value
        XCTAssertFalse(answer.deviceSecret.isEmpty)
        await assertEventually { model.pairing?.pairedName == "Pixel 9" }
        XCTAssertEqual(model.phones.map(\.name), ["Pixel 9"])
        model.closePairing()
    }

    func testLastSeenReadsInPlainWords() {
        let now = Date()
        XCTAssertEqual(AppModel.lastSeen(nil, now: now), "")
        XCTAssertEqual(AppModel.lastSeen(now.addingTimeInterval(-30), now: now), "Connected just now")
        XCTAssertEqual(AppModel.lastSeen(now.addingTimeInterval(-600), now: now), "Seen 10 minutes ago")
        XCTAssertTrue(AppModel.lastSeen(now.addingTimeInterval(-86_400), now: now).hasPrefix("Seen "))
    }

    func testTheReceiveFolderCanBeChosenAndResetToTheDefault() async throws {
        let chosen = fixture.root.appendingPathComponent("chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        model.chooseReceiveFolder(chosen)
        XCTAssertEqual(model.receiveFolder, chosen.path)
        XCTAssertEqual(fixture.service.settings.receiveRoot.path, chosen.path)
        model.useDefaultReceiveFolder()
        XCTAssertTrue(fixture.service.settings.isDefaultReceiveRoot)
        XCTAssertTrue(model.receiveFolder.hasSuffix("received"))
    }

    func testTheQRCodeCarriesTheText() throws {
        let text = "lazysend://pair?v=1&id=0123456789abcdef&n=Test%20Mac&fp=" + String(repeating: "A", count: 43) + "&a=192.168.1.5&p=52734&t=" + String(repeating: "B", count: 22)
        let image = try XCTUnwrap(QRCode.image(for: text))
        XCTAssertGreaterThan(image.size.width, 100)
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        guard let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]) else {
            throw XCTSkip("No QR detector on this machine")
        }
        let found = detector.features(in: CIImage(cgImage: cg)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        XCTAssertEqual(found, [text])
    }
}

func waitUntil(timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return await condition()
}

func assertEventually(file: StaticString = #filePath, line: UInt = #line, _ condition: @MainActor () -> Bool) async {
    let reached = await waitUntil(condition)
    XCTAssertTrue(reached, file: file, line: line)
}
#endif

import Foundation
import XCTest
@testable import LazySendKit
@testable import LazySendServer

final class TransferLinkTests: XCTestCase {
    private var harness: Harness!
    private var phone: Phone!

    override func setUp() async throws {
        harness = try await Harness()
        phone = try await harness.pair()
    }

    override func tearDown() async throws {
        await harness.tearDown()
    }

    private var phoneFolder: URL { harness.received.appendingPathComponent("Test iPhone") }

    private func files(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    func testTextAndLinkAreStoredAtOnceNewestFirst() async throws {
        let first = try await phone.client.postItem(ItemRequest(kind: "text", text: "hello there"))
        XCTAssertTrue(first.done)
        let second = try await phone.client.postItem(ItemRequest(kind: "link", url: "https://example.com/a?b=c"))
        XCTAssertTrue(second.done)
        let items = harness.service.history.items
        XCTAssertEqual(items.map(\.kind), ["link", "text"])
        XCTAssertEqual(items[1].text, "hello there")
        XCTAssertEqual(items[0].url, "https://example.com/a?b=c")
        XCTAssertEqual(items[0].deviceName, "Test iPhone")
    }

    func testBadTextAndLinksAreRefused() async throws {
        await expectRefused(400, "badRequest") { _ = try await phone.client.postItem(ItemRequest(kind: "text", text: "")) }
        await expectRefused(400, "badRequest") { _ = try await phone.client.postItem(ItemRequest(kind: "text")) }
        await expectRefused(413, "tooLarge") {
            _ = try await phone.client.postItem(ItemRequest(kind: "text", text: String(repeating: "a", count: 1024 * 1024 + 1)))
        }
        await expectRefused(400, "badRequest") { _ = try await phone.client.postItem(ItemRequest(kind: "link", url: "ftp://example.com/x")) }
        await expectRefused(400, "badRequest") { _ = try await phone.client.postItem(ItemRequest(kind: "link", url: "javascript:alert(1)")) }
        await expectRefused(400, "badRequest") { _ = try await phone.client.postItem(ItemRequest(kind: "link", url: "/relative")) }
        await expectRefused(400, "badRequest") { _ = try await phone.client.postItem(ItemRequest(kind: "other")) }
        XCTAssertTrue(harness.service.history.items.isEmpty)
    }

    func testTextOfOneMebibyteIsAccepted() async throws {
        let state = try await phone.client.postItem(ItemRequest(kind: "text", text: String(repeating: "\"", count: 1024 * 1024)))
        XCTAssertTrue(state.done)
    }

    func testFileUploadInChunksIsRenamedIntoPlace() async throws {
        let content = bytes(250_000)
        var announced: [ReceivedFile] = []
        let lock = NSLock()
        harness.service.inbox.onFileReceived = { file in
            lock.lock()
            announced.append(file)
            lock.unlock()
        }
        let state = try await phone.beginFile("photo.jpg", content)
        XCTAssertFalse(state.done)
        XCTAssertEqual(state.offset, 0)
        XCTAssertEqual(files(in: phoneFolder), [state.id + ".part"])
        let mid = try await phone.put(state.id, offset: 0, content.prefix(100_000))
        XCTAssertEqual(mid.offset, 100_000)
        XCTAssertFalse(mid.done)
        let more = try await phone.put(state.id, offset: 100_000, content.subdata(in: 100_000..<250_000))
        XCTAssertTrue(more.done)
        XCTAssertEqual(more.offset, 250_000)
        XCTAssertEqual(files(in: phoneFolder), ["photo.jpg"])
        XCTAssertEqual(try Data(contentsOf: phoneFolder.appendingPathComponent("photo.jpg")), content)
        lock.lock()
        XCTAssertEqual(announced.map(\.url.lastPathComponent), ["photo.jpg"])
        XCTAssertEqual(announced.first?.size, 250_000)
        lock.unlock()
        let again = try await phone.client.itemState(state.id)
        XCTAssertTrue(again.done)
    }

    func testSecondFileWithTheSameNameGetsASuffix() async throws {
        try await phone.upload("note.txt", bytes(100))
        try await phone.upload("note.txt", bytes(200))
        try await phone.upload("note.txt", bytes(300))
        XCTAssertEqual(files(in: phoneFolder), ["note (2).txt", "note (3).txt", "note.txt"])
    }

    func testNamesFromThePhoneAreMadeSafe() async throws {
        try await phone.upload("../../escape.txt", bytes(10))
        try await phone.upload("a:b\\c.txt", bytes(10))
        try await phone.upload("...", bytes(10))
        try await phone.upload(".hidden", bytes(10))
        let names = files(in: phoneFolder)
        XCTAssertTrue(names.allSatisfy { !$0.contains("/") && !$0.hasPrefix(".") })
        XCTAssertEqual(names.count, 4)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.received.appendingPathComponent("escape.txt").path))
        XCTAssertEqual(FileNames.clean("x".padding(toLength: 400, withPad: "x", startingAt: 0) + ".png").utf8.count, 240)
        XCTAssertTrue(FileNames.clean(String(repeating: "x", count: 400) + ".png").hasSuffix(".png"))
    }

    func testReceivedFilesAreMarkedAsDownloadedAndKeepTheirDate() async throws {
        try await phone.upload("dated.txt", bytes(100), modified: "2025-03-14T12:00:00Z")
        let url = phoneFolder.appendingPathComponent("dated.txt")
#if os(macOS)
        XCTAssertGreaterThan(getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0), 0)
#endif
        let modified = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        XCTAssertEqual(modified.timeIntervalSince1970, 1_741_953_600, accuracy: 1)
    }

    func testUploadResumesAfterADroppedConnection() async throws {
        let content = bytes(400_000)
        let state = try await phone.beginFile("big.bin", content)
        _ = try await phone.partialChunk(state.id, offset: 0, declared: 400_000, sent: content.prefix(120_000), hangUp: true)
        let resumed = try await waitForSettledOffset(state.id)
        XCTAssertGreaterThan(resumed, 0)
        XCTAssertLessThanOrEqual(resumed, 120_000)
        let rest = try await phone.put(state.id, offset: resumed, content.subdata(in: Int(resumed)..<400_000))
        XCTAssertTrue(rest.done)
        XCTAssertEqual(try Data(contentsOf: phoneFolder.appendingPathComponent("big.bin")), content)
    }

    func testUploadResumesAfterTheAppRestarts() async throws {
        let content = bytes(300_000)
        let state = try await phone.beginFile("restart.bin", content)
        _ = try await phone.put(state.id, offset: 0, content.prefix(100_000))
        try await harness.restart()
        let after = try await phone.client.itemState(state.id)
        XCTAssertEqual(after.offset, 100_000)
        XCTAssertFalse(after.done)
        let rest = try await phone.put(state.id, offset: 100_000, content.subdata(in: 100_000..<300_000))
        XCTAssertTrue(rest.done)
        XCTAssertEqual(try Data(contentsOf: phoneFolder.appendingPathComponent("restart.bin")), content)
    }

    func testNewChunkTakesOverFromAHalfOpenOne() async throws {
        let content = bytes(300_000)
        let state = try await phone.beginFile("takeover.bin", content)
        let open = try await phone.partialChunk(state.id, offset: 0, declared: 300_000, sent: content.prefix(50_000), hangUp: false)
        defer { open.cancel() }
        let written = try await waitForOffset(state.id) { $0 >= 50_000 }
        let rest = try await phone.put(state.id, offset: written, content.subdata(in: Int(written)..<300_000))
        XCTAssertTrue(rest.done)
        XCTAssertEqual(try Data(contentsOf: phoneFolder.appendingPathComponent("takeover.bin")), content)
    }

    func testWrongOffsetGetsConflictWithTheCurrentOffset() async throws {
        let content = bytes(20_000)
        let state = try await phone.beginFile("offset.bin", content)
        _ = try await phone.put(state.id, offset: 0, content.prefix(5000))
        do {
            _ = try await phone.put(state.id, offset: 1000, content.subdata(in: 1000..<6000))
            XCTFail("The offset is wrong")
        } catch let error as LinkError {
            XCTAssertEqual(error.status, 409)
            XCTAssertEqual(error.code, "offsetMismatch")
            XCTAssertEqual(error.offset, 5000)
        }
        let rest = try await phone.put(state.id, offset: 5000, content.subdata(in: 5000..<20_000))
        XCTAssertTrue(rest.done)
    }

    func testChunkPastTheEndOrWithoutAnOffsetIsRefused() async throws {
        let content = bytes(1000)
        let state = try await phone.beginFile("end.bin", content)
        await expectRefused(400, "badRequest") { _ = try await phone.put(state.id, offset: 0, bytes(1001)) }
        await expectRefused(400, "badRequest") { _ = try await phone.put(state.id, offset: 2000, bytes(10)) }
        let missing = try await phone.raw("PUT", "/v1/items/\(state.id)/data", body: bytes(10))
        XCTAssertEqual(missing.status, 400)
        let letters = try await phone.raw("PUT", "/v1/items/\(state.id)/data", body: bytes(10), headers: ["X-Offset": "abc"])
        XCTAssertEqual(letters.status, 400)
        let empty = try await phone.raw("PUT", "/v1/items/\(state.id)/data", body: Data(), headers: ["X-Offset": "0"])
        XCTAssertNotEqual(empty.status, 200)
    }

    func testWrongSha256DiscardsTheFile() async throws {
        let content = bytes(5000)
        var request = phone.fileRequest("bad.bin", content)
        request.sha256 = sha256(bytes(5000, seed: 1))
        let state = try await phone.client.postItem(request)
        await expectRefused(422, "hashMismatch") { _ = try await phone.put(state.id, offset: 0, content) }
        XCTAssertEqual(files(in: phoneFolder), [])
        await expectRefused(404, "notFound") { _ = try await phone.client.itemState(state.id) }
    }

    func testSha256IsCheckedAfterAResumeToo() async throws {
        let content = bytes(60_000)
        var request = phone.fileRequest("resumed.bin", content)
        request.sha256 = sha256(bytes(60_000, seed: 2))
        let state = try await phone.client.postItem(request)
        _ = try await phone.put(state.id, offset: 0, content.prefix(30_000))
        try await harness.restart()
        await expectRefused(422, "hashMismatch") { _ = try await phone.put(state.id, offset: 30_000, content.subdata(in: 30_000..<60_000)) }
        XCTAssertEqual(files(in: phoneFolder), [])

        let good = try await phone.beginFile("resumed-ok.bin", content)
        _ = try await phone.put(good.id, offset: 0, content.prefix(30_000))
        try await harness.restart()
        let done = try await phone.put(good.id, offset: 30_000, content.subdata(in: 30_000..<60_000))
        XCTAssertTrue(done.done)
        XCTAssertEqual(files(in: phoneFolder), ["resumed-ok.bin"])
    }

    func testEmptyFileIsDoneAtOnce() async throws {
        let state = try await phone.beginFile("empty.txt", Data())
        XCTAssertTrue(state.done)
        XCTAssertEqual(try Data(contentsOf: phoneFolder.appendingPathComponent("empty.txt")), Data())
    }

    func testAChunkOfAFileThatIsDoneAnswersItsDoneState() async throws {
        let content = bytes(1000)
        let id = try await phone.upload("done.bin", content)
        let again = try await phone.put(id, offset: 0, content)
        XCTAssertTrue(again.done)
        XCTAssertEqual(files(in: phoneFolder), ["done.bin"])
    }

    func testRefusesWhenTheDriveWouldDropUnderOneGibibyte() async throws {
        harness.space.bytes = Limits.minFree + 999
        await expectRefused(507, "diskFull") { _ = try await phone.beginFile("big.bin", bytes(1000)) }
        harness.space.bytes = Limits.minFree + 1000
        let state = try await phone.beginFile("fits.bin", bytes(1000))
        harness.space.bytes = Limits.minFree + 100
        await expectRefused(507, "diskFull") { _ = try await phone.put(state.id, offset: 0, bytes(1000)) }
        harness.space.bytes = Int64.max
        let done = try await phone.put(state.id, offset: 0, bytes(1000))
        XCTAssertTrue(done.done)
    }

    func testOneItemOfAnotherPhoneIsNotVisible() async throws {
        let other = try await harness.pair(name: "Other")
        let state = try await phone.beginFile("mine.bin", bytes(1000))
        await expectRefused(404, "notFound") { _ = try await other.client.itemState(state.id) }
        await expectRefused(404, "notFound") { _ = try await other.put(state.id, offset: 0, bytes(1000)) }
        _ = try await phone.client.itemState(state.id)
    }

    func testGalleryItemsGoToAMonthFolderByTheirModifiedDate() async throws {
        try await phone.upload("IMG_1.jpg", bytes(500), sourceId: "asset-1", modified: "2025-03-14T12:00:00Z")
        try await phone.upload("IMG_2.jpg", bytes(500), sourceId: "asset-2", modified: "2024-11-20T12:00:00Z")
        try await phone.upload("IMG_3.jpg", bytes(500), sourceId: "asset-3")
        let gallery = phoneFolder.appendingPathComponent("Gallery")
        XCTAssertTrue(files(in: gallery).contains("2025-03"))
        XCTAssertTrue(files(in: gallery).contains("2024-11"))
        XCTAssertEqual(files(in: gallery.appendingPathComponent("2025-03")), ["IMG_1.jpg"])
        XCTAssertEqual(files(in: gallery).count, 3)
    }

    func testImplausibleModifiedDateStillReceivesTheFile() async throws {
        try await phone.upload("old.jpg", bytes(100), sourceId: "asset-old", modified: "1970-01-01T00:00:00Z")
        try await phone.upload("future.jpg", bytes(100), sourceId: "asset-future", modified: "2200-01-01T00:00:00Z")
        let gallery = phoneFolder.appendingPathComponent("Gallery")
        let months = files(in: gallery)
        XCTAssertEqual(months.count, 1)
        XCTAssertEqual(files(in: gallery.appendingPathComponent(months[0])), ["future.jpg", "old.jpg"])
    }

    func testAnUnreadableModifiedDateIsRefused() async throws {
        await expectRefused(400, "badRequest") { _ = try await phone.beginFile("x.jpg", bytes(10), modified: "yesterday") }
    }

    func testGalleryCheckReturnsOnlyWhatIsNewAndSurvivesARestart() async throws {
        let before = try await phone.client.galleryMissing(["a", "b", "c", "b"])
        XCTAssertEqual(before, ["a", "b", "c"])
        try await phone.upload("a.jpg", bytes(100), sourceId: "a")
        try await phone.upload("c.jpg", bytes(100), sourceId: "c")
        let after = try await phone.client.galleryMissing(["c", "b", "a", "d"])
        XCTAssertEqual(after, ["b", "d"])
        try await harness.restart()
        let restarted = try await phone.client.galleryMissing(["a", "b", "c"])
        XCTAssertEqual(restarted, ["b"])
    }

    func testAnAssetReceivedBeforeIsAnsweredAsADuplicate() async throws {
        try await phone.upload("a.jpg", bytes(100), sourceId: "asset-a")
        let again = try await phone.beginFile("a.jpg", bytes(100), sourceId: "asset-a")
        XCTAssertTrue(again.done)
        XCTAssertEqual(again.duplicate, true)
        XCTAssertEqual(again.id, "")
        XCTAssertEqual(again.offset, 100)
        XCTAssertEqual(files(in: phoneFolder.appendingPathComponent("Gallery")).count, 1)
    }

    func testTheSameAssetInProgressIsNotStartedTwice() async throws {
        let content = bytes(5000)
        let first = try await phone.beginFile("p.jpg", content, sourceId: "asset-p")
        _ = try await phone.put(first.id, offset: 0, content.prefix(2000))
        let second = try await phone.beginFile("p.jpg", content, sourceId: "asset-p")
        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(second.offset, 2000)
        let results = try await withThrowingTaskGroup(of: String.self) { group -> [String] in
            for _ in 0..<8 {
                group.addTask { try await self.phone.beginFile("q.jpg", content, sourceId: "asset-q").id }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        XCTAssertEqual(Set(results).count, 1)
    }

    func testAFileStillInProgressIsNotCountedAsReceived() async throws {
        let content = bytes(4000)
        let state = try await phone.beginFile("half.jpg", content, sourceId: "asset-half")
        _ = try await phone.put(state.id, offset: 0, content.prefix(1000))
        let missing = try await phone.client.galleryMissing(["asset-half"])
        XCTAssertEqual(missing, ["asset-half"])
    }

    func testGalleryIndexIsPerPhone() async throws {
        let other = try await harness.pair(name: "Other")
        try await phone.upload("a.jpg", bytes(100), sourceId: "shared")
        let missing = try await other.client.galleryMissing(["shared"])
        XCTAssertEqual(missing, ["shared"])
    }

    func testGalleryIndexOutlivesForgettingThePhone() async throws {
        let id = phone.id
        try await phone.upload("a.jpg", bytes(100), sourceId: "kept")
        try await phone.client.forgetSelf()
        XCTAssertTrue(harness.service.gallery.contains(id, "kept"))
        let again = try await harness.pair(id: id)
        let missing = try await again.client.galleryMissing(["kept", "new"])
        XCTAssertEqual(missing, ["new"])
    }

    func testGalleryCheckTakesAtMostAThousandIds() async throws {
        let thousand = (0..<1000).map { "id-\($0)" }
        let all = try await phone.client.galleryMissing(thousand)
        XCTAssertEqual(all.count, 1000)
        await expectRefused(413, "tooLarge") { _ = try await phone.client.galleryMissing(thousand + ["one-more"]) }
        let bad = try await phone.json("POST", "/v1/gallery/check", ["ids": ["fine", "bad\nid"]])
        XCTAssertEqual(bad.status, 400)
    }

    func testReceiveFolderCanBeMoved() async throws {
        let elsewhere = harness.root.appendingPathComponent("elsewhere")
        harness.service.settings.setReceiveRoot(elsewhere)
        try await phone.upload("moved.txt", bytes(100))
        XCTAssertEqual(files(in: elsewhere.appendingPathComponent("Test iPhone")), ["moved.txt"])
        harness.service.settings.setReceiveRoot(nil)
        try await phone.upload("back.txt", bytes(100))
        XCTAssertEqual(files(in: phoneFolder), ["back.txt"])
    }

    func testAMovedReceiveFolderDoesNotStrandATransferInProgress() async throws {
        let content = bytes(2000)
        let state = try await phone.beginFile("stay.bin", content)
        harness.service.settings.setReceiveRoot(harness.root.appendingPathComponent("elsewhere"))
        let done = try await phone.put(state.id, offset: 0, content)
        XCTAssertTrue(done.done)
        XCTAssertEqual(files(in: phoneFolder), ["stay.bin"])
    }

    func testRemovingAPhoneLeavesNoPartBehind() async throws {
        let state = try await phone.beginFile("gone.bin", bytes(5000))
        _ = try await phone.put(state.id, offset: 0, bytes(5000).prefix(1000))
        harness.service.devices.remove(phone.id)
        XCTAssertEqual(files(in: phoneFolder), [])
        XCTAssertTrue(harness.service.inbox.transfers.isEmpty)
    }

    func testAPartDeletedBehindOurBackDropsTheRecord() async throws {
        let state = try await phone.beginFile("lost.bin", bytes(5000))
        try FileManager.default.removeItem(at: phoneFolder.appendingPathComponent(state.id + ".part"))
        await expectRefused(404, "notFound") { _ = try await phone.put(state.id, offset: 0, bytes(100)) }
        await expectRefused(404, "notFound") { _ = try await phone.client.itemState(state.id) }
    }

    func testAFullPartIsFinishedByTheNextStatusRequestAfterARestart() async throws {
        let content = bytes(3000)
        let state = try await phone.beginFile("full.bin", content)
        try content.write(to: phoneFolder.appendingPathComponent(state.id + ".part"))
        try await harness.restart()
        XCTAssertEqual(files(in: phoneFolder), [state.id + ".part"])
        let after = try await phone.client.itemState(state.id)
        XCTAssertTrue(after.done)
        XCTAssertEqual(files(in: phoneFolder), ["full.bin"])
    }

    func testAnAssetIsNeverNeitherInProgressNorReceived() async throws {
        let content = bytes(2000)
        let state = try await phone.beginFile("race.jpg", content, sourceId: "race-asset")
        let results = try await withThrowingTaskGroup(of: Bool.self) { group -> [Bool] in
            group.addTask { try await self.phone.put(state.id, offset: 0, content).done }
            for _ in 0..<6 {
                group.addTask { try await self.phone.beginFile("race.jpg", content, sourceId: "race-asset").id != state.id }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        let all = FileManager.default.enumerator(atPath: phoneFolder.appendingPathComponent("Gallery").path)?.allObjects as? [String] ?? []
        XCTAssertEqual(all.filter { $0.hasSuffix(".jpg") || $0.hasSuffix(".part") }.count, 1)
        XCTAssertEqual(results.count, 7)
    }

    func testAnEmptyPutAtTheEndFinishesAFullPart() async throws {
        let content = bytes(3000)
        let state = try await phone.beginFile("end.bin", content)
        let handle = try FileHandle(forWritingTo: phoneFolder.appendingPathComponent(state.id + ".part"))
        try handle.write(contentsOf: content)
        try handle.close()
        let done = try await phone.put(state.id, offset: 3000, Data())
        XCTAssertTrue(done.done)
    }

    func testAnEmptyPutBeforeTheEndIsAMismatch() async throws {
        let state = try await phone.beginFile("early.bin", bytes(3000))
        await expectRefused(400, "badRequest") { _ = try await phone.put(state.id, offset: 0, Data()) }
    }

    // The offset once the server has stopped writing what a dropped connection left in its buffers.
    private func waitForSettledOffset(_ id: String) async throws -> Int64 {
        var last: Int64 = -1
        var stable = 0
        let end = Date().addingTimeInterval(10)
        while Date() < end {
            let now = harness.service.inbox.state(phone.id, id)?.offset ?? 0
            stable = now == last && now > 0 ? stable + 1 : 0
            if stable >= 5 { return now }
            last = now
            try await Task.sleep(nanoseconds: 60_000_000)
        }
        return last
    }

    private func waitForOffset(_ id: String, _ condition: (Int64) -> Bool) async throws -> Int64 {
        var offset: Int64 = 0
        _ = await waitUntil {
            offset = harness.service.inbox.state(phone.id, id)?.offset ?? 0
            return condition(offset)
        }
        return offset
    }
}

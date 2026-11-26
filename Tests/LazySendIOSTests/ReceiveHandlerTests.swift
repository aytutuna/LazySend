#if os(iOS)
import LazySendKit
import XCTest
@testable import LazySendIOS
@testable import LazySendServer

@MainActor
final class ReceiveHandlerTests: XCTestCase {
    private func fixture() -> (handler: ReceiveHandler, timeline: Timeline, folder: URL, env: AppEnvironment) {
        let env = AppEnvironment.temporary()
        let timeline = Timeline(file: env.support.appendingPathComponent("timeline.json"))
        let handler = ReceiveHandler(pcId: "office-pc-0001", pcName: "Office PC", timeline: timeline, folder: env.documents, notifier: .silent, defaults: env.defaults,
                                     saved: SavedAssets(file: env.support.appendingPathComponent("saved-assets.json")),
                                     gallery: GalleryIndex(directory: env.support.appendingPathComponent("guest-index")))
        return (handler, timeline, env.documents, env)
    }

    private func file(_ id: String = "item-0001", name: String, size: Int64) -> OutboxEntry {
        OutboxEntry(id: id, kind: "file", name: name, size: size, mime: "text/plain")
    }

    private func exists(_ folder: URL, _ name: String) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
    }

    func testTextAndLinksGoToTheTimeline() async {
        let (handler, timeline, _, _) = fixture()
        await handler.receiveNote(OutboxEntry(id: "note-0001", kind: "text", text: "hello"))
        await handler.receiveNote(OutboxEntry(id: "note-0002", kind: "link", url: "https://alazy.app"))
        let text = timeline.get("in-note-0001")
        XCTAssertEqual(text?.kind, .text)
        XCTAssertEqual(text?.title, "hello")
        XCTAssertEqual(text?.direction, .received)
        XCTAssertEqual(text?.pcName, "Office PC")
        XCTAssertEqual(text?.state, .done)
        XCTAssertEqual(timeline.get("in-note-0002")?.kind, .link)
        let done = await handler.isDone(OutboxEntry(id: "note-0001", kind: "text"))
        XCTAssertTrue(done)
    }

    func testFileIsKeptAsPartUntilFinished() async throws {
        let (handler, timeline, folder, _) = fixture()
        let item = file(name: "report.txt", size: 5)
        let have = try await handler.prepareFile(item)
        XCTAssertEqual(have, 0)
        XCTAssertTrue(exists(folder, "report.txt.part"))
        XCTAssertEqual(timeline.get("in-item-0001")?.state, .active)
        try handler.write(Data("hello".utf8), for: item)
        try await handler.finishFile(item)
        XCTAssertFalse(exists(folder, "report.txt.part"))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("report.txt")), Data("hello".utf8))
        let entry = timeline.get("in-item-0001")
        XCTAssertEqual(entry?.state, .done)
        XCTAssertEqual(entry?.fileName, "report.txt")
        let done = await handler.isDone(item)
        XCTAssertTrue(done)
    }

    func testNamesAreMadeSafeAndUnique() async throws {
        let (handler, timeline, folder, _) = fixture()
        let first = file("item-0001", name: "bad/na:me.txt", size: 0)
        let second = file("item-0002", name: "bad/na:me.txt", size: 0)
        _ = try await handler.prepareFile(first)
        _ = try await handler.prepareFile(second)
        XCTAssertEqual(timeline.get("in-item-0001")?.fileName, "bad_na_me.txt.part")
        XCTAssertEqual(timeline.get("in-item-0002")?.fileName, "bad_na_me (2).txt.part")
        try await handler.finishFile(first)
        try await handler.finishFile(second)
        XCTAssertTrue(exists(folder, "bad_na_me.txt"))
        XCTAssertTrue(exists(folder, "bad_na_me (2).txt"))
    }

    func testNameHelpers() {
        XCTAssertEqual(ReceiveHandler.unique("a.txt") { $0 == "a.txt" || $0 == "a (2).txt" }, "a (3).txt")
        XCTAssertEqual(ReceiveHandler.unique("a") { $0 == "a" }, "a (2)")
    }

    func testHalfSavedFileResumesFromItsSize() async throws {
        let (first, timeline, folder, env) = fixture()
        let item = file(name: "big.txt", size: 11)
        _ = try await first.prepareFile(item)
        try first.write(Data("hello".utf8), for: item)
        await first.pause(item)
        XCTAssertEqual(timeline.get("in-item-0001")?.state, .paused)

        let second = ReceiveHandler(pcId: "office-pc-0001", pcName: "Office PC", timeline: timeline, folder: folder, notifier: .silent, defaults: env.defaults,
                                      saved: SavedAssets(file: env.support.appendingPathComponent("saved-assets.json")),
                                     gallery: GalleryIndex(directory: env.support.appendingPathComponent("guest-index")))
        let have = try await second.prepareFile(item)
        XCTAssertEqual(have, 5)
        XCTAssertEqual(timeline.get("in-item-0001")?.bytes, 5)
        try second.write(Data(" world".utf8), for: item)
        try await second.finishFile(item)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("big.txt")), Data("hello world".utf8))
    }

    func testResetEmptiesThePart() async throws {
        let (handler, _, folder, _) = fixture()
        let item = file(name: "again.txt", size: 3)
        _ = try await handler.prepareFile(item)
        try handler.write(Data("abc".utf8), for: item)
        try handler.resetFile(item)
        try handler.write(Data("xyz".utf8), for: item)
        try await handler.finishFile(item)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("again.txt")), Data("xyz".utf8))
    }

    func testFailureRemovesThePartAndMarksTheEntry() async throws {
        let (handler, timeline, folder, _) = fixture()
        let item = file(name: "broken.txt", size: 10)
        _ = try await handler.prepareFile(item)
        try handler.write(Data("abc".utf8), for: item)
        await handler.fail(item, reason: "disk full")
        XCTAssertFalse(exists(folder, "broken.txt.part"))
        let entry = timeline.get("in-item-0001")
        XCTAssertEqual(entry?.state, .failed)
        XCTAssertEqual(entry?.detail, "disk full")
    }

    func testFailureOfAnItemNeverStartedAddsAFailedEntry() async {
        let (handler, timeline, _, _) = fixture()
        await handler.fail(file("item-0009", name: "never.txt", size: 1), reason: "nope")
        XCTAssertEqual(timeline.get("in-item-0009")?.state, .failed)
        XCTAssertEqual(timeline.get("in-item-0009")?.title, "never.txt")
    }

    private func gallery(_ id: String, name: String, size: Int64, taken: String? = nil) -> OutboxEntry {
        OutboxEntry(id: id, kind: "file", name: name, size: size, mime: "image/jpeg", sourceId: "asset-" + id + "#photo", taken: taken)
    }

    func testGalleryFileIsFiledUnderTheComputerByTheMonthItWasTaken() async throws {
        let (handler, timeline, folder, _) = fixture()
        let item = gallery("gallery-0001", name: "IMG_1.jpg", size: 3, taken: "2021-03-15T12:00:00Z")
        _ = try await handler.prepareFile(item)
        try handler.write(Data([1, 2, 3]), for: item)
        try await handler.finishFile(item)
        let month = Inbox.month(Date(timeIntervalSince1970: 1_615_809_600))
        let placed = folder.appendingPathComponent("Office PC/Gallery/\(month)/IMG_1.jpg")
        XCTAssertEqual(try Data(contentsOf: placed), Data([1, 2, 3]))
        let modified = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: placed.path)[.modificationDate] as? Date)
        XCTAssertEqual(modified.timeIntervalSince1970, 1_615_809_600, accuracy: 1)
        XCTAssertFalse(exists(folder, "Office PC/gallery-0001.part"))
        XCTAssertNil(timeline.get("in-gallery-0001"))
        let done = await handler.isDone(item)
        XCTAssertTrue(done)
    }

    func testGalleryFileWithoutADateIsFiledByTheDayItArrived() async throws {
        let (handler, _, folder, _) = fixture()
        let item = gallery("gallery-0002", name: "IMG_2.jpg", size: 1)
        _ = try await handler.prepareFile(item)
        try handler.write(Data([5]), for: item)
        try await handler.finishFile(item)
        XCTAssertTrue(exists(folder, "Office PC/Gallery/\(Inbox.month(Date()))/IMG_2.jpg"))
    }

    func testGalleryFilesShareOneRowForTheComputer() async throws {
        let (handler, timeline, _, _) = fixture()
        for index in 1...3 {
            let item = gallery("gallery-010\(index)", name: "IMG_\(index).jpg", size: 1)
            _ = try await handler.prepareFile(item)
            try handler.write(Data([1]), for: item)
            try await handler.finishFile(item)
        }
        let rows = timeline.entries.filter { $0.kind == .gallery }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.count, 3)
        XCTAssertEqual(rows.first?.id, "in-gallery-office-pc-0001")
        XCTAssertEqual(rows.first?.direction, .received)
        XCTAssertFalse(timeline.entries.contains { $0.kind == .file })
    }

    func testHalfSavedGalleryFileContinuesFromItsSize() async throws {
        let (first, timeline, folder, env) = fixture()
        let item = gallery("gallery-0003", name: "IMG_3.jpg", size: 11)
        _ = try await first.prepareFile(item)
        try first.write(Data("hello".utf8), for: item)
        await first.pause(item)
        let second = ReceiveHandler(pcId: "office-pc-0001", pcName: "Office PC", timeline: timeline, folder: folder, notifier: .silent, defaults: env.defaults,
                                    saved: SavedAssets(file: env.support.appendingPathComponent("saved-assets.json")),
                                     gallery: GalleryIndex(directory: env.support.appendingPathComponent("guest-index")))
        let have = try await second.prepareFile(item)
        XCTAssertEqual(have, 5)
    }

    func testAnAssetReceivedBeforeIsDoneUnderANewItemId() async throws {
        let (handler, _, _, _) = fixture()
        let item = gallery("gallery-0005", name: "IMG_5.jpg", size: 1)
        _ = try await handler.prepareFile(item)
        try handler.write(Data([1]), for: item)
        try await handler.finishFile(item)
        var again = item
        again.id = "gallery-0006"
        let done = await handler.isDone(again)
        XCTAssertTrue(done)
    }

    func testRemovingAComputerDeletesItsPartsAndKeepsSavedFiles() async throws {
        let (handler, _, folder, _) = fixture()
        let finished = gallery("gallery-0007", name: "IMG_7.jpg", size: 1)
        _ = try await handler.prepareFile(finished)
        try handler.write(Data([1]), for: finished)
        try await handler.finishFile(finished)
        let begun = gallery("gallery-0008", name: "IMG_8.jpg", size: 10)
        _ = try await handler.prepareFile(begun)
        XCTAssertTrue(exists(folder, "Office PC/gallery-0008.part"))
        ReceiveHandler.discardParts(folder: folder, pcName: "Office PC")
        XCTAssertFalse(exists(folder, "Office PC/gallery-0008.part"))
        XCTAssertTrue(exists(folder, "Office PC/Gallery/\(Inbox.month(Date()))/IMG_7.jpg"))
    }

    func testOldPartsNoItemWillContinueAreSweptButListedAndFreshOnesStay() async throws {
        let (_, _, folder, _) = fixture()
        let directory = folder.appendingPathComponent("Office PC", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["stale-part-0001", "listed-part-0001", "fresh-part-0001"] {
            try Data([1]).write(to: directory.appendingPathComponent(name + ".part"))
        }
        let old = Date().addingTimeInterval(-3 * 24 * 3600)
        for name in ["stale-part-0001", "listed-part-0001"] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: directory.appendingPathComponent(name + ".part").path)
        }
        ReceiveHandler.removeStaleParts(folder: folder, pcName: "Office PC", keeping: ["listed-part-0001"])
        XCTAssertFalse(exists(folder, "Office PC/stale-part-0001.part"))
        XCTAssertTrue(exists(folder, "Office PC/listed-part-0001.part"))
        XCTAssertTrue(exists(folder, "Office PC/fresh-part-0001.part"))
    }

    func testGalleryFileIsAcknowledgedAfterTheDownload() async throws {
        let (handler, _, folder, _) = fixture()
        let item = gallery("gallery-0004", name: "IMG_4.jpg", size: 4, taken: "2022-07-01T09:30:00+02:00")
        let api = ScriptedOutbox(items: [item], files: [item.id: Data([1, 2, 3, 4])])
        let taken = try await OutboxCollector(handler: handler).collect(api: api, wait: 0)
        XCTAssertEqual(taken, 1)
        XCTAssertEqual(api.acknowledged, [item.id])
        XCTAssertTrue(exists(folder, "Office PC/Gallery"))
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
#endif

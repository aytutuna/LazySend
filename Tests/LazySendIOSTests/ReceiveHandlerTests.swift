#if os(iOS)
import LazySendKit
import XCTest
@testable import LazySendIOS

@MainActor
final class ReceiveHandlerTests: XCTestCase {
    private func fixture() -> (handler: ReceiveHandler, timeline: Timeline, folder: URL, env: AppEnvironment) {
        let env = AppEnvironment.temporary()
        let timeline = Timeline(file: env.support.appendingPathComponent("timeline.json"))
        let handler = ReceiveHandler(pcName: "Office PC", timeline: timeline, folder: env.documents, notifier: .silent, defaults: env.defaults,
                                     saved: SavedAssets(file: env.support.appendingPathComponent("saved-assets.json")))
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
        XCTAssertEqual(ReceiveHandler.safeName(nil), "file")
        XCTAssertEqual(ReceiveHandler.safeName("  "), "file")
        XCTAssertEqual(ReceiveHandler.safeName(".hidden"), "_.hidden")
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

        let second = ReceiveHandler(pcName: "Office PC", timeline: timeline, folder: folder, notifier: .silent, defaults: env.defaults,
                                      saved: SavedAssets(file: env.support.appendingPathComponent("saved-assets.json")))
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
}
#endif

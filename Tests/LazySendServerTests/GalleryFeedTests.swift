import Foundation
import XCTest
@testable import LazySendKit
@testable import LazySendServer

/// A photo library of small files made on demand, counting how many were exported.
final class FakeLibrary: @unchecked Sendable {
    private let lock = NSLock()
    private let folder: URL
    private var exported = 0
    var assets: [(id: String, name: String, taken: Date?)]
    /// Sizes the assets claim; 3 for the rest.
    var sizes: [String: Int64] = [:]
    /// How many more exports of an asset fail.
    var failures: [String: Int] = [:]

    init(folder: URL, count: Int) {
        self.folder = folder
        assets = (1...count).map { ("asset-\($0)#photo", "IMG_\($0).jpg", Date(timeIntervalSince1970: 1_615_809_600 + Double($0))) }
    }

    var exports: Int {
        lock.lock()
        defer { lock.unlock() }
        return exported
    }

    func items() -> [GalleryItem] {
        assets.map { asset in
            GalleryItem(sourceId: asset.id, name: asset.name, mime: "image/jpeg", modified: asset.taken, sizeHint: sizes[asset.id] ?? 3) { [self] in
                lock.lock()
                exported += 1
                let failing = failures[asset.id] ?? 0
                if failing > 0 { failures[asset.id] = failing - 1 }
                lock.unlock()
                if failing > 0 { throw CocoaError(.fileReadUnknown) }
                let temp = folder.appendingPathComponent("export-" + UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
                let file = temp.appendingPathComponent("original")
                try Data(repeating: 1, count: Int(sizes[asset.id] ?? 3)).write(to: file)
                return ExportedFile(url: file, size: 3, cleanup: { try? FileManager.default.removeItem(at: temp) })
            }
        }
    }
}

@MainActor
final class GalleryFeedTests: XCTestCase {
    private var root: URL!
    private var library: FakeLibrary!
    private var outbox: Outbox!
    private var feed: GalleryFeed!
    private let guest = "guest-phone-0001"
    private var free = Int64.max

    private var outgoing: URL { root.appendingPathComponent("Outgoing", isDirectory: true) }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lazysend-feed-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        library = FakeLibrary(folder: root, count: 50)
        makeFeed()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    // Also what a restart does: the same folders, new objects.
    private func makeFeed() {
        outbox = Outbox(url: root.appendingPathComponent("outbox.json"))
        let library = self.library!
        feed = GalleryFeed(outbox: outbox, indexDirectory: root.appendingPathComponent("feed-index"),
                           stateURL: root.appendingPathComponent("feeds.json"), outgoing: outgoing, retryDelay: 0.05, queueBytes: 100,
                           freeSpace: { [unowned self] in free }, library: { library.items() })
    }

    private func queued() -> [OutboxItem] {
        outbox.pending(guest)
    }

    private func copies() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: outgoing.path)) ?? []
    }

    func testNeverMoreThanTwentyAreQueuedAndNothingIsExportedAhead() async {
        await feed.start(guest)
        XCTAssertEqual(queued().count, 20)
        XCTAssertEqual(library.exports, 20)
        XCTAssertEqual(copies().count, 20)
        XCTAssertEqual(feed.progress(guest), GalleryFeedProgress(sent: 0, total: 50, done: false))
        XCTAssertEqual(queued().first?.sourceId, "asset-1#photo")
        XCTAssertEqual(queued().first?.name, "IMG_1.jpg")
        XCTAssertEqual(queued().first?.taken, Date(timeIntervalSince1970: 1_615_809_601))
    }

    func testAnAcknowledgementMarksTheItemSentAndTopsUp() async {
        await feed.start(guest)
        let first = queued()[0]
        outbox.acknowledge(guest, first.id)
        let refilled = await waitUntil { self.queued().count == 20 && self.library.exports == 21 }
        XCTAssertTrue(refilled)
        XCTAssertEqual(feed.progress(guest)?.sent, 1)
        XCTAssertFalse(queued().contains { $0.sourceId == first.sourceId })
        XCTAssertFalse(FileManager.default.fileExists(atPath: outgoing.appendingPathComponent(URL(fileURLWithPath: first.path ?? "").deletingLastPathComponent().lastPathComponent).path))
        XCTAssertEqual(copies().count, 20)
    }

    func testARestartResumesWithoutSendingAgain() async {
        await feed.start(guest)
        let done = queued().prefix(5).map { $0.sourceId }
        for item in queued().prefix(5) { outbox.acknowledge(guest, item.id) }
        _ = await waitUntil { self.queued().count == 20 }
        let waiting = Set(queued().compactMap(\.sourceId))
        makeFeed()
        XCTAssertEqual(feed.running, [guest])
        await feed.resume()
        let ids = queued().compactMap(\.sourceId)
        XCTAssertEqual(ids.count, 20)
        XCTAssertEqual(Set(ids), waiting)
        XCTAssertTrue(Set(ids).isDisjoint(with: done.compactMap { $0 }))
        XCTAssertEqual(feed.progress(guest)?.sent, 5)
        XCTAssertEqual(feed.progress(guest)?.total, 50)
        for item in queued() { outbox.acknowledge(guest, item.id) }
        _ = await waitUntil { self.queued().count == 20 }
        XCTAssertTrue(Set(queued().compactMap(\.sourceId)).isDisjoint(with: done.compactMap { $0 }))
        XCTAssertTrue(Set(queued().compactMap(\.sourceId)).isDisjoint(with: waiting))
    }

    func testStopClearsTheQueueAndTheCopies() async {
        await feed.start(guest)
        feed.stop(guest)
        XCTAssertTrue(queued().isEmpty)
        XCTAssertTrue(copies().isEmpty)
        XCTAssertNil(feed.progress(guest))
        XCTAssertTrue(feed.running.isEmpty)
        makeFeed()
        XCTAssertTrue(feed.running.isEmpty)
    }

    func testStopKeepsWhatTheGuestAlreadyHas() async {
        await feed.start(guest)
        outbox.acknowledge(guest, queued()[0].id)
        _ = await waitUntil { self.library.exports == 21 }
        feed.stop(guest)
        await feed.start(guest)
        XCTAssertEqual(feed.progress(guest)?.total, 49)
        XCTAssertFalse(queued().contains { $0.sourceId == "asset-1#photo" })
    }

    func testRemovingTheGuestClearsEverything() async {
        await feed.start(guest)
        outbox.acknowledge(guest, queued()[0].id)
        _ = await waitUntil { self.library.exports == 21 }
        feed.reconcile(paired: [])
        XCTAssertTrue(queued().isEmpty)
        XCTAssertTrue(copies().isEmpty)
        XCTAssertNil(feed.progress(guest))
        await feed.start(guest)
        XCTAssertEqual(feed.progress(guest)?.total, 50)
    }

    func testAPairedGuestIsLeftAloneByTheCheck() async {
        await feed.start(guest)
        feed.reconcile(paired: [guest])
        XCTAssertEqual(queued().count, 20)
    }

    func testTheRunEndsWhenEveryAssetIsSentAndAnotherRunSendsOnlyNewOnes() async {
        library = FakeLibrary(folder: root, count: 25)
        makeFeed()
        await feed.start(guest)
        while !queued().isEmpty {
            for item in queued() { outbox.acknowledge(guest, item.id) }
            _ = await waitUntil { self.feed.progress(self.guest)?.done == true || self.queued().count > 0 }
        }
        _ = await waitUntil { self.feed.progress(self.guest)?.done == true }
        XCTAssertEqual(feed.progress(guest), GalleryFeedProgress(sent: 25, total: 25, done: true))
        XCTAssertTrue(feed.running.isEmpty)
        XCTAssertTrue(copies().isEmpty)
        library.assets.append(("asset-26#photo", "IMG_26.jpg", nil))
        await feed.start(guest)
        XCTAssertEqual(feed.progress(guest), GalleryFeedProgress(sent: 0, total: 1, done: false))
        XCTAssertEqual(queued().map(\.sourceId), ["asset-26#photo"])
        XCTAssertNil(queued().first?.taken)
    }

    func testADateOutsideTheUsableYearsIsLeftOutOfTheEntry() async {
        library.assets = [("old#photo", "old.jpg", Date(timeIntervalSince1970: -5_000_000_000)), ("ok#photo", "ok.jpg", Date(timeIntervalSince1970: 1_615_809_600))]
        await feed.start(guest)
        let entries = queued().map(\.entry)
        XCTAssertNil(entries[0].taken)
        XCTAssertEqual(entries[1].taken, "2021-03-15T12:00:00Z")
    }

    func testAnAssetThatFailsToExportIsTriedOnceMoreAtTheEnd() async {
        library = FakeLibrary(folder: root, count: 3)
        library.failures["asset-2#photo"] = 1
        makeFeed()
        await feed.start(guest)
        XCTAssertEqual(queued().compactMap(\.sourceId), ["asset-1#photo", "asset-3#photo", "asset-2#photo"])
        for item in queued() { outbox.acknowledge(guest, item.id) }
        _ = await waitUntil { self.feed.progress(self.guest)?.done == true }
        XCTAssertEqual(feed.progress(guest), GalleryFeedProgress(sent: 3, total: 3, done: true))
    }

    func testAnAssetThatFailsTwiceIsCountedAsNotSent() async {
        library = FakeLibrary(folder: root, count: 3)
        library.failures["asset-2#photo"] = 5
        makeFeed()
        await feed.start(guest)
        XCTAssertEqual(queued().count, 2)
        XCTAssertEqual(library.exports, 4)
        for item in queued() { outbox.acknowledge(guest, item.id) }
        _ = await waitUntil { self.feed.progress(self.guest)?.done == true }
        XCTAssertEqual(feed.progress(guest), GalleryFeedProgress(sent: 2, total: 3, done: true, failed: 1))
        makeFeed()
        XCTAssertEqual(feed.progress(guest)?.failed, 1)
    }

    func testOneOversizeItemStillGoesAndTheRestWaitForTheByteCap() async {
        library = FakeLibrary(folder: root, count: 4)
        library.sizes = ["asset-1#photo": 150, "asset-2#photo": 60, "asset-3#photo": 60]
        makeFeed()
        await feed.start(guest)
        XCTAssertEqual(queued().compactMap(\.sourceId), ["asset-1#photo"])
        outbox.acknowledge(guest, queued()[0].id)
        // 60 bytes fit under the cap of 100 once, 120 do not.
        _ = await waitUntil { self.queued().count == 1 && self.library.exports == 2 }
        XCTAssertEqual(queued().compactMap(\.sourceId), ["asset-2#photo"])
        XCTAssertEqual(library.exports, 2)
    }

    func testAFullPhoneWaitsAndGoesOnWhenThereIsRoom() async {
        free = 1024 * 1024 * 1024 + 2
        await feed.start(guest)
        XCTAssertTrue(queued().isEmpty)
        XCTAssertEqual(library.exports, 0)
        XCTAssertEqual(feed.progress(guest)?.wait, .storage)
        free = Int64.max
        let queuedNow = await waitUntil { self.queued().count == 20 }
        XCTAssertTrue(queuedNow)
        XCTAssertNil(feed.progress(guest)?.wait)
    }

    func testAFullOutboxMakesTheFeedWaitInsteadOfDroppingAssets() async throws {
        for number in 1...Limits.maxOutboxItemsPerDevice { try outbox.queueText(guest, "note \(number)") }
        await feed.start(guest)
        XCTAssertEqual(feed.progress(guest)?.wait, .outbox)
        XCTAssertEqual(library.exports, 0)
        XCTAssertTrue(queued().isEmpty)
        let first = try XCTUnwrap(outbox.pending(guest).first)
        outbox.acknowledge(guest, first.id)
        let queuedOne = await waitUntil { self.queued().count == 1 }
        XCTAssertTrue(queuedOne)
        XCTAssertEqual(queued().first?.sourceId, "asset-1#photo")
        XCTAssertEqual(feed.progress(guest)?.wait, .outbox)
        XCTAssertEqual(library.exports, 1)
    }

    func testRemovingTheGuestWhileTheLibraryIsBeingReadCancelsTheStart() async {
        let slow = library!
        feed = GalleryFeed(outbox: outbox, indexDirectory: root.appendingPathComponent("feed-index"),
                           stateURL: root.appendingPathComponent("feeds.json"), outgoing: outgoing, library: {
                               try? await Task.sleep(nanoseconds: 300_000_000)
                               return slow.items()
                           })
        let starting = Task { await self.feed.start(self.guest) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        feed.reconcile(paired: [])
        await starting.value
        XCTAssertNil(feed.progress(guest))
        XCTAssertTrue(queued().isEmpty)
        XCTAssertEqual(library.exports, 0)
        XCTAssertTrue(copies().isEmpty)
    }

    func testAFeedPausesWhilePhotosCannotBeRead() async {
        await feed.start(guest)
        feed.setPhotosAllowed(false)
        XCTAssertEqual(feed.progress(guest)?.wait, .photos)
        outbox.acknowledge(guest, queued()[0].id)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(queued().count, 19)
        XCTAssertEqual(library.exports, 20)
        feed.setPhotosAllowed(true)
        await feed.resume()
        XCTAssertEqual(queued().count, 20)
        XCTAssertNil(feed.progress(guest)?.wait)
    }

    func testTheTotalGrowsWhenTheLibraryDoes() async {
        library = FakeLibrary(folder: root, count: 2)
        makeFeed()
        await feed.start(guest)
        library.assets += [("asset-3#photo", "IMG_3.jpg", nil)]
        for item in queued() { outbox.acknowledge(guest, item.id) }
        _ = await waitUntil { self.feed.progress(self.guest)?.done == true }
        XCTAssertEqual(feed.progress(guest)?.sent, 2)
        XCTAssertGreaterThanOrEqual(feed.progress(guest)?.total ?? 0, feed.progress(guest)?.sent ?? 0)
    }

    func testAnIdTheOutboxCannotKeepIsNotQueued() async {
        library.assets = [("", "a.jpg", nil), ("fine#photo", "b.jpg", nil)]
        await feed.start(guest)
        XCTAssertEqual(queued().compactMap(\.sourceId), ["fine#photo"])
        XCTAssertEqual(feed.progress(guest)?.total, 1)
    }
}

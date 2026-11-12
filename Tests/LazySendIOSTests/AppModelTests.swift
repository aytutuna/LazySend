#if os(iOS)
import LazySendKit
import XCTest
@testable import LazySendIOS

@MainActor
final class AppModelTests: XCTestCase {
    private func pairedModel() throws -> (AppModel, PairedPc) {
        let model = AppModel(env: .temporary())
        let pc = PairedPc(id: "office-pc-1", name: "Office PC", fingerprint: Base64Url.encode(Data(repeating: 3, count: 32)),
                          addresses: [], port: 52734)
        try model.store.put(pc, secret: "secret")
        model.refreshPcs()
        return (model, pc)
    }

    func testNothingPairedShowsTheEmptyState() {
        let model = AppModel(env: .temporary())
        XCTAssertTrue(model.pcs.isEmpty)
        XCTAssertNil(model.selected)
        XCTAssertTrue(model.timeline.entries.isEmpty)
    }

    func testPairedPcIsSelected() throws {
        let (model, pc) = try pairedModel()
        XCTAssertEqual(model.selected?.id, pc.id)
    }

    func testDemoDataPairsAnOfficePcAndFillsTheTimeline() {
        let model = AppModel(env: .temporary(demo: true))
        XCTAssertEqual(model.selected?.name, "Office PC")
        XCTAssertEqual(Set(model.timeline.entries.map(\.kind)), [.text, .link, .file, .gallery])
        XCTAssertTrue(model.timeline.entries.contains { $0.state == .failed })
    }

    func testNotesAreSentAsLinkOrTextAndFailWhenThePcIsUnreachable() async throws {
        let (model, pc) = try pairedModel()
        try model.sendNote("https://alazy.app/send/", to: pc)
        try model.sendNote("see you at five", to: pc)
        await model.waitForSends()
        let link = try XCTUnwrap(model.timeline.entries.first { $0.kind == .link })
        let text = try XCTUnwrap(model.timeline.entries.first { $0.kind == .text })
        XCTAssertEqual(link.title, "https://alazy.app/send/")
        XCTAssertEqual(text.title, "see you at five")
        for entry in [link, text] {
            XCTAssertEqual(entry.direction, .sent)
            XCTAssertEqual(entry.state, .failed)
            XCTAssertEqual(entry.detail, "Office PC is not reachable")
        }
    }

    func testAnEmptyNoteIsRefused() throws {
        let (model, pc) = try pairedModel()
        XCTAssertThrowsError(try model.sendNote("  \n", to: pc)) { XCTAssertEqual($0 as? NoteError, .empty) }
        XCTAssertTrue(model.timeline.entries.isEmpty)
    }

    func testSharedItemStaysQueuedWhileThePcIsUnreachable() async throws {
        let (model, pc) = try pairedModel()
        try model.queue.add(QueuedItem(id: "share-0001", pcId: pc.id, kind: "text", text: "from the share sheet"))
        model.drainShareQueue()
        await model.waitForSends()
        XCTAssertEqual(model.queue.items().map(\.id), ["share-0001"])
        XCTAssertEqual(model.timeline.get("share-share-0001")?.state, .failed)
    }

    private func pickedFile(_ model: AppModel, name: String = "a.txt") throws -> URL {
        let folder = model.env.support.appendingPathComponent("picked-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data("hello".utf8).write(to: url)
        return url
    }

    private func copy(_ model: AppModel, _ entry: TimelineEntry) -> URL? {
        entry.localFile.map { model.env.support.appendingPathComponent("Outgoing").appendingPathComponent($0) }
    }

    func testAFileNotDeliveredKeepsItsCopy() async throws {
        let (model, pc) = try pairedModel()
        let source = try pickedFile(model)
        model.sendFiles([source], to: pc)
        await model.waitForSends()
        let entry = try XCTUnwrap(model.timeline.entries.first)
        XCTAssertEqual(entry.state, .failed)
        XCTAssertEqual(entry.pcId, pc.id)
        let kept = try XCTUnwrap(copy(model, entry))
        XCTAssertEqual(try Data(contentsOf: kept), Data("hello".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    func testResumeSendsTheKeptCopyAgain() async throws {
        let (model, pc) = try pairedModel()
        model.sendFiles([try pickedFile(model)], to: pc)
        await model.waitForSends()
        let id = try XCTUnwrap(model.timeline.entries.first).id
        model.resumeSend(id)
        XCTAssertEqual(model.timeline.get(id)?.state, .active)
        await model.waitForSends()
        let entry = try XCTUnwrap(model.timeline.get(id))
        XCTAssertEqual(entry.state, .failed)
        XCTAssertNotNil(copy(model, entry))
    }

    func testResumeWithoutTheCopyFailsTheEntry() throws {
        let (model, pc) = try pairedModel()
        model.timeline.add(TimelineEntry(id: "out-gone", direction: .sent, kind: .file, pcName: pc.name, title: "a.txt", state: .paused,
                                         pcId: pc.id, itemId: "item1", localFile: "out-gone/a.txt"))
        model.resumeSend("out-gone")
        let entry = try XCTUnwrap(model.timeline.get("out-gone"))
        XCTAssertEqual(entry.state, .failed)
        XCTAssertNil(entry.localFile)
        XCTAssertNil(entry.itemId)
    }

    func testCopiesWithoutAnEntryAreRemovedOnLaunch() throws {
        let env = AppEnvironment.temporary()
        let stray = env.support.appendingPathComponent("Outgoing/out-orphan", isDirectory: true)
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: stray.appendingPathComponent("a.txt"))
        _ = AppModel(env: env)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path))
    }

    func testAStoppedShareIsQueuedAgainByTheNextDrain() async throws {
        let (model, pc) = try pairedModel()
        try model.queue.add(QueuedItem(id: "share-0003", pcId: pc.id, kind: "text", text: "later"))
        model.drainShareQueue()
        model.stopSending()
        await model.waitForSends()
        XCTAssertEqual(model.timeline.get("share-share-0003")?.state, .paused)
        model.drainShareQueue()
        XCTAssertEqual(model.timeline.get("share-share-0003")?.state, .active)
        await model.waitForSends()
        XCTAssertEqual(model.queue.items().map(\.id), ["share-0003"])
    }

    func testSharedItemForAnUnknownPcIsDropped() throws {
        let (model, _) = try pairedModel()
        try model.queue.add(QueuedItem(id: "share-0002", pcId: "nobody", kind: "text", text: "lost"))
        model.drainShareQueue()
        XCTAssertTrue(model.queue.items().isEmpty)
    }

    func testGallerySyncWithoutPhotoAccessAddsNothingAndAsksForSettings() async throws {
        let (model, pc) = try pairedModel()
        model.startGallerySync(for: pc)
        await model.waitForGallery()
        XCTAssertEqual(model.photoNotice, .denied)
        XCTAssertNil(model.timeline.get("gallery-" + pc.id))
        XCTAssertFalse(model.galleryRunning)
        XCTAssertFalse(model.env.defaults.bool(forKey: Keys.galleryPending))
    }

    func testGallerySyncWithLimitedAccessStartsAndWaitsForTheUnreachablePc() async throws {
        var env = AppEnvironment.temporary()
        env.photos = PhotoSource(access: { .limited }, items: { _ in [] })
        let model = AppModel(env: env)
        let pc = PairedPc(id: "office-pc-1", name: "Office PC", fingerprint: Base64Url.encode(Data(repeating: 3, count: 32)),
                          addresses: [], port: 52734)
        try model.store.put(pc, secret: "secret")
        model.refreshPcs()
        model.startGallerySync(for: pc)
        await Task.yield()
        XCTAssertTrue(model.galleryRunning)
        model.stopGallery()
        await model.waitForGallery()
        XCTAssertEqual(model.photoNotice, .limited)
        XCTAssertEqual(model.timeline.get("gallery-" + pc.id)?.state, .paused)
        XCTAssertFalse(model.env.defaults.bool(forKey: Keys.galleryPending))
    }
}
#endif

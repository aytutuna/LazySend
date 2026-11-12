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

    func testSharedItemForAnUnknownPcIsDropped() throws {
        let (model, _) = try pairedModel()
        try model.queue.add(QueuedItem(id: "share-0002", pcId: "nobody", kind: "text", text: "lost"))
        model.drainShareQueue()
        XCTAssertTrue(model.queue.items().isEmpty)
    }

    func testGallerySyncSaysItIsNotAvailableYet() throws {
        let (model, pc) = try pairedModel()
        model.startGallerySync(for: pc)
        XCTAssertNotNil(model.galleryMessage)
    }
}
#endif

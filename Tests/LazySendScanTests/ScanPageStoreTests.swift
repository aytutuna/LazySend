import CoreGraphics
import Foundation
import XCTest
@testable import LazySendScan

final class ScanPageStoreTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("page-store-" + UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private func page(_ byte: UInt8, filter: CaptureFilter = .original) -> ScanPage {
        let corners = Quad(topLeft: CGPoint(x: 1, y: 2), topRight: CGPoint(x: 90, y: 3), bottomRight: CGPoint(x: 88, y: 120),
                           bottomLeft: CGPoint(x: 4, y: 118))
        return ScanPage(corners: corners, filter: filter, jpeg: Data([0xFF, 0xD8, byte]), width: 600, height: 800, dpi: 150, gray: false)
    }

    func testAPageComesBackWithItsPictureCornersAndFilter() throws {
        let store = ScanPageStore(folder: folder)
        let saved = page(1, filter: .whiteboard)
        try store.save(saved, source: Data([9, 9]))
        let loaded = try XCTUnwrap(ScanPageStore(folder: folder).load().first)
        XCTAssertEqual(loaded.id, saved.id)
        XCTAssertEqual(loaded.jpeg, saved.jpeg)
        XCTAssertEqual(loaded.corners, saved.corners)
        XCTAssertEqual(loaded.filter, .whiteboard)
        XCTAssertEqual([loaded.width, loaded.height, loaded.dpi], [600, 800, 150])
        XCTAssertEqual(store.source(of: saved.id), Data([9, 9]))
    }

    func testPagesLoadInTheOrderTheyWereSavedAndReordered() throws {
        let store = ScanPageStore(folder: folder)
        let pages = [page(1), page(2), page(3)]
        for page in pages { try store.save(page, source: Data()) }
        XCTAssertEqual(store.load().map(\.id), pages.map(\.id))
        try store.setOrder([pages[2].id, pages[0].id, pages[1].id])
        XCTAssertEqual(store.load().map(\.id), [pages[2].id, pages[0].id, pages[1].id])
    }

    func testSavingAPageAgainKeepsItsPlaceAndReplacesIt() throws {
        let store = ScanPageStore(folder: folder)
        var pages = [page(1), page(2)]
        for page in pages { try store.save(page, source: Data([1])) }
        pages[0].jpeg = Data([0xFF, 0xD8, 7])
        try store.save(pages[0], source: Data([2]))
        let loaded = store.load()
        XCTAssertEqual(loaded.map(\.id), pages.map(\.id))
        XCTAssertEqual(loaded[0].jpeg, Data([0xFF, 0xD8, 7]))
        XCTAssertEqual(store.source(of: pages[0].id), Data([2]))
    }

    func testARemovedPageIsGoneFromDisk() throws {
        let store = ScanPageStore(folder: folder)
        let pages = [page(1), page(2)]
        for page in pages { try store.save(page, source: Data([5])) }
        store.remove(pages[0].id)
        XCTAssertEqual(store.load().map(\.id), [pages[1].id])
        XCTAssertNil(store.source(of: pages[0].id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(pages[0].id.uuidString).path))
    }

    func testClearingRemovesEveryPage() throws {
        let store = ScanPageStore(folder: folder)
        for byte: UInt8 in 1...3 { try store.save(page(byte), source: Data()) }
        store.removeAll()
        XCTAssertTrue(store.load().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        try store.save(page(4), source: Data())
        XCTAssertEqual(store.load().count, 1)
    }

    func testAFolderThatWasNotFinishedIsLeftOutAndRemoved() throws {
        let store = ScanPageStore(folder: folder)
        let kept = page(1)
        try store.save(kept, source: Data())
        let stray = folder.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        let broken = page(2)
        try store.save(broken, source: Data())
        try FileManager.default.removeItem(at: folder.appendingPathComponent(broken.id.uuidString).appendingPathComponent("page.json"))
        XCTAssertEqual(store.load().map(\.id), [kept.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(broken.id.uuidString).path))
    }
}

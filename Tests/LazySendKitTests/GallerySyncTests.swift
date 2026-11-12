import XCTest
@testable import LazySendKit

private final class Refusing: GalleryLink, @unchecked Sendable {
    let missingStatus: Int?
    let postStatus: Int?

    init(missingStatus: Int? = nil, postStatus: Int? = nil) {
        self.missingStatus = missingStatus
        self.postStatus = postStatus
    }

    private func refusal(_ status: Int) -> LinkError {
        .refused(status: status, code: "unauthorized", message: "unauthorized happened", offset: nil)
    }

    func galleryMissing(_ ids: [String]) async throws -> [String] {
        if let status = missingStatus { throw refusal(status) }
        return ids
    }

    func postItem(_ item: ItemRequest) async throws -> ItemState {
        if let status = postStatus { throw refusal(status) }
        return ItemState(id: "item1", offset: 0, done: false)
    }

    func itemState(_ id: String) async throws -> ItemState {
        ItemState(id: id, offset: 0, done: false)
    }

    func putChunk(id: String, offset: Int64, data: Data, onBytes: @escaping @Sendable (Int64) -> Void) async throws -> ItemState {
        ItemState(id: id, offset: Int64(data.count), done: true)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func bump() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

final class GallerySyncTests: XCTestCase {
    private func items(_ count: Int, exports: Counter) throws -> [GalleryItem] {
        let folder = try temporaryFolder()
        let file = try randomFile(in: folder, bytes: 100)
        return (0..<count).map { index in
            GalleryItem(sourceId: "asset-\(index)#photo", name: "IMG_\(index).JPG", mime: "image/jpeg", modified: nil, sizeHint: 100) {
                exports.bump()
                return ExportedFile(url: file.url, size: 100, cleanup: {})
            }
        }
    }

    private func run(_ link: GalleryLink, items: [GalleryItem]) async throws -> GalleryResult {
        let sync = GallerySync(items: items, awaitReachable: { link }, reconnect: { link }, retryDelays: [], sleep: { _ in }, report: { _ in })
        return try await sync.run()
    }

    func testARefusedDeviceWhileSendingIsForgottenAndStopsTheRun() async throws {
        let exports = Counter()
        let result = try await run(Refusing(postStatus: 401), items: try items(3, exports: exports))
        XCTAssertEqual(result, .forgotten)
        XCTAssertEqual(exports.count, 1)
    }

    func testARefusedDeviceWhileCheckingIsForgotten() async throws {
        let exports = Counter()
        let result = try await run(Refusing(missingStatus: 401), items: try items(2, exports: exports))
        XCTAssertEqual(result, .forgotten)
        XCTAssertEqual(exports.count, 0)
    }

    func testOtherRefusalsSkipTheItem() async throws {
        let exports = Counter()
        let result = try await run(Refusing(postStatus: 400), items: try items(2, exports: exports))
        XCTAssertEqual(result, .finished(sent: 0, failed: 2))
    }
}

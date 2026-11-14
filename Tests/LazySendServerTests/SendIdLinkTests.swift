import Foundation
import XCTest
@testable import LazySendKit
@testable import LazySendServer

final class SendIdLinkTests: XCTestCase {
    private var harness: Harness!
    private var phone: Phone!
    private let sendId = "AbCdEfGhIjKlMnOpQrStUv"

    override func setUp() async throws {
        harness = try await Harness()
        phone = try await harness.pair()
    }

    override func tearDown() async throws {
        await harness.tearDown()
    }

    private func post(_ body: [String: Any]) async throws -> Reply {
        try await phone.json("POST", "/v1/items", body)
    }

    private func fileBody(size: Int, sendId: String? = nil) -> [String: Any] {
        ["kind": "file", "name": "a.bin", "size": size, "sendId": sendId ?? self.sendId]
    }

    func testRepeatInProgressGivesTheCurrentOffset() async throws {
        let content = bytes(5000)
        let first = try await post(fileBody(size: 5000))
        XCTAssertEqual(first.status, 201)
        let id = try XCTUnwrap(first.json["id"] as? String)
        _ = try await phone.put(id, offset: 0, content.prefix(2000))

        let again = try await post(fileBody(size: 5000))

        XCTAssertEqual(again.status, 200)
        XCTAssertEqual(again.json["id"] as? String, id)
        XCTAssertEqual(again.json["offset"] as? Int, 2000)
        XCTAssertEqual(again.json["done"] as? Bool, false)
        XCTAssertEqual(harness.service.inbox.transfers.count, 1)
    }

    func testRepeatInProgressSurvivesARestart() async throws {
        let content = bytes(5000)
        let first = try await post(fileBody(size: 5000))
        let id = try XCTUnwrap(first.json["id"] as? String)
        _ = try await phone.put(id, offset: 0, content.prefix(1500))

        try await harness.restart()
        let again = try await post(fileBody(size: 5000))

        XCTAssertEqual(again.status, 200)
        XCTAssertEqual(again.json["id"] as? String, id)
        XCTAssertEqual(again.json["offset"] as? Int, 1500)
    }

    func testRepeatFinishedIsDoneAndAddsNothing() async throws {
        let content = bytes(5000)
        let first = try await post(fileBody(size: 5000))
        let id = try XCTUnwrap(first.json["id"] as? String)
        _ = try await phone.put(id, offset: 0, content)
        try await harness.restart()
        let lock = NSLock()
        var received = 0
        harness.service.inbox.onFileReceived = { _ in
            lock.lock()
            received += 1
            lock.unlock()
        }

        let again = try await post(fileBody(size: 5000))

        XCTAssertEqual(again.status, 200)
        XCTAssertEqual(again.json["id"] as? String, id)
        XCTAssertEqual(again.json["offset"] as? Int, 5000)
        XCTAssertEqual(again.json["done"] as? Bool, true)
        lock.lock()
        XCTAssertEqual(received, 0)
        lock.unlock()
        let folder = harness.received.appendingPathComponent("Test iPhone")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["a.bin"])
    }

    func testOtherSizeOrKindWithTheSameSendIdIsRefused() async throws {
        let first = try await post(fileBody(size: 100))
        XCTAssertEqual(first.status, 201)

        let size = try await post(fileBody(size: 101))
        let kind = try await post(["kind": "text", "text": "hi", "sendId": sendId])

        XCTAssertEqual(size.status, 400)
        XCTAssertEqual(size.code, "badRequest")
        XCTAssertEqual(kind.status, 400)
        XCTAssertEqual(kind.code, "badRequest")
    }

    func testMalformedSendIdIsRefused() async throws {
        for bad in ["short", "0123456789abcde", "0123456789abcdef!", String(repeating: "a", count: 65)] {
            let file = try await post(fileBody(size: 10, sendId: bad))
            let text = try await post(["kind": "text", "text": "hi", "sendId": bad])
            XCTAssertEqual(file.status, 400, bad)
            XCTAssertEqual(text.status, 400, bad)
        }
        XCTAssertTrue(harness.service.history.items.isEmpty)
        XCTAssertTrue(harness.service.inbox.transfers.isEmpty)
    }

    func testRepeatedTextAndLinkAddNoSecondHistoryEntry() async throws {
        let text: [String: Any] = ["kind": "text", "text": "hello", "sendId": sendId]
        let link: [String: Any] = ["kind": "link", "url": "https://alazy.app/", "sendId": "ZyXwVuTsRqPoNmLkJiHgFe"]
        let firstText = try await post(text)
        XCTAssertEqual(firstText.status, 201)
        _ = try await post(link)

        try await harness.restart()
        let again = try await post(text)
        let againLink = try await post(link)

        XCTAssertEqual(again.status, 200)
        XCTAssertEqual(again.json["id"] as? String, firstText.json["id"] as? String)
        XCTAssertEqual(again.json["done"] as? Bool, true)
        XCTAssertEqual(againLink.status, 200)
        XCTAssertEqual(harness.service.history.items.count, 2)
    }

    func testSendIdIsScopedToTheDevice() async throws {
        let other = try await harness.pair(name: "Other", id: newId())
        let mine = try await post(fileBody(size: 10))
        let theirs = try await other.json("POST", "/v1/items", fileBody(size: 10))

        XCTAssertEqual(theirs.status, 201)
        XCTAssertNotEqual(mine.json["id"] as? String, theirs.json["id"] as? String)
    }
}

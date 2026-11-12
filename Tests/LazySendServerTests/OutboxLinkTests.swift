import Foundation
import XCTest
@testable import LazySendKit
@testable import LazySendServer

final class OutboxLinkTests: XCTestCase {
    private var harness: Harness!
    private var phone: Phone!
    private var outbox: Outbox { harness.service.outbox }

    override func setUp() async throws {
        harness = try await Harness()
        phone = try await harness.pair()
    }

    override func tearDown() async throws {
        await harness.tearDown()
    }

    private func makeFile(_ name: String, _ content: Data) throws -> URL {
        let folder = harness.root.appendingPathComponent("outgoing", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try content.write(to: url)
        return url
    }

    func testPollReturnsPendingItemsAtOnce() async throws {
        try outbox.queueText(phone.id, "first")
        try outbox.queueLink(phone.id, "https://example.com/")
        let reply = try await phone.client.outbox(wait: 0)
        XCTAssertEqual(reply.items.map(\.kind), ["text", "link"])
        XCTAssertEqual(reply.items[0].text, "first")
        XCTAssertEqual(reply.items[1].url, "https://example.com/")
        XCTAssertFalse(reply.more)
        // Still there until acknowledged.
        let again = try await phone.client.outbox(wait: 0)
        XCTAssertEqual(again.items.map(\.id), reply.items.map(\.id))
    }

    func testLongPollReturnsAsSoonAsSomethingIsQueued() async throws {
        let started = Date()
        let waiting = Task { try await phone.client.outbox(wait: 20) }
        try await Task.sleep(nanoseconds: 400_000_000)
        try outbox.queueText(phone.id, "late")
        let reply = try await waiting.value
        XCTAssertEqual(reply.items.map(\.text), ["late"])
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testLongPollWithNothingQueuedEndsEmptyAtTheTimeout() async throws {
        let started = Date()
        let reply = try await phone.client.outbox(wait: 1)
        XCTAssertTrue(reply.items.isEmpty)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.9)
        XCTAssertLessThan(Date().timeIntervalSince(started), 8)
    }

    func testItemsQueuedForAnotherPhoneDoNotWakeThisOne() async throws {
        let other = try await harness.pair(name: "Other")
        let started = Date()
        let waiting = Task { try await phone.client.outbox(wait: 2) }
        try await Task.sleep(nanoseconds: 300_000_000)
        try outbox.queueText(other.id, "not for you")
        let reply = try await waiting.value
        XCTAssertTrue(reply.items.isEmpty)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 1.8)
    }

    func testWaitIsCappedAndMustBeANumber() async throws {
        for bad in ["abc", "-1", "", "1234567"] {
            let reply = try await phone.raw("GET", "/v1/outbox?wait=\(bad)")
            XCTAssertEqual(reply.status, 400, bad)
        }
        let started = Date()
        try outbox.queueText(phone.id, "now")
        let reply = try await phone.raw("GET", "/v1/outbox?wait=99999")
        XCTAssertEqual(reply.status, 200)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testFileDownloadsWholeAndByRange() async throws {
        let content = bytes(100_000)
        let item = try XCTUnwrap(outbox.queueFiles(phone.id, [(try makeFile("data.bin", content), nil, "application/x-test")]).first)
        let listed = try await phone.client.outbox(wait: 0)
        XCTAssertEqual(listed.items.first?.name, "data.bin")
        XCTAssertEqual(listed.items.first?.size, 100_000)
        XCTAssertEqual(listed.items.first?.mime, "application/x-test")
        var status = 0
        var total: Int64 = 0
        var got = Data()
        try await phone.client.download(id: item.id, from: 0, onStart: { status = $0; total = $1 }, sink: { got.append($0) })
        XCTAssertEqual(status, 200)
        XCTAssertEqual(total, 100_000)
        XCTAssertEqual(got, content)
        got = Data()
        try await phone.client.download(id: item.id, from: 60_000, onStart: { status = $0; total = $1 }, sink: { got.append($0) })
        XCTAssertEqual(status, 206)
        XCTAssertEqual(total, 100_000)
        XCTAssertEqual(got, content.suffix(from: 60_000))
        let head = try await phone.raw("GET", "/v1/outbox/\(item.id)/data", headers: ["Range": "bytes=99999-"])
        XCTAssertEqual(head.status, 206)
        XCTAssertEqual(head.header("Content-Range"), "bytes 99999-99999/100000")
        XCTAssertEqual(head.header("Accept-Ranges"), "bytes")
        XCTAssertEqual(head.header("Content-Type"), "application/x-test")
    }

    func testABigFileStreamsWithoutBeingHeldInMemoryByTheTest() async throws {
        let content = bytes(3_000_000)
        let item = try XCTUnwrap(outbox.queueFiles(phone.id, [(try makeFile("big.bin", content), nil, nil)]).first)
        var got = Data()
        try await phone.client.download(id: item.id, from: 0, onStart: { _, _ in }, sink: { got.append($0) })
        XCTAssertEqual(got.count, 3_000_000)
        XCTAssertEqual(sha256(got), sha256(content))
        let type = try await phone.raw("GET", "/v1/outbox/\(item.id)/data").header("Content-Type")
        XCTAssertEqual(type, "application/octet-stream")
    }

    func testBadRangesAreRefused() async throws {
        let item = try XCTUnwrap(outbox.queueFiles(phone.id, [(try makeFile("r.bin", bytes(1000)), nil, nil)]).first)
        for range in ["bytes=0-5", "bytes=-5", "bytes=abc-", "items=3-", "bytes=1000-", "bytes=5000-"] {
            let reply = try await phone.raw("GET", "/v1/outbox/\(item.id)/data", headers: ["Range": range])
            XCTAssertEqual(reply.status, 416, range)
        }
        let past = try await phone.raw("GET", "/v1/outbox/\(item.id)/data", headers: ["Range": "bytes=5000-"])
        XCTAssertEqual(past.header("Content-Range"), "bytes */1000")
    }

    func testAnEmptyFileIsAlwaysSentWhole() async throws {
        let item = try XCTUnwrap(outbox.queueFiles(phone.id, [(try makeFile("empty.bin", Data()), nil, nil)]).first)
        let reply = try await phone.raw("GET", "/v1/outbox/\(item.id)/data", headers: ["Range": "bytes=0-"])
        XCTAssertEqual(reply.status, 200)
        XCTAssertEqual(reply.data.count, 0)
    }

    func testFileThatChangedOrWentIsNotServed() async throws {
        let url = try makeFile("moving.bin", bytes(1000))
        let item = try XCTUnwrap(outbox.queueFiles(phone.id, [(url, nil, nil)]).first)
        try bytes(2000).write(to: url)
        let changed = try await phone.raw("GET", "/v1/outbox/\(item.id)/data")
        XCTAssertEqual(changed.status, 409)
        XCTAssertEqual(changed.code, "changed")
        try FileManager.default.removeItem(at: url)
        let gone = try await phone.raw("GET", "/v1/outbox/\(item.id)/data")
        XCTAssertEqual(gone.status, 404)
    }

    func testTextItemsHaveNoData() async throws {
        let item = try outbox.queueText(phone.id, "text")
        let reply = try await phone.raw("GET", "/v1/outbox/\(item.id)/data")
        XCTAssertEqual(reply.status, 404)
    }

    func testAcknowledgingRemovesTheItemAndOnlyThatOne() async throws {
        let first = try outbox.queueText(phone.id, "one")
        let second = try outbox.queueText(phone.id, "two")
        try await phone.client.acknowledge(first.id)
        let reply = try await phone.client.outbox(wait: 0)
        XCTAssertEqual(reply.items.map(\.id), [second.id])
        try await phone.client.acknowledge(first.id)
        try await phone.client.acknowledge("0123456789abcdef")
        XCTAssertEqual(outbox.pending(phone.id).count, 1)
    }

    func testAnotherPhoneCannotAcknowledgeOrDownload() async throws {
        let other = try await harness.pair(name: "Other")
        let item = try XCTUnwrap(outbox.queueFiles(phone.id, [(try makeFile("mine.bin", bytes(100)), nil, nil)]).first)
        let download = try await other.raw("GET", "/v1/outbox/\(item.id)/data")
        XCTAssertEqual(download.status, 404)
        try await other.client.acknowledge(item.id)
        XCTAssertEqual(outbox.pending(phone.id).count, 1)
    }

    func testTheOutboxSurvivesARestartUntilAcknowledged() async throws {
        let item = try outbox.queueText(phone.id, "kept")
        try await harness.restart()
        let reply = try await phone.client.outbox(wait: 0)
        XCTAssertEqual(reply.items.map(\.id), [item.id])
        try await phone.client.acknowledge(item.id)
        try await harness.restart()
        let empty = try await phone.client.outbox(wait: 0)
        XCTAssertTrue(empty.items.isEmpty)
    }

    func testQueueRefusesWhatCannotBeSent() async throws {
        XCTAssertThrowsError(try outbox.queueText(phone.id, ""))
        XCTAssertThrowsError(try outbox.queueText(phone.id, String(repeating: "a", count: 1024 * 1024 + 1)))
        XCTAssertThrowsError(try outbox.queueLink(phone.id, "ftp://example.com/x"))
        XCTAssertThrowsError(try outbox.queueLink(phone.id, "not a link"))
        XCTAssertTrue(outbox.queueFiles(phone.id, [(harness.root.appendingPathComponent("missing"), nil, nil)]).isEmpty)
        XCTAssertTrue(outbox.queueFiles(phone.id, [(harness.root, nil, nil)]).isEmpty)
        XCTAssertTrue(outbox.pending(phone.id).isEmpty)
    }

    func testAReplyHoldsAtMostAHundredItems() async throws {
        for index in 0..<150 { try outbox.queueText(phone.id, "item \(index)") }
        let reply = try await phone.client.outbox(wait: 0)
        XCTAssertEqual(reply.items.count, 100)
        XCTAssertTrue(reply.more)
        XCTAssertEqual(reply.items.first?.text, "item 0")
        for item in reply.items { try await phone.client.acknowledge(item.id) }
        let rest = try await phone.client.outbox(wait: 0)
        XCTAssertEqual(rest.items.count, 50)
        XCTAssertFalse(rest.more)
    }

    func testAReplyHoldsAtMostFourMebibytesOfText() async throws {
        let big = String(repeating: "x", count: 1024 * 1024)
        for _ in 0..<6 { try outbox.queueText(phone.id, big) }
        let reply = try await phone.client.outbox(wait: 0)
        XCTAssertEqual(reply.items.count, 4)
        XCTAssertTrue(reply.more)
    }

    func testAtMostAThousandItemsWaitForOnePhone() async throws {
        for index in 0..<1000 { try outbox.queueText(phone.id, "item \(index)") }
        XCTAssertThrowsError(try outbox.queueText(phone.id, "one too many")) { error in
            XCTAssertEqual(error as? OutboxError, .tooMany)
        }
        let urls = try (0..<3).map { try makeFile("f\($0).bin", bytes(10)) }
        XCTAssertTrue(outbox.queueFiles(phone.id, urls.map { ($0, nil, nil) }).isEmpty)
    }

    func testManyFilesAreQueuedWithOneSaveAndStopAtTheLimit() async throws {
        for index in 0..<998 { try outbox.queueText(phone.id, "item \(index)") }
        let urls = try (0..<5).map { try makeFile("g\($0).bin", bytes(10)) }
        let queued = outbox.queueFiles(phone.id, urls.map { ($0, nil, nil) })
        XCTAssertEqual(queued.count, 2)
        XCTAssertEqual(outbox.pending(phone.id).count, 1000)
    }

    func testRemovingAPhoneOnTheComputerClearsWhatWaitsForIt() async throws {
        try outbox.queueText(phone.id, "waiting")
        harness.service.devices.remove(phone.id)
        XCTAssertTrue(outbox.pending(phone.id).isEmpty)
    }

    func testAFileCanBeFoundThroughALocator() async throws {
        let url = try makeFile("located.bin", bytes(500))
        let item = try XCTUnwrap(outbox.queueFiles(phone.id, [(url, Data("bookmark".utf8), nil)]).first)
        let moved = harness.root.appendingPathComponent("outgoing/elsewhere.bin")
        try FileManager.default.moveItem(at: url, to: moved)
        outbox.locate = { _ in moved }
        var got = Data()
        try await phone.client.download(id: item.id, from: 0, onStart: { _, _ in }, sink: { got.append($0) })
        XCTAssertEqual(got.count, 500)
    }
}

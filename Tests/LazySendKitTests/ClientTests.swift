import XCTest
@testable import LazySendKit

final class ClientTests: XCTestCase {
    func testHealthOverThePinnedKey() async throws {
        let pc = try FakePc()
        let health = try await LinkClient(endpoint: pc.endpoint, pin: pc.pin).health()
        XCTAssertEqual(health.service, "lazysend")
        XCTAssertEqual(health.protocolVersion, 1)
    }

    func testRefusesAnotherKeyBeforeSendingAnything() async throws {
        let pc = try FakePc()
        let other = SpkiFingerprint.of(try TestServer.fixture("test-other", "der"))!
        do {
            _ = try await LinkClient(endpoint: pc.endpoint, pin: other).health()
            XCTFail("The certificate should have been refused")
        } catch {
            XCTAssertEqual(error as? LinkError, .wrongCertificate)
        }
        XCTAssertTrue(pc.server.requests.isEmpty)
    }

    func testWrongSecretIsUnauthorized() async throws {
        let pc = try FakePc()
        let client = LinkClient(endpoint: pc.endpoint, pin: pc.pin, credentials: Credentials(deviceId: pc.phoneId, secret: "nope"))
        do {
            _ = try await client.hello()
            XCTFail("Expected a 401")
        } catch {
            XCTAssertEqual((error as? LinkError)?.status, 401)
            XCTAssertEqual((error as? LinkError)?.code, "unauthorized")
        }
    }

    func testHelloListsAddresses() async throws {
        let pc = try FakePc()
        let hello = try await LinkClient(endpoint: pc.endpoint, pin: pc.pin, credentials: pc.credentials).hello()
        XCTAssertEqual(hello.desktopId, pc.desktopId)
        XCTAssertEqual(hello.addresses, ["127.0.0.1", "172.20.10.2"])
    }

    func testNoteAsTextAndLink() async throws {
        let pc = try FakePc()
        let client = LinkClient(endpoint: pc.endpoint, pin: pc.pin, credentials: pc.credentials)
        _ = try await client.postItem(.note("hello there"))
        _ = try await client.postItem(.note("  https://example.com/a?b=1 "))
        XCTAssertEqual(pc.notes.map(\.kind), ["text", "link"])
        XCTAssertEqual(pc.notes.map(\.value), ["hello there", "https://example.com/a?b=1"])
    }

    func testUploadsAFileInChunks() async throws {
        let pc = try FakePc()
        let folder = try temporaryFolder()
        let file = try randomFile(in: folder, bytes: 2_500_000)
        var request = try ItemRequest.file(at: file.url, name: "payload.bin", mime: "application/octet-stream", modified: nil)
        request.sourceId = "asset-1#photo"
        let client = LinkClient(endpoint: pc.endpoint, pin: pc.pin, credentials: pc.credentials)
        let uploader = Uploader(chunkBytes: 1_000_000, sleep: { _ in }, connect: { client })
        let result = try await uploader.send(request, source: FileDataSource(url: file.url))
        XCTAssertFalse(result.duplicate)
        XCTAssertEqual(pc.uploads.values.first?.data, file.data)
        XCTAssertEqual(pc.uploads.values.first?.done, true)
        XCTAssertEqual(pc.chunkOffsets, [0, 1_000_000, 2_000_000])

        let again = try await Uploader(sleep: { _ in }, connect: { client }).send(request, source: FileDataSource(url: file.url))
        XCTAssertTrue(again.duplicate)
        XCTAssertEqual(pc.chunkOffsets.count, 3)
    }

    func testResumesFromTheComputersOffsetAfterADroppedChunk() async throws {
        let pc = try FakePc()
        let folder = try temporaryFolder()
        let file = try randomFile(in: folder, bytes: 1_200_000)
        let request = try ItemRequest.file(at: file.url, name: "payload.bin", mime: nil, modified: nil)
        pc.dropNextChunkAfter = 300_000
        let client = LinkClient(endpoint: pc.endpoint, pin: pc.pin, credentials: pc.credentials)
        _ = try await Uploader(chunkBytes: 1_000_000, sleep: { _ in }, connect: { client }).send(request, source: FileDataSource(url: file.url))
        XCTAssertEqual(pc.uploads.values.first?.data, file.data)
        XCTAssertEqual(pc.chunkOffsets, [0, 300_000, 1_000_000])
    }

    func testPausesWhileTheComputerIsBusy() async throws {
        let pc = try FakePc()
        let folder = try temporaryFolder()
        let file = try randomFile(in: folder, bytes: 10_000)
        let request = try ItemRequest.file(at: file.url, name: "payload.bin", mime: nil, modified: nil)
        pc.busyChunks = 2
        let client = LinkClient(endpoint: pc.endpoint, pin: pc.pin, credentials: pc.credentials)
        let waits = Waits()
        _ = try await Uploader(sleep: { await waits.add($0) }, connect: { client }).send(request, source: FileDataSource(url: file.url))
        XCTAssertEqual(pc.uploads.values.first?.data, file.data)
        let recorded = await waits.values
        XCTAssertEqual(recorded, [1, 1])
    }

    func testGalleryCheckKeepsTheOrderGiven() async throws {
        let pc = try FakePc()
        let client = LinkClient(endpoint: pc.endpoint, pin: pc.pin, credentials: pc.credentials)
        let missing = try await client.galleryMissing(["b", "a", "b", "c"])
        XCTAssertEqual(missing, ["b", "a", "c"])
    }

    func testDownloadsFromARangeAndAcknowledges() async throws {
        let pc = try FakePc()
        let file = Data((0..<10_000).map { UInt8($0 % 251) })
        pc.queue(OutboxEntry(id: "o1", kind: "file", name: "a.bin", size: Int64(file.count)), file: file)
        let client = LinkClient(endpoint: pc.endpoint, pin: pc.pin, credentials: pc.credentials)
        let reply = try await client.outbox(wait: 0)
        XCTAssertEqual(reply.items.map(\.id), ["o1"])
        var status = 0
        var total: Int64 = 0
        var got = Data()
        try await client.download(id: "o1", from: 4_000, onStart: { status = $0; total = $1 }, sink: { got.append($0) })
        XCTAssertEqual(status, 206)
        XCTAssertEqual(total, 10_000)
        XCTAssertEqual(got, file.suffix(from: 4_000))
        try await client.acknowledge("o1")
        XCTAssertEqual(pc.acknowledged, ["o1"])
    }

    func testRangePastTheEndIsRefused() async throws {
        let pc = try FakePc()
        pc.queue(OutboxEntry(id: "o1", kind: "file", name: "a.bin", size: 10), file: Data(count: 10))
        let client = LinkClient(endpoint: pc.endpoint, pin: pc.pin, credentials: pc.credentials)
        do {
            try await client.download(id: "o1", from: 10, onStart: { _, _ in }, sink: { _ in })
            XCTFail("Expected a 416")
        } catch {
            XCTAssertEqual((error as? LinkError)?.status, 416)
        }
    }
}

actor Waits {
    private(set) var values: [TimeInterval] = []

    func add(_ seconds: TimeInterval) {
        values.append(seconds)
    }
}

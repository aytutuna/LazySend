import CryptoKit
import Foundation
@testable import LazySendKit

/// The computer's side of CONTRACTS.md, just enough for the client tests: pairing, items and their chunks,
/// the gallery index and the outbox, with hooks to break a connection or refuse a request.
final class FakePc: @unchecked Sendable {
    struct Upload {
        var name: String
        var size: Int64
        var sha256: String?
        var sourceId: String?
        var data = Data()
        var done = false
    }

    let desktopId = "pc-test-0001"
    let phoneId = "phone-test-0001"
    let secret = Base64Url.encode(Data(repeating: 7, count: 32))
    let token = Base64Url.encode(Data(repeating: 9, count: 16))
    private(set) var server: TestServer!
    private let lock = NSLock()

    private(set) var uploads: [String: Upload] = [:]
    private(set) var received = Set<String>()
    private(set) var notes: [(kind: String, value: String)] = []
    private(set) var outbox: [OutboxEntry] = []
    private(set) var outboxFiles: [String: Data] = [:]
    private(set) var acknowledged: [String] = []
    private(set) var chunkOffsets: [Int64] = []
    private(set) var ranges: [String] = []

    /// Keeps this many bytes of the next chunk and drops the connection without answering.
    var dropNextChunkAfter: Int?
    /// Answers this many chunk requests with 409 busy before taking one.
    var busyChunks = 0
    /// Cuts the next file download after this many bytes.
    var cutNextDownloadAfter: Int?
    var knowsPhone = true
    var approves = true
    var pin: Data { try! TestServer.pin() }

    init() throws {
        server = try TestServer { [unowned self] in self.handle($0) }
    }

    deinit {
        server.stop()
    }

    var endpoint: Endpoint { Endpoint(host: "127.0.0.1", port: server.port) }
    var credentials: Credentials { Credentials(deviceId: phoneId, secret: secret) }

    func queue(_ entry: OutboxEntry, file: Data? = nil) {
        lock.lock()
        outbox.append(entry)
        if let file = file { outboxFiles[entry.id] = file }
        lock.unlock()
    }

    private func authorized(_ request: TestRequest) -> Bool {
        knowsPhone && request.headers["x-device-id"] == phoneId && request.headers["authorization"] == "Bearer " + secret
    }

    private func object(_ body: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
    }

    private func handle(_ request: TestRequest) -> TestReply {
        lock.lock()
        defer { lock.unlock() }
        let path = request.path
        if request.method == "GET" && path == "/v1/health" {
            return .json("{\"service\":\"lazysend\",\"protocolVersion\":1,\"paired\":\(authorized(request))}")
        }
        if request.method == "POST" && path == "/v1/pair" {
            let body = object(request.body)
            guard body["token"] as? String == token else { return .error(403, "tokenInvalid") }
            guard approves else { return .error(403, "declined") }
            return .json("{\"protocolVersion\":1,\"desktopId\":\"\(desktopId)\",\"desktopName\":\"Test PC\",\"deviceSecret\":\"\(secret)\"}")
        }
        guard authorized(request) else { return .error(401, "unauthorized") }
        switch (request.method, path) {
        case ("GET", "/v1/hello"):
            return .json("{\"protocolVersion\":1,\"desktopId\":\"\(desktopId)\",\"desktopName\":\"Test PC\",\"maxChunkBytes\":67108864,\"addresses\":[\"127.0.0.1\",\"172.20.10.2\"]}")
        case ("DELETE", "/v1/devices/self"):
            knowsPhone = false
            return .answer(status: 204)
        case ("POST", "/v1/items"):
            return postItem(object(request.body))
        case ("POST", "/v1/gallery/check"):
            let ids = object(request.body)["ids"] as? [String] ?? []
            var seen = Set<String>()
            let missing = ids.filter { !received.contains($0) && seen.insert($0).inserted }
            let list = missing.map { "\"\($0)\"" }.joined(separator: ",")
            return .json("{\"missing\":[\(list)]}")
        case ("GET", "/v1/outbox"):
            let data = (try? JSONEncoder().encode(outbox)) ?? Data("[]".utf8)
            return .json("{\"items\":\(String(decoding: data, as: UTF8.self))}")
        default:
            break
        }
        let parts = path.split(separator: "/").map(String.init)
        if parts.count == 4, parts[1] == "items", parts[3] == "data", request.method == "PUT" { return putChunk(parts[2], request) }
        if parts.count == 3, parts[1] == "items", request.method == "GET" {
            guard let upload = uploads[parts[2]] else { return .error(404, "notFound") }
            return .json("{\"id\":\"\(parts[2])\",\"offset\":\(upload.data.count),\"done\":\(upload.done)}")
        }
        if parts.count == 4, parts[1] == "outbox", parts[3] == "data", request.method == "GET" { return download(parts[2], request) }
        if parts.count == 3, parts[1] == "outbox", request.method == "DELETE" {
            outbox.removeAll { $0.id == parts[2] }
            acknowledged.append(parts[2])
            return .answer(status: 204)
        }
        return .error(404, "notFound")
    }

    private func postItem(_ body: [String: Any]) -> TestReply {
        switch body["kind"] as? String {
        case "text":
            notes.append(("text", body["text"] as? String ?? ""))
            return .json(201, "{\"id\":\"note\",\"offset\":0,\"done\":true}")
        case "link":
            notes.append(("link", body["url"] as? String ?? ""))
            return .json(201, "{\"id\":\"note\",\"offset\":0,\"done\":true}")
        case "file":
            let size = (body["size"] as? NSNumber)?.int64Value ?? 0
            let sourceId = body["sourceId"] as? String
            if let sourceId = sourceId, received.contains(sourceId) {
                return .json(200, "{\"id\":\"\",\"offset\":\(size),\"done\":true,\"duplicate\":true}")
            }
            if let sourceId = sourceId, let existing = uploads.first(where: { $0.value.sourceId == sourceId && !$0.value.done && $0.value.size == size }) {
                return .json(201, "{\"id\":\"\(existing.key)\",\"offset\":\(existing.value.data.count),\"done\":false}")
            }
            let id = "item\(uploads.count + 1)"
            uploads[id] = Upload(name: body["name"] as? String ?? "", size: size, sha256: body["sha256"] as? String, sourceId: sourceId)
            return .json(201, "{\"id\":\"\(id)\",\"offset\":0,\"done\":\(size == 0)}")
        default:
            return .error(400, "badRequest")
        }
    }

    private func putChunk(_ id: String, _ request: TestRequest) -> TestReply {
        if busyChunks > 0 {
            busyChunks -= 1
            return .error(409, "busy")
        }
        guard var upload = uploads[id] else { return .error(404, "notFound") }
        let offset = Int64(request.headers["x-offset"] ?? "") ?? -1
        chunkOffsets.append(offset)
        if upload.done { return .json("{\"id\":\"\(id)\",\"offset\":\(upload.size),\"done\":true}") }
        guard offset == Int64(upload.data.count) else { return .error(409, "offsetMismatch", offset: Int64(upload.data.count)) }
        if let keep = dropNextChunkAfter {
            dropNextChunkAfter = nil
            upload.data.append(request.body.prefix(keep))
            uploads[id] = upload
            return .drop
        }
        upload.data.append(request.body)
        if Int64(upload.data.count) == upload.size {
            let hash = SHA256.hash(data: upload.data).map { String(format: "%02x", $0) }.joined()
            if let expected = upload.sha256, expected != hash {
                uploads[id] = nil
                return .error(422, "hashMismatch")
            }
            upload.done = true
            if let sourceId = upload.sourceId { received.insert(sourceId) }
        }
        uploads[id] = upload
        return .json("{\"id\":\"\(id)\",\"offset\":\(upload.data.count),\"done\":\(upload.done)}")
    }

    private func download(_ id: String, _ request: TestRequest) -> TestReply {
        guard let file = outboxFiles[id] else { return .error(404, "notFound") }
        var cut = cutNextDownloadAfter
        cutNextDownloadAfter = nil
        if let range = request.headers["range"] {
            ranges.append(range)
            guard range.hasPrefix("bytes="), range.hasSuffix("-"), let start = Int(range.dropFirst(6).dropLast()), start < file.count else {
                return .answer(status: 416, headers: ["Content-Range": "bytes */\(file.count)"])
            }
            cut = cut.map { min($0, file.count - start) }
            return .answer(status: 206, headers: ["Content-Range": "bytes \(start)-\(file.count - 1)/\(file.count)"],
                           body: file.suffix(from: start), cutAfter: cut)
        }
        return .answer(status: 200, body: file, cutAfter: cut)
    }
}

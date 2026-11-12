import CryptoKit
import Foundation
import Network
import Security
import XCTest
@testable import LazySendKit
@testable import LazySendServer

// The real server on loopback with a temporary folder for everything it keeps, and phones that talk to it with the
// LazySendKit client. Its certificate is the test-only PKCS#12 in Fixtures (password "test").

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_793_000_000)

    var now: Date {
        get {
            lock.lock()
            defer { lock.unlock() }
            return current
        }
        set {
            lock.lock()
            current = newValue
            lock.unlock()
        }
    }
}

final class FreeSpace: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Int64.max

    var bytes: Int64 {
        get {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        set {
            lock.lock()
            value = newValue
            lock.unlock()
        }
    }
}

struct Reply {
    var status: Int
    var data: Data
    var response: HTTPURLResponse

    var code: String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
    }

    var json: [String: Any] {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func header(_ name: String) -> String? {
        response.value(forHTTPHeaderField: name)
    }
}

final class Harness: @unchecked Sendable {
    let root: URL
    let paths: SendPaths
    let clock = TestClock()
    let space = FreeSpace()
    private(set) var service: LinkService
    private(set) var port = 0
    var approve: @Sendable (PairRequest) async -> Bool = { _ in true }
    var approvalTimeout: TimeInterval = 120

    var received: URL { paths.defaultReceiveRoot }

    init() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lazysend-server-" + UUID().uuidString, isDirectory: true)
        paths = SendPaths(root: root.appendingPathComponent("state"), defaultReceiveRoot: root.appendingPathComponent("received"))
        service = try Harness.makeService(paths, clock, space)
        try await begin()
    }

    private static func makeService(_ paths: SendPaths, _ clock: TestClock, _ space: FreeSpace) throws -> LinkService {
        try LinkService(paths: paths, identity: try identity(), clock: { clock.now }, freeSpace: { _ in space.bytes })
    }

    private func begin() async throws {
        service.router.desktopName = { "Test Mac" }
        service.router.approvalTimeout = approvalTimeout
        let approve = self.approve
        service.router.approvePairing = { await approve($0) }
        port = try await service.start(port: 0)
    }

    /// Stops the server and starts a new one on the same folders, as a restart of the app would.
    func restart() async throws {
        await service.stop()
        service = try Harness.makeService(paths, clock, space)
        try await begin()
    }

    func tearDown() async {
        await service.stop()
        try? FileManager.default.removeItem(at: root)
    }

    static func fixture(_ name: String, _ ext: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }

    static func identity() throws -> SecIdentity {
        var options: [String: Any] = [kSecImportExportPassphrase as String: "test"]
        if #available(macOS 15.0, iOS 15.0, *) { options[kSecImportToMemoryOnly as String] = true }
        var items: CFArray?
        let status = SecPKCS12Import(try fixture("test-server", "p12") as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let first = (items as? [[String: Any]])?.first,
              let identity = first[kSecImportItemIdentity as String] else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return identity as! SecIdentity
    }

    var endpoint: Endpoint { Endpoint(host: "127.0.0.1", port: port) }

    func pair(name: String = "Test iPhone", id: String = newId()) async throws -> Phone {
        let code = service.openPairing(addresses: ["127.0.0.1"])
        let phone = Phone(harness: self, id: id)
        let answer = try await LinkClient(endpoint: endpoint, pin: service.fingerprint)
            .pair(token: code.token, phoneId: id, phoneName: name, appVersion: "1.0")
        phone.secret = answer.deviceSecret
        return phone
    }
}

final class Phone: @unchecked Sendable {
    let harness: Harness
    let id: String
    var secret = ""
    let session: PinnedSession

    init(harness: Harness, id: String) {
        self.harness = harness
        self.id = id
        session = PinnedSession(pin: harness.service.fingerprint)
    }

    var client: LinkClient {
        LinkClient(endpoint: harness.endpoint, session: session, credentials: Credentials(deviceId: id, secret: secret))
    }

    func raw(_ method: String, _ path: String, body: Data? = nil, headers: [String: String] = [:],
             authenticated: Bool = true) async throws -> Reply {
        let url = LinkClient.url(harness.endpoint, path: path)!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = method
        if authenticated {
            request.setValue(id, forHTTPHeaderField: "X-Device-Id")
            request.setValue("Bearer " + secret, forHTTPHeaderField: "Authorization")
        }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await session.run(request, body: body)
        return Reply(status: response.statusCode, data: data, response: response)
    }

    func json(_ method: String, _ path: String, _ body: Any? = nil) async throws -> Reply {
        let data = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        return try await raw(method, path, body: data, headers: ["Content-Type": "application/json"])
    }

    func beginFile(_ name: String, _ content: Data, sourceId: String? = nil, modified: String? = nil,
                   hash: Bool = true) async throws -> ItemState {
        try await client.postItem(fileRequest(name, content, sourceId: sourceId, modified: modified, hash: hash))
    }

    func fileRequest(_ name: String, _ content: Data, sourceId: String? = nil, modified: String? = nil, hash: Bool = true) -> ItemRequest {
        ItemRequest(kind: "file", name: name, size: Int64(content.count), modified: modified, sourceId: sourceId,
                    sha256: hash ? sha256(content) : nil)
    }

    func put(_ id: String, offset: Int64, _ data: Data) async throws -> ItemState {
        try await client.putChunk(id: id, offset: offset, data: data, onBytes: { _ in })
    }

    /// Sends a whole file in chunks of `chunk` bytes; returns the item's id.
    @discardableResult
    func upload(_ name: String, _ content: Data, chunk: Int = 100_000, sourceId: String? = nil, modified: String? = nil) async throws -> String {
        let state = try await beginFile(name, content, sourceId: sourceId, modified: modified)
        var offset = state.offset
        var done = state.done
        while !done {
            let end = min(Int(offset) + chunk, content.count)
            let answer = try await put(state.id, offset: offset, content.subdata(in: Int(offset)..<end))
            offset = answer.offset
            done = answer.done
        }
        return state.id
    }

    /// Starts a chunk and sends only the first `sent` bytes of it. With `hangUp` the connection is closed, as a
    /// phone does when the Wi-Fi drops; without it the connection stays half open until the returned
    /// connection is cancelled.
    func partialChunk(_ id: String, offset: Int64, declared: Int, sent: Data, hangUp: Bool) async throws -> NWConnection {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, DispatchQueue.global())
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(harness.port))!,
                                      using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()))
        let queue = DispatchQueue(label: "lazysend.test.raw")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = ResumeOnce(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.resume(nil)
                case .failed(let error): once.resume(error)
                default: break
                }
            }
            connection.start(queue: queue)
        }
        let head = "PUT /v1/items/\(id)/data HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Device-Id: \(self.id)\r\nAuthorization: Bearer \(secret)\r\n"
            + "X-Offset: \(offset)\r\nContent-Length: \(declared)\r\n\r\n"
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = ResumeOnce(continuation)
            connection.send(content: Data(head.utf8) + sent, completion: .contentProcessed { once.resume($0) })
        }
        if hangUp { connection.cancel() }
        return connection
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume(_ error: Error?) {
        lock.lock()
        let waiting = continuation
        continuation = nil
        lock.unlock()
        if let error = error { waiting?.resume(throwing: error) } else { waiting?.resume() }
    }
}

func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func bytes(_ count: Int, seed: UInt8 = 7) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
}

func expectRefused(_ status: Int, _ code: String, file: StaticString = #filePath, line: UInt = #line,
                   _ block: () async throws -> Void) async {
    do {
        try await block()
        XCTFail("Expected \(code)", file: file, line: line)
    } catch let error as LinkError {
        XCTAssertEqual(error.status, status, file: file, line: line)
        XCTAssertEqual(error.code, code, file: file, line: line)
    } catch {
        XCTFail("Unexpected \(error)", file: file, line: line)
    }
}

func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

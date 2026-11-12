import Foundation
import Network
import Security
@testable import LazySendKit

// A TLS server on loopback for the client tests. Its certificate is the test-only PKCS#12 in Fixtures
// (test-server.p12, password "test"); nothing outside the tests trusts it.

struct TestRequest {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data
}

enum TestReply {
    case answer(status: Int, headers: [String: String] = [:], body: Data = Data(), cutAfter: Int? = nil)
    /// Closes the connection without an answer.
    case drop

    static func json(_ status: Int = 200, _ text: String) -> TestReply {
        .answer(status: status, headers: ["Content-Type": "application/json"], body: Data(text.utf8))
    }

    static func error(_ status: Int, _ code: String, offset: Int64? = nil) -> TestReply {
        let extra = offset.map { ",\"offset\":\($0)" } ?? ""
        return json(status, "{\"error\":\"\(code)\",\"message\":\"\(code) happened\"\(extra)}")
    }
}

final class TestServer: @unchecked Sendable {
    static let fixtures = "Fixtures"

    static func fixture(_ name: String, _ ext: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: fixtures) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }

    static func identity() throws -> SecIdentity {
        let options: [String: Any] = [kSecImportExportPassphrase as String: "test", kSecImportToMemoryOnly as String: true]
        var items: CFArray?
        let status = SecPKCS12Import(try fixture("test-server", "p12") as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let first = (items as? [[String: Any]])?.first,
              let identity = first[kSecImportItemIdentity as String] else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return identity as! SecIdentity
    }

    /// The fingerprint of the server's certificate, which is what a pairing code carries.
    static func pin() throws -> Data {
        SpkiFingerprint.of(try fixture("test-server", "der"))!
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "lazysend.testserver")
    private let lock = NSLock()
    private var handler: (TestRequest) -> TestReply
    private(set) var port: Int = 0

    var requests: [TestRequest] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }
    private var seen: [TestRequest] = []

    init(handler: @escaping (TestRequest) -> TestReply) throws {
        self.handler = handler
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sec_identity_create(try TestServer.identity())!)
        listener = try NWListener(using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()), on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [unowned self] connection in self.serve(connection) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 10)
        guard let bound = listener.port else { throw CocoaError(.serverCertificateUntrusted) }
        port = Int(bound.rawValue)
    }

    func stop() {
        listener.cancel()
    }

    func setHandler(_ handler: @escaping (TestRequest) -> TestReply) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, Data())
    }

    private func read(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [self] data, _, complete, error in
            var buffer = buffer
            if let data = data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                let length = TestServer.contentLength(head)
                let bodyStart = end.upperBound
                if head.lowercased().contains("expect: 100-continue"), buffer.count == bodyStart, length > 0 {
                    connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .contentProcessed { _ in })
                }
                if buffer.count - bodyStart >= length {
                    respond(connection, head, Data(buffer[bodyStart..<(bodyStart + length)]))
                    return
                }
            }
            if error != nil || complete {
                connection.cancel()
            } else {
                read(connection, buffer)
            }
        }
    }

    private static func contentLength(_ head: String) -> Int {
        for line in head.components(separatedBy: "\r\n") where line.lowercased().hasPrefix("content-length:") {
            return Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
        }
        return 0
    }

    private func respond(_ connection: NWConnection, _ head: String, _ body: Data) {
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        let target = String(first[1])
        let parts = target.split(separator: "?", maxSplits: 1)
        var query: [String: String] = [:]
        if parts.count > 1 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                query[String(kv[0])] = kv.count > 1 ? String(kv[1]) : ""
            }
        }
        let request = TestRequest(method: String(first[0]), path: String(parts[0]), query: query, headers: headers, body: body)
        lock.lock()
        seen.append(request)
        let current = handler
        lock.unlock()
        switch current(request) {
        case .drop:
            connection.cancel()
        case .answer(let status, let extra, let payload, let cut):
            var text = "HTTP/1.1 \(status) Status\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n"
            for (name, value) in extra { text += "\(name): \(value)\r\n" }
            text += "\r\n"
            var out = Data(text.utf8)
            out.append(cut.map { payload.prefix($0) } ?? payload)
            connection.send(content: out, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

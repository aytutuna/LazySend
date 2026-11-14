import Foundation
import Network
import Security

/// Limits and timeouts of the server.
public struct LinkServerOptions {
    public var maxConnections = 16
    /// How many of those one address may hold, so that it cannot shut the phones out.
    public var maxConnectionsPerPeer = 6
    public var handshakeTimeout: TimeInterval = 10
    /// How long the request line and headers may take to arrive.
    public var headTimeout: TimeInterval = 10
    /// How long a body may stall between two reads, and a response between two writes. A file upload has no other limit.
    public var idleTimeout: TimeInterval = 30
    /// How long a small body (pairing) may take in all, from its first read.
    public var bodyTimeout: TimeInterval = 15
    /// A refused request's unread body is read and dropped up to this size before closing.
    public var maxDiscardBytes: Int64 = 1024 * 1024
    /// The whole time that dropping may take, however slowly the client sends.
    public var discardTimeout: TimeInterval = 5
    /// Which peers are answered (others are closed before TLS); every peer when nil.
    public var allowPeer: ((NWEndpoint.Host) -> Bool)?
    /// When stopping, how long requests already being served may take to finish before they are cut off.
    public var stopGrace: TimeInterval = 2

    public init() {}
}

public enum LinkServerError: Error, Equatable {
    case alreadyRunning
    case unusableIdentity
}

/// The phone link server: TLS 1.2/1.3 over TCP with the computer's own identity, one request per connection, the
/// small HTTP/1.1 subset of `LinkHttp`, every request handed to `LinkRouter`. One listener takes every interface,
/// wired ones included. Peers `LinkServerOptions.allowPeer` refuses or `LinkRateLimiter` blocks are closed before
/// TLS, and every step is bounded in time.
public final class LinkServer: @unchecked Sendable {
    private struct Served {
        let link: Link
        let peer: [UInt8]
        var task: Task<Void, Never>?
    }

    private let identity: SecIdentity
    private let router: LinkRouter
    private let limiter: LinkRateLimiter
    private let options: LinkServerOptions
    private let clock: () -> Date
    private let queue = DispatchQueue(label: "LinkServer")
    private let lock = NSLock()
    private var listener: NWListener?
    private var served: [Int: Served] = [:]
    private var nextNumber = 0
    private var running = false
    private var bound = 0

    /// Called, on the server's queue, when the listener fails after `start` returned, so the server no longer
    /// accepts. Set before `start`.
    public var onFailure: (@Sendable () -> Void)?

    public init(identity: SecIdentity, router: LinkRouter, limiter: LinkRateLimiter,
                options: LinkServerOptions = LinkServerOptions(), clock: @escaping () -> Date = { Date() }) {
        self.identity = identity
        self.router = router
        self.limiter = limiter
        self.options = options
        self.clock = clock
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    /// The port listened on; 0 when stopped.
    public var port: Int {
        lock.lock()
        defer { lock.unlock() }
        return bound
    }

    public var activeConnections: Int {
        lock.lock()
        defer { lock.unlock() }
        return served.count
    }

    /// Listens on `port`, or on a free one when that one is taken (or when it is 0). Returns the port.
    @discardableResult
    public func start(port: Int) async throws -> Int {
        guard let tlsIdentity = sec_identity_create(identity) else { throw LinkServerError.unusableIdentity }
        guard begin() else { throw LinkServerError.alreadyRunning }
        do {
            var started: (NWListener, Int)?
            if port != 0, let wanted = NWEndpoint.Port(rawValue: UInt16(port)) {
                started = try? await listen(tlsIdentity, port: wanted)
            }
            if started == nil { started = try await listen(tlsIdentity, port: .any) }
            let (listener, actual) = started!
            finishStart(listener, port: actual)
            return actual
        } catch {
            finishStart(nil, port: 0)
            throw error
        }
    }

    /// Stops listening at once, lets the requests being served finish for `LinkServerOptions.stopGrace` (a phone
    /// removing itself still gets its answer), then cuts off the rest; nothing listens once it returns.
    public func stop() async {
        guard let stopping = takeListener() else { return }
        stopping.newConnectionHandler = nil
        stopping.cancel()
        await waitUntilCancelled(stopping)
        await waitForConnections(seconds: options.stopGrace)
        for entry in servedNow() {
            entry.task?.cancel()
            entry.link.cancel()
        }
        await waitForConnections(seconds: 10)
        finishStart(nil, port: 0)
    }

    private func parameters(_ identity: sec_identity_t) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let security = tls.securityProtocolOptions
        sec_protocol_options_set_local_identity(security, identity)
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)
        sec_protocol_options_set_tls_tickets_enabled(security, false)
        sec_protocol_options_set_tls_resumption_enabled(security, false)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = false
#if os(iOS)
        parameters.prohibitedInterfaceTypes = [.cellular]
#endif
        // The port can be taken again at once after a restart, while closed connections still hold it.
        parameters.allowLocalEndpointReuse = true
        return parameters
    }

    private func listen(_ identity: sec_identity_t, port: NWEndpoint.Port) async throws -> (NWListener, Int) {
        let listener = try NWListener(using: parameters(identity), on: port)
        let queue = self.queue
        let actual: Int = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            let once = Once<Int>(continuation)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    once.resume(.success(Int(listener.port?.rawValue ?? 0)))
                case .failed(let error):
                    // After the start nothing accepts any more (the network was reset, say): the owner starts afresh.
                    if once.resume(.failure(error)) {
                        listener.cancel()
                    } else {
                        self?.onFailure?()
                    }
                case .waiting(let error):
                    // A port that is taken will not free itself; fail now so another one is tried.
                    if case .posix(let code) = error, code == .EADDRINUSE || code == .EACCES {
                        if once.resume(.failure(error)) { listener.cancel() }
                    }
                case .cancelled:
                    once.resume(.failure(NWError.posix(.ECANCELED)))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
            // A `.waiting` listener (macOS keeps one there while the Local Network prompt is open) is given this
            // long to become ready.
            queue.asyncAfter(deadline: .now() + 10) {
                if once.resume(.failure(NWError.posix(.ETIMEDOUT))) { listener.cancel() }
            }
        }
        return (listener, actual)
    }

    private func accept(_ connection: NWConnection) {
        guard case .hostPort(let remote, _) = connection.endpoint, let admitted = admit(connection, from: remote) else {
            connection.cancel()
            return
        }
        let task = Task {
            await self.serve(admitted.link, remote: remote)
            self.finished(admitted.number)
        }
        lock.lock()
        served[admitted.number]?.task = task
        lock.unlock()
    }

    /// The connection counted as served; nil when it is refused (stopped, too many, too many from this peer, a peer
    /// not answered or blocked).
    private func admit(_ connection: NWConnection, from remote: NWEndpoint.Host) -> (link: Link, number: Int)? {
        lock.lock()
        defer { lock.unlock() }
        let peer = Peers.bytes(remote) ?? []
        guard running, served.count < options.maxConnections,
              served.values.filter({ $0.peer == peer }).count < options.maxConnectionsPerPeer,
              options.allowPeer?(remote) ?? true, !limiter.isBlocked(remote, now: clock())
        else { return nil }
        nextNumber += 1
        let link = Link(connection, queue: queue)
        served[nextNumber] = Served(link: link, peer: peer, task: nil)
        return (link, nextNumber)
    }

    private func serve(_ link: Link, remote: NWEndpoint.Host) async {
        defer { link.cancel() }
        guard await link.ready(timeout: options.handshakeTimeout) else { return }
        // A client that went away or timed out has nothing to be answered.
        try? await serveRequest(link, remote: remote)
    }

    private func serveRequest(_ link: Link, remote: NWEndpoint.Host) async throws {
        let capacity = LinkHttp.maxHeadBytes + 4096
        var buffer = Data()
        var parsed = HttpParseResult(status: .incomplete)
        let deadline = Date().addingTimeInterval(options.headTimeout)
        while parsed.status == .incomplete {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { return }
            let chunk = try await link.receive(maxLength: capacity - buffer.count, timeout: left)
            if chunk.isEmpty { return }
            buffer.append(chunk)
            parsed = LinkHttp.parse(buffer)
            if parsed.status == .incomplete && buffer.count >= capacity {
                parsed = HttpParseResult(status: .invalid, errorStatus: 431)
            }
        }
        guard parsed.status == .complete, let head = parsed.head else {
            try await write(.error(parsed.errorStatus, .badRequest), to: link)
            return
        }

        let idle = options.idleTimeout
        var sendContinue: (() async throws -> Void)?
        if head.expectsContinue {
            sendContinue = { try await link.send(LinkHttp.continueResponse, timeout: idle) }
        }
        let pace = BodyPace(small: (head.contentLength ?? 0) <= Int64(Limits.maxSmallBody), options: options)
        let body = LinkRequestBody(length: head.contentLength ?? 0, prefix: Data(buffer.dropFirst(parsed.consumed)),
                                   sendContinue: sendContinue) { (maxLength: Int) in
            do {
                let wait = try pace.timeToRead()
                return try await link.receive(maxLength: maxLength, timeout: wait)
            } catch {
                link.cancel()
                throw error
            }
        }
        let request = LinkRequest(head: head, body: body, remote: remote)
        let response: LinkResponse
        if head.method == "GET" && head.path == Route.outbox {
            // A guest that hangs up during the long poll frees its slot at once instead of after the wait.
            let handler = Task { await router.handle(request) }
            let watcher = Task {
                if let data = try? await link.receive(maxLength: 1, timeout: 3600), data.isEmpty { handler.cancel() }
            }
            response = await handler.value
            watcher.cancel()
        } else {
            response = await router.handle(request)
        }
        // A send into a closed connection still completes once; a phone that already hung up never gets the secret.
        if response.written != nil, await link.peerClosed() {
            response.discard()
            response.written?(false)
            return
        }
        do {
            try await write(response, to: link)
        } catch {
            response.written?(false)
            throw error
        }
        response.written?(true)
        // Leave the client its whole send when it is small, so closing does not cut off the answer.
        let limit = options.discardTimeout
        let cutOff = Task {
            try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
            if !Task.isCancelled { link.cancel() }
        }
        _ = try? await body.discard(maxBytes: options.maxDiscardBytes)
        cutOff.cancel()
    }

    private func write(_ response: LinkResponse, to link: Link) async throws {
        let head = LinkHttp.responseHead(status: response.status, headers: response.headers, contentLength: response.contentLength)
        switch response.payload {
        case .data(let data):
            try await link.send(head + data, timeout: options.idleTimeout)
        case .file(let handle, let length):
            defer { try? handle.close() }
            try await link.send(head, timeout: options.idleTimeout)
            var left = length
            while left > 0 {
                guard let chunk = try handle.read(upToCount: Int(min(256 * 1024, left))), !chunk.isEmpty else {
                    throw NWError.posix(.ECONNRESET)
                }
                try await link.send(chunk, timeout: options.idleTimeout)
                left -= Int64(chunk.count)
            }
        }
    }

    private func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return false }
        running = true
        return true
    }

    /// Ends a start: listening on `started`, or not at all when it is nil.
    private func finishStart(_ started: NWListener?, port: Int) {
        lock.lock()
        defer { lock.unlock() }
        listener = started
        bound = port
        running = started != nil
    }

    private func takeListener() -> NWListener? {
        lock.lock()
        defer { lock.unlock() }
        guard running else { return nil }
        running = false
        let taken = listener
        listener = nil
        return taken
    }

    private func servedNow() -> [Served] {
        lock.lock()
        defer { lock.unlock() }
        return Array(served.values)
    }

    private func finished(_ number: Int) {
        lock.lock()
        served.removeValue(forKey: number)
        lock.unlock()
    }

    /// Waits (2 s at most) until the listener has let go of its socket, so nothing answers once `stop()` returns.
    private func waitUntilCancelled(_ stopped: NWListener) async {
        let end = Date().addingTimeInterval(2)
        while Date() < end {
            if case .cancelled = stopped.state { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func waitForConnections(seconds: TimeInterval) async {
        let end = Date().addingTimeInterval(seconds)
        while activeConnections > 0 && Date() < end && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

extension LinkResponse {
    func discard() {
        if case .file(let handle, _) = payload { try? handle.close() }
    }
}

/// The time a request's body is allowed: a small one has `bodyTimeout` in all, any other must keep moving, with
/// `idleTimeout` between two reads. Either ends the connection (ETIMEDOUT).
private final class BodyPace: @unchecked Sendable {
    private let lock = NSLock()
    private let small: Bool
    private let options: LinkServerOptions
    private var started: Date?

    init(small: Bool, options: LinkServerOptions) {
        self.small = small
        self.options = options
    }

    func timeToRead() throws -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        let begin = started ?? Date()
        started = begin
        guard small else { return options.idleTimeout }
        let left = options.bodyTimeout - Date().timeIntervalSince(begin)
        guard left > 0 else { throw NWError.posix(.ETIMEDOUT) }
        return min(options.idleTimeout, left)
    }
}

/// One accepted connection: its handshake, reads and writes as async calls, each bounded in time. When one takes
/// too long it fails with ETIMEDOUT, and the server then cancels the connection.
private final class Link: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue

    init(_ connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    /// Starts the connection; true once its TLS handshake is done.
    func ready(timeout: TimeInterval) async -> Bool {
        let connection = self.connection
        let queue = self.queue
        let result: Bool? = try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            let once = Once<Bool>(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.resume(.success(true))
                case .failed, .waiting, .cancelled:
                    once.resume(.success(false))
                default:
                    break
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) {
                once.resume(.success(false))
            }
            connection.start(queue: queue)
        }
        return result ?? false
    }

    /// At most `maxLength` bytes; empty once the peer closed. A cancelled task stops waiting.
    func receive(maxLength: Int, timeout: TimeInterval) async throws -> Data {
        let connection = self.connection
        let queue = self.queue
        let once = OnceBox<Data>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                once.set(continuation)
                let timer = DispatchWorkItem {
                    once.resume(.failure(NWError.posix(.ETIMEDOUT)))
                }
                queue.asyncAfter(deadline: .now() + timeout, execute: timer)
                connection.receive(minimumIncompleteLength: 1, maximumLength: max(maxLength, 1)) { data, _, _, error in
                    timer.cancel()
                    if let data = data, !data.isEmpty {
                        once.resume(.success(data))
                    } else if let error = error {
                        once.resume(.failure(error))
                    } else {
                        once.resume(.success(Data()))
                    }
                }
            }
        } onCancel: {
            once.resume(.failure(CancellationError()))
        }
    }

    /// True when the peer has closed its side; anything it sent meanwhile is dropped.
    func peerClosed() async -> Bool {
        let connection = self.connection
        let queue = self.queue
        return (try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            let once = Once<Bool>(continuation)
            let timer = DispatchWorkItem {
                once.resume(.success(false))
            }
            queue.asyncAfter(deadline: .now() + 0.05, execute: timer)
            connection.receive(minimumIncompleteLength: 0, maximumLength: 1) { _, _, isComplete, error in
                timer.cancel()
                once.resume(.success(isComplete || error != nil))
            }
        }) ?? false
    }

    func send(_ data: Data, timeout: TimeInterval) async throws {
        let connection = self.connection
        let queue = self.queue
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once<Void>(continuation)
            let timer = DispatchWorkItem {
                once.resume(.failure(NWError.posix(.ETIMEDOUT)))
            }
            queue.asyncAfter(deadline: .now() + timeout, execute: timer)
            connection.send(content: data, completion: .contentProcessed({ error in
                timer.cancel()
                if let error = error {
                    once.resume(.failure(error))
                } else {
                    once.resume(.success(()))
                }
            }))
        }
    }

    func cancel() {
        connection.cancel()
    }
}

/// A continuation resumed by whichever of its callbacks comes first.
private final class Once<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    /// Resumes with `result`; false when it was resumed before.
    @discardableResult
    func resume(_ result: Result<Value, Error>) -> Bool {
        lock.lock()
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: result)
        return waiting != nil
    }
}

/// Like `Once`, for a continuation that is only made after the cancellation handler is installed. A result that
/// arrives first is kept for it.
private final class OnceBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var early: Result<Value, Error>?
    private var done = false

    func set(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let early = early {
            done = true
            lock.unlock()
            continuation.resume(with: early)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resume(_ result: Result<Value, Error>) {
        lock.lock()
        if done {
            lock.unlock()
            return
        }
        guard let waiting = continuation else {
            if early == nil { early = result }
            lock.unlock()
            return
        }
        continuation = nil
        done = true
        lock.unlock()
        waiting.resume(with: result)
    }
}

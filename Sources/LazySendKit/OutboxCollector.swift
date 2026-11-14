import Foundation

/// Where what the computer sends ends up: the app's timeline and its Documents folder. The writes are
/// synchronous because they are called as the bytes arrive.
public protocol OutboxHandler: Sendable {
    /// The item is already stored, so a repeat of it (the computer keeps it until it is acknowledged) is skipped.
    func isDone(_ item: OutboxEntry) async -> Bool
    func receiveNote(_ item: OutboxEntry) async
    /// Starts the item's entry and gives the length of the half-saved file from an earlier try, 0 when there is none.
    func prepareFile(_ item: OutboxEntry) async throws -> Int64
    func resetFile(_ item: OutboxEntry) throws
    func write(_ data: Data, for item: OutboxEntry) throws
    func progress(_ item: OutboxEntry, bytes: Int64)
    func finishFile(_ item: OutboxEntry) async throws
    func pause(_ item: OutboxEntry) async
    func fail(_ item: OutboxEntry, reason: String) async
}

/// The handler cannot store anything right now (the receive folder is missing, denied or on a volume that is not
/// there). The item stays queued on the computer and is asked for again later.
public struct StorageUnavailable: Error, LocalizedError {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }

    public var errorDescription: String? { reason }
}

private actor AsyncLock {
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if held {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            held = true
        }
    }

    func release() {
        if waiters.isEmpty {
            held = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

private final class Counter: @unchecked Sendable {
    var written: Int64
    var total: Int64 = -1

    init(_ written: Int64) {
        self.written = written
    }
}

/// Takes what a computer has queued for this phone. One per computer: the foreground watch and the
/// periodic check can both ask for the same item, and one at a time keeps them off each other's file.
public final class OutboxCollector: @unchecked Sendable {
    private let handler: OutboxHandler
    private let lock = AsyncLock()

    public init(handler: OutboxHandler) {
        self.handler = handler
    }

    /// Takes everything pending once; with `wait` above 0 the request is held open until something comes.
    /// Returns how many items were taken. A computer that is busy or unreachable leaves the rest queued and throws.
    public func collect(api: OutboxAPI, wait: Int) async throws -> Int {
        var taken = 0
        var more = true
        while more {
            let reply = try await api.outbox(wait: min(wait, LinkProtocol.maxOutboxWait))
            more = reply.more
            await lock.acquire()
            do {
                for item in reply.items {
                    try await handle(item, api: api)
                    taken += 1
                }
            } catch {
                await lock.release()
                throw error
            }
            await lock.release()
        }
        return taken
    }

    private func handle(_ item: OutboxEntry, api: OutboxAPI) async throws {
        do {
            if !(await handler.isDone(item)) {
                switch item.kind {
                case "text", "link": await handler.receiveNote(item)
                case "file": try await download(item, api: api)
                default: break
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as LinkError where OutboxCollector.leavesQueued(error) {
            throw error
        } catch is StorageUnavailable {
            throw error
        } catch {
            // One item that cannot be stored must not stop the ones behind it, and it will not get better.
            await handler.fail(item, reason: error.localizedDescription)
        }
        try await api.acknowledge(item.id)
    }

    private static func leavesQueued(_ error: LinkError) -> Bool {
        switch error {
        case .network, .wrongCertificate: return true
        case .badResponse: return false
        case .refused(let status, _, _, _): return error.isBusy || status == 401 || status >= 500
        }
    }

    private func download(_ item: OutboxEntry, api: OutboxAPI) async throws {
        let size = item.size ?? 0
        var have = try await handler.prepareFile(item)
        if have > size {
            try handler.resetFile(item)
            have = 0
        }
        // A half-saved file that already holds every byte only needs putting in place.
        if have < size {
            let counter = Counter(have)
            let start = have
            let handler = self.handler
            do {
                try await api.download(id: item.id, from: start, onStart: { status, total in
                    counter.total = total
                    if status == 200 && start > 0 {
                        try handler.resetFile(item)
                        counter.written = 0
                    }
                }, sink: { data in
                    try handler.write(data, for: item)
                    counter.written += Int64(data.count)
                    handler.progress(item, bytes: counter.written)
                })
                if counter.written != (counter.total >= 0 ? counter.total : size) { throw LinkError.network("The download stopped early.") }
            } catch {
                await handler.pause(item)
                throw error
            }
        }
        try await handler.finishFile(item)
    }
}

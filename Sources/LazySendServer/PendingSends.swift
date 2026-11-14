import Foundation

/// A file sent to a computer that is not finished: enough to carry on after the app was closed.
public struct PendingSend: Codable, Equatable, Sendable {
    public var hostId: String
    public var sendId: String
    public var path: String
    public var size: Int64
    /// The file's modified time in whole seconds, which is all the host is told of it.
    public var modified: Int64
    public var sha256: String
    /// Security-scoped, so a sandboxed app can open a file it was given outside its container again.
    public var bookmark: Data?

    static func seconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970.rounded(.down))
    }
}

struct PendingFile: Codable {
    var sends: [PendingSend] = []
}

/// The unfinished file sends to other computers, in pending.json next to the guest's other files.
public final class PendingSends: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var file: PendingFile

    public init(url: URL) {
        self.url = url
        file = JsonFile.load(PendingFile.self, from: url) ?? PendingFile()
    }

    public var sends: [PendingSend] {
        lock.lock()
        defer { lock.unlock() }
        return file.sends
    }

    func add(_ send: PendingSend) {
        lock.lock()
        file.sends.removeAll { $0.sendId == send.sendId }
        file.sends.append(send)
        JsonFile.save(file, to: url)
        lock.unlock()
    }

    func remove(_ sendId: String) {
        lock.lock()
        let before = file.sends.count
        file.sends.removeAll { $0.sendId == sendId }
        if file.sends.count != before { JsonFile.save(file, to: url) }
        lock.unlock()
    }

    func removeHost(_ hostId: String) {
        lock.lock()
        let before = file.sends.count
        file.sends.removeAll { $0.hostId == hostId }
        if file.sends.count != before { JsonFile.save(file, to: url) }
        lock.unlock()
    }
}

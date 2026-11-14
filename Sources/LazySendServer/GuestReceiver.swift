import Foundation
import LazySendKit

/// Stores what one host has queued for this computer. Texts and links go into the received history under the item's
/// own id, so a repeat is noticed. A file is written as `<id>.part` in `<receive folder>/<host name>/`, which a dropped
/// download continues, then renamed, marked as downloaded and reported.
final class GuestReceiver: OutboxHandler, @unchecked Sendable {
    private weak var guest: GuestService?
    private let hostId: String
    private let lock = NSLock()
    private var handles: [String: FileHandle] = [:]

    init(hostId: String, guest: GuestService) {
        self.hostId = hostId
        self.guest = guest
    }

    private var host: PairedPc? { guest?.hosts.get(hostId) }

    private func directory() throws -> URL {
        guard let guest = guest, let host = host else { throw CocoaError(.fileNoSuchFile) }
        return guest.settings.receiveRoot.appendingPathComponent(FileNames.clean(host.name, fallback: "Computer"), isDirectory: true)
    }

    // An item's id names its part file, so one that is not a plain id is refused.
    private func partURL(for item: OutboxEntry) throws -> URL {
        guard isValidId(item.id) else { throw CocoaError(.fileWriteInvalidFileName) }
        return try directory().appendingPathComponent(item.id + ".part")
    }

    func isDone(_ item: OutboxEntry) async -> Bool {
        guard item.kind != "file", let history = guest?.history else { return false }
        return history.items.contains { $0.id == item.id }
    }

    func receiveNote(_ item: OutboxEntry) async {
        guard let guest = guest, let host = host else { return }
        let link = item.kind == "link"
        let text = item.text ?? ""
        let acceptable = isValidId(item.id)
            && (link ? isAcceptableLink(item.url) : !text.isEmpty && text.utf8.count <= LinkProtocol.maxTextBytes)
        guard acceptable else {
            guest.onFailed?("A \(link ? "link" : "text") from \(host.name) could not be received: it is not text or a web address Lazy Send takes.")
            return
        }
        let stored = guest.history.add(deviceId: host.id, deviceName: host.name, kind: item.kind, text: link ? nil : text,
                                       url: link ? item.url : nil, id: item.id, now: Date())
        guest.onTextReceived?(stored)
    }

    func prepareFile(_ item: OutboxEntry) async throws -> Int64 {
        let part = try partURL(for: item)
        let fm = FileManager.default
        try fm.createDirectory(at: part.deletingLastPathComponent(), withIntermediateDirectories: true)
        closeHandle(item.id)
        var have: Int64 = 0
        if fm.fileExists(atPath: part.path) {
            let attributes = try? fm.attributesOfItem(atPath: part.path)
            have = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        } else if !fm.createFile(atPath: part.path, contents: nil) {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: part)
        _ = try handle.seekToEnd()
        lock.lock()
        handles[item.id] = handle
        lock.unlock()
        return have
    }

    func resetFile(_ item: OutboxEntry) throws {
        let handle = try openHandle(for: item)
        try handle.truncate(atOffset: 0)
        try handle.seek(toOffset: 0)
    }

    func write(_ data: Data, for item: OutboxEntry) throws {
        try openHandle(for: item).write(contentsOf: data)
    }

    func progress(_ item: OutboxEntry, bytes: Int64) {}

    func finishFile(_ item: OutboxEntry) async throws {
        closeHandle(item.id)
        let part = try partURL(for: item)
        let folder = part.deletingLastPathComponent()
        let target = folder.appendingPathComponent(FileNames.unique(in: folder, name: FileNames.clean(item.name)))
        try FileManager.default.moveItem(at: part, to: target)
        Inbox.markAsDownloaded(target)
        guard let host = host else { return }
        guest?.onFileReceived?(ReceivedFile(deviceId: host.id, deviceName: host.name, url: target, size: item.size ?? 0, sourceId: nil))
    }

    func pause(_ item: OutboxEntry) async {
        closeHandle(item.id)
    }

    /// What an item that is dropped from the host's queue leaves half-downloaded is of no use.
    func fail(_ item: OutboxEntry, reason: String) async {
        closeHandle(item.id)
        if let part = try? partURL(for: item) { try? FileManager.default.removeItem(at: part) }
        guest?.onFailed?("\(item.name ?? "An item") from \(host?.name ?? "a computer") could not be received: \(reason)")
    }

    private func openHandle(for item: OutboxEntry) throws -> FileHandle {
        lock.lock()
        defer { lock.unlock() }
        guard let handle = handles[item.id] else { throw CocoaError(.fileWriteUnknown) }
        return handle
    }

    private func closeHandle(_ id: String) {
        lock.lock()
        let handle = handles.removeValue(forKey: id)
        lock.unlock()
        try? handle?.close()
    }
}

import Foundation
import LazySendKit

/// Stores what one host has queued for this computer. Texts and links go into the received history under the item's
/// own id, so a repeat is noticed. A file is written as `<id>.part` in `<receive folder>/<host name>/`, which a dropped
/// download continues, then renamed, marked as downloaded and reported. A receive folder that cannot be used leaves the
/// item queued on the host.
final class GuestReceiver: OutboxHandler, @unchecked Sendable {
    static let finishedKept = 200
    static let staleAfter: TimeInterval = 24 * 3600

    private weak var guest: GuestService?
    private let hostId: String
    private let lock = NSLock()
    private var handles: [String: FileHandle] = [:]
    // Where each file in progress is being written, fixed when it starts so a rename of the host cannot strand it.
    private var parts: [String: URL] = [:]
    // The files finished lately, so one the host lists again because its acknowledgement was lost is only acknowledged.
    private var finished: [String] = []
    private var reportedStorage = false

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
        if item.kind == "file" {
            lock.lock()
            defer { lock.unlock() }
            return finished.contains(item.id)
        }
        guard let history = guest?.history else { return false }
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
        closeHandle(item.id)
        var have: Int64 = 0
        let handle: FileHandle
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: part.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: part.path) {
                let attributes = try? fm.attributesOfItem(atPath: part.path)
                have = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            } else if !fm.createFile(atPath: part.path, contents: nil) {
                throw CocoaError(.fileWriteUnknown)
            }
            handle = try FileHandle(forWritingTo: part)
            _ = try handle.seekToEnd()
        } catch {
            reportStorage(error)
            throw StorageUnavailable(reason: error.localizedDescription)
        }
        lock.lock()
        handles[item.id] = handle
        parts[item.id] = part
        reportedStorage = false
        lock.unlock()
        return have
    }

    // Said once until storage works again, as the item is asked for every few seconds.
    private func reportStorage(_ error: Error) {
        lock.lock()
        let first = !reportedStorage
        reportedStorage = true
        lock.unlock()
        if first {
            guest?.onFailed?("Files from \(host?.name ?? "a computer") cannot be saved in the receive folder (\(error.localizedDescription)). They stay queued there until it works.")
        }
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
        lock.lock()
        let started = parts[item.id]
        lock.unlock()
        guard let part = started else { throw CocoaError(.fileNoSuchFile) }
        let folder = part.deletingLastPathComponent()
        let target = folder.appendingPathComponent(FileNames.unique(in: folder, name: FileNames.clean(item.name)))
        try FileManager.default.moveItem(at: part, to: target)
        lock.lock()
        parts[item.id] = nil
        finished.append(item.id)
        if finished.count > GuestReceiver.finishedKept { finished.removeFirst(finished.count - GuestReceiver.finishedKept) }
        lock.unlock()
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
        lock.lock()
        let part = parts.removeValue(forKey: item.id)
        lock.unlock()
        if let part = part { try? FileManager.default.removeItem(at: part) }
        guest?.onFailed?("\(item.name ?? "An item") from \(host?.name ?? "a computer") could not be received: \(reason)")
    }

    /// The host was removed, so what it had begun is of no use either.
    func discardParts() {
        lock.lock()
        let open = Array(handles.values)
        let started = Array(parts.values)
        handles = [:]
        parts = [:]
        lock.unlock()
        open.forEach { try? $0.close() }
        started.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    /// Part files in the host's folder that no listed item will continue and that nothing has touched for a day. The
    /// folder is named after the host, so a phone of the same name may share it; its parts are younger or are
    /// removed by the same rule on its own side.
    func removeStaleParts(keeping listed: Set<String>) {
        guard let folder = try? directory(), let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        lock.lock()
        let active = Set(parts.keys)
        lock.unlock()
        let now = Date()
        for name in names where name.hasSuffix(".part") {
            let id = String(name.dropLast(5))
            let url = folder.appendingPathComponent(name)
            guard isValidId(id), !listed.contains(id), !active.contains(id),
                  let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  now.timeIntervalSince(modified) > GuestReceiver.staleAfter else { continue }
            try? FileManager.default.removeItem(at: url)
        }
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

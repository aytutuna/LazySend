import CryptoKit
import Foundation
import LazySendKit

public struct ReceivedFile: Equatable, Sendable {
    public var deviceId: String
    public var deviceName: String
    public var url: URL
    public var size: Int64
    public var sourceId: String?
}

/// A file being received, as the window shows it.
public struct Transfer: Equatable, Identifiable, Sendable {
    public var id: String
    public var deviceId: String
    public var deviceName: String
    public var name: String
    public var size: Int64
    public var received: Int64
    public var isGallery: Bool
}

/// A file being received (or finished a while ago), kept in a small JSON file so a restart can go on.
final class IncomingFile: Codable, @unchecked Sendable {
    var id = ""
    var deviceId = ""
    var deviceName = ""
    var name = ""
    var size: Int64 = 0
    var mime: String?
    var modified: Date?
    var sourceId: String?
    var sha256: String?
    /// The folder the file ends up in, fixed when the transfer starts so changing the receive folder later strands nothing.
    var directory = ""
    var started = Date()
    var done = false
    var path: String?
    var finished: Date?
}

private final class Writer: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    private var active: Task<Void, Error>?
    var hash: SHA256?
    var hashed: Int64 = 0

    func tryAcquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if busy { return false }
        busy = true
        return true
    }

    func release() {
        lock.lock()
        busy = false
        active = nil
        lock.unlock()
    }

    func setActive(_ task: Task<Void, Error>) {
        lock.lock()
        active = task
        lock.unlock()
    }

    func cancelActive() {
        lock.lock()
        let task = active
        lock.unlock()
        task?.cancel()
    }
}

private struct SourceKey: Hashable {
    var device: String
    var source: String
}

/// Files from phones: begun with the item's metadata, filled in chunks into `<id>.part` in the folder they will end
/// up in, and renamed into place when the last byte is in and the SHA-256, when given, matches. The offset a phone
/// resumes from is the length of the part file, so what was written before a dropped connection or a restart counts.
/// One chunk is written at a time per file: a newer request takes over from one that is still open.
public final class Inbox: @unchecked Sendable {
    static let partKept: TimeInterval = 7 * 24 * 3600
    static let doneKept: TimeInterval = 24 * 3600
    static let takeOverWait: TimeInterval = 5

    private let directory: URL
    private let receiveRoot: () -> URL
    private let index: GalleryIndex
    private let freeSpace: (URL) -> Int64
    private let clock: () -> Date
    private let lock = NSLock()
    private var files: [String: IncomingFile] = [:]
    private var bySource: [SourceKey: IncomingFile] = [:]
    private var writers: [String: Writer] = [:]
    private var lastPrune = Date.distantPast

    public var onFileReceived: ((ReceivedFile) -> Void)?

    /// `directory` holds the transfers' small state files, `receiveRoot` is asked for when a transfer starts, and
    /// `freeSpace` gives the free bytes on the volume of a path.
    public init(directory: URL, receiveRoot: @escaping () -> URL, index: GalleryIndex,
                freeSpace: @escaping (URL) -> Int64 = Inbox.volumeFreeBytes, clock: @escaping () -> Date = { Date() }) {
        self.directory = directory
        self.receiveRoot = receiveRoot
        self.index = index
        self.freeSpace = freeSpace
        self.clock = clock
        load()
    }

    public var transfers: [Transfer] {
        lock.lock()
        let open = files.values.filter { !$0.done }
        lock.unlock()
        return open.map {
            Transfer(id: $0.id, deviceId: $0.deviceId, deviceName: $0.deviceName, name: $0.name, size: $0.size,
                     received: partLength($0), isGallery: $0.sourceId != nil)
        }.sorted { $0.id < $1.id }
    }

    /// Starts a file, or finds the one already started for the same source id. A source id that was received
    /// before answers done.
    func begin(_ device: PairedDevice, _ request: ItemRequest) throws -> ItemState {
        guard let size = request.size, size >= 0 else { throw Refusal(status: 400, failure: .badRequest) }
        if let source = request.sourceId, !GalleryIndex.isValidSourceId(source) { throw Refusal(status: 400, failure: .badRequest) }
        var sha256: String?
        if let text = request.sha256 {
            let hex = "0123456789abcdefABCDEF".utf8
            guard text.utf8.count == 64, text.utf8.allSatisfy({ hex.contains($0) }) else { throw Refusal(status: 400, failure: .badRequest) }
            sha256 = text.lowercased()
        }
        var modified: Date?
        if let text = request.modified {
            guard let date = Inbox.parseDate(text) else { throw Refusal(status: 400, failure: .badRequest) }
            // A phone can send any date; only plausible ones are kept.
            let year = Calendar(identifier: .gregorian).component(.year, from: date)
            if (1980...2100).contains(year) { modified = date }
        }
        if let source = request.sourceId, index.contains(device.id, source) {
            return ItemState(id: "", offset: size, done: true, duplicate: true)
        }
        let now = clock()
        pruneIfDue(now)
        var folder = receiveRoot().appendingPathComponent(FileNames.clean(device.name, fallback: "Phone"), isDirectory: true)
        if request.sourceId != nil {
            folder = folder.appendingPathComponent("Gallery", isDirectory: true)
                .appendingPathComponent(Inbox.month(modified ?? now), isDirectory: true)
        }
        if freeSpace(folder) - size < Limits.minFree { throw Refusal(status: 507, failure: .diskFull) }
        let file = IncomingFile()
        file.id = newId()
        file.deviceId = device.id
        file.deviceName = device.name
        file.name = FileNames.clean(request.name)
        file.size = size
        file.mime = request.mime
        file.modified = modified
        file.sourceId = request.sourceId
        file.sha256 = sha256
        file.directory = folder.path
        file.started = now
        // Looked up and added in one step, so two requests for the same asset cannot start two transfers.
        var existing: IncomingFile?
        lock.lock()
        if let source = request.sourceId, let known = bySource[SourceKey(device: device.id, source: source)], !known.done, known.size == size {
            existing = known
        }
        if existing == nil { track(file) }
        lock.unlock()
        if let existing = existing {
            finishIfFull(existing)
            return state(of: existing)
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: partURL(file).path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            save(file)
            if size == 0 { try complete(file, writer: nil) }
        } catch let refusal as Refusal {
            throw refusal
        } catch {
            discard(file)
            throw Refusal(status: 500, failure: .serverError)
        }
        return state(of: file)
    }

    /// Where a file of `deviceId` stands; nil when there is no such file.
    func state(_ deviceId: String, _ id: String) -> ItemState? {
        guard let file = find(id), file.deviceId == deviceId else { return nil }
        finishIfFull(file)
        return find(id).map { state(of: $0) }
    }

    /// Writes `length` bytes of `body` at `offset`. Returns the new state, done once the last byte is in. When the
    /// connection breaks, what arrived stays and the error is thrown.
    func write(deviceId: String, id: String, offset: Int64, length: Int64, body: LinkRequestBody) async throws -> ItemState {
        guard let file = find(id), file.deviceId == deviceId else { throw Refusal(status: 404, failure: .notFound) }
        if file.done {
            // The last chunk got through but its answer did not.
            _ = try? await body.discard(maxBytes: Int64.max)
            return state(of: file)
        }
        guard length >= 0, !(length == 0 && offset != file.size), offset >= 0, offset <= file.size, length <= file.size - offset else {
            throw Refusal(status: 400, failure: .badRequest)
        }
        guard length <= Limits.maxChunk else { throw Refusal(status: 413, failure: .tooLarge) }
        guard freeSpace(URL(fileURLWithPath: file.directory)) - length >= Limits.minFree else { throw Refusal(status: 507, failure: .diskFull) }

        let writer = writerFor(id)
        guard await acquire(writer) else { throw Refusal(status: 409, failure: .busy) }
        defer { writer.release() }
        // The record may have been discarded while this request waited for the gate.
        guard find(id) != nil else { throw Refusal(status: 404, failure: .notFound) }
        if file.done { return state(of: file) }
        if length == 0 {
            // A part that is full but never got through `complete`: finish it.
            let current = partLength(file)
            if current != file.size { throw Refusal(status: 409, failure: .offsetMismatch(current)) }
            try complete(file, writer: writer)
            return state(of: file)
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forUpdating: partURL(file))
        } catch {
            // Someone removed the part: the record is no use, the phone starts the file again.
            discard(file)
            throw Refusal(status: 404, failure: .notFound)
        }
        let current: Int64
        do {
            current = Int64(try handle.seekToEnd())
        } catch {
            try? handle.close()
            throw Refusal(status: 500, failure: .serverError)
        }
        if current != offset {
            try? handle.close()
            _ = try? await body.discard(maxBytes: Int64.max)
            throw Refusal(status: 409, failure: .offsetMismatch(current))
        }
        if offset == 0 {
            writer.hashed = 0
            writer.hash = file.sha256 == nil ? nil : SHA256()
        } else if writer.hashed != offset {
            writer.hash = nil
        }
        let work = Task { () throws -> Void in
            var left = length
            while left > 0 {
                let chunk = try await body.read(maxLength: Int(min(256 * 1024, left)))
                if chunk.isEmpty { throw InboxError.endedEarly }
                do {
                    try handle.write(contentsOf: chunk)
                } catch {
                    throw Refusal(status: 500, failure: .serverError)
                }
                writer.hash?.update(data: chunk)
                writer.hashed += Int64(chunk.count)
                left -= Int64(chunk.count)
            }
        }
        writer.setActive(work)
        do {
            try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        } catch {
            try? handle.close()
            throw error
        }
        try? handle.close()
        let end = partLength(file)
        if end < file.size { return state(of: file, offset: end) }
        try complete(file, writer: writer)
        return state(of: file)
    }

    /// Drops what a phone had begun and not finished, and the records of what it finished (it was removed). Received
    /// files stay.
    func removeDevice(_ deviceId: String) {
        lock.lock()
        let own = files.values.filter { $0.deviceId == deviceId }
        lock.unlock()
        for file in own {
            // A chunk still coming in is stopped first, so its part can be deleted.
            let writer = writerFor(file.id)
            writer.cancelActive()
            let end = Date().addingTimeInterval(Inbox.takeOverWait)
            var held = writer.tryAcquire()
            while !held && Date() < end {
                Thread.sleep(forTimeInterval: 0.01)
                held = writer.tryAcquire()
            }
            discard(file)
            if held { writer.release() }
        }
    }

    /// Finishes a file whose part is already full but never got through `complete` (it threw, or the process ended
    /// first). Skipped while a chunk is being written.
    private func finishIfFull(_ file: IncomingFile) {
        guard !file.done, partLength(file) == file.size else { return }
        let writer = writerFor(file.id)
        guard writer.tryAcquire() else { return }
        defer { writer.release() }
        if !file.done { try? complete(file, writer: writer) }
    }

    private func complete(_ file: IncomingFile, writer: Writer?) throws {
        guard find(file.id) != nil else { throw Refusal(status: 404, failure: .notFound) }
        let part = partURL(file)
        let placed: URL
        do {
            if let expected = file.sha256 {
                let actual: String
                if let writer = writer, let hash = writer.hash, writer.hashed == file.size {
                    actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
                    writer.hash = nil
                } else {
                    actual = try sha256Hex(of: part)
                }
                if actual != expected {
                    discard(file)
                    throw Refusal(status: 422, failure: .hashMismatch)
                }
            }
            placed = try moveIntoPlace(file, part)
        } catch let refusal as Refusal {
            throw refusal
        } catch {
            throw Refusal(status: 500, failure: .serverError)
        }
        // The file is in place: record that first, so nothing below can make the phone send it again.
        file.done = true
        file.path = placed.path
        file.finished = clock()
        lock.lock()
        let removed = files[file.id] == nil
        lock.unlock()
        // The index takes the asset before it stops being tracked, so a second request for it finds one or the other.
        if !removed, let source = file.sourceId { index.add(file.deviceId, source) }
        lock.lock()
        untrack(file)
        lock.unlock()
        // The phone was removed while the file was finishing: the file stays, nothing is announced or recorded.
        if removed { return }
        save(file)
        Inbox.markAsDownloaded(placed)
        if let modified = file.modified {
            try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: placed.path)
        }
        lock.lock()
        writers[file.id] = nil
        lock.unlock()
        onFileReceived?(ReceivedFile(deviceId: file.deviceId, deviceName: file.deviceName, url: placed, size: file.size, sourceId: file.sourceId))
    }

    /// Tags the file as downloaded, so Gatekeeper's checks apply to what a phone sends (an app, a script).
    static func markAsDownloaded(_ url: URL) {
        let value = "0081;\(String(Int(Date().timeIntervalSince1970), radix: 16));Lazy Send;"
        _ = value.withCString { setxattr(url.path, "com.apple.quarantine", $0, strlen($0), 0, 0) }
    }

    private func moveIntoPlace(_ file: IncomingFile, _ part: URL) throws -> URL {
        let folder = URL(fileURLWithPath: file.directory, isDirectory: true)
        // Another file may take the name between the check and the move.
        var attempt = 0
        while true {
            let target = folder.appendingPathComponent(FileNames.unique(in: folder, name: file.name))
            do {
                try FileManager.default.moveItem(at: part, to: target)
                return target
            } catch {
                attempt += 1
                if attempt >= 20 { throw error }
                if !FileManager.default.fileExists(atPath: target.path) { Thread.sleep(forTimeInterval: 0.1) }
            }
        }
    }

    private func discard(_ file: IncomingFile) {
        // A part that cannot be deleted keeps its record, so a later cleanup finds it again.
        if FileManager.default.fileExists(atPath: partURL(file).path) {
            do {
                try FileManager.default.removeItem(at: partURL(file))
            } catch {
                return
            }
        }
        lock.lock()
        files[file.id] = nil
        untrack(file)
        writers[file.id] = nil
        lock.unlock()
        try? FileManager.default.removeItem(at: metaURL(file.id))
    }

    // With the lock held.
    private func track(_ file: IncomingFile) {
        files[file.id] = file
        if !file.done, let source = file.sourceId { bySource[SourceKey(device: file.deviceId, source: source)] = file }
    }

    // With the lock held.
    private func untrack(_ file: IncomingFile) {
        guard let source = file.sourceId else { return }
        let key = SourceKey(device: file.deviceId, source: source)
        if bySource[key] === file { bySource[key] = nil }
    }

    private func find(_ id: String) -> IncomingFile? {
        lock.lock()
        defer { lock.unlock() }
        return files[id]
    }

    private func writerFor(_ id: String) -> Writer {
        lock.lock()
        defer { lock.unlock() }
        if let writer = writers[id] { return writer }
        let writer = Writer()
        writers[id] = writer
        return writer
    }

    private func acquire(_ writer: Writer) async -> Bool {
        if writer.tryAcquire() { return true }
        writer.cancelActive()
        let end = Date().addingTimeInterval(Inbox.takeOverWait)
        while Date() < end {
            try? await Task.sleep(nanoseconds: 10_000_000)
            if Task.isCancelled { return false }
            if writer.tryAcquire() { return true }
        }
        return false
    }

    private func isStale(_ file: IncomingFile, _ now: Date) -> Bool {
        if file.done { return now.timeIntervalSince(file.finished ?? file.started) > Inbox.doneKept }
        return now.timeIntervalSince(lastActivity(file)) > Inbox.partKept
    }

    /// Drops finished records older than a day and parts nobody has touched for a week; at most once an hour.
    private func pruneIfDue(_ now: Date) {
        lock.lock()
        if now.timeIntervalSince(lastPrune) < 3600 {
            lock.unlock()
            return
        }
        lastPrune = now
        let stale = files.values.filter { isStale($0, now) }
        lock.unlock()
        for file in stale {
            let writer = writerFor(file.id)
            guard writer.tryAcquire() else { continue }
            discard(file)
            writer.release()
        }
    }

    private func state(of file: IncomingFile, offset: Int64? = nil) -> ItemState {
        if file.done { return ItemState(id: file.id, offset: file.size, done: true) }
        return ItemState(id: file.id, offset: offset ?? partLength(file), done: false)
    }

    private func partLength(_ file: IncomingFile) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: partURL(file).path)[.size]) as? NSNumber)?.int64Value ?? 0
    }

    private func partURL(_ file: IncomingFile) -> URL {
        URL(fileURLWithPath: file.directory, isDirectory: true).appendingPathComponent(file.id + ".part")
    }

    private func metaURL(_ id: String) -> URL {
        directory.appendingPathComponent(id + ".json")
    }

    private func save(_ file: IncomingFile) {
        JsonFile.save(file, to: metaURL(file.id))
    }

    private func lastActivity(_ file: IncomingFile) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: partURL(file).path)[.modificationDate]) as? Date ?? file.started
    }

    private func load() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        let now = clock()
        lastPrune = now
        for name in names where name.hasSuffix(".json") {
            let url = directory.appendingPathComponent(name)
            guard let file = JsonFile.load(IncomingFile.self, from: url), isValidId(file.id), !file.directory.isEmpty else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            let stale = isStale(file, now)
            lock.lock()
            track(file)
            lock.unlock()
            if stale { discard(file) }
        }
    }

    private static func parseDate(_ text: String) -> Date? {
        if let date = ISO8601DateFormatter().date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    private static func month(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: date)
    }

    /// Free bytes on the volume of `url`, or of its nearest folder that exists; unlimited when the volume does not say.
    public static func volumeFreeBytes(_ url: URL) -> Int64 {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        guard let free = (try? probe.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity else {
            return Int64.max
        }
        return Int64(free)
    }
}

enum InboxError: Error {
    case endedEarly
}

import Foundation
import LazySendKit

/// Something the computer wants a phone to have. A file stays where it is and is read when the phone downloads it.
public struct OutboxItem: Codable, Equatable, Identifiable, Sendable {
    public var id = ""
    public var deviceId = ""
    public var kind = ""
    public var text: String?
    public var url: String?
    public var path: String?
    /// Opens the file again after a restart where the sandbox forgot the path.
    public var bookmark: Data?
    public var name: String?
    public var size: Int64?
    public var mime: String?
    public var queued = Date()

    var entry: OutboxEntry {
        OutboxEntry(id: id, kind: kind, text: text, url: url, name: name, size: size, mime: mime)
    }

    var inlineBytes: Int {
        (text?.utf8.count ?? 0) + (url?.utf8.count ?? 0)
    }
}

struct OutboxFile: Codable {
    var items: [OutboxItem] = []
}

public enum OutboxError: Error, Equatable {
    case badText
    case badLink
    case tooMany
}

/// What waits for each phone to pick it up, kept in outbox.json so it survives a restart. An item stays until the
/// phone acknowledges it. A phone that asks with nothing waiting is held until something is queued.
public final class Outbox: @unchecked Sendable {
    private let url: URL
    private let clock: () -> Date
    private let lock = NSLock()
    private var file: OutboxFile
    private var waiters: [UUID: (deviceId: String, signal: AsyncStream<Void>.Continuation)] = [:]

    public var onChange: (() -> Void)?

    /// Where an item's file is now; the stored path unless the app resolves a bookmark.
    public var locate: (OutboxItem) -> URL? = { item in item.path.map { URL(fileURLWithPath: $0) } }

    public init(url: URL, clock: @escaping () -> Date = { Date() }) {
        self.url = url
        self.clock = clock
        file = JsonFile.load(OutboxFile.self, from: url) ?? OutboxFile()
    }

    public var all: [OutboxItem] {
        lock.lock()
        defer { lock.unlock() }
        return file.items
    }

    public func pending(_ deviceId: String) -> [OutboxItem] {
        lock.lock()
        defer { lock.unlock() }
        return file.items.filter { $0.deviceId == deviceId }
    }

    public func find(_ deviceId: String, _ id: String) -> OutboxItem? {
        lock.lock()
        defer { lock.unlock() }
        return file.items.first { $0.deviceId == deviceId && $0.id == id }
    }

    @discardableResult
    public func queueText(_ deviceId: String, _ text: String) throws -> OutboxItem {
        guard !text.isEmpty, text.utf8.count <= LinkProtocol.maxTextBytes else { throw OutboxError.badText }
        return try add([OutboxItem(kind: ItemKind.text, text: text)], deviceId, atMost: false)[0]
    }

    @discardableResult
    public func queueLink(_ deviceId: String, _ link: String) throws -> OutboxItem {
        guard isAcceptableLink(link) else { throw OutboxError.badLink }
        return try add([OutboxItem(kind: ItemKind.link, url: link)], deviceId, atMost: false)[0]
    }

    /// Queues the existing files among `files` with one save, as many as fit under the limit; returns the items queued.
    @discardableResult
    public func queueFiles(_ deviceId: String, _ files: [(url: URL, bookmark: Data?, mime: String?)]) -> [OutboxItem] {
        var items: [OutboxItem] = []
        for file in files {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: file.url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
                  let size = (try? FileManager.default.attributesOfItem(atPath: file.url.path)[.size] as? NSNumber)?.int64Value
            else { continue }
            var item = OutboxItem(kind: ItemKind.file, path: file.url.path, bookmark: file.bookmark, name: file.url.lastPathComponent, size: size)
            item.mime = file.mime
            items.append(item)
        }
        return (try? add(items, deviceId, atMost: true)) ?? []
    }

    /// The phone's pending items; when there are none, waits up to `seconds` for one to be queued.
    public func wait(_ deviceId: String, seconds: Int) async -> [OutboxItem] {
        let (stream, signal) = AsyncStream.makeStream(of: Void.self)
        let key = UUID()
        lock.lock()
        let items = file.items.filter { $0.deviceId == deviceId }
        if !items.isEmpty || seconds <= 0 {
            lock.unlock()
            return items
        }
        waiters[key] = (deviceId, signal)
        lock.unlock()
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            signal.finish()
        }
        for await _ in stream { break }
        timer.cancel()
        lock.lock()
        waiters[key] = nil
        lock.unlock()
        return pending(deviceId)
    }

    /// The phone has the item: removes it. False when it was not there.
    @discardableResult
    public func acknowledge(_ deviceId: String, _ id: String) -> Bool {
        lock.lock()
        let before = file.items.count
        file.items.removeAll { $0.deviceId == deviceId && $0.id == id }
        let removed = file.items.count != before
        if removed { JsonFile.save(file, to: url) }
        lock.unlock()
        if removed { onChange?() }
        return removed
    }

    /// Drops everything waiting for the phone (it was removed, or the user cleared the queue).
    public func clear(_ deviceId: String) {
        lock.lock()
        let before = file.items.count
        file.items.removeAll { $0.deviceId == deviceId }
        let removed = file.items.count != before
        if removed { JsonFile.save(file, to: url) }
        lock.unlock()
        if removed { onChange?() }
    }

    private func add(_ added: [OutboxItem], _ deviceId: String, atMost: Bool) throws -> [OutboxItem] {
        var items = added
        lock.lock()
        let room = Limits.maxOutboxItemsPerDevice - file.items.filter { $0.deviceId == deviceId }.count
        if !atMost && items.count > room {
            lock.unlock()
            throw OutboxError.tooMany
        }
        if items.count > room { items = Array(items.prefix(max(room, 0))) }
        if items.isEmpty {
            lock.unlock()
            return items
        }
        for index in items.indices {
            items[index].id = newId()
            items[index].deviceId = deviceId
            items[index].queued = clock()
        }
        file.items += items
        JsonFile.save(file, to: url)
        for (key, waiter) in waiters where waiter.deviceId == deviceId {
            waiter.signal.yield()
            waiter.signal.finish()
            waiters[key] = nil
        }
        lock.unlock()
        onChange?()
        return items
    }
}

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
    public var sourceId: String?
    public var taken: Date?
    public var clip: Bool?
    public var queued = Date()

    // A date outside 1980 to 2100 is left out, as a guest would not use it.
    private var plausibleTaken: Date? {
        guard let taken = taken, (1980...2100).contains(Calendar(identifier: .gregorian).component(.year, from: taken)) else { return nil }
        return taken
    }

    var entry: OutboxEntry { listed(at: Date()) }

    /// What the guest is told of the item at `now`; the clip flag is left out once the item is older than `LinkProtocol.clipMaxAge`.
    func listed(at now: Date) -> OutboxEntry {
        OutboxEntry(id: id, kind: kind, text: text, url: url, name: name, size: size, mime: mime, sourceId: sourceId,
                    taken: plausibleTaken.map { ISO8601DateFormatter().string(from: $0) },
                    clip: clip == true && now.timeIntervalSince(queued) <= LinkProtocol.clipMaxAge ? true : nil)
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
    // Items whose file is being sent right now, by how many downloads.
    private var serving: [String: Int] = [:]

    public var onChange: (() -> Void)?
    /// Called with the item the phone just acknowledged, while the queue is still locked so that nothing sees the item
    /// gone before this has run. It must not call back into the outbox.
    public var onAcknowledged: ((OutboxItem) -> Void)?

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
        return clipFirst(file.items.filter { $0.deviceId == deviceId })
    }

    // Items still worth clipping go first, so a guest that takes them in list order is not held up by a gallery feed.
    private func clipFirst(_ items: [OutboxItem]) -> [OutboxItem] {
        let now = clock()
        func clips(_ item: OutboxItem) -> Bool { item.clip == true && now.timeIntervalSince(item.queued) <= LinkProtocol.clipMaxAge }
        return items.filter(clips) + items.filter { !clips($0) }
    }

    public func find(_ deviceId: String, _ id: String) -> OutboxItem? {
        lock.lock()
        defer { lock.unlock() }
        return file.items.first { $0.deviceId == deviceId && $0.id == id }
    }

    @discardableResult
    public func queueText(_ deviceId: String, _ text: String, clip: Bool? = nil) throws -> OutboxItem {
        guard !text.isEmpty, text.utf8.count <= LinkProtocol.maxTextBytes else { throw OutboxError.badText }
        return try add([OutboxItem(kind: ItemKind.text, text: text, clip: clip)], deviceId, atMost: false)[0]
    }

    @discardableResult
    public func queueLink(_ deviceId: String, _ link: String, clip: Bool? = nil) throws -> OutboxItem {
        guard isAcceptableLink(link) else { throw OutboxError.badLink }
        return try add([OutboxItem(kind: ItemKind.link, url: link, clip: clip)], deviceId, atMost: false)[0]
    }

    /// Queues the existing files among `files` with one save, as many as fit under the limit; returns the items queued.
    @discardableResult
    public func queueFiles(_ deviceId: String, _ files: [(url: URL, bookmark: Data?, mime: String?)], clip: Bool? = nil) -> [OutboxItem] {
        let items = files.compactMap { fileItem($0.url, bookmark: $0.bookmark, mime: $0.mime, clip: clip) }
        return (try? add(items, deviceId, atMost: true)) ?? []
    }

    /// Queues one file from the phone's own library for the phone to file as a gallery item. Nil when the file is not
    /// there or the id is not usable; throws `tooMany` when the device already has all it may.
    @discardableResult
    public func queueGalleryFile(_ deviceId: String, url: URL, mime: String?, sourceId: String, taken: Date?) throws -> OutboxItem? {
        guard GalleryIndex.isValidSourceId(sourceId), var item = fileItem(url, bookmark: nil, mime: mime) else { return nil }
        item.sourceId = sourceId
        item.taken = taken
        return try add([item], deviceId, atMost: false).first
    }

    private func fileItem(_ url: URL, bookmark: Data?, mime: String?, clip: Bool? = nil) -> OutboxItem? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        else { return nil }
        var item = OutboxItem(kind: ItemKind.file, path: url.path, bookmark: bookmark, name: url.lastPathComponent, size: size)
        item.mime = mime
        item.clip = clip
        return item
    }

    /// The phone's pending items; when there are none, waits up to `seconds` for one to be queued.
    public func wait(_ deviceId: String, seconds: Int) async -> [OutboxItem] {
        let (stream, signal) = AsyncStream.makeStream(of: Void.self)
        let key = UUID()
        lock.lock()
        let items = file.items.filter { $0.deviceId == deviceId }
        if !items.isEmpty || seconds <= 0 {
            lock.unlock()
            return clipFirst(items)
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
        let found = file.items.first { $0.deviceId == deviceId && $0.id == id }
        if let item = found {
            file.items.removeAll { $0.deviceId == deviceId && $0.id == id }
            JsonFile.save(file, to: url)
            onAcknowledged?(item)
        }
        lock.unlock()
        guard found != nil else { return false }
        onChange?()
        return true
    }

    /// The router is about to send the item's file; the item stays through `removeGalleryItems` until `endServing`.
    func beginServing(_ id: String) {
        lock.lock()
        serving[id, default: 0] += 1
        lock.unlock()
    }

    func endServing(_ id: String) {
        lock.lock()
        serving[id] = (serving[id] ?? 1) > 1 ? serving[id]! - 1 : nil
        lock.unlock()
    }

    public func isServing(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return serving[id] != nil
    }

    /// Takes the gallery items back out for the phone without acknowledging them, except the ones being downloaded
    /// right now, which the phone acknowledges as usual; returns what was removed.
    @discardableResult
    public func removeGalleryItems(_ deviceId: String) -> [OutboxItem] {
        lock.lock()
        let gone = file.items.filter { $0.deviceId == deviceId && $0.sourceId != nil && serving[$0.id] == nil }
        if !gone.isEmpty {
            let ids = Set(gone.map(\.id))
            file.items.removeAll { ids.contains($0.id) }
            JsonFile.save(file, to: url)
        }
        lock.unlock()
        if !gone.isEmpty { onChange?() }
        return gone
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

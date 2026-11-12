import Foundation

public struct ReceivedItem: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var deviceId: String
    public var deviceName: String
    public var kind: String
    public var text: String?
    public var url: String?
    public var received: Date
}

struct HistoryFile: Codable {
    var items: [ReceivedItem] = []
}

/// The texts and links received, newest first. Old entries go when there are more than `maxItems` or their text
/// adds up to more than `maxTextBytes`.
public final class ReceivedHistory: @unchecked Sendable {
    public static let maxItems = 500
    public static let maxTextBytes = 16 * 1024 * 1024

    private let url: URL
    private let lock = NSLock()
    private var file: HistoryFile

    public var onChange: (() -> Void)?

    public init(url: URL) {
        self.url = url
        file = JsonFile.load(HistoryFile.self, from: url) ?? HistoryFile()
    }

    public var items: [ReceivedItem] {
        lock.lock()
        defer { lock.unlock() }
        return file.items
    }

    @discardableResult
    func add(_ device: PairedDevice, kind: String, text: String?, url link: String?, now: Date) -> ReceivedItem {
        let item = ReceivedItem(id: newId(), deviceId: device.id, deviceName: device.name, kind: kind, text: text, url: link, received: now)
        lock.lock()
        file.items.insert(item, at: 0)
        var bytes = 0
        var keep = 0
        for entry in file.items {
            bytes += (entry.text?.utf8.count ?? 0) + (entry.url?.utf8.count ?? 0)
            if keep >= ReceivedHistory.maxItems || (keep > 0 && bytes > ReceivedHistory.maxTextBytes) { break }
            keep += 1
        }
        file.items.removeSubrange(keep...)
        JsonFile.save(file, to: url)
        lock.unlock()
        onChange?()
        return item
    }

    @discardableResult
    public func remove(_ id: String) -> Bool {
        lock.lock()
        let before = file.items.count
        file.items.removeAll { $0.id == id }
        let removed = file.items.count != before
        if removed { JsonFile.save(file, to: url) }
        lock.unlock()
        if removed { onChange?() }
        return removed
    }

    public func clear() {
        lock.lock()
        file.items = []
        JsonFile.save(file, to: url)
        lock.unlock()
        onChange?()
    }
}

import Foundation

public enum AppGroup {
    public static let id = "group.com.lazysend.lazysend"

    /// Lazy Send's folder in the group container the app and its share extension both reach; the app's own
    /// Application Support folder where the group is not available (an unsigned Simulator build).
    public static func folder() -> URL {
        let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("LazySend", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// What the phone keeps as a host (pairings, its outbox, the files it queues), in a folder of its own.
    public static func hostFolder() -> URL {
        let folder = AppGroup.folder().appendingPathComponent("Host", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

public struct QueuedItem: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var pcId: String
    public var kind: String
    public var text: String?
    public var url: String?
    public var name: String?
    public var mime: String?
    public var modified: Date?
    public var created: Date
    public var itemId: String?

    public init(id: String, pcId: String, kind: String, text: String? = nil, url: String? = nil, name: String? = nil,
                mime: String? = nil, modified: Date? = nil, created: Date = Date(), itemId: String? = nil) {
        self.id = id
        self.pcId = pcId
        self.kind = kind
        self.text = text
        self.url = url
        self.name = name
        self.mime = mime
        self.modified = modified
        self.created = created
        self.itemId = itemId
    }
}

/// What the share sheet leaves for the app to send: a folder per item with `item.json` and, for a file, the
/// file itself. An item is written under `Staging` and moved into `Queue` whole, so the app never reads one
/// half written.
public struct ShareQueue: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    private var queue: URL { root.appendingPathComponent("Queue", isDirectory: true) }
    private var staging: URL { root.appendingPathComponent("Staging", isDirectory: true) }

    /// Queues `item`, copying `file` next to it when it is a file, or moving it when the caller has no more use for it.
    public func add(_ item: QueuedItem, file: URL? = nil, move: Bool = false) throws {
        let fm = FileManager.default
        let folder = staging.appendingPathComponent(item.id, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            if let file = file {
                let target = folder.appendingPathComponent("data")
                if move {
                    try fm.moveItem(at: file, to: target)
                } else {
                    try fm.copyItem(at: file, to: target)
                }
            }
            try JSONEncoder().encode(item).write(to: folder.appendingPathComponent("item.json"))
            try fm.createDirectory(at: queue, withIntermediateDirectories: true)
            try fm.moveItem(at: folder, to: queue.appendingPathComponent(item.id, isDirectory: true))
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
    }

    public func items() -> [QueuedItem] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: queue, includingPropertiesForKeys: nil)) ?? []
        let found = folders.compactMap { folder in
            (try? Data(contentsOf: folder.appendingPathComponent("item.json"))).flatMap { try? JSONDecoder().decode(QueuedItem.self, from: $0) }
        }
        return found.sorted { $0.created < $1.created }
    }

    public func update(_ id: String, _ change: (inout QueuedItem) -> Void) {
        let url = queue.appendingPathComponent(id, isDirectory: true).appendingPathComponent("item.json")
        guard let saved = try? Data(contentsOf: url), var item = try? JSONDecoder().decode(QueuedItem.self, from: saved) else { return }
        change(&item)
        try? JSONEncoder().encode(item).write(to: url, options: .atomic)
    }

    public func dataURL(_ id: String) -> URL {
        queue.appendingPathComponent(id, isDirectory: true).appendingPathComponent("data")
    }

    public func remove(_ id: String) {
        try? FileManager.default.removeItem(at: queue.appendingPathComponent(id, isDirectory: true))
    }
}

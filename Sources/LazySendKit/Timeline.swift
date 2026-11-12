import Combine
import Foundation

public enum Direction: String, Codable, Sendable {
    case sent
    case received
}

public enum EntryKind: String, Codable, Sendable {
    case text
    case link
    case file
    case gallery
}

public enum EntryState: String, Codable, Sendable {
    case active
    case paused
    case done
    case failed
}

public struct TimelineEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var time: Date
    public var direction: Direction
    public var kind: EntryKind
    public var pcName: String
    /// The text or address for a note, the file name for a file, "Photos and videos" for a gallery sync.
    public var title: String
    public var detail: String
    public var state: EntryState
    public var bytes: Int64
    public var totalBytes: Int64
    public var count: Int
    public var totalCount: Int
    /// A received file's name in the app's Documents folder; for a download in progress, the part that is there so far.
    public var fileName: String?
    public var mime: String?
    /// For a file being sent: the computer it goes to, its id for the file once known, and where the app keeps
    /// the copy it sends from (relative to its outgoing folder) until the file is delivered.
    public var pcId: String?
    public var itemId: String?
    public var localFile: String?

    public init(id: String, time: Date = Date(), direction: Direction, kind: EntryKind, pcName: String, title: String, detail: String = "",
                state: EntryState = .active, bytes: Int64 = 0, totalBytes: Int64 = 0, count: Int = 0, totalCount: Int = 0,
                fileName: String? = nil, mime: String? = nil, pcId: String? = nil, itemId: String? = nil, localFile: String? = nil) {
        self.id = id
        self.time = time
        self.direction = direction
        self.kind = kind
        self.pcName = pcName
        self.title = title
        self.detail = detail
        self.state = state
        self.bytes = bytes
        self.totalBytes = totalBytes
        self.count = count
        self.totalCount = totalCount
        self.fileName = fileName
        self.mime = mime
        self.pcId = pcId
        self.itemId = itemId
        self.localFile = localFile
    }
}

@MainActor
public final class Timeline: ObservableObject {
    @Published public private(set) var entries: [TimelineEntry]
    private let file: URL
    private let limit: Int

    public init(file: URL, limit: Int = 500) {
        self.file = file
        self.limit = limit
        let saved = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([TimelineEntry].self, from: $0) } ?? []
        // Nothing is running when the app starts, so what was in progress is paused.
        entries = saved.map { entry in
            var entry = entry
            if entry.state == .active { entry.state = .paused }
            return entry
        }
    }

    public func get(_ id: String) -> TimelineEntry? {
        entries.first { $0.id == id }
    }

    public func add(_ entry: TimelineEntry) {
        entries = Array(([entry] + entries.filter { $0.id != entry.id }).prefix(limit))
        save()
    }

    /// Progress changes often and only the state at the end matters, so this does not write; `save` does.
    public func update(_ id: String, _ change: (inout TimelineEntry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[index])
    }

    public func remove(_ id: String) {
        entries.removeAll { $0.id == id }
        save()
    }

    public func clear() {
        entries = []
        save()
    }

    public func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}

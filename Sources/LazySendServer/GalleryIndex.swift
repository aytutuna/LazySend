import Foundation

/// The source ids (a phone's own asset ids) already received from each phone, so a gallery sync sends only what
/// is new. One text file per phone, an id on each line, appended to as files arrive and read whole once per run.
public final class GalleryIndex: @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    private var byDevice: [String: Set<String>] = [:]

    public init(directory: URL) {
        self.directory = directory
    }

    /// Whether `id` can be kept: 1 to 256 characters, none of them a control character.
    static func isValidSourceId(_ id: String?) -> Bool {
        guard let id = id, !id.isEmpty, id.count <= Limits.maxSourceIdLength else { return false }
        return !id.unicodeScalars.contains { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) }
    }

    public func contains(_ deviceId: String, _ sourceId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return load(deviceId).contains(sourceId)
    }

    /// The ids of `ids` not received from `deviceId` yet, in the order given, each once.
    public func missing(_ deviceId: String, _ ids: [String]) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let known = load(deviceId)
        var seen = Set<String>()
        return ids.filter { !known.contains($0) && seen.insert($0).inserted }
    }

    public func add(_ deviceId: String, _ sourceId: String) {
        lock.lock()
        defer { lock.unlock() }
        _ = load(deviceId)
        guard byDevice[deviceId]?.insert(sourceId).inserted == true else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = path(deviceId)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((sourceId + "\n").utf8))
    }

    /// Forgets what was received from the phone, so a gallery sync sends everything again.
    public func clear(_ deviceId: String) {
        lock.lock()
        defer { lock.unlock() }
        byDevice[deviceId] = nil
        try? FileManager.default.removeItem(at: path(deviceId))
    }

    // With the lock held.
    private func load(_ deviceId: String) -> Set<String> {
        if let set = byDevice[deviceId] { return set }
        var set = Set<String>()
        if let text = try? String(contentsOf: path(deviceId), encoding: .utf8) {
            for line in text.split(separator: "\n") { set.insert(String(line)) }
        }
        byDevice[deviceId] = set
        return set
    }

    private func path(_ deviceId: String) -> URL {
        directory.appendingPathComponent(deviceId + ".txt")
    }
}

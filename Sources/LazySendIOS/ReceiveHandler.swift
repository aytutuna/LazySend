#if os(iOS)
import Foundation
import LazySendKit
import Photos
import UniformTypeIdentifiers

/// Stores what a computer sends in the app's Documents folder and the timeline. A file is kept as
/// `<name>.part` until it is whole, so a later try can carry on from its size.
final class ReceiveHandler: OutboxHandler, @unchecked Sendable {
    private let pcName: String
    private let timeline: Timeline
    private let folder: URL
    private let notifier: Notifier
    private let defaults: UserDefaults
    private let saved: SavedAssets
    private let lock = NSLock()
    private var handles: [String: FileHandle] = [:]
    private var parts: [String: URL] = [:]
    private var lastReport: [String: Date] = [:]

    init(pcName: String, timeline: Timeline, folder: URL, notifier: Notifier, defaults: UserDefaults, saved: SavedAssets) {
        self.pcName = pcName
        self.timeline = timeline
        self.folder = folder
        self.notifier = notifier
        self.defaults = defaults
        self.saved = saved
    }

    private func entryId(_ item: OutboxEntry) -> String {
        "in-" + item.id
    }

    func isDone(_ item: OutboxEntry) async -> Bool {
        let id = entryId(item)
        return await MainActor.run { timeline.get(id)?.state == .done }
    }

    func receiveNote(_ item: OutboxEntry) async {
        let body = item.text ?? item.url ?? ""
        guard !body.isEmpty else { return }
        let entry = TimelineEntry(id: entryId(item), direction: .received, kind: item.kind == "link" ? .link : .text,
                                  pcName: pcName, title: body, state: .done)
        await MainActor.run { timeline.add(entry) }
        notifier.post(pcName, body)
    }

    func prepareFile(_ item: OutboxEntry) async throws -> Int64 {
        let id = entryId(item)
        let previous = await MainActor.run { timeline.get(id) }
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        closeHandle(item.id)
        let part: URL
        var have: Int64 = 0
        if let name = previous?.fileName, name.hasSuffix(".part"), fm.fileExists(atPath: folder.appendingPathComponent(name).path) {
            part = folder.appendingPathComponent(name)
            let attributes = try? fm.attributesOfItem(atPath: part.path)
            have = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        } else {
            let folder = self.folder
            let name = ReceiveHandler.unique(ReceiveHandler.safeName(item.name)) {
                fm.fileExists(atPath: folder.appendingPathComponent($0).path) || fm.fileExists(atPath: folder.appendingPathComponent($0 + ".part").path)
            }
            part = folder.appendingPathComponent(name + ".part")
            guard fm.createFile(atPath: part.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        }
        let handle = try FileHandle(forWritingTo: part)
        _ = try handle.seekToEnd()
        lock.lock()
        handles[item.id] = handle
        parts[item.id] = part
        lock.unlock()
        let entry = TimelineEntry(id: id, time: previous?.time ?? Date(), direction: .received, kind: .file, pcName: pcName,
                                  title: String(part.lastPathComponent.dropLast(5)), state: .active, bytes: have,
                                  totalBytes: item.size ?? 0, fileName: part.lastPathComponent, mime: item.mime)
        await MainActor.run { timeline.add(entry) }
        return have
    }

    func resetFile(_ item: OutboxEntry) throws {
        let handle = try openHandle(for: item)
        try handle.truncate(atOffset: 0)
        try handle.seek(toOffset: 0)
        let id = entryId(item)
        Task { @MainActor in self.timeline.update(id) { $0.bytes = 0 } }
    }

    func write(_ data: Data, for item: OutboxEntry) throws {
        try openHandle(for: item).write(contentsOf: data)
    }

    func progress(_ item: OutboxEntry, bytes: Int64) {
        lock.lock()
        let now = Date()
        let due = now.timeIntervalSince(lastReport[item.id] ?? Date.distantPast) >= 0.25
        if due { lastReport[item.id] = now }
        lock.unlock()
        guard due else { return }
        let id = entryId(item)
        Task { @MainActor in self.timeline.update(id) { $0.bytes = bytes } }
    }

    func finishFile(_ item: OutboxEntry) async throws {
        let id = entryId(item)
        closeHandle(item.id)
        lock.lock()
        let part = parts.removeValue(forKey: item.id)
        lock.unlock()
        guard let part = part else { throw CocoaError(.fileNoSuchFile) }
        let fm = FileManager.default
        let folder = self.folder
        let wanted = String(part.lastPathComponent.dropLast(5))
        // Another file may have taken the name while this one was coming in.
        let name = ReceiveHandler.unique(wanted) { fm.fileExists(atPath: folder.appendingPathComponent($0).path) }
        let target = folder.appendingPathComponent(name)
        try fm.moveItem(at: part, to: target)
        let size = item.size ?? 0
        await MainActor.run {
            timeline.update(id) {
                $0.state = .done
                $0.bytes = size
                $0.title = name
                $0.fileName = name
            }
            timeline.save()
        }
        notifier.post(pcName, name)
        saveToPhotos(target, mime: item.mime)
    }

    func pause(_ item: OutboxEntry) async {
        closeHandle(item.id)
        let id = entryId(item)
        await MainActor.run {
            timeline.update(id) { $0.state = .paused }
            timeline.save()
        }
    }

    func fail(_ item: OutboxEntry, reason: String) async {
        closeHandle(item.id)
        lock.lock()
        parts[item.id] = nil
        lock.unlock()
        let id = entryId(item)
        let folder = self.folder
        let pcName = self.pcName
        await MainActor.run {
            if let name = timeline.get(id)?.fileName, name.hasSuffix(".part") {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
            }
            if timeline.get(id) == nil {
                timeline.add(TimelineEntry(id: id, direction: .received, kind: item.kind == "file" ? .file : .text, pcName: pcName,
                                           title: item.name ?? item.text ?? item.url ?? "", detail: reason, state: .failed))
            } else {
                timeline.update(id) {
                    $0.state = .failed
                    $0.detail = reason
                    $0.fileName = nil
                }
                timeline.save()
            }
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
        lastReport[id] = nil
        lock.unlock()
        try? handle?.close()
    }

    private func saveToPhotos(_ url: URL, mime: String?) {
        guard defaults.bool(forKey: Keys.photos) else { return }
        let type = UTType(filenameExtension: url.pathExtension)
        let isVideo = mime?.hasPrefix("video/") == true || type?.conforms(to: .movie) == true
        let isImage = mime?.hasPrefix("image/") == true || type?.conforms(to: .image) == true
        guard isVideo || isImage else { return }
        let saved = self.saved
        PHPhotoLibrary.shared().performChanges({
            let request = isVideo ? PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                                  : PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
            if let id = request?.placeholderForCreatedAsset?.localIdentifier { saved.insert(id) }
        }, completionHandler: nil)
    }

    static func safeName(_ name: String?) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let underscore: Unicode.Scalar = "_"
        var clean = ""
        for scalar in (name ?? "").unicodeScalars {
            clean.unicodeScalars.append(forbidden.contains(scalar) ? underscore : scalar)
        }
        clean = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasPrefix(".") { clean = "_" + clean }
        clean = String(clean.prefix(200))
        return clean.isEmpty ? "file" : clean
    }

    static func unique(_ name: String, taken: (String) -> Bool) -> String {
        if !taken(name) { return name }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            if !taken(candidate) { return candidate }
            n += 1
        }
    }
}
#endif

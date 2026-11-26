#if os(iOS)
import Foundation
import LazySendKit
import LazySendServer
import Photos
import UniformTypeIdentifiers

/// Stores what a computer sends in the app's Documents folder and the timeline. A file is kept as
/// `<name>.part` until it is whole, so a later try can carry on from its size. Files from the computer's photo
/// library are filed under `<computer name>/Gallery/YYYY-MM/` and show as one row for the computer.
final class ReceiveHandler: OutboxHandler, @unchecked Sendable {
    private let pcId: String
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
    private let gallery: GalleryIndex
    private var reportedFull = false
    // Files that went on from a part left by an earlier try: not a fresh arrival, so they do not take the pasteboard.
    private var resumedParts = Set<String>()
    private let onClip: (@Sendable (ClipContent) -> Void)?

    init(pcId: String, pcName: String, timeline: Timeline, folder: URL, notifier: Notifier, defaults: UserDefaults, saved: SavedAssets,
         gallery: GalleryIndex, onClip: (@Sendable (ClipContent) -> Void)? = nil) {
        self.pcId = pcId
        self.pcName = pcName
        self.timeline = timeline
        self.folder = folder
        self.notifier = notifier
        self.defaults = defaults
        self.saved = saved
        self.gallery = gallery
        self.onClip = onClip
    }

    private func entryId(_ item: OutboxEntry) -> String {
        "in-" + item.id
    }

    private var computerFolder: URL {
        folder.appendingPathComponent(FileNames.clean(pcName, fallback: "Computer"), isDirectory: true)
    }

    private var galleryRowId: String {
        "in-gallery-" + pcId
    }

    func isDone(_ item: OutboxEntry) async -> Bool {
        if let source = item.gallerySource { return gallery.contains(pcId, source) }
        let id = entryId(item)
        return await MainActor.run { timeline.get(id)?.state == .done }
    }

    func receiveNote(_ item: OutboxEntry) async {
        let body = item.text ?? item.url ?? ""
        guard !body.isEmpty else { return }
        let entry = TimelineEntry(id: entryId(item), direction: .received, kind: item.kind == "link" ? .link : .text,
                                  pcName: pcName, title: body, state: .done, clip: item.clip)
        await MainActor.run { timeline.add(entry) }
        notifier.post(pcName, body)
        if item.clip == true, let content = ClipContent.of(kind: item.kind, text: item.text, url: item.url, file: nil) { onClip?(content) }
    }

    func prepareFile(_ item: OutboxEntry) async throws -> Int64 {
        if item.gallerySource != nil { return try prepareGalleryFile(item) }
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
            let name = ReceiveHandler.unique(FileNames.clean(item.name)) {
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
        if have > 0 { resumedParts.insert(item.id) }
        lock.unlock()
        let entry = TimelineEntry(id: id, time: previous?.time ?? Date(), direction: .received, kind: .file, pcName: pcName,
                                  title: String(part.lastPathComponent.dropLast(5)), state: .active, bytes: have,
                                  totalBytes: item.size ?? 0, fileName: part.lastPathComponent, mime: item.mime, clip: item.clip)
        await MainActor.run { timeline.add(entry) }
        return have
    }

    // The part is named by the item's id, which the computer keeps for the item, so a later try finds it.
    private func prepareGalleryFile(_ item: OutboxEntry) throws -> Int64 {
        guard isValidId(item.id) else { throw CocoaError(.fileWriteInvalidFileName) }
        let fm = FileManager.default
        let part = computerFolder.appendingPathComponent(item.id + ".part")
        try fm.createDirectory(at: computerFolder, withIntermediateDirectories: true)
        closeHandle(item.id)
        var have: Int64 = 0
        if fm.fileExists(atPath: part.path) {
            have = ((try? fm.attributesOfItem(atPath: part.path))?[.size] as? NSNumber)?.int64Value ?? 0
        } else if !fm.createFile(atPath: part.path, contents: nil) {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: part)
        _ = try handle.seekToEnd()
        lock.lock()
        handles[item.id] = handle
        parts[item.id] = part
        lock.unlock()
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
        do {
            try openHandle(for: item).write(contentsOf: data)
        } catch {
            guard error.isOutOfSpace else { throw error }
            // A full disk says nothing about the item: it stays queued, and the user is told once until a file gets through.
            lock.lock()
            let first = !reportedFull
            reportedFull = true
            lock.unlock()
            if first {
                let id = "full-" + pcId
                let name = pcName
                Task { @MainActor in
                    self.timeline.add(TimelineEntry(id: id, direction: .received, kind: .text, pcName: name,
                                                    title: String(localized: "This phone is out of storage"),
                                                    detail: String(localized: "Files stay queued on \(name) until there is room."), state: .failed))
                }
            }
            throw StorageUnavailable(reason: error.localizedDescription)
        }
    }

    func progress(_ item: OutboxEntry, bytes: Int64) {
        guard item.gallerySource == nil else { return }
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
        if item.gallerySource != nil { return try await finishGalleryFile(item) }
        let id = entryId(item)
        closeHandle(item.id)
        lock.lock()
        let part = parts.removeValue(forKey: item.id)
        let resumed = resumedParts.remove(item.id) != nil
        reportedFull = false
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
        ReceiveHandler.saveToPhotos(target, mime: item.mime, defaults: defaults, saved: saved)
        if item.clip == true, !resumed, let content = ClipContent.of(kind: "file", text: nil, url: nil, file: target) { onClip?(content) }
    }

    private func finishGalleryFile(_ item: OutboxEntry) async throws {
        closeHandle(item.id)
        lock.lock()
        let part = parts.removeValue(forKey: item.id)
        reportedFull = false
        lock.unlock()
        guard let part = part, let month = item.galleryFolder(in: computerFolder) else { throw CocoaError(.fileNoSuchFile) }
        let fm = FileManager.default
        try fm.createDirectory(at: month, withIntermediateDirectories: true)
        let name = ReceiveHandler.unique(FileNames.clean(item.name)) { fm.fileExists(atPath: month.appendingPathComponent($0).path) }
        let target = month.appendingPathComponent(name)
        try fm.moveItem(at: part, to: target)
        if let taken = item.takenDate {
            try? fm.setAttributes([.modificationDate: taken], ofItemAtPath: target.path)
        }
        if let source = item.gallerySource { gallery.add(pcId, source) }
        let row = galleryRowId
        let pcName = self.pcName
        let first = await MainActor.run { () -> Bool in
            let first = timeline.get(row) == nil
            if first {
                timeline.add(TimelineEntry(id: row, direction: .received, kind: .gallery, pcName: pcName,
                                           title: String(localized: "Photos and videos"), state: .done))
            }
            timeline.update(row) {
                $0.count += 1
                $0.time = Date()
            }
            if (timeline.get(row)?.count ?? 0) % 20 == 0 { timeline.save() }
            return first
        }
        if first { notifier.post(pcName, String(localized: "Receiving photos and videos.")) }
        ReceiveHandler.saveToPhotos(target, mime: item.mime, taken: item.takenDate, defaults: defaults, saved: saved)
    }

    func pause(_ item: OutboxEntry) async {
        closeHandle(item.id)
        guard item.gallerySource == nil else { return }
        let id = entryId(item)
        await MainActor.run {
            timeline.update(id) { $0.state = .paused }
            timeline.save()
        }
    }

    func fail(_ item: OutboxEntry, reason: String) async {
        closeHandle(item.id)
        lock.lock()
        let part = parts.removeValue(forKey: item.id)
        lock.unlock()
        if item.gallerySource != nil, let part = part { try? FileManager.default.removeItem(at: part) }
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

    // The part files a computer left in its folder: named by an item's id, which keeps them apart from saved files.
    private static func partFiles(folder: URL, pcName: String) -> [URL] {
        let directory = folder.appendingPathComponent(FileNames.clean(pcName, fallback: "Computer"), isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".part") && isValidId(String($0.dropLast(5))) }.map { directory.appendingPathComponent($0) }
    }

    /// The computer was removed, so what it had begun is of no use.
    static func discardParts(folder: URL, pcName: String) {
        partFiles(folder: folder, pcName: pcName).forEach { try? FileManager.default.removeItem(at: $0) }
    }

    /// Parts no listed item will continue that nothing has touched for a day.
    static func removeStaleParts(folder: URL, pcName: String, keeping listed: Set<String>, now: Date = Date()) {
        for url in partFiles(folder: folder, pcName: pcName) where !listed.contains(String(url.lastPathComponent.dropLast(5))) {
            guard let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  now.timeIntervalSince(modified) > 24 * 3600 else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func saveToPhotos(_ url: URL, mime: String?, taken: Date? = nil, defaults: UserDefaults, saved: SavedAssets) {
        guard defaults.bool(forKey: Keys.photos) else { return }
        let type = UTType(filenameExtension: url.pathExtension)
        let isVideo = mime?.hasPrefix("video/") == true || type?.conforms(to: .movie) == true
        let isImage = mime?.hasPrefix("image/") == true || type?.conforms(to: .image) == true
        guard isVideo || isImage else { return }
        PHPhotoLibrary.shared().performChanges({
            let request = isVideo ? PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                                  : PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
            if let taken = taken { request?.creationDate = taken }
            if let id = request?.placeholderForCreatedAsset?.localIdentifier { saved.insert(id) }
        }, completionHandler: nil)
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

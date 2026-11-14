import Foundation
import LazySendKit

public struct GalleryFeedProgress: Equatable, Sendable {
    public var sent: Int
    public var total: Int
    public var done: Bool
}

/// Feeds a phone's photo library into a guest's outbox, a few files at a time. A file is exported and copied into
/// `outgoing` only when it is queued, and the copy goes when the guest acknowledges it. The assets a guest has
/// acknowledged are kept per guest, so a later run sends only what is new.
@MainActor
public final class GalleryFeed {
    public static let queueLimit = 20

    private struct Run: Codable, Equatable {
        var total: Int
        var base: Int
        var done = false
    }

    private struct Saved: Codable {
        var runs: [String: Run] = [:]
    }

    private let outbox: Outbox
    private let sent: GalleryIndex
    private let stateURL: URL
    private let outgoing: URL
    private let library: @Sendable () async -> [GalleryItem]
    private var runs: [String: Run]
    // What is left to queue for each running guest, last first.
    private var lists: [String: [GalleryItem]] = [:]
    private var loading: Set<String> = []
    private var filling: Set<String> = []
    private var refill: Set<String> = []
    private var staging: Set<String> = []

    public var onChange: (() -> Void)?

    /// `library` lists what the phone may send, without the assets it saved itself.
    public init(outbox: Outbox, indexDirectory: URL, stateURL: URL, outgoing: URL, library: @escaping @Sendable () async -> [GalleryItem]) {
        self.outbox = outbox
        self.stateURL = stateURL
        self.outgoing = outgoing
        self.library = library
        let sent = GalleryIndex(directory: indexDirectory)
        self.sent = sent
        runs = JsonFile.load(Saved.self, from: stateURL)?.runs ?? [:]
        // Recorded where the acknowledgement arrives, so an item the guest has is never queued again.
        outbox.onAcknowledged = { [weak self] item in
            if let id = item.sourceId, GalleryIndex.isValidSourceId(id) { sent.add(item.deviceId, id) }
            Task { @MainActor in self?.acknowledged(item) }
        }
    }

    public func progress(_ deviceId: String) -> GalleryFeedProgress? {
        guard let run = runs[deviceId] else { return nil }
        return GalleryFeedProgress(sent: max(sent.count(deviceId) - run.base, 0), total: run.total, done: run.done)
    }

    public var running: Set<String> {
        Set(runs.filter { !$0.value.done }.keys)
    }

    /// Whether `folder` in `outgoing` holds a file that is about to be queued.
    public func isStaging(_ folder: String) -> Bool {
        staging.contains(folder)
    }

    public func start(_ deviceId: String) async {
        guard runs[deviceId]?.done != false else { return }
        let todo = await candidates(for: deviceId)
        runs[deviceId] = Run(total: todo.count, base: sent.count(deviceId))
        lists[deviceId] = todo.reversed()
        save()
        await fill(deviceId)
    }

    /// Carries on the runs that were going when the app was closed, and tops the others up.
    public func resume() async {
        for deviceId in running.sorted() {
            if lists[deviceId] == nil, !loading.contains(deviceId) {
                loading.insert(deviceId)
                let todo = await candidates(for: deviceId)
                loading.remove(deviceId)
                guard runs[deviceId]?.done == false else { continue }
                lists[deviceId] = todo.reversed()
            }
            await fill(deviceId)
        }
    }

    /// Ends the run and takes back what was queued and not yet acknowledged, with its copies.
    public func stop(_ deviceId: String) {
        runs[deviceId] = nil
        lists[deviceId] = nil
        for item in outbox.removeGalleryItems(deviceId) { discardCopy(of: item) }
        save()
    }

    /// The guest is gone: its run, its queue, its copies and the list of what it has.
    public func forget(_ deviceId: String) {
        stop(deviceId)
        sent.clear(deviceId)
    }

    /// Drops what belongs to guests that are no longer paired.
    public func reconcile(paired: Set<String>) {
        for deviceId in runs.keys where !paired.contains(deviceId) { forget(deviceId) }
    }

    private func acknowledged(_ item: OutboxItem) {
        discardCopy(of: item)
        onChange?()
        if runs[item.deviceId]?.done == false { Task { await fill(item.deviceId) } }
    }

    // The assets the guest has not got yet, in the library's order.
    private func candidates(for deviceId: String) async -> [GalleryItem] {
        let all = await library().filter { GalleryIndex.isValidSourceId($0.sourceId) }
        let missing = Set(sent.missing(deviceId, all.map(\.sourceId)))
        var seen = Set<String>()
        return all.filter { missing.contains($0.sourceId) && seen.insert($0.sourceId).inserted }
    }

    private func fill(_ deviceId: String) async {
        if filling.contains(deviceId) {
            refill.insert(deviceId)
            return
        }
        filling.insert(deviceId)
        defer { filling.remove(deviceId) }
        repeat {
            refill.remove(deviceId)
            await topUp(deviceId)
        } while refill.contains(deviceId)
    }

    private func topUp(_ deviceId: String) async {
        while runs[deviceId]?.done == false, lists[deviceId] != nil {
            let waiting = outbox.pending(deviceId).filter { $0.sourceId != nil }
            if waiting.count >= Self.queueLimit { return }
            guard let item = lists[deviceId]?.popLast() else {
                if waiting.isEmpty { finish(deviceId) }
                return
            }
            if sent.contains(deviceId, item.sourceId) || waiting.contains(where: { $0.sourceId == item.sourceId }) { continue }
            await queue(item, for: deviceId)
        }
    }

    private func queue(_ item: GalleryItem, for deviceId: String) async {
        // An asset that cannot be read is left out of this run.
        guard let exported = try? await item.export() else { return }
        defer { exported.cleanup() }
        guard runs[deviceId]?.done == false else { return }
        let folder = UUID().uuidString
        let directory = outgoing.appendingPathComponent(folder, isDirectory: true)
        let file = directory.appendingPathComponent(Self.safeName(item.name))
        staging.insert(folder)
        defer { staging.remove(folder) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            do {
                try FileManager.default.moveItem(at: exported.url, to: file)
            } catch {
                try FileManager.default.copyItem(at: exported.url, to: file)
            }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            return
        }
        if outbox.queueGalleryFile(deviceId, url: file, mime: item.mime, sourceId: item.sourceId, taken: item.modified) == nil {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func finish(_ deviceId: String) {
        runs[deviceId]?.done = true
        lists[deviceId] = nil
        save()
    }

    private func discardCopy(of item: OutboxItem) {
        guard let path = item.path else { return }
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
        try? FileManager.default.removeItem(at: outgoing.appendingPathComponent(folder, isDirectory: true))
    }

    private func save() {
        JsonFile.save(Saved(runs: runs), to: stateURL)
        onChange?()
    }

    private static func safeName(_ name: String) -> String {
        let clean = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return clean.isEmpty || clean == "." || clean == ".." ? "file" : clean
    }
}

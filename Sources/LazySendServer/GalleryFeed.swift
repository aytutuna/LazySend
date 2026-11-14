import Foundation
import LazySendKit

/// Why a running feed is not queuing anything for now.
public enum GalleryFeedWait: Equatable, Sendable {
    case storage
    /// The guest has as many items waiting as the outbox holds.
    case outbox
    /// The phone no longer lets the app read its photos.
    case photos
}

public struct GalleryFeedProgress: Equatable, Sendable {
    public var sent: Int
    public var total: Int
    public var done: Bool
    /// Assets that could not be read, also after a second try.
    public var failed = 0
    public var wait: GalleryFeedWait?
}

/// Feeds a phone's photo library into a guest's outbox, a few files at a time. A file is exported and copied into
/// `outgoing` only when it is queued, and the copy goes when the guest acknowledges it. The assets a guest has
/// acknowledged are kept per guest, so a later run sends only what is new.
@MainActor
public final class GalleryFeed {
    public static let queueLimit = 20
    /// About this many bytes of copies wait at a time; one item always may, however large.
    public static let queueBytes: Int64 = 1024 * 1024 * 1024

    private struct Run: Codable, Equatable {
        var total: Int
        var base: Int
        var done = false
        var failed = 0
    }

    private struct Saved: Codable {
        var runs: [String: Run] = [:]
    }

    private let outbox: Outbox
    private let sent: GalleryIndex
    private let stateURL: URL
    private let outgoing: URL
    private let library: @Sendable () async -> [GalleryItem]
    private let freeSpace: () -> Int64
    private let retryDelay: TimeInterval
    private let queueBytes: Int64
    private var runs: [String: Run]
    // What is left to queue for each running guest, last first.
    private var lists: [String: [GalleryItem]] = [:]
    // Assets that failed once, tried again when the list is used up, and the ids already tried twice.
    private var later: [String: [GalleryItem]] = [:]
    private var retried: [String: Set<String>] = [:]
    private var waits: [String: GalleryFeedWait] = [:]
    private var photosDenied = false
    private var loading: Set<String> = []
    // Guests whose run is being set up: the library is read before the run exists.
    private var starting: Set<String> = []
    private var filling: Set<String> = []
    private var refill: Set<String> = []
    private var staging: Set<String> = []

    public var onChange: (@MainActor () -> Void)?

    /// `library` lists what the phone may send, without the assets it saved itself.
    public init(outbox: Outbox, indexDirectory: URL, stateURL: URL, outgoing: URL, retryDelay: TimeInterval = 30,
                queueBytes: Int64 = GalleryFeed.queueBytes, freeSpace: (() -> Int64)? = nil, library: @escaping @Sendable () async -> [GalleryItem]) {
        self.outbox = outbox
        self.retryDelay = retryDelay
        self.queueBytes = queueBytes
        self.freeSpace = freeSpace ?? { Inbox.volumeFreeBytes(outgoing) }
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
        let count = max(sent.count(deviceId) - run.base, 0)
        return GalleryFeedProgress(sent: count, total: max(run.total, count + run.failed), done: run.done, failed: run.failed,
                                   wait: run.done ? nil : (photosDenied ? .photos : waits[deviceId]))
    }

    public var running: Set<String> {
        Set(runs.filter { !$0.value.done }.keys)
    }

    /// Whether `folder` in `outgoing` holds a file that is about to be queued.
    public func isStaging(_ folder: String) -> Bool {
        staging.contains(folder)
    }

    public func start(_ deviceId: String) async {
        guard runs[deviceId]?.done != false, starting.insert(deviceId).inserted else { return }
        let todo = await candidates(for: deviceId)
        // Removing the guest while the library was being read cancels the start.
        guard starting.remove(deviceId) != nil else { return }
        runs[deviceId] = Run(total: todo.count, base: sent.count(deviceId))
        lists[deviceId] = todo.reversed()
        save()
        await fill(deviceId)
    }

    /// Tells the feed whether the app may read the photo library; while it may not, running feeds are paused.
    public func setPhotosAllowed(_ allowed: Bool) {
        guard photosDenied == allowed else { return }
        photosDenied = !allowed
        onChange?()
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
        starting.remove(deviceId)
        runs[deviceId] = nil
        lists[deviceId] = nil
        later[deviceId] = nil
        retried[deviceId] = nil
        waits[deviceId] = nil
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
        for deviceId in Set(runs.keys).union(starting) where !paired.contains(deviceId) { forget(deviceId) }
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
            if await !topUp(deviceId) {
                try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                refill.insert(deviceId)
            }
        } while refill.contains(deviceId) && runs[deviceId]?.done == false
    }

    /// False when the phone is too full to export the next asset and the try has to be repeated later.
    private func topUp(_ deviceId: String) async -> Bool {
        while runs[deviceId]?.done == false, lists[deviceId] != nil, !photosDenied {
            let waiting = outbox.pending(deviceId).filter { $0.sourceId != nil }
            if waiting.count >= Self.queueLimit { return true }
            guard let item = lists[deviceId]?.last else {
                if let again = later[deviceId], !again.isEmpty {
                    lists[deviceId] = again.reversed()
                    later[deviceId] = nil
                    continue
                }
                if waiting.isEmpty { finish(deviceId) }
                return true
            }
            if sent.contains(deviceId, item.sourceId) || waiting.contains(where: { $0.sourceId == item.sourceId }) {
                lists[deviceId]?.removeLast()
                continue
            }
            if outbox.pending(deviceId).count >= Limits.maxOutboxItemsPerDevice {
                setWait(.outbox, for: deviceId)
                return true
            }
            let queuedBytes = waiting.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
            if !waiting.isEmpty, queuedBytes + item.sizeHint > queueBytes { return true }
            if freeSpace() - item.sizeHint < Limits.minFree {
                setWait(.storage, for: deviceId)
                return false
            }
            setWait(nil, for: deviceId)
            lists[deviceId]?.removeLast()
            await queue(item, for: deviceId)
        }
        return true
    }

    private func setWait(_ wait: GalleryFeedWait?, for deviceId: String) {
        guard waits[deviceId] != wait else { return }
        waits[deviceId] = wait
        onChange?()
    }

    // An asset that cannot be read is tried once more after the others, then counted as not sent.
    private func failed(_ item: GalleryItem, for deviceId: String) {
        guard runs[deviceId]?.done == false else { return }
        if retried[deviceId, default: []].insert(item.sourceId).inserted {
            later[deviceId, default: []].append(item)
        } else {
            runs[deviceId]?.failed += 1
            save()
        }
    }

    private func queue(_ item: GalleryItem, for deviceId: String) async {
        guard let exported = try? await item.export() else {
            failed(item, for: deviceId)
            return
        }
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
        do {
            if try outbox.queueGalleryFile(deviceId, url: file, mime: item.mime, sourceId: item.sourceId, taken: item.modified) == nil {
                try? FileManager.default.removeItem(at: directory)
            }
        } catch {
            // Someone else filled the outbox meanwhile: the asset waits for the next acknowledgement.
            try? FileManager.default.removeItem(at: directory)
            lists[deviceId]?.append(item)
            setWait(.outbox, for: deviceId)
        }
    }

    private func finish(_ deviceId: String) {
        runs[deviceId]?.done = true
        lists[deviceId] = nil
        later[deviceId] = nil
        retried[deviceId] = nil
        waits[deviceId] = nil
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

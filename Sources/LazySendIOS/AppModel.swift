#if os(iOS)
import BackgroundTasks
import Foundation
import LazySendKit
import Photos
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private final class ProgressWire: @unchecked Sendable {
    private let lock = NSLock()
    private var acked: Int64 = 0
    private var inflight: Int64 = 0
    private var last = Date.distantPast

    func acknowledged(_ offset: Int64) -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        acked = offset
        inflight = 0
        return due()
    }

    func sent(_ bytes: Int64) -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        inflight = bytes
        return due()
    }

    // At most four reports a second.
    private func due() -> Int64? {
        let now = Date()
        if now.timeIntervalSince(last) < 0.25 { return nil }
        last = now
        return acked + inflight
    }
}

private struct Job {
    let entryId: String
    let work: @MainActor () async -> Void
}

private enum Sent {
    case done
    /// Not delivered and worth another try later.
    case waiting
    case failed
}

/// Why the photo library may not give the gallery sync everything.
enum PhotoNotice: Equatable {
    case limited
    case denied
}

@MainActor
final class AppModel: ObservableObject {
    let env: AppEnvironment
    let store: PcStore
    let connector: PcConnector
    let timeline: Timeline
    let queue: ShareQueue

    @Published private(set) var pcs: [PairedPc] = []
    @Published private(set) var selectedId: String?
    @Published private(set) var links: [String: LinkKind] = [:]
    @Published private(set) var savesToPhotos: Bool
    @Published private(set) var photoNotice: PhotoNotice?
    @Published private(set) var galleryRunning = false

    private var galleryTask: Task<Void, Never>?
    private var galleryRun = 0
    private var gallerySaved = 0
    private var watchers: [String: Task<Void, Never>] = [:]
    private var collectors: [String: OutboxCollector] = [:]
    private var jobs: [Job] = []
    private var pump: Task<Void, Never>?
    private var current: String?
    private var queued: Set<String> = []
    private var resuming: Set<String> = []
    private var held: Set<String> = []
    private var grace = UIBackgroundTaskIdentifier.invalid
    private let saved: SavedAssets

    init(env: AppEnvironment) {
        self.env = env
        store = PcStore(file: env.folder.appendingPathComponent("pcs.json"), secrets: env.secrets)
        connector = PcConnector(store: store, discovery: env.discovery)
        timeline = Timeline(file: env.support.appendingPathComponent("timeline.json"))
        queue = ShareQueue(root: env.folder)
        saved = SavedAssets(file: env.support.appendingPathComponent("saved-assets.json"))
        savesToPhotos = env.defaults.bool(forKey: Keys.photos)
        if env.demo { seedDemo() }
        removeStrayCopies()
        refreshPcs()
    }

    // Where a file being sent is kept until it is delivered. Application Support, not tmp, which the system may empty.
    private var outgoing: URL {
        env.support.appendingPathComponent("Outgoing", isDirectory: true)
    }

    private func removeStrayCopies() {
        let fm = FileManager.default
        let wanted = Set(timeline.entries.filter { $0.state != .done }.compactMap(\.localFile).map { ($0 as NSString).deletingLastPathComponent })
        let folders = (try? fm.contentsOfDirectory(at: outgoing, includingPropertiesForKeys: nil)) ?? []
        for folder in folders where !wanted.contains(folder.lastPathComponent) {
            try? fm.removeItem(at: folder)
        }
    }

    var selected: PairedPc? {
        pcs.first { $0.id == selectedId }
    }

    func documentURL(_ name: String) -> URL {
        env.documents.appendingPathComponent(name)
    }

    func refreshPcs() {
        pcs = store.pcs
        let saved = selectedId ?? env.defaults.string(forKey: Keys.selected)
        selectedId = pcs.contains { $0.id == saved } ? saved : pcs.first?.id
    }

    func select(_ id: String) {
        selectedId = id
        env.defaults.set(id, forKey: Keys.selected)
    }

    func sceneChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            start()
        case .background:
            stopWatching()
            scheduleCheck()
        default:
            break
        }
    }

    func start() {
        refreshPcs()
        for pc in pcs where watchers[pc.id] == nil {
            let id = pc.id
            watchers[id] = Task { await self.watch(id) }
        }
        drainShareQueue()
        resumeSends()
        resumeGallery()
    }

    func stopWatching() {
        for task in watchers.values { task.cancel() }
        watchers = [:]
    }

    private func watch(_ id: String) async {
        while !Task.isCancelled {
            let reached: Reached?
            do {
                reached = try await connector.awaitReachable(id)
            } catch {
                return
            }
            guard let reached = reached else {
                lostPc(id)
                return
            }
            links[id] = reached.link
            guard let collector = outboxCollector(for: id) else { return }
            do {
                while true {
                    _ = try await collector.collect(api: reached.client, wait: LinkProtocol.maxOutboxWait)
                }
            } catch is CancellationError {
                return
            } catch {
                if (error as? LinkError)?.status == 401 {
                    lostPc(id)
                    return
                }
                links[id] = nil
                try? await Task.sleep(nanoseconds: UInt64(Double.random(in: 2...5) * 1_000_000_000))
            }
        }
    }

    private func outboxCollector(for id: String) -> OutboxCollector? {
        if let existing = collectors[id] { return existing }
        guard let pc = store.get(id) else { return nil }
        let handler = ReceiveHandler(pcName: pc.name, timeline: timeline, folder: env.documents, notifier: env.notifier, defaults: env.defaults, saved: saved)
        let made = OutboxCollector(handler: handler)
        collectors[id] = made
        return made
    }

    /// The computer no longer knows this phone, so the pairing is dropped here too.
    private func lostPc(_ id: String) {
        guard let pc = store.get(id) else { return }
        store.remove(id)
        collectors[id] = nil
        links[id] = nil
        timeline.add(TimelineEntry(id: "notice-" + UUID().uuidString, direction: .received, kind: .text, pcName: pc.name,
                                   title: String(localized: "\(pc.name) no longer knows this phone. It was removed here."), state: .done))
        refreshPcs()
    }

    func pair(_ code: PairingCode) async throws -> PairedPc {
        let pc = try await Pairing.pair(code, phoneName: env.phoneName, appVersion: env.appVersion, connector: connector, store: store)
        refreshPcs()
        select(pc.id)
        env.notifier.ask()
        start()
        return pc
    }

    func remove(_ pc: PairedPc) async {
        watchers[pc.id]?.cancel()
        watchers[pc.id] = nil
        if let reached = await connector.connect(pc, search: false).reached {
            try? await reached.client.forgetSelf()
        }
        store.remove(pc.id)
        collectors[pc.id] = nil
        links[pc.id] = nil
        refreshPcs()
    }

    func setSavesToPhotos(_ on: Bool) {
        guard on else {
            savesToPhotos = false
            env.defaults.set(false, forKey: Keys.photos)
            return
        }
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            let allowed = status == .authorized || status == .limited
            self.savesToPhotos = allowed
            self.env.defaults.set(allowed, forKey: Keys.photos)
        }
    }


    func sendNote(_ text: String, to pc: PairedPc) throws {
        let request = try ItemRequest.note(text)
        drainShareQueue()
        let id = "out-" + UUID().uuidString
        timeline.add(TimelineEntry(id: id, direction: .sent, kind: request.kind == "link" ? .link : .text, pcName: pc.name,
                                   title: request.url ?? request.text ?? ""))
        enqueue(id) { _ = await self.post(request, to: pc, entryId: id) }
    }

    /// `scoped` is for URLs from the document picker, which are copied first; picked photos are temp files already.
    func sendFiles(_ urls: [URL], to pc: PairedPc, scoped: Bool = false) {
        drainShareQueue()
        for url in urls {
            let id = "out-" + UUID().uuidString
            timeline.add(TimelineEntry(id: id, direction: .sent, kind: .file, pcName: pc.name, title: url.lastPathComponent, pcId: pc.id))
            enqueue(id) { await self.deliverFile(url, scoped: scoped, to: pc, entryId: id) }
        }
    }

    func resumeSend(_ entryId: String) {
        held.remove(entryId)
        guard let entry = timeline.get(entryId), entry.direction == .sent, entry.kind == .file, !resuming.contains(entryId),
              entry.state == .paused || entry.state == .failed, let local = entry.localFile else { return }
        let file = outgoing.appendingPathComponent(local)
        guard FileManager.default.fileExists(atPath: file.path) else {
            discardStaged(entryId)
            finish(entryId, .failed, String(localized: "The file is no longer available."))
            return
        }
        guard let pc = entry.pcId.flatMap({ store.get($0) }) else {
            discardStaged(entryId)
            finish(entryId, .failed, String(localized: "\(entry.pcName) was removed."))
            return
        }
        resuming.insert(entryId)
        timeline.update(entryId) {
            $0.state = .active
            $0.detail = ""
        }
        let itemId = entry.itemId
        enqueue(entryId) {
            await self.sendStaged(file, to: pc, entryId: entryId, resumeItemId: itemId)
            self.resuming.remove(entryId)
        }
    }

    private func resumeSends() {
        for entry in timeline.entries where entry.direction == .sent && entry.kind == .file && entry.state == .paused
            && entry.localFile != nil && !held.contains(entry.id) {
            resumeSend(entry.id)
        }
    }

    func resumeGallerySync(_ entry: TimelineEntry) {
        guard entry.kind == .gallery, let pc = store.get(String(entry.id.dropFirst(TimelineEntry.galleryPrefix.count))) else { return }
        startGallerySync(for: pc)
    }

    func startGallerySync(for pc: PairedPc) {
        guard galleryTask == nil else { return }
        galleryRunning = true
        env.defaults.set(true, forKey: Keys.galleryPending)
        beginGrace()
        galleryTask = Task { await self.runGallery(pc) }
    }

    func stopGallery() {
        env.defaults.set(false, forKey: Keys.galleryPending)
        galleryTask?.cancel()
    }

    /// For the system ending a background task: the sync pauses and carries on when the app is opened again.
    func pauseGallery() {
        galleryTask?.cancel()
    }

    func waitForGallery() async {
        await galleryTask?.value
    }

    private func resumeGallery() {
        guard galleryTask == nil, let id = galleryToResume(timeline.entries, pending: env.defaults.bool(forKey: Keys.galleryPending)) else { return }
        guard let pc = store.get(id) else {
            env.defaults.set(false, forKey: Keys.galleryPending)
            return
        }
        startGallerySync(for: pc)
    }

    private func runGallery(_ pc: PairedPc) async {
        let id = TimelineEntry.galleryId(pc.id)
        galleryRun += 1
        let run = galleryRun
        gallerySaved = 0
        defer {
            galleryTask = nil
            galleryRunning = false
            if env.background { UIApplication.shared.isIdleTimerDisabled = false }
            endGrace()
        }
        switch await env.photos.access() {
        case .denied:
            photoNotice = .denied
            env.defaults.set(false, forKey: Keys.galleryPending)
            if timeline.get(id)?.state == .paused { finish(id, .failed, String(localized: "Photos are not allowed.")) }
            return
        case .limited:
            photoNotice = .limited
        case .allowed:
            photoNotice = nil
        }
        if env.background { UIApplication.shared.isIdleTimerDisabled = true }
        let previous = timeline.get(id)
        timeline.add(TimelineEntry(id: id, direction: .sent, kind: .gallery, pcName: pc.name, title: String(localized: "Photos and videos"),
                                   detail: String(localized: "Looking for what is new"), state: .active,
                                   count: previous?.count ?? 0, totalCount: previous?.totalCount ?? 0))
        BackgroundGallery.request(title: String(localized: "Sending photos and videos"), subtitle: pc.name)
        let items = await env.photos.items(saved.all)
        let connector = self.connector
        let sync = GallerySync(
            items: items,
            awaitReachable: { [weak self] in
                guard let reached = try await connector.awaitReachable(pc.id) else { return nil }
                await self?.noteLink(reached.link, for: pc.id)
                return reached.client
            },
            reconnect: {
                guard let again = await connector.connect(pc, search: false).reached else {
                    throw LinkError.network(String(localized: "\(pc.name) is not reachable"))
                }
                return again.client
            },
            report: { [weak self] progress in
                Task { @MainActor in self?.galleryProgress(progress, run: run, pc: pc) }
            })
        do {
            let result = try await sync.run()
            if result == .forgotten { lostPc(pc.id) }
            timeline.update(id) { $0.finish(result, pcName: pc.name) }
            timeline.save()
            env.defaults.set(false, forKey: Keys.galleryPending)
            if case .finished = result {
                BackgroundGallery.finish(success: true)
            } else {
                BackgroundGallery.finish(success: false)
            }
        } catch {
            if error is CancellationError || Task.isCancelled {
                finish(id, .paused)
            } else {
                env.defaults.set(false, forKey: Keys.galleryPending)
                finish(id, .failed, error.localizedDescription)
            }
            BackgroundGallery.finish(success: false)
        }
    }

    private func noteLink(_ link: LinkKind, for pcId: String) {
        links[pcId] = link
    }

    private func galleryProgress(_ progress: GalleryProgress, run: Int, pc: PairedPc) {
        guard run == galleryRun, galleryTask != nil else { return }
        let link = links[pc.id]
        timeline.update(TimelineEntry.galleryId(pc.id)) { $0.apply(progress, pcName: pc.name, link: link) }
        if progress.count != gallerySaved, progress.count % 20 == 0 {
            gallerySaved = progress.count
            timeline.save()
        }
        if let entry = timeline.get(TimelineEntry.galleryId(pc.id)) {
            BackgroundGallery.update(title: String(localized: "Sending photos and videos"), subtitle: entry.progressLine,
                                     completed: progress.bytes, total: progress.totalBytes)
        }
    }

    func stopSending() {
        held.formUnion(jobs.map(\.entryId))
        if let current = current { held.insert(current) }
        pump?.cancel()
    }

    func waitForSends() async {
        await pump?.value
    }

    private func enqueue(_ entryId: String, _ work: @escaping @MainActor () async -> Void) {
        jobs.append(Job(entryId: entryId, work: work))
        guard pump == nil else { return }
        beginGrace()
        pump = Task {
            while !self.jobs.isEmpty {
                let job = self.jobs.removeFirst()
                if Task.isCancelled {
                    self.finish(job.entryId, .paused)
                    self.resuming.remove(job.entryId)
                    // A share left unsent is picked up again by the next drain, not only after a relaunch.
                    if job.entryId.hasPrefix("share-") { self.queued.remove(String(job.entryId.dropFirst("share-".count))) }
                } else {
                    self.current = job.entryId
                    await job.work()
                    self.current = nil
                }
            }
            self.pump = nil
            self.endGrace()
        }
    }

    // The grace period after leaving the app is a few seconds, enough to finish a small item; a big one pauses
    // when it runs out, keeps its copy and the computer's id for it, and carries on from the computer's offset.
    private func beginGrace() {
        guard env.background, grace == .invalid else { return }
        grace = UIApplication.shared.beginBackgroundTask(withName: "send") { [weak self] in
            MainActor.assumeIsolated {
                self?.pump?.cancel()
                // A continued processing task is given its own time, so the gallery only stops with that one.
                if !BackgroundGallery.isRunning { self?.galleryTask?.cancel() }
                self?.endGrace(force: true)
            }
        }
    }

    // Shared by the send queue and the gallery sync: it ends when both are done, or when the system says time is up.
    private func endGrace(force: Bool = false) {
        guard grace != .invalid, force || (pump == nil && galleryTask == nil) else { return }
        UIApplication.shared.endBackgroundTask(grace)
        grace = .invalid
    }

    private func finish(_ id: String, _ state: EntryState, _ detail: String = "") {
        timeline.update(id) {
            $0.state = state
            $0.detail = detail
        }
        timeline.save()
    }

    private func setBytes(_ id: String, _ bytes: Int64) {
        timeline.update(id) { $0.bytes = bytes }
    }

    private func reach(_ pc: PairedPc, entryId: String) async -> Reached? {
        switch await connector.connect(pc, userAction: true) {
        case .reached(let reached):
            links[pc.id] = reached.link
            return reached
        case .unreachable:
            finish(entryId, .failed, String(localized: "\(pc.name) is not reachable"))
        case .forgotten:
            lostPc(pc.id)
            finish(entryId, .failed, String(localized: "\(pc.name) no longer knows this phone."))
        }
        return nil
    }

    private func missed(_ pc: PairedPc) -> Sent {
        store.get(pc.id) == nil ? .failed : .waiting
    }

    private func post(_ request: ItemRequest, to pc: PairedPc, entryId: String) async -> Sent {
        guard let reached = await reach(pc, entryId: entryId) else { return missed(pc) }
        do {
            _ = try await reached.client.postItem(request)
            finish(entryId, .done)
            return .done
        } catch is CancellationError {
            finish(entryId, .paused)
            return .waiting
        } catch {
            return failed(error, pc: pc, entryId: entryId)
        }
    }

    private func failed(_ error: Error, pc: PairedPc, entryId: String) -> Sent {
        finish(entryId, .failed, error.localizedDescription)
        guard let link = error as? LinkError else { return .failed }
        if link.status == 401 {
            lostPc(pc.id)
            return .failed
        }
        return link.isTransient ? .waiting : .failed
    }

    private func deliverFile(_ url: URL, scoped: Bool, to pc: PairedPc, entryId: String) async {
        let folder = outgoing.appendingPathComponent(entryId, isDirectory: true)
        let file: URL
        do {
            file = try await Task.detached { try AppModel.stage(url, scoped: scoped, into: folder) }.value
        } catch {
            finish(entryId, .failed, error.localizedDescription)
            return
        }
        timeline.update(entryId) { $0.localFile = entryId + "/" + file.lastPathComponent }
        timeline.save()
        await sendStaged(file, to: pc, entryId: entryId, resumeItemId: nil)
    }

    // A picked file is ours already and is moved; one from the document picker is copied while access to it lasts.
    nonisolated private static func stage(_ url: URL, scoped: Bool, into folder: URL) throws -> URL {
        let fm = FileManager.default
        let target = folder.appendingPathComponent(url.lastPathComponent)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            if scoped {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                try fm.copyItem(at: url, to: target)
            } else {
                try fm.moveItem(at: url, to: target)
                try? fm.removeItem(at: url.deletingLastPathComponent())
            }
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
        return target
    }

    private func sendStaged(_ file: URL, to pc: PairedPc, entryId: String, resumeItemId: String?) async {
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let outcome = await upload(file, name: file.lastPathComponent, mime: mime, modified: modified, to: pc, entryId: entryId,
                                   resumeItemId: resumeItemId) { [weak self] id in
            self?.timeline.update(entryId) { $0.itemId = id }
            self?.timeline.save()
        }
        if outcome != .waiting { discardStaged(entryId) }
    }

    private func discardStaged(_ entryId: String) {
        try? FileManager.default.removeItem(at: outgoing.appendingPathComponent(entryId, isDirectory: true))
        timeline.update(entryId) {
            $0.localFile = nil
            $0.itemId = nil
        }
        timeline.save()
    }

    // `remember` gets the computer's id for the file as soon as it is known, so a later run can carry on with it.
    private func upload(_ file: URL, name: String, mime: String?, modified: Date?, to pc: PairedPc, entryId: String,
                        resumeItemId: String? = nil, remember: @escaping @MainActor (String) -> Void) async -> Sent {
        let request: ItemRequest
        do {
            request = try await Task.detached { try ItemRequest.file(at: file, name: name, mime: mime, modified: modified) }.value
        } catch {
            finish(entryId, .failed, error.localizedDescription)
            return .failed
        }
        timeline.update(entryId) { $0.totalBytes = request.size ?? 0 }
        guard let first = await reach(pc, entryId: entryId) else { return missed(pc) }
        let connector = self.connector
        var used = false
        let uploader = Uploader(resumeItemId: resumeItemId) { () async throws -> UploadAPI in
            if !used {
                used = true
                return first.client
            }
            guard let again = await connector.connect(pc, search: false).reached else {
                throw LinkError.network(String(localized: "\(pc.name) is not reachable"))
            }
            return again.client
        }
        let wire = ProgressWire()
        let show: @Sendable (Int64) -> Void = { [weak self] bytes in
            Task { @MainActor in self?.setBytes(entryId, bytes) }
        }
        do {
            let result = try await uploader.send(request, source: FileDataSource(url: file), onItem: { id in
                Task { @MainActor in remember(id) }
            }, onProgress: { offset in
                if let total = wire.acknowledged(offset) { show(total) }
            }, onBytes: { sent in
                if let total = wire.sent(sent) { show(total) }
            })
            let detail = result.duplicate ? String(localized: "Already on the PC") : ""
            timeline.update(entryId) {
                $0.bytes = $0.totalBytes
                $0.state = .done
                $0.detail = detail
                $0.itemId = nil
            }
            timeline.save()
            return .done
        } catch is CancellationError {
            finish(entryId, .paused)
            return .waiting
        } catch {
            return failed(error, pc: pc, entryId: entryId)
        }
    }

    func drainShareQueue() {
        for item in queue.items() where !queued.contains(item.id) {
            guard let pc = store.get(item.pcId) else {
                queue.remove(item.id)
                continue
            }
            queued.insert(item.id)
            let id = "share-" + item.id
            let kind: EntryKind = item.kind == "file" ? .file : (item.kind == "link" ? .link : .text)
            timeline.add(TimelineEntry(id: id, direction: .sent, kind: kind, pcName: pc.name, title: item.url ?? item.text ?? item.name ?? ""))
            enqueue(id) { await self.deliver(item, to: pc, entryId: id) }
        }
    }

    private func deliver(_ item: QueuedItem, to pc: PairedPc, entryId: String) async {
        let outcome: Sent
        if item.kind == "file" {
            let queue = self.queue
            outcome = await upload(queue.dataURL(item.id), name: item.name ?? "file", mime: item.mime, modified: item.modified, to: pc,
                                   entryId: entryId, resumeItemId: item.itemId) { id in
                queue.update(item.id) { $0.itemId = id }
            }
        } else {
            outcome = await post(ItemRequest(kind: item.kind, text: item.text, url: item.url), to: pc, entryId: entryId)
        }
        queued.remove(item.id)
        if outcome != .waiting { queue.remove(item.id) }
    }


    func scheduleCheck() {
        guard env.background else { return }
        let request = BGAppRefreshTaskRequest(identifier: Keys.check)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    func check() async {
        scheduleCheck()
        for pc in store.pcs {
            guard let reached = await connector.connect(pc, search: false).reached, let collector = outboxCollector(for: pc.id) else { continue }
            _ = try? await collector.collect(api: reached.client, wait: 0)
        }
    }


    private func seedDemo() {
        let pc = PairedPc(id: "demo-office-pc", name: "Office PC", fingerprint: Base64Url.encode(Data(repeating: 7, count: 32)),
                          addresses: [], port: LinkProtocol.defaultPort)
        try? store.put(pc, secret: "demo")
        let now = Date()
        let entries = [
            TimelineEntry(id: "demo-1", time: now.addingTimeInterval(-18000), direction: .sent, kind: .text, pcName: pc.name,
                          title: "Book the meeting room for Thursday", state: .done),
            TimelineEntry(id: "demo-2", time: now.addingTimeInterval(-14400), direction: .sent, kind: .link, pcName: pc.name,
                          title: "https://alazy.app/send/", state: .done),
            TimelineEntry(id: "demo-3", time: now.addingTimeInterval(-10800), direction: .received, kind: .file, pcName: pc.name,
                          title: "Quarterly report.pdf", state: .done, bytes: 2_400_000, totalBytes: 2_400_000,
                          fileName: "Quarterly report.pdf", mime: "application/pdf"),
            TimelineEntry(id: "demo-4", time: now.addingTimeInterval(-7200), direction: .sent, kind: .file, pcName: pc.name,
                          title: "Holiday video.mp4", detail: "Office PC is not reachable", state: .failed, totalBytes: 183_000_000),
            TimelineEntry(id: "demo-5", time: now.addingTimeInterval(-1800), direction: .received, kind: .text, pcName: pc.name,
                          title: "The door code is 4821", state: .done),
            TimelineEntry(id: "demo-6", time: now.addingTimeInterval(-600), direction: .sent, kind: .gallery, pcName: pc.name,
                          title: String(localized: "Photos and videos"), detail: LinkKind.wifi.label, state: .active, bytes: 1_300_000_000,
                          totalBytes: 3_900_000_000, count: 128, totalCount: 412),
        ]
        for entry in entries { timeline.add(entry) }
    }
}
#endif

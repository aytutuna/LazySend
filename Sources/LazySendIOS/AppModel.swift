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
    @Published var galleryMessage: String?

    private var watchers: [String: Task<Void, Never>] = [:]
    private var collectors: [String: OutboxCollector] = [:]
    private var jobs: [Job] = []
    private var pump: Task<Void, Never>?
    private var queued: Set<String> = []
    private var grace = UIBackgroundTaskIdentifier.invalid

    init(env: AppEnvironment) {
        self.env = env
        store = PcStore(file: env.folder.appendingPathComponent("pcs.json"), secrets: env.secrets)
        connector = PcConnector(store: store, discovery: env.discovery)
        timeline = Timeline(file: env.support.appendingPathComponent("timeline.json"))
        queue = ShareQueue(root: env.folder)
        savesToPhotos = env.defaults.bool(forKey: Keys.photos)
        if env.demo { seedDemo() }
        refreshPcs()
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
        let handler = ReceiveHandler(pcName: pc.name, timeline: timeline, folder: env.documents, notifier: env.notifier, defaults: env.defaults)
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
        let id = "out-" + UUID().uuidString
        timeline.add(TimelineEntry(id: id, direction: .sent, kind: request.kind == "link" ? .link : .text, pcName: pc.name,
                                   title: request.url ?? request.text ?? ""))
        enqueue(id) { _ = await self.post(request, to: pc, entryId: id) }
    }

    /// `scoped` is for URLs from the document picker, which are copied first; picked photos are temp files already.
    func sendFiles(_ urls: [URL], to pc: PairedPc, scoped: Bool = false) {
        for url in urls {
            let id = "out-" + UUID().uuidString
            timeline.add(TimelineEntry(id: id, direction: .sent, kind: .file, pcName: pc.name, title: url.lastPathComponent))
            enqueue(id) { await self.deliverFile(url, scoped: scoped, to: pc, entryId: id) }
        }
    }

    func startGallerySync(for pc: PairedPc) {
        galleryMessage = String(localized: "Sending a whole gallery is not available yet.")
    }

    func stopSending() {
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
                } else {
                    await job.work()
                }
            }
            self.pump = nil
            self.endGrace()
        }
    }

    // The grace period after leaving the app is a few seconds, enough to finish a small item; a big one pauses
    // when it runs out and carries on from its offset next time.
    private func beginGrace() {
        guard env.background, grace == .invalid else { return }
        grace = UIApplication.shared.beginBackgroundTask(withName: "send") { [weak self] in
            MainActor.assumeIsolated {
                self?.pump?.cancel()
                self?.endGrace()
            }
        }
    }

    private func endGrace() {
        guard grace != .invalid else { return }
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
        let file: URL
        if scoped {
            do {
                file = try await Task.detached { try AppModel.copyToTemp(url) }.value
            } catch {
                finish(entryId, .failed, error.localizedDescription)
                return
            }
        } else {
            file = url
        }
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        _ = await upload(file, name: url.lastPathComponent, mime: mime, modified: modified, to: pc, entryId: entryId)
    }

    nonisolated private static func copyToTemp(_ url: URL) throws -> URL {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lazysend-send-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: copy)
        return copy
    }

    private func upload(_ file: URL, name: String, mime: String?, modified: Date?, to pc: PairedPc, entryId: String) async -> Sent {
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
        let uploader = Uploader { () async throws -> UploadAPI in
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
            let result = try await uploader.send(request, source: FileDataSource(url: file), onProgress: { offset in
                if let total = wire.acknowledged(offset) { show(total) }
            }, onBytes: { sent in
                if let total = wire.sent(sent) { show(total) }
            })
            let detail = result.duplicate ? String(localized: "Already on the PC") : ""
            timeline.update(entryId) {
                $0.bytes = $0.totalBytes
                $0.state = .done
                $0.detail = detail
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
            outcome = await upload(queue.dataURL(item.id), name: item.name ?? "file", mime: item.mime, modified: item.modified, to: pc, entryId: entryId)
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
                          title: String(localized: "Photos and videos"), state: .active, bytes: 1_300_000_000,
                          totalBytes: 3_900_000_000, count: 128, totalCount: 412),
        ]
        for entry in entries { timeline.add(entry) }
    }
}
#endif

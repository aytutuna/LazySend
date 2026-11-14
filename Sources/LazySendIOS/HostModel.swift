#if os(iOS)
import Foundation
import LazySendKit
import LazySendServer
import UniformTypeIdentifiers

struct HostPairing: Equatable {
    var link: String
    /// What a guest that cannot scan types, `XXXX-XXXX`, and the digits it shows next to it.
    var shortCode: String
    var match: String
    var check: String
    var expires: Date
    var pairedName: String?
    /// Used up, expired or closed.
    var finished = false
}

struct HostApproval: Equatable {
    var name: String
    var platform: String
    /// The digits the other phone shows too.
    var match: String
}

enum HostSendError: Error, LocalizedError, Equatable {
    case notPaired
    case tooMany(String)

    var errorDescription: String? {
        switch self {
        case .notPaired: return String(localized: "That phone is no longer paired.")
        case .tooMany(let name): return String(localized: "Too many items are waiting for \(name). Wait until it picks some up.")
        }
    }
}

/// The phone as a host: the server of `LazySendServer` while the app is in front, the phones paired with it, what
/// they send and what waits for them. A phone that is a host and also a guest of the same device keeps two
/// separate lists, the guest's in `PcStore` and this one in the group container.
@MainActor
final class HostModel: ObservableObject {
    static let sentPrefix = "host-out-"

    @Published private(set) var listening = false
    @Published private(set) var pairing: HostPairing?
    @Published private(set) var approval: HostApproval?
    @Published private(set) var devices: [PairedDevice] = []
    @Published private(set) var problem: String?

    var onDevicesChanged: (() -> Void)?

    private let env: AppEnvironment
    private let phoneId: () -> String
    private let timeline: Timeline
    private let saved: SavedAssets
    private var service: LinkService?
    private var foreground = false
    private var receiving = false
    private var reconciling: Task<Void, Never>?
    private var reconcileAgain = false
    private var approvalAnswer: CheckedContinuation<Bool, Never>?
    private var ticker: Task<Void, Never>?
    private var staging: Set<String> = []

    init(env: AppEnvironment, phoneId: @escaping () -> String, timeline: Timeline, saved: SavedAssets) {
        self.env = env
        self.phoneId = phoneId
        self.timeline = timeline
        self.saved = saved
        if !HostedPhones.read(in: root).isEmpty { _ = makeService() }
    }

    private var root: URL {
        env.folder.appendingPathComponent("Host", isDirectory: true)
    }

    private var outgoing: URL {
        root.appendingPathComponent("Outgoing", isDirectory: true)
    }

    var port: Int { service?.port ?? 0 }

    var fingerprint: Data { service?.fingerprint ?? Data() }

    private var wantsServer: Bool {
        guard foreground, let service = service else { return false }
        return receiving || !devices.isEmpty || approval != nil || service.router.awaitingApproval > 0
    }

    private func makeService() -> LinkService? {
        if let service = service { return service }
        let id = phoneId()
        guard isValidId(id) else {
            problem = String(localized: "This phone's keychain is locked. Unlock the phone and try again.")
            return nil
        }
        do {
            let made = try LinkService(paths: SendPaths(root: root, defaultReceiveRoot: env.documents), identity: try env.identity(), desktopId: id)
            let name = env.phoneName
            made.router.desktopName = { name }
            if let addresses = env.addresses { made.router.addresses = addresses }
            wire(made)
            service = made
            devices = made.devices.devices
            problem = nil
            settleSent()
            return made
        } catch {
            problem = (error as? SelfSignedCertificateError)?.message ?? error.localizedDescription
            return nil
        }
    }

    private func wire(_ service: LinkService) {
        service.router.onTextReceived = { [weak self] item in
            Task { @MainActor in self?.received(item) }
        }
        service.inbox.onFileReceived = { [weak self] file in
            Task { @MainActor in self?.received(file) }
        }
        service.devices.onChange = { [weak self] in
            Task { @MainActor in self?.devicesChanged() }
        }
        service.outbox.onChange = { [weak self] in
            Task { @MainActor in self?.settleSent() }
        }
        service.router.onDevicePaired = { [weak self] device in
            Task { @MainActor in self?.devicePaired(device) }
        }
        service.router.onApprovalSettled = { [weak self] in
            Task { @MainActor in self?.reconcile() }
        }
        service.router.approvePairingMatching = { [weak self] request, match in
            await self?.ask(request, match: match) ?? false
        }
        service.server.onFailure = { [weak self] in
            Task { @MainActor in await self?.restart() }
        }
        // The container's path can change between launches, so the file is found again by its two last components.
        let outgoing = self.outgoing
        service.outbox.locate = { item in
            guard let path = item.path else { return nil }
            let url = URL(fileURLWithPath: path)
            return outgoing.appendingPathComponent(url.deletingLastPathComponent().lastPathComponent).appendingPathComponent(url.lastPathComponent)
        }
    }

    /// Only a phone in front can listen: iOS suspends the app soon after it leaves the screen.
    func sceneChanged(active: Bool) {
        foreground = active
        if !active {
            service?.closePairing()
            pairing = nil
            settleApproval(false)
        }
        reconcile()
    }

    func beginReceiving() {
        receiving = true
        if env.demo {
            demoPairing()
            return
        }
        guard makeService() != nil else { return }
        if ticker == nil {
            ticker = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    self.refresh()
                }
            }
        }
        reconcile()
    }

    func endReceiving() {
        receiving = false
        ticker?.cancel()
        ticker = nil
        service?.closePairing()
        pairing = nil
        settleApproval(false)
        reconcile()
    }

    func renewPairing() {
        service?.closePairing()
        pairing = nil
        reconcile()
    }

    /// Waits for the server to be in the state the model wants.
    func settle() async {
        while let task = reconciling { await task.value }
    }

    private func reconcile() {
        if reconciling != nil {
            reconcileAgain = true
            return
        }
        reconciling = Task { @MainActor in
            repeat {
                reconcileAgain = false
                await applyServerState()
            } while reconcileAgain
            reconciling = nil
        }
    }

    private func applyServerState() async {
        guard let service = service else { return }
        let running = service.server.isRunning
        if wantsServer && !running {
            do {
                let port = try await service.start()
                problem = nil
                env.advertiser?.register(port: port, desktopId: service.devices.desktopId, name: env.phoneName)
            } catch {
                problem = String(localized: "Lazy Send could not start listening: \(error.localizedDescription)")
            }
        } else if !wantsServer && running {
            env.advertiser?.unregister()
            await service.stop()
        }
        listening = service.server.isRunning
        if listening && receiving && foreground && pairing == nil { openPairing(service) }
    }

    private func restart() async {
        env.advertiser?.unregister()
        await service?.stop()
        listening = false
        reconcile()
    }

    private func openPairing(_ service: LinkService) {
        let code = service.openPairing(addresses: env.addresses?())
        guard let session = service.pairing else { return }
        pairing = HostPairing(link: code.uri, shortCode: session.shortCodeText,
                              match: SpkiFingerprint.matchCode(service.fingerprint, shortCode: session.shortCode),
                              check: code.checkCode, expires: session.expires)
    }

    /// Keeps the shown code current: the addresses as they are now, and whether it can still be used.
    func refresh() {
        guard var state = pairing, let service = service else { return }
        if let code = service.pairingCode(addresses: env.addresses?()) {
            if code.uri != state.link { state.link = code.uri }
        } else {
            state.finished = true
        }
        if state != pairing { pairing = state }
    }

    private func devicePaired(_ device: PairedDevice) {
        pairing?.pairedName = device.name
        problem = nil
    }

    private func devicesChanged() {
        devices = service?.devices.devices ?? []
        settleSent()
        reconcile()
        onDevicesChanged?()
    }

    func remove(_ id: String) {
        service?.devices.remove(id)
    }

    func ask(_ request: PairRequest, match: String) async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                Task { @MainActor in
                    self.settleApproval(false)
                    self.approvalAnswer = continuation
                    self.approval = HostApproval(name: PairedDeviceStore.cleanName(request.phoneName), platform: request.platform, match: match)
                }
            }
        } onCancel: {
            Task { @MainActor in self.settleApproval(false) }
        }
    }

    func answerApproval(_ allow: Bool) {
        settleApproval(allow)
    }

    private func settleApproval(_ allow: Bool) {
        let waiting = approvalAnswer
        approvalAnswer = nil
        approval = nil
        waiting?.resume(returning: allow)
    }

    private func received(_ item: ReceivedItem) {
        let link = item.kind == "link"
        let body = (link ? item.url : item.text) ?? ""
        timeline.add(TimelineEntry(id: "in-" + item.id, time: item.received, direction: .received, kind: link ? .link : .text,
                                   pcName: item.deviceName, title: body, state: .done))
        env.notifier.post(item.deviceName, String(body.prefix(120)))
    }

    private func received(_ file: ReceivedFile) {
        let mime = UTType(filenameExtension: file.url.pathExtension)?.preferredMIMEType
        if file.sourceId != nil {
            let id = "in-gallery-" + file.deviceId
            if timeline.get(id) == nil {
                timeline.add(TimelineEntry(id: id, direction: .received, kind: .gallery, pcName: file.deviceName,
                                           title: String(localized: "Photos and videos"), state: .done))
                env.notifier.post(file.deviceName, String(localized: "Receiving photos and videos."))
            }
            timeline.update(id) {
                $0.count += 1
                $0.time = Date()
            }
            if (timeline.get(id)?.count ?? 0) % 20 == 0 { timeline.save() }
        } else {
            timeline.add(TimelineEntry(id: "in-file-" + UUID().uuidString, direction: .received, kind: .file, pcName: file.deviceName,
                                       title: file.url.lastPathComponent, state: .done, bytes: file.size, totalBytes: file.size,
                                       fileName: relativeName(file.url), mime: mime))
            env.notifier.post(file.deviceName, file.url.lastPathComponent)
        }
        ReceiveHandler.saveToPhotos(file.url, mime: mime, defaults: env.defaults, saved: saved)
    }

    // The name under Documents, with the phone's folder in front of it.
    private func relativeName(_ url: URL) -> String {
        let base = env.documents.resolvingSymlinksInPath().path + "/"
        let path = url.resolvingSymlinksInPath().path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : url.lastPathComponent
    }

    @discardableResult
    func sendNote(_ text: String, to id: String) throws -> OutboxItem {
        guard let service = service, let device = devices.first(where: { $0.id == id }) else { throw HostSendError.notPaired }
        let request = try ItemRequest.note(text)
        let item: OutboxItem
        do {
            if request.kind == "link", let url = request.url {
                item = try service.outbox.queueLink(id, url)
            } else {
                item = try service.outbox.queueText(id, text.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression))
            }
        } catch OutboxError.tooMany {
            throw HostSendError.tooMany(device.name)
        } catch {
            throw NoteError.tooLarge
        }
        addSent(item, kind: request.kind == "link" ? .link : .text, title: request.url ?? request.text ?? text, device: device)
        return item
    }

    /// Queues the files for the phone. Each is copied into the app first (a picked file is moved), so it stays
    /// readable until the phone has it. Returns how many were queued.
    @discardableResult
    func sendFiles(_ urls: [URL], to id: String, scoped: Bool = false, names: [String]? = nil) async throws -> Int {
        guard let service = service, let device = devices.first(where: { $0.id == id }) else { throw HostSendError.notPaired }
        var staged: [URL] = []
        var failure: Error?
        for (index, url) in urls.enumerated() {
            let folder = outgoing.appendingPathComponent(UUID().uuidString, isDirectory: true)
            staging.insert(folder.lastPathComponent)
            let name = names.map { $0[index] }
            do {
                staged.append(try await Task.detached { try AppModel.stage(url, scoped: scoped, into: folder, name: name) }.value)
            } catch {
                staging.remove(folder.lastPathComponent)
                failure = error
            }
        }
        let files = staged.map { (url: $0, bookmark: Data?.none, mime: UTType(filenameExtension: $0.pathExtension)?.preferredMIMEType) }
        let queued = service.outbox.queueFiles(id, files)
        for file in staged.dropFirst(queued.count) { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        for item in queued {
            addSent(item, kind: .file, title: item.name ?? "", device: device)
        }
        staging.subtract(staged.map { $0.deletingLastPathComponent().lastPathComponent })
        sweepOutgoing()
        if let failure = failure, queued.isEmpty { throw failure }
        if queued.count < staged.count { throw HostSendError.tooMany(device.name) }
        return queued.count
    }

    private func addSent(_ item: OutboxItem, kind: EntryKind, title: String, device: PairedDevice) {
        timeline.add(TimelineEntry(id: HostModel.sentPrefix + item.id, direction: .sent, kind: kind, pcName: device.name, title: title,
                                   detail: String(localized: "Waiting for \(device.name) to connect"), state: .active,
                                   totalBytes: item.size ?? 0, pcId: HostedPhones.target(device.id), itemId: item.id))
    }

    /// What left the outbox was picked up by the phone, or went with the phone when it was removed; what is still
    /// there is waiting, also after a restart. The copies of files nobody waits for any more go.
    private func settleSent() {
        guard let service = service else { return }
        var changed = false
        for entry in timeline.entries where entry.id.hasPrefix(HostModel.sentPrefix) && entry.state != .done && entry.state != .failed {
            guard let deviceId = entry.pcId.flatMap(HostedPhones.id(ofTarget:)), let itemId = entry.itemId else { continue }
            if service.outbox.find(deviceId, itemId) != nil {
                if entry.state != .active { timeline.update(entry.id) { $0.state = .active } }
                continue
            }
            let paired = service.devices.devices.contains { $0.id == deviceId }
            let removed = String(localized: "\(entry.pcName) was removed.")
            timeline.update(entry.id) {
                $0.state = paired ? .done : .failed
                $0.detail = paired ? "" : removed
                $0.bytes = paired ? $0.totalBytes : $0.bytes
            }
            changed = true
        }
        if changed { timeline.save() }
        sweepOutgoing()
    }

    private func sweepOutgoing() {
        guard let service = service else { return }
        let wanted = Set(service.outbox.all.compactMap(\.path).map { ($0 as NSString).deletingLastPathComponent }
            .map { ($0 as NSString).lastPathComponent })
        let folders = (try? FileManager.default.contentsOfDirectory(at: outgoing, includingPropertiesForKeys: nil)) ?? []
        for folder in folders where !wanted.contains(folder.lastPathComponent) && !staging.contains(folder.lastPathComponent) {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// What the share sheet left for a phone: queued for it, the way the app sends the same things.
    func deliver(_ item: QueuedItem, dataURL: URL, to id: String) async -> Bool {
        do {
            if item.kind == "file" {
                try await sendFiles([dataURL], to: id, scoped: true, names: [item.name ?? "file"])
            } else if item.kind == "link", let url = item.url {
                try sendNote(url, to: id)
            } else {
                try sendNote(item.text ?? "", to: id)
            }
            return true
        } catch HostSendError.tooMany {
            return false
        } catch {
            return true
        }
    }

    private func demoPairing() {
        let fingerprint = Data(repeating: 7, count: 32)
        let code = PairingCode(desktopId: "demo-iphone-0001", name: env.phoneName, fingerprint: Base64Url.encode(fingerprint),
                               addresses: ["192.168.1.24"], port: LinkProtocol.defaultPort, token: Base64Url.encode(Data(repeating: 9, count: 16)))
        pairing = HostPairing(link: code.uri, shortCode: "7KQ2-M9XD", match: SpkiFingerprint.matchCode(fingerprint, shortCode: "7KQ2M9XD"),
                              check: code.checkCode, expires: Date().addingTimeInterval(PairingSession.lifetime))
        listening = true
    }
}
#endif

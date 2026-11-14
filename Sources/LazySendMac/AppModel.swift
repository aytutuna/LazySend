#if os(macOS)
import AppKit
import Foundation
import LazySendKit
import LazySendServer

public struct PhoneRow: Identifiable, Equatable {
    public var id: String
    public var name: String
    public var platform: String
    public var lastSeen: String
    /// A computer this Mac is a guest of, not a phone paired with it.
    public var computer = false
}

public enum TimelineKind: Equatable {
    case text
    case link
    case file
    case gallery
}

public struct TimelineRow: Identifiable, Equatable {
    public var id: String
    public var kind: TimelineKind
    public var sent: Bool
    public var deviceId: String
    public var deviceName: String
    public var time: Date
    public var text: String?
    public var fileURL: URL?
    public var outboxId: String?
    public var heading = ""
    public var detail = ""
    public var canCancel = false
    public var cancelled = false
    public var count = 0
    public var active = false
    public var lastArrival = Date.distantPast

    public var canCopy: Bool { kind == .text || kind == .link }
    public var canOpen: Bool { kind == .link || fileURL != nil }
    public var canShowInFinder: Bool { fileURL != nil }
}

public struct PairingState: Equatable {
    public var code: PairingCode
    public var remaining: Int
    public var pairedName: String?
    /// What a guest that cannot scan types, `XXXX-XXXX`, and the digits it then shows next to it.
    public var shortCode = ""
    public var match = ""
    public var finished: Bool { pairedName != nil || remaining <= 0 }
}

public struct PairApproval: Equatable {
    public var name: String
    public var platform: String
    /// The digits the other device shows too; both screens must agree before this one allows it.
    public var match = ""
}

// TODO: import the camera roll of a phone on a cable (ImageCaptureCore), as the Windows app does through WPD.

/// What the window shows and does: the paired phones, one timeline of what arrived and what was sent, the pairing
/// prompt, and the server that runs while it is needed.
@MainActor
public final class AppModel: ObservableObject {
    static let maxRows = 500
    static let galleryIdle: TimeInterval = 8

    @Published public private(set) var phones: [PhoneRow] = []
    @Published public private(set) var timeline: [TimelineRow] = []
    @Published public var selectedPhoneId: String?
    @Published public var notice: String?
    @Published public private(set) var pairing: PairingState?
    @Published public private(set) var approval: PairApproval?
    @Published public private(set) var connecting: ConnectModel?
    @Published public private(set) var status = ""
    @Published public private(set) var receiveFolder = ""
    @Published public var copyReceivedText: Bool {
        didSet { service.settings.copyTextToClipboard = copyReceivedText }
    }

    public let service: LinkService
    private let advertiser: Advertiser?
    private let guest: GuestService?
    private let sendLanes = SendLanes(2)
    private var sends: [String: Task<Void, Never>] = [:]
    private let pasteboard: NSPasteboard
    private let notify: (String, String) -> Void
    private let scratch: URL
    private var approvalAnswer: CheckedContinuation<Bool, Never>?
    private var tick: Timer?
    private var startError: String?
    private var reconciling = false
    private var reconcileAgain = false
    private let locator = FileLocator()
    private var receiveScope: URL?

    init(service: LinkService, advertiser: Advertiser? = nil, guest: GuestService? = nil, pasteboard: NSPasteboard = .general,
         scratch: URL? = nil, notify: @escaping (String, String) -> Void = { _, _ in }) {
        self.service = service
        self.advertiser = advertiser
        self.guest = guest
        self.pasteboard = pasteboard
        self.notify = notify
        self.scratch = scratch ?? FileManager.default.temporaryDirectory.appendingPathComponent("lazysend-clipboard", isDirectory: true)
        copyReceivedText = service.settings.copyTextToClipboard
        receiveFolder = service.settings.receiveRoot.path
        wire()
        refreshPhones()
        for item in service.history.items.reversed() { addText(item, arrived: false) }
        for phone in service.devices.devices {
            for waiting in service.outbox.pending(phone.id) { addSent(waiting, deviceName: phone.name) }
        }
        clearScratch()
    }

    private func wire() {
        service.router.onTextReceived = { [weak self] item in
            Task { @MainActor in self?.addText(item, arrived: true) }
        }
        service.inbox.onFileReceived = { [weak self] file in
            Task { @MainActor in self?.addFile(file) }
        }
        service.outbox.onChange = { [weak self] in
            Task { @MainActor in self?.refreshSent() }
        }
        let locator = self.locator
        service.outbox.locate = { item in locator.locate(item) }
        service.devices.onChange = { [weak self] in
            Task { @MainActor in
                self?.refreshPhones()
                self?.reconcileServer()
            }
        }
        service.router.onDevicePaired = { [weak self] device in
            Task { @MainActor in self?.devicePaired(device) }
        }
        service.router.onApprovalSettled = { [weak self] in
            Task { @MainActor in self?.reconcileServer() }
        }
        service.router.approvePairingMatching = { [weak self] request, match in
            await self?.ask(request, match: match) ?? false
        }
        service.server.onFailure = { [weak self] in
            Task { @MainActor in await self?.restartServer() }
        }
        guard let guest = guest else { return }
        guest.onTextReceived = { [weak self] item in
            Task { @MainActor in self?.addText(item, arrived: true) }
        }
        guest.onFileReceived = { [weak self] file in
            Task { @MainActor in self?.addFile(file) }
        }
        guest.onFailed = { [weak self] text in
            Task { @MainActor in self?.notice = text }
        }
        guest.onForgotten = { [weak self] name in
            Task { @MainActor in self?.notice = "\(name) no longer recognizes this Mac. Connect to it again to send to it." }
        }
        guest.onChange = { [weak self] in
            Task { @MainActor in self?.refreshPhones() }
        }
    }

    /// Starts the clock that keeps the window current, the server if a phone is paired and the watch on the computers this Mac is a guest of.
    public func start() {
        guard tick == nil else { return }
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.second() }
        }
        reconcileServer()
        guest?.start()
    }

    public func stop() async {
        tick?.invalidate()
        tick = nil
        guest?.stop()
        advertiser?.unregister()
        await service.stop()
    }

    private var wantsServer: Bool {
        !service.devices.devices.isEmpty || pairing != nil || service.router.awaitingApproval > 0
    }

    private func reconcileServer() {
        if reconciling {
            reconcileAgain = true
            return
        }
        reconciling = true
        Task { @MainActor in
            repeat {
                reconcileAgain = false
                await applyServerState()
            } while reconcileAgain
            reconciling = false
        }
    }

    private func applyServerState() async {
        let running = service.server.isRunning
        if wantsServer && !running {
            do {
                let port = try await service.start()
                startError = nil
                advertiser?.register(port: port, desktopId: service.devices.desktopId, name: service.router.desktopName())
            } catch {
                startError = "Lazy Send could not start listening: \(error.localizedDescription)"
            }
        } else if !wantsServer && running {
            advertiser?.unregister()
            await service.stop()
        }
        updateStatus()
    }

    private func restartServer() async {
        advertiser?.unregister()
        await service.stop()
        reconcileServer()
    }

    private func updateStatus() {
        if let startError = startError {
            status = startError
        } else if service.server.isRunning {
            status = "Listening for phones on port \(service.server.port)."
        } else {
            status = ""
        }
    }

    private func refreshPhones() {
        var rows = service.devices.devices.map { PhoneRow(id: $0.id, name: $0.name, platform: $0.platform, lastSeen: AppModel.lastSeen($0.lastSeen, now: Date())) }
        rows += (guest?.hosts.pcs ?? []).map { PhoneRow(id: $0.id, name: $0.name, platform: "computer", lastSeen: computerStatus($0.id), computer: true) }
        phones = rows
        if selectedPhoneId == nil || !rows.contains(where: { $0.id == selectedPhoneId }) { selectedPhoneId = rows.first?.id }
        refreshSent()
    }

    private func computerStatus(_ id: String) -> String {
        guest?.isReachable(id) == true ? "Connected" : "Not reachable right now"
    }

    static func lastSeen(_ seen: Date?, now: Date) -> String {
        guard let seen = seen else { return "" }
        let ago = now.timeIntervalSince(seen)
        if ago < 120 { return "Connected just now" }
        if ago < 3600 { return "Seen \(Int(ago / 60)) minutes ago" }
        return "Seen " + seen.formatted(date: .abbreviated, time: .shortened)
    }

    public func remove(phone id: String) {
        if let guest = guest, guest.hosts.get(id) != nil {
            Task { await guest.forget(id) }
        } else {
            service.devices.remove(id)
        }
    }

    private var selectedPhone: PhoneRow? {
        phones.first { $0.id == selectedPhoneId }
    }

    public var targetTitle: String {
        selectedPhone.map { "Send to \($0.name)" } ?? "Lazy Send"
    }

    /// Opens a pairing session and starts the server for it.
    public func beginPairing() async {
        if !service.server.isRunning {
            do {
                let port = try await service.start()
                startError = nil
                advertiser?.register(port: port, desktopId: service.devices.desktopId, name: service.router.desktopName())
            } catch {
                startError = "Lazy Send could not start listening: \(error.localizedDescription)"
                notice = startError
                updateStatus()
                return
            }
        }
        let code = service.openPairing()
        var state = PairingState(code: code, remaining: Int(PairingSession.lifetime))
        if let session = service.pairing {
            state.shortCode = session.shortCodeText
            state.match = SpkiFingerprint.matchCode(service.fingerprint, shortCode: session.shortCode)
        }
        pairing = state
        updateStatus()
    }

    public func closePairing() {
        service.closePairing()
        pairing = nil
        settleApproval(false)
        reconcileServer()
    }

    public func renewPairing() async {
        service.closePairing()
        pairing = nil
        await beginPairing()
    }

    private func devicePaired(_ device: PairedDevice) {
        if pairing != nil { pairing?.pairedName = device.name }
        notice = nil
    }

    func ask(_ request: PairRequest, match: String = "") async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                Task { @MainActor in
                    self.settleApproval(false)
                    self.approvalAnswer = continuation
                    self.approval = PairApproval(name: PairedDeviceStore.cleanName(request.phoneName), platform: request.platform, match: match)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
            }
        } onCancel: {
            Task { @MainActor in self.settleApproval(false) }
        }
    }

    public func answerApproval(_ allow: Bool) {
        settleApproval(allow)
    }

    private func settleApproval(_ allow: Bool) {
        let waiting = approvalAnswer
        approvalAnswer = nil
        approval = nil
        waiting?.resume(returning: allow)
    }

    private func second() {
        let now = Date()
        // A listener that could not start (the Local Network prompt still open, say) is tried again.
        if startError != nil, wantsServer, !service.server.isRunning { reconcileServer() }
        let devices = service.devices.devices
        let seen = phones.map { phone -> PhoneRow in
            var phone = phone
            if phone.computer {
                phone.lastSeen = computerStatus(phone.id)
            } else if let device = devices.first(where: { $0.id == phone.id }) {
                phone.lastSeen = AppModel.lastSeen(device.lastSeen, now: now)
            }
            return phone
        }
        if seen != phones { phones = seen }
        finishGalleries(now: now)
        guard var state = pairing else { return }
        if let session = service.pairing {
            state.remaining = Int(session.remaining(at: now).rounded(.up))
            if let code = service.pairingCode(), code != state.code { state.code = code }
        } else if state.pairedName == nil {
            state.remaining = 0
        }
        if state != pairing { pairing = state }
    }

    func addText(_ item: ReceivedItem, arrived: Bool) {
        let link = item.kind == "link"
        var row = TimelineRow(id: item.id, kind: link ? .link : .text, sent: false, deviceId: item.deviceId,
                              deviceName: item.deviceName, time: item.received, text: link ? item.url : item.text)
        row.heading = link ? "Link from \(item.deviceName)" : "Text from \(item.deviceName)"
        row.detail = AppModel.stamp(item.received)
        push(row)
        guard arrived else { return }
        if !link, copyReceivedText, let text = item.text { copy(text) }
        notify(row.heading, link ? (item.url ?? "") : String((item.text ?? "").prefix(120)))
    }

    func addFile(_ file: ReceivedFile) {
        let now = Date()
        if file.sourceId != nil {
            addGalleryFile(file, now: now)
            return
        }
        var row = TimelineRow(id: UUID().uuidString, kind: .file, sent: false, deviceId: file.deviceId, deviceName: file.deviceName,
                              time: now, fileURL: file.url)
        row.heading = file.url.lastPathComponent
        row.detail = "\(AppModel.size(file.size)), from \(file.deviceName), \(AppModel.stamp(now))"
        push(row)
        notify("File from \(file.deviceName)", file.url.lastPathComponent)
    }

    private func addGalleryFile(_ file: ReceivedFile, now: Date) {
        if let index = timeline.firstIndex(where: { $0.kind == .gallery && $0.deviceId == file.deviceId && $0.active }) {
            timeline[index].count += 1
            timeline[index].lastArrival = now
            describeGallery(&timeline[index])
            return
        }
        var row = TimelineRow(id: UUID().uuidString, kind: .gallery, sent: false, deviceId: file.deviceId, deviceName: file.deviceName,
                              time: now, fileURL: file.url.deletingLastPathComponent().deletingLastPathComponent())
        row.active = true
        row.count = 1
        row.lastArrival = now
        describeGallery(&row)
        push(row)
        notify("Photos from \(file.deviceName)", "Receiving photos and videos.")
    }

    private func describeGallery(_ row: inout TimelineRow) {
        let count = row.count.formatted()
        row.heading = row.active ? "Receiving photos from \(row.deviceName): \(count) so far"
            : "Received \(count) photos and videos from \(row.deviceName)"
        row.detail = AppModel.stamp(row.time)
    }

    /// A gallery row is done once nothing has arrived for a while and the phone has nothing more in progress.
    func finishGalleries(now: Date) {
        let busy = Set(service.inbox.transfers.filter { $0.isGallery }.map(\.deviceId))
        for index in timeline.indices where timeline[index].kind == .gallery && timeline[index].active {
            guard now.timeIntervalSince(timeline[index].lastArrival) > AppModel.galleryIdle, !busy.contains(timeline[index].deviceId) else { continue }
            timeline[index].active = false
            describeGallery(&timeline[index])
        }
    }

    @discardableResult
    public func sendText(_ text: String) -> Bool {
        guard let phone = target() else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if phone.computer { return sendNote(text, to: phone) }
        do {
            let note = try ItemRequest.note(text)
            let item: OutboxItem
            if note.kind == "link", let url = note.url {
                item = try service.outbox.queueLink(phone.id, url)
            } else {
                item = try service.outbox.queueText(phone.id, AppModel.trimmingEnd(text))
            }
            addSent(item, deviceName: phone.name)
            return true
        } catch OutboxError.tooMany {
            notice = "Too many items are waiting for \(phone.name). Wait until it picks some up."
        } catch {
            notice = "That text is too long to send (the limit is 1 MiB)."
        }
        return false
    }

    @discardableResult
    public func sendFiles(_ urls: [URL]) -> Int {
        guard let phone = target() else { return 0 }
        var readable: [URL] = []
        var problem: String?
        for url in urls {
            var isDirectory: ObjCBool = false
            let reachable = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if reachable && isDirectory.boolValue {
                problem = "Folders cannot be sent yet. Send the files in them, or zip the folder first."
            } else if !reachable || !FileManager.default.isReadableFile(atPath: url.path) {
                problem = "\(url.lastPathComponent) is not there or Lazy Send may not read it."
            } else {
                readable.append(url)
            }
        }
        var started = 0
        if phone.computer {
            for url in readable { sendFile(url, to: phone) }
            started = readable.count
        } else {
            var files: [(url: URL, bookmark: Data?, mime: String?)] = []
            for url in readable {
                let scoped = url.startAccessingSecurityScopedResource()
                let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                if scoped { url.stopAccessingSecurityScopedResource() }
                files.append((url, bookmark, AppModel.mime(of: url)))
            }
            // One save for the whole drop, however many files it holds.
            let queued = files.isEmpty ? [] : service.outbox.queueFiles(phone.id, files)
            for item in queued { addSent(item, deviceName: phone.name) }
            if queued.count < files.count { problem = "Too many items are waiting for \(phone.name). Wait until it picks some up." }
            started = queued.count
        }
        if let problem = problem { notice = problem }
        return started
    }

    /// What is on the pasteboard goes to the selected phone: files as they are, a picture as a PNG, text as a note.
    @discardableResult
    public func sendPasteboard() -> Bool {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return sendFiles(urls) > 0
        }
        if let image = NSImage(pasteboard: pasteboard), let png = AppModel.png(image) {
            let name = "Pasted image \(Int(Date().timeIntervalSince1970)).png"
            do {
                try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
                let url = scratch.appendingPathComponent(name)
                try png.write(to: url)
                return sendFiles([url]) > 0
            } catch {
                notice = "The picture could not be prepared for sending."
                return false
            }
        }
        if let text = pasteboard.string(forType: .string) { return sendText(text) }
        return false
    }

    /// Files from Open With, the Dock icon or a `lazysend:open?file=` address.
    public func open(_ urls: [URL]) {
        var files: [URL] = []
        for url in urls {
            if url.isFileURL {
                files.append(url)
            } else {
                files += HandOff.files(in: url)
            }
        }
        guard !files.isEmpty else { return }
        if target() != nil { sendFiles(files) }
    }

    private func target() -> PhoneRow? {
        if let phone = selectedPhone { return phone }
        notice = "Pair a phone first."
        return nil
    }

    private func addSent(_ item: OutboxItem, deviceName: String) {
        let kind: TimelineKind = item.kind == "link" ? .link : item.kind == "file" ? .file : .text
        var row = TimelineRow(id: item.id, kind: kind, sent: true, deviceId: item.deviceId, deviceName: deviceName, time: item.queued,
                              text: item.kind == "link" ? item.url : item.text,
                              fileURL: item.path.map { URL(fileURLWithPath: $0) }, outboxId: item.id)
        switch item.kind {
        case "file": row.heading = item.name ?? "File"
        case "link": row.heading = "Link to \(deviceName)"
        default: row.heading = "Text to \(deviceName)"
        }
        row.canCancel = true
        describeSent(&row, "Waiting for \(deviceName)")
        push(row)
    }

    private func describeSent(_ row: inout TimelineRow, _ status: String) {
        var size = ""
        if row.kind == .file, let path = row.fileURL?.path,
           let bytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value {
            size = AppModel.size(bytes) + ", "
        }
        row.detail = "\(size)\(status), \(AppModel.stamp(row.time))"
    }

    /// Waiting items that left the outbox were picked up by the phone, or withdrawn here.
    private func refreshSent() {
        locator.keep(Set(service.outbox.all.map { $0.id }))
        let paired = Set(service.devices.devices.map(\.id))
        for index in timeline.indices where timeline[index].sent && timeline[index].canCancel {
            guard let outboxId = timeline[index].outboxId, service.outbox.find(timeline[index].deviceId, outboxId) == nil else { continue }
            timeline[index].canCancel = false
            let gone = timeline[index].cancelled || !paired.contains(timeline[index].deviceId)
            describeSent(&timeline[index], gone ? "Cancelled" : "Delivered")
        }
    }

    public func cancel(_ row: TimelineRow) {
        guard row.canCancel else { return }
        if let task = sends[row.id] {
            task.cancel()
            updateRow(row.id) {
                $0.canCancel = false
                self.describeSent(&$0, "Cancelled")
            }
            return
        }
        guard let outboxId = row.outboxId, let index = timeline.firstIndex(where: { $0.id == row.id }) else { return }
        timeline[index].cancelled = true
        if !service.outbox.acknowledge(row.deviceId, outboxId) { refreshSent() }
    }

    // MARK: Sending to a computer

    private func sendNote(_ text: String, to computer: PhoneRow) -> Bool {
        guard let guest = guest else { return false }
        let note: ItemRequest
        do {
            note = try ItemRequest.note(text)
        } catch {
            notice = "That text is too long to send (the limit is 1 MiB)."
            return false
        }
        let link = note.kind == "link"
        let sent = link ? note : ItemRequest(kind: "text", text: AppModel.trimmingEnd(text))
        var row = TimelineRow(id: UUID().uuidString, kind: link ? .link : .text, sent: true, deviceId: computer.id, deviceName: computer.name,
                              time: Date(), text: link ? sent.url : sent.text)
        row.heading = link ? "Link to \(computer.name)" : "Text to \(computer.name)"
        let id = computer.id
        startSend(row, size: 0) { _ in try await guest.send(sent, to: id) }
        return true
    }

    private func sendFile(_ url: URL, to computer: PhoneRow) {
        guard let guest = guest else { return }
        var row = TimelineRow(id: UUID().uuidString, kind: .file, sent: true, deviceId: computer.id, deviceName: computer.name, time: Date(),
                              fileURL: url)
        row.heading = url.lastPathComponent
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        let id = computer.id
        startSend(row, size: size) { progress in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            try await guest.sendFile(at: url, to: id, onProgress: progress)
        }
    }

    typealias SendWork = @Sendable (_ progress: @escaping @Sendable (Int64) -> Void) async throws -> Void

    /// Adds a row for what is being sent and runs `work`, two at a time; the row says how it went.
    private func startSend(_ row: TimelineRow, size: Int64, work: @escaping SendWork) {
        var row = row
        row.canCancel = true
        describeSent(&row, "Waiting to send")
        push(row)
        let rowId = row.id
        let name = row.deviceName
        let lanes = sendLanes
        sends[rowId] = Task { [weak self] in
            await lanes.acquire()
            var outcome = "Sent to \(name)"
            if Task.isCancelled {
                outcome = "Cancelled"
            } else {
                self?.updateRow(rowId) { self?.describeSent(&$0, "Sending") }
                do {
                    try await work { sent in
                        Task { @MainActor in
                            guard size > 0 else { return }
                            self?.updateRow(rowId) { self?.describeSent(&$0, "Sending, \(min(sent * 100 / size, 100))%") }
                        }
                    }
                } catch {
                    outcome = Task.isCancelled || error is CancellationError ? "Cancelled" : "Not sent: \(error.localizedDescription)"
                }
            }
            await lanes.release()
            self?.sends[rowId] = nil
            self?.updateRow(rowId) {
                $0.canCancel = false
                self?.describeSent(&$0, outcome)
            }
        }
    }

    private func updateRow(_ id: String, _ change: (inout TimelineRow) -> Void) {
        guard let index = timeline.firstIndex(where: { $0.id == id }) else { return }
        change(&timeline[index])
    }

    // MARK: Connecting to a computer

    public func beginConnecting() {
        guard let guest = guest, connecting == nil else { return }
        let model = ConnectModel(guest: guest, ownId: service.devices.desktopId)
        model.onPaired = { [weak self] pc in
            self?.refreshPhones()
            self?.selectedPhoneId = pc.id
        }
        connecting = model
    }

    public func closeConnecting() {
        connecting?.cancel()
        connecting = nil
    }

    /// Adds a row at the top; past `maxRows` the oldest rows go, except those still waiting for a phone.
    private func push(_ row: TimelineRow) {
        timeline.insert(row, at: 0)
        var index = timeline.count - 1
        while index >= 0 && timeline.count > AppModel.maxRows {
            if !timeline[index].canCancel { timeline.remove(at: index) }
            index -= 1
        }
    }

    /// Takes a folder the user chose as the receive folder, kept across launches by a bookmark.
    public func chooseReceiveFolder(_ url: URL) {
        let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        openReceiveScope(url)
        service.settings.setReceiveRoot(url, bookmark: bookmark)
        receiveFolder = url.path
    }

    public func useDefaultReceiveFolder() {
        closeReceiveScope()
        service.settings.setReceiveRoot(nil)
        receiveFolder = service.settings.receiveRoot.path
    }

    /// Opens the chosen receive folder again after a launch; once is enough.
    public func resumeReceiveFolder() {
        guard receiveScope == nil, let bookmark = service.settings.receiveBookmark else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) else { return }
        openReceiveScope(url)
        if url.path != service.settings.receiveRoot.path || stale {
            service.settings.setReceiveRoot(url, bookmark: try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil))
        }
        receiveFolder = url.path
    }

    private func openReceiveScope(_ url: URL) {
        closeReceiveScope()
        if url.startAccessingSecurityScopedResource() { receiveScope = url }
    }

    private func closeReceiveScope() {
        receiveScope?.stopAccessingSecurityScopedResource()
        receiveScope = nil
    }

    private func clearScratch() {
        let waiting = Set(service.devices.devices.flatMap { service.outbox.pending($0.id) }.compactMap(\.path))
        let names = (try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? []
        for name in names where !waiting.contains(scratch.appendingPathComponent(name).path) {
            try? FileManager.default.removeItem(at: scratch.appendingPathComponent(name))
        }
    }

    func copy(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    static func trimmingEnd(_ text: String) -> String {
        var end = text.endIndex
        while end > text.startIndex, text[text.index(before: end)].isWhitespace { end = text.index(before: end) }
        return String(text[text.startIndex..<end])
    }

    static func stamp(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func mime(of url: URL) -> String? {
        (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.preferredMIMEType
    }

    static func png(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

/// Opens the files of a queued item again after the sandbox forgot their paths, by the bookmark kept with the item.
final class FileLocator: @unchecked Sendable {
    private let lock = NSLock()
    private var scopes: [String: URL] = [:]

    /// One access per queued item, kept until the item leaves the queue, so a download that resumes does not open
    /// the file again.
    func locate(_ item: OutboxItem) -> URL? {
        if let path = item.path, FileManager.default.isReadableFile(atPath: path) { return URL(fileURLWithPath: path) }
        lock.lock()
        defer { lock.unlock() }
        if let url = scopes[item.id] { return url }
        guard let bookmark = item.bookmark else { return item.path.map { URL(fileURLWithPath: $0) } }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else { return nil }
        scopes[item.id] = url
        return url
    }

    /// Lets go of the files of items that are no longer queued.
    func keep(_ ids: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        for (id, url) in scopes where !ids.contains(id) {
            url.stopAccessingSecurityScopedResource()
            scopes[id] = nil
        }
    }
}

/// `lazysend:open?file=<path>`, the `file` parameter repeated for each absolute path (CONTRACTS.md).
enum HandOff {
    static func files(in url: URL) -> [URL] {
        guard url.scheme?.lowercased() == "lazysend",
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.path.lowercased() == "open" || parts.host?.lowercased() == "open"
        else { return [] }
        return (parts.queryItems ?? []).filter { $0.name == "file" }.compactMap(\.value).filter { $0.hasPrefix("/") }
            .map { URL(fileURLWithPath: $0) }
    }
}

/// Lets `limit` sends run at once and holds the rest in the order they came.
actor SendLanes {
    private var free: Int
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(_ limit: Int) {
        free = limit
    }

    func acquire() async {
        if free > 0 {
            free -= 1
        } else {
            await withCheckedContinuation { waiting.append($0) }
        }
    }

    func release() {
        if waiting.isEmpty {
            free += 1
        } else {
            waiting.removeFirst().resume()
        }
    }
}
#endif

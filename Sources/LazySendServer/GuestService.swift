import Foundation
import UniformTypeIdentifiers
import LazySendKit

/// The secret a host gave this computer is in the Keychain no longer, or the Keychain will not give it up. The host
/// stays listed; connecting to it again replaces the secret.
public struct HostKeyUnreadable: Error, LocalizedError {
    public let hostName: String

    public var errorDescription: String? { "The key for \(hostName) cannot be read. Connect to it again." }
}

/// A file left unfinished by an earlier run of the app. `wait` returns once the host answers, `run` checks the file and
/// sends the rest (it throws when the file is gone or changed), and `drop` forgets the entry when the user cancels
/// before `run`.
public struct ResumedSend: Sendable {
    public let send: PendingSend
    public let wait: @Sendable () async throws -> Void
    public let run: @Sendable (@escaping @Sendable (Int64) -> Void) async throws -> Void
    public let drop: @Sendable () -> Void
}

enum ResumeError: Error, LocalizedError {
    case changed(String)
    case hostRemoved

    var errorDescription: String? {
        switch self {
        case .changed(let name): return "\(name) is gone or has changed since it was left unfinished."
        case .hostRemoved: return "The computer was removed."
        }
    }
}

/// This computer as a guest of other computers: pairing with them, sending to them, and taking what they queue
/// while the app runs. A host that does not answer is tried again quietly, a little later each time; one that no
/// longer knows this computer is dropped. The callbacks are raised on whatever thread saw the event.
public final class GuestService: @unchecked Sendable {
    public static let maxHosts = 16
    static let chunkBytes = 4 * 1024 * 1024

    public let hosts: PcStore
    public let connector: PcConnector
    let history: ReceivedHistory
    let settings: SendSettings
    let pending: PendingSends
    let gallery: GalleryIndex
    private let guestName: String
    private let appVersion: String
    private let firstRetry: TimeInterval
    private let lastRetry: TimeInterval
    private let lock = NSLock()
    private var watchers: [String: Task<Void, Never>] = [:]
    private var collectors: [String: OutboxCollector] = [:]
    private var receivers: [String: GuestReceiver] = [:]
    private var reachable = Set<String>()
    private var running = false
    private var ending = false

    /// The list of hosts or which of them answer changed.
    public var onChange: (() -> Void)?
    public var onTextReceived: ((ReceivedItem) -> Void)?
    public var onFileReceived: ((ReceivedFile) -> Void)?
    /// An item could not be stored and was dropped from the host's queue; the argument says what and why.
    public var onFailed: ((String) -> Void)?
    /// A host that no longer knows this computer was dropped; the argument is its name.
    public var onForgotten: ((String) -> Void)?
    /// A file left unfinished by an earlier run is carrying on; `ResumedSend.run` does it.
    public var onSendResumed: ((ResumedSend) -> Void)?

    public init(hosts: PcStore, connector: PcConnector, history: ReceivedHistory, settings: SendSettings, pending: PendingSends,
                guestName: String, appVersion: String, firstRetry: TimeInterval = 5, lastRetry: TimeInterval = 60) {
        self.hosts = hosts
        self.connector = connector
        self.history = history
        self.settings = settings
        self.pending = pending
        gallery = GalleryIndex(directory: settings.paths.guestIndexDirectory)
        self.guestName = guestName
        self.appVersion = appVersion
        self.firstRetry = firstRetry
        self.lastRetry = lastRetry
    }

    /// The hosts a gallery file is coming in from now.
    public var hostsReceivingGallery: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(receivers.filter { $0.value.isReceivingGallery }.keys)
    }

    public func isReachable(_ hostId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return reachable.contains(hostId)
    }

    /// Starts taking what the paired hosts queue, and does so for each one paired later. Files left unfinished by an
    /// earlier run go on once their host answers.
    public func start() {
        lock.lock()
        running = true
        ending = false
        lock.unlock()
        for host in hosts.pcs { watch(host.id) }
        for send in pending.sends {
            if hosts.get(send.hostId) == nil {
                pending.remove(send.sendId)
            } else {
                onSendResumed?(ResumedSend(send: send,
                                           wait: { [self] in try await waitForHost(send.hostId) },
                                           run: { [self] progress in try await resume(send, onProgress: progress) },
                                           drop: { [self] in pending.remove(send.sendId) }))
            }
        }
    }

    public func stop() {
        lock.lock()
        running = false
        ending = true
        let tasks = Array(watchers.values)
        watchers = [:]
        lock.unlock()
        tasks.forEach { $0.cancel() }
    }

    /// Pairs with the computer in a pairing link (scanned from its screen or pasted). The link carries the
    /// certificate's fingerprint, so the connection is pinned from the start. The host's user is asked to allow it.
    public func pair(_ code: PairingCode) async throws -> PairedPc {
        try checkRoom(for: code.desktopId)
        let pc = try await Pairing.pair(code, phoneName: guestName, appVersion: appVersion, platform: "mac", connector: connector, store: hosts)
        paired(pc)
        return pc
    }

    /// Pairs with a computer found on the network by the code its screen shows. `confirm` gets the six digits that
    /// agree with the host's screen only when the certificate is the host's own; the code is not sent unless it
    /// answers yes.
    public func pair(host: NearbyHost, code: String, confirm: (String) async -> Bool) async throws -> PairedPc {
        try checkRoom(for: host.id)
        let pc = try await Pairing.pair(code: code, with: host, phoneName: guestName, appVersion: appVersion, platform: "mac",
                                        confirm: confirm, connector: connector, store: hosts)
        paired(pc)
        return pc
    }

    private func checkRoom(for id: String) throws {
        if hosts.get(id) == nil && hosts.pcs.count >= GuestService.maxHosts {
            throw PairingError.refused("Too many computers are paired. Remove one first.")
        }
    }

    // Pairing again replaces the secret, so what was watching with the old one starts over with the new.
    private func paired(_ pc: PairedPc) {
        lock.lock()
        let old = watchers.removeValue(forKey: pc.id)
        collectors[pc.id] = nil
        receivers[pc.id] = nil
        lock.unlock()
        old?.cancel()
        onChange?()
        watch(pc.id)
    }

    /// Tells the host to forget this computer (when it answers) and drops it here either way.
    public func forget(_ id: String) async {
        guard let pc = hosts.get(id) else { return }
        if let reached = await connector.connect(pc, search: false).reached {
            try? await reached.client.forgetSelf()
        }
        removeLocally(id)
    }

    private func removeLocally(_ id: String) {
        hosts.remove(id)
        pending.removeHost(id)
        gallery.clear(id)
        lock.lock()
        collectors[id] = nil
        let receiver = receivers.removeValue(forKey: id)
        reachable.remove(id)
        let task = watchers.removeValue(forKey: id)
        lock.unlock()
        task?.cancel()
        receiver?.discardParts()
        let connector = self.connector
        Task { await connector.forget(id) }
        onChange?()
    }

    /// The host answered 401 to `secret`. It counts only while that is still the secret kept: pairing again in the
    /// meantime replaced it, and the host's refusal was for the old one.
    private func lost(_ id: String, using secret: String?) {
        guard let pc = hosts.get(id), hosts.secret(for: id) == secret else { return }
        removeLocally(id)
        onForgotten?(pc.name)
    }

    /// A text or a link (what `ItemRequest.note` made of it).
    public func send(_ note: ItemRequest, to id: String) async throws {
        // One id for every try, so a post whose answer was lost is not stored twice.
        var note = note
        if note.sendId == nil { note.sendId = newSendId() }
        var failures = 0
        while true {
            let secret = hosts.secret(for: id)
            do {
                _ = try await client(for: id, search: failures == 0).postItem(note)
                return
            } catch let error as LinkError where error.isTransient && failures < Uploader.retryDelays.count {
                try await Task.sleep(nanoseconds: UInt64(Uploader.retryDelays[failures] * 1_000_000_000))
                failures += 1
            } catch let error as LinkError where error.status == 401 {
                lost(id, using: secret)
                throw error
            }
        }
    }

    /// A file, in chunks that carry on after a drop. `onProgress` gets the bytes the host is known to have.
    /// `bookmark` opens the file again after a restart, where the sandbox has forgotten its path.
    public func sendFile(at url: URL, to id: String, bookmark: Data? = nil, clip: Bool? = nil,
                         onProgress: @escaping @Sendable (Int64) -> Void = { _ in }) async throws {
        let sendId = newSendId()
        let (request, modified) = try await Task.detached { () throws -> (ItemRequest, Date?) in
            let values = try? url.resourceValues(forKeys: [.contentTypeKey, .contentModificationDateKey])
            let request = try ItemRequest.file(at: url, name: url.lastPathComponent, mime: values?.contentType?.preferredMIMEType,
                                               modified: values?.contentModificationDate, sendId: sendId, clip: clip)
            return (request, values?.contentModificationDate)
        }.value
        let send = PendingSend(hostId: id, sendId: sendId, path: url.standardizedFileURL.path, size: request.size ?? 0,
                               modified: PendingSend.seconds(modified ?? Date(timeIntervalSince1970: 0)), sha256: request.sha256 ?? "",
                               bookmark: bookmark, clip: clip)
        try await sendPending(send, url: url, request: request, onProgress: onProgress)
    }

    private func waitForHost(_ hostId: String) async throws {
        while !isReachable(hostId) {
            guard hosts.get(hostId) != nil else { throw ResumeError.hostRemoved }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    /// Carries on with a file the host may already have part of; the caller has waited for the host.
    private func resume(_ send: PendingSend, onProgress: @escaping @Sendable (Int64) -> Void) async throws {
        var url = URL(fileURLWithPath: send.path)
        var scoped = false
        #if os(macOS)
        var stale = false
        if let data = send.bookmark,
           let opened = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) {
            url = opened
            scoped = opened.startAccessingSecurityScopedResource()
        }
        #endif
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .contentModificationDateKey])
        guard let size = values?.fileSize, let modified = values?.contentModificationDate,
              Int64(size) == send.size, PendingSend.seconds(modified) == send.modified else {
            pending.remove(send.sendId)
            throw ResumeError.changed(url.lastPathComponent)
        }
        let request = ItemRequest(kind: "file", name: url.lastPathComponent, size: send.size, mime: values?.contentType?.preferredMIMEType,
                                  modified: ISO8601DateFormatter().string(from: modified), sha256: send.sha256, sendId: send.sendId, clip: send.clip)
        try await sendPending(send, url: url, request: request, onProgress: onProgress)
    }

    // A send that did not finish leaves no entry, unless the app is ending: then the next run carries on.
    private func sendPending(_ send: PendingSend, url: URL, request: ItemRequest, onProgress: @escaping @Sendable (Int64) -> Void) async throws {
        pending.add(send)
        let id = send.hostId
        let secret = hosts.secret(for: id)
        var first = true
        let uploader = Uploader(chunkBytes: GuestService.chunkBytes) { [self] () async throws -> UploadAPI in
            let search = first
            first = false
            return try await client(for: id, search: search)
        }
        do {
            _ = try await uploader.send(request, source: FileDataSource(url: url), onProgress: onProgress)
        } catch let error as LinkError where error.status == 401 {
            settle(send)
            lost(id, using: secret)
            throw error
        } catch {
            settle(send)
            throw error
        }
        pending.remove(send.sendId)
    }

    private func settle(_ send: PendingSend) {
        lock.lock()
        let keep = ending
        lock.unlock()
        if !keep { pending.remove(send.sendId) }
    }

    /// A client for the host, or the reason there is none: a 401 when it dropped this computer, a network error otherwise.
    private func client(for id: String, search: Bool) async throws -> LinkClient {
        guard let pc = hosts.get(id) else {
            throw LinkError.refused(status: 401, code: "unauthorized", message: "This computer is not paired any more.", offset: nil)
        }
        guard hosts.secret(for: id) != nil else {
            throw HostKeyUnreadable(hostName: pc.name)
        }
        switch await connector.connect(pc, search: search) {
        case .reached(let reached): return reached.client
        case .forgotten:
            throw LinkError.refused(status: 401, code: "unauthorized", message: "\(pc.name) no longer recognizes this computer.", offset: nil)
        case .unreachable:
            throw LinkError.network("Could not reach \(pc.name). Both computers need to be on the same network.")
        }
    }

    private func watch(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        guard running, watchers[id] == nil else { return }
        watchers[id] = Task { [weak self] in await self?.watchLoop(id) }
    }

    private func collector(for id: String) -> (OutboxCollector, GuestReceiver) {
        lock.lock()
        defer { lock.unlock() }
        if let existing = collectors[id], let receiver = receivers[id] { return (existing, receiver) }
        let receiver = GuestReceiver(hostId: id, guest: self)
        let made = OutboxCollector(handler: receiver)
        collectors[id] = made
        receivers[id] = receiver
        return (made, receiver)
    }

    private func setReachable(_ id: String, _ value: Bool) {
        lock.lock()
        let changed = value ? reachable.insert(id).inserted : reachable.remove(id) != nil
        lock.unlock()
        if changed { onChange?() }
    }

    /// Keeps the host's outbox open. Whatever goes wrong it tries again later; only a host that dropped this
    /// computer, one removed here or the end of the app stops it.
    private func watchLoop(_ id: String) async {
        var retry = firstRetry
        while !Task.isCancelled {
            guard let pc = hosts.get(id) else { return }
            let secret = hosts.secret(for: id)
            switch await connector.connect(pc) {
            case .forgotten:
                lost(id, using: secret)
                return
            case .reached(let reached):
                retry = firstRetry
                setReachable(id, true)
                do {
                    let (outbox, receiver) = collector(for: id)
                    if let waiting = try? await reached.client.outbox(wait: 0), !waiting.more {
                        receiver.removeStaleParts(keeping: Set(waiting.items.map(\.id)))
                    }
                    while true {
                        let asked = Date()
                        let taken = try await outbox.collect(api: reached.client, wait: LinkProtocol.maxOutboxWait)
                        // A host that answers a long poll at once with nothing is not waiting; do not spin on it.
                        if taken == 0 && Date().timeIntervalSince(asked) < 1 { try await Task.sleep(nanoseconds: 1_000_000_000) }
                    }
                } catch is CancellationError {
                    return
                } catch {
                    if (error as? LinkError)?.status == 401 {
                        lost(id, using: secret)
                        return
                    }
                }
            case .unreachable:
                break
            }
            setReachable(id, false)
            do {
                try await Task.sleep(nanoseconds: UInt64(retry * 1_000_000_000))
            } catch {
                return
            }
            retry = min(retry * 2, lastRetry)
        }
    }
}

import Foundation
import Network
import LazySendKit

/// A request's body: exactly its Content-Length of bytes (none without one), from what was read with the head and
/// then the connection. A client that sent `Expect: 100-continue` is told to send its body only when the body is
/// first read, so a request refused before that never sends it. Read by one task at a time.
public final class LinkRequestBody: @unchecked Sendable {
    public typealias Source = (Int) async throws -> Data

    public let length: Int64
    public private(set) var remaining: Int64
    public private(set) var hasStarted = false

    private var buffered: Data
    private let sendContinue: (() async throws -> Void)?
    private let source: Source

    public init(length: Int64, prefix: Data = Data(), sendContinue: (() async throws -> Void)? = nil, source: @escaping Source) {
        self.length = length
        remaining = length
        buffered = Int64(prefix.count) > length ? Data(prefix.prefix(Int(length))) : prefix
        self.sendContinue = sendContinue
        self.source = source
    }

    /// The client still holds its body back: it asked to wait and was not told to send it.
    public var isWithheld: Bool {
        sendContinue != nil && !hasStarted && remaining > 0
    }

    /// The next bytes of the body, at most `maxLength`; empty at its end or when the connection closed early.
    public func read(maxLength: Int) async throws -> Data {
        guard remaining > 0, maxLength > 0 else { return Data() }
        if !hasStarted {
            hasStarted = true
            if let sendContinue = sendContinue { try await sendContinue() }
        }
        let chunk: Data
        if !buffered.isEmpty {
            let count = min(maxLength, buffered.count)
            chunk = Data(buffered.prefix(count))
            buffered = Data(buffered.dropFirst(count))
        } else {
            chunk = try await source(Int(min(Int64(maxLength), remaining)))
            if chunk.isEmpty { return Data() }
        }
        remaining -= Int64(chunk.count)
        return chunk
    }

    /// Reads and drops the rest of the body when it is at most `maxBytes`, so the connection can be closed without
    /// cutting the client off mid-send; a withheld body needs no reading. Returns whether nothing is left unread.
    public func discard(maxBytes: Int64) async throws -> Bool {
        if isWithheld || remaining == 0 { return true }
        if remaining > maxBytes { return false }
        while remaining > 0 {
            if try await read(maxLength: 81920).isEmpty { return false }
        }
        return true
    }

    func readAll() async -> Data? {
        var bytes = Data()
        while Int64(bytes.count) < length {
            guard let chunk = try? await read(maxLength: Int(length) - bytes.count), !chunk.isEmpty else { return nil }
            bytes.append(chunk)
        }
        return bytes
    }
}

public struct LinkRequest {
    public var head: HttpRequestHead
    public var body: LinkRequestBody
    public var remote: NWEndpoint.Host

    public init(head: HttpRequestHead, body: LinkRequestBody, remote: NWEndpoint.Host) {
        self.head = head
        self.body = body
        self.remote = remote
    }
}

public struct LinkResponse {
    public enum Payload {
        case data(Data)
        /// The rest of a file from the handle's position, `length` bytes. The server closes the handle.
        case file(FileHandle, length: Int64)
    }

    public let status: Int
    /// Headers besides Content-Length and Connection, which the server adds.
    public let headers: [HttpHeader]
    public let payload: Payload
    /// Called once by the server with whether the response was written to the client.
    public var written: (@Sendable (Bool) -> Void)?

    public var contentLength: Int64 {
        switch payload {
        case .data(let data): return Int64(data.count)
        case .file(_, let length): return length
        }
    }

    static func json<T: Encodable>(_ status: Int, _ value: T, headers: [HttpHeader] = []) -> LinkResponse {
        let body = (try? JSONEncoder.link.encode(value)) ?? Data()
        return LinkResponse(status: status, headers: [HttpHeader("Content-Type", "application/json; charset=utf-8")] + headers,
                            payload: .data(body))
    }

    static func error(_ status: Int, _ failure: Failure, headers: [HttpHeader] = []) -> LinkResponse {
        json(status, failure, headers: headers)
    }

    static func empty(_ status: Int) -> LinkResponse {
        LinkResponse(status: status, headers: [], payload: .data(Data()))
    }

    /// The body as text (tests).
    public var text: String {
        if case .data(let data) = payload { return String(decoding: data, as: UTF8.self) }
        return ""
    }
}

/// What the phone link server does with each request (the routes are in CONTRACTS.md). Unpaired clients may only
/// check reachability and pair with the open pairing session's token; everything else needs a paired phone's id and
/// secret, and a wrong secret gets 401. Every request counts towards the sender's rate limit, every failed secret or
/// token towards its failure limit. The `on...` closures are called on the request's task.
public final class LinkRouter: @unchecked Sendable {
    private let devices: PairedDeviceStore
    private let inbox: Inbox
    private let history: ReceivedHistory
    private let outbox: Outbox
    private let gallery: GalleryIndex
    private let limiter: LinkRateLimiter
    private let clock: () -> Date
    private let lock = NSLock()
    private var awaiting = 0

    public init(devices: PairedDeviceStore, inbox: Inbox, history: ReceivedHistory, outbox: Outbox, gallery: GalleryIndex,
                limiter: LinkRateLimiter, clock: @escaping () -> Date = { Date() }) {
        self.devices = devices
        self.inbox = inbox
        self.history = history
        self.outbox = outbox
        self.gallery = gallery
        self.limiter = limiter
        self.clock = clock
    }

    public var desktopName: () -> String = { ProcessInfo.processInfo.hostName }

    /// The computer's addresses now, for hello, so a phone paired on one network finds it on another (a USB tether).
    public var addresses: () -> [String] = { Peers.pairingAddresses() }

    /// The pairing session open now; nil when pairing is not open.
    public var currentPairing: () -> PairingSession? = { nil }

    /// Asks the user whether the phone that presented a valid token may pair. Without an answer within
    /// `approvalTimeout` the pairing is declined and the task asking is cancelled. The default declines too: a code
    /// is only shown where someone can answer.
    public var approvePairing: (PairRequest) async -> Bool = { _ in false }

    /// Like `approvePairing`, and used instead of it when set: the second argument is the check code both screens
    /// should show.
    public var approvePairingMatching: ((PairRequest, String) async -> Bool)?

    /// The certificate's fingerprint, for the match code of a pairing by short code.
    public var fingerprint: () -> Data = { Data() }

    public var approvalTimeout: TimeInterval = 120

    public var onDevicePaired: ((PairedDevice) -> Void)?
    public var onTextReceived: ((ReceivedItem) -> Void)?
    /// A pairing request counted in `awaitingApproval` ended: paired, declined, refused or cut off.
    public var onApprovalSettled: (() -> Void)?

    /// Phones that presented a valid token and wait for the user's answer, so the app keeps listening for them.
    public var awaitingApproval: Int {
        lock.lock()
        defer { lock.unlock() }
        return awaiting
    }

    public func handle(_ request: LinkRequest) async -> LinkResponse {
        let now = clock()
        guard limiter.tryRequest(request.remote, now: now) else {
            return .error(429, .rateLimited, headers: [HttpHeader("Retry-After", "60")])
        }
        do {
            return try await route(request, now: now)
        } catch let refusal as Refusal {
            return .error(refusal.status, refusal.failure)
        } catch {
            return .error(500, .serverError)
        }
    }

    private func route(_ request: LinkRequest, now: Date) async throws -> LinkResponse {
        let head = request.head
        let path = head.path
        switch path {
        case Route.health:
            guard head.method == "GET" else { return LinkRouter.notAllowed("GET") }
            return health(request, now: now)
        case Route.pair:
            guard head.method == "POST" else { return LinkRouter.notAllowed("POST") }
            return await pair(request, now: now)
        case Route.hello:
            guard head.method == "GET" else { return LinkRouter.notAllowed("GET") }
            return hello(request, now: now)
        case Route.deviceSelf:
            guard head.method == "DELETE" else { return LinkRouter.notAllowed("DELETE") }
            return removeSelf(request, now: now)
        case Route.items:
            guard head.method == "POST" else { return LinkRouter.notAllowed("POST") }
            return try await postItem(request, now: now)
        case Route.galleryCheck:
            guard head.method == "POST" else { return LinkRouter.notAllowed("POST") }
            return try await galleryCheck(request, now: now)
        case Route.outbox:
            guard head.method == "GET" else { return LinkRouter.notAllowed("GET") }
            return try await outboxList(request, now: now)
        default:
            break
        }
        if path.hasPrefix(Route.itemsPrefix) {
            let rest = String(path.dropFirst(Route.itemsPrefix.count))
            if rest.hasSuffix("/data") {
                guard head.method == "PUT" else { return LinkRouter.notAllowed("PUT") }
                return try await putChunk(request, id: String(rest.dropLast(5)), now: now)
            }
            guard head.method == "GET" else { return LinkRouter.notAllowed("GET") }
            return itemStatus(request, id: rest, now: now)
        }
        if path.hasPrefix(Route.outboxPrefix) {
            let rest = String(path.dropFirst(Route.outboxPrefix.count))
            if rest.hasSuffix("/data") {
                guard head.method == "GET" else { return LinkRouter.notAllowed("GET") }
                return outboxData(request, id: String(rest.dropLast(5)), now: now)
            }
            guard head.method == "DELETE" else { return LinkRouter.notAllowed("DELETE") }
            return acknowledge(request, id: rest, now: now)
        }
        return .error(404, .notFound)
    }

    private static func notAllowed(_ allow: String) -> LinkResponse {
        .error(405, .methodNotAllowed, headers: [HttpHeader("Allow", allow)])
    }

    private static func unauthorized() -> LinkResponse {
        .error(401, .unauthorized, headers: [HttpHeader("WWW-Authenticate", "Bearer")])
    }

    /// The paired phone the request comes from; nil (a failure counted) when its id and secret do not match one.
    private func authenticate(_ request: LinkRequest, now: Date) -> PairedDevice? {
        let device = devices.authenticate(id: request.head.header(Route.deviceIdHeader), secret: request.head.bearerToken, now: now)
        if device == nil { limiter.recordFailure(request.remote, now: now) }
        return device
    }

    private func health(_ request: LinkRequest, now: Date) -> LinkResponse {
        var paired = false
        if request.head.bearerToken != nil || request.head.header(Route.deviceIdHeader) != nil {
            guard authenticate(request, now: now) != nil else { return LinkRouter.unauthorized() }
            paired = true
        }
        return .json(200, Health(service: LinkProtocol.serviceName, protocolVersion: LinkProtocol.version, paired: paired))
    }

    private func hello(_ request: LinkRequest, now: Date) -> LinkResponse {
        guard authenticate(request, now: now) != nil else { return LinkRouter.unauthorized() }
        return .json(200, Hello(protocolVersion: LinkProtocol.version, desktopId: devices.desktopId, desktopName: desktopName(),
                                maxChunkBytes: Limits.maxChunk, addresses: addresses()))
    }

    private func pair(_ request: LinkRequest, now: Date) async -> LinkResponse {
        guard let length = request.head.contentLength else { return .error(411, .lengthRequired) }
        guard length <= Int64(Limits.maxSmallBody) else { return .error(413, .tooLarge) }
        // Before the body is read: a body is only worth waiting for while a code is shown.
        guard let session = currentPairing() else { return .error(403, .pairingClosed) }
        guard let body = await request.body.readAll(), var pair = try? JSONDecoder().decode(PairRequest.self, from: body),
              isValidId(pair.phoneId) else { return .error(400, .badRequest) }
        // Counted from before the token is used until the phone is stored (or refused), so the app never stops
        // listening in between.
        changeAwaiting(by: 1)
        var settleWhenWritten = false
        defer {
            if !settleWhenWritten { settleApproval() }
        }
        switch session.redeem(pair.token, now: now, peer: Peers.bytes(request.remote) ?? []) {
        case .wrongToken:
            limiter.recordFailure(request.remote, now: now)
            return .error(403, .tokenInvalid)
        case .expired:
            return .error(403, .tokenExpired)
        case .alreadyUsed:
            return .error(403, .tokenUsed)
        case .closed:
            return .error(403, .pairingClosed)
        case .accepted:
            break
        }
        let name = PairedDeviceStore.cleanName(pair.phoneName)
        pair.phoneName = name.isEmpty ? "Phone" : name
        let match: String
        if let code = PairingSession.normalizeShortCode(pair.token) {
            match = SpkiFingerprint.matchCode(fingerprint(), shortCode: code)
        } else {
            match = SpkiFingerprint.checkCode(fingerprint())
        }
        let response = await approveAndPair(pair, match: match)
        settleWhenWritten = response.written != nil
        return response
    }

    private func settleApproval() {
        changeAwaiting(by: -1)
        onApprovalSettled?()
    }

    private func approveAndPair(_ pair: PairRequest, match: String) async -> LinkResponse {
        guard await approve(pair, match: match) else { return .error(403, .declined) }
        let secret: String
        do {
            secret = try devices.pair(id: pair.phoneId, name: pair.phoneName, platform: pair.platform, appVersion: pair.appVersion, now: clock())
        } catch PairedDeviceError.tooManyDevices {
            return .error(409, .tooManyDevices)
        } catch {
            return .error(500, .serverError)
        }
        var response = LinkResponse.json(200, PairResponse(protocolVersion: LinkProtocol.version, desktopId: devices.desktopId,
                                                          desktopName: desktopName(), deviceSecret: secret))
        // The phone counts as paired once it has the secret; when the reply never got to it, it is forgotten again.
        let phoneId = pair.phoneId
        response.written = { [self] delivered in
            if !delivered {
                devices.remove(phoneId)
            } else if let device = devices.devices.first(where: { $0.id == phoneId }) {
                onDevicePaired?(device)
            }
            settleApproval()
        }
        return response
    }

    /// The user's answer; false when none came within `approvalTimeout` or the request was cut off.
    private func approve(_ pair: PairRequest, match: String) async -> Bool {
        let ask: (PairRequest) async -> Bool
        if let matching = approvePairingMatching {
            ask = { await matching($0, match) }
        } else {
            ask = approvePairing
        }
        let timeout = approvalTimeout
        let (answers, answer) = AsyncStream.makeStream(of: Bool.self)
        let asking = Task {
            answer.yield(await ask(pair))
        }
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
            answer.yield(false)
        }
        var approved = false
        for await value in answers {
            approved = value
            break
        }
        answer.finish()
        asking.cancel()
        timer.cancel()
        return approved
    }

    private func removeSelf(_ request: LinkRequest, now: Date) -> LinkResponse {
        guard let device = authenticate(request, now: now) else { return LinkRouter.unauthorized() }
        devices.remove(device.id)
        return .empty(204)
    }

    private func postItem(_ request: LinkRequest, now: Date) async throws -> LinkResponse {
        guard let device = authenticate(request, now: now) else { return LinkRouter.unauthorized() }
        guard let length = request.head.contentLength else { return .error(411, .lengthRequired) }
        guard length <= Int64(Limits.maxItemBody) else { return .error(413, .tooLarge) }
        guard let body = await request.body.readAll(), let item = try? JSONDecoder().decode(ItemRequest.self, from: body) else {
            return .error(400, .badRequest)
        }
        switch item.kind {
        case ItemKind.text:
            guard let text = item.text, !text.isEmpty else { return .error(400, .badRequest) }
            guard text.utf8.count <= LinkProtocol.maxTextBytes else { return .error(413, .tooLarge) }
            return stored(history.add(device, kind: ItemKind.text, text: text, url: nil, now: now))
        case ItemKind.link:
            guard isAcceptableLink(item.url) else { return .error(400, .badRequest) }
            return stored(history.add(device, kind: ItemKind.link, text: nil, url: item.url, now: now))
        case ItemKind.file:
            let state = try inbox.begin(device, item)
            return .json(state.done ? 200 : 201, state)
        default:
            return .error(400, .badRequest)
        }
    }

    private func stored(_ item: ReceivedItem) -> LinkResponse {
        onTextReceived?(item)
        return .json(201, ItemState(id: item.id, offset: 0, done: true))
    }

    private func itemStatus(_ request: LinkRequest, id: String, now: Date) -> LinkResponse {
        guard let device = authenticate(request, now: now) else { return LinkRouter.unauthorized() }
        guard isValidId(id), let state = inbox.state(device.id, id) else { return .error(404, .notFound) }
        return .json(200, state)
    }

    private func putChunk(_ request: LinkRequest, id: String, now: Date) async throws -> LinkResponse {
        guard let device = authenticate(request, now: now) else { return LinkRouter.unauthorized() }
        guard isValidId(id) else { return .error(404, .notFound) }
        guard let length = request.head.contentLength else { return .error(411, .lengthRequired) }
        guard length <= Limits.maxChunk else { return .error(413, .tooLarge) }
        guard let text = request.head.header(Route.offsetHeader), text.utf8.count <= 15,
              text.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let offset = Int64(text) else { return .error(400, .badRequest) }
        let state = try await inbox.write(deviceId: device.id, id: id, offset: offset, length: length, body: request.body)
        return .json(200, state)
    }

    private func galleryCheck(_ request: LinkRequest, now: Date) async throws -> LinkResponse {
        guard let device = authenticate(request, now: now) else { return LinkRouter.unauthorized() }
        guard let length = request.head.contentLength else { return .error(411, .lengthRequired) }
        guard length <= Int64(Limits.maxGalleryBody) else { return .error(413, .tooLarge) }
        guard let body = await request.body.readAll(), let check = try? JSONDecoder().decode(GalleryCheckRequest.self, from: body),
              check.ids.allSatisfy({ GalleryIndex.isValidSourceId($0) }) else { return .error(400, .badRequest) }
        guard check.ids.count <= Limits.maxGalleryIds else { return .error(413, .tooLarge) }
        return .json(200, GalleryCheckReply(missing: gallery.missing(device.id, check.ids)))
    }

    private func outboxList(_ request: LinkRequest, now: Date) async throws -> LinkResponse {
        guard let device = authenticate(request, now: now) else { return LinkRouter.unauthorized() }
        var wait = 0
        if let text = LinkHttp.queryParameters(request.head.query)["wait"] {
            guard (1...6).contains(text.utf8.count), text.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let seconds = Int(text) else {
                return .error(400, .badRequest)
            }
            wait = seconds
        }
        wait = min(wait, LinkProtocol.maxOutboxWait)
        let items = await outbox.wait(device.id, seconds: wait)
        var entries: [OutboxEntry] = []
        var inline = 0
        for item in items {
            let bytes = item.inlineBytes
            if !entries.isEmpty && (entries.count >= Limits.maxOutboxItemsPerReply || inline + bytes > Limits.maxOutboxInlineBytes) { break }
            entries.append(item.entry)
            inline += bytes
        }
        return .json(200, OutboxReply(items: entries, more: entries.count < items.count))
    }

    private func outboxData(_ request: LinkRequest, id: String, now: Date) -> LinkResponse {
        guard let device = authenticate(request, now: now) else { return LinkRouter.unauthorized() }
        guard let item = outbox.find(device.id, id), item.kind == ItemKind.file else { return .error(404, .notFound) }
        var start: Int64 = 0
        var partial = false
        if let range = request.head.header("Range") {
            partial = true
            // Only "bytes=n-" is understood: a download resumed where it broke.
            guard range.hasPrefix("bytes="), range.hasSuffix("-"), (8...22).contains(range.utf8.count),
                  let from = Int64(range.dropFirst(6).dropLast()), range.dropFirst(6).dropLast().utf8.allSatisfy({ $0 >= 48 && $0 <= 57 })
            else { return .error(416, .rangeNotSatisfiable) }
            start = from
        }
        guard let url = outbox.locate(item), let handle = try? FileHandle(forReadingFrom: url),
              let end = try? handle.seekToEnd() else { return .error(404, .notFound) }
        let size = Int64(end)
        if size == 0 { partial = false }
        if let queued = item.size, queued != size {
            try? handle.close()
            return .error(409, .changed)
        }
        if start > size || (partial && start == size && size > 0) {
            try? handle.close()
            return .error(416, .rangeNotSatisfiable, headers: [HttpHeader("Content-Range", "bytes */\(size)")])
        }
        do {
            try handle.seek(toOffset: UInt64(start))
        } catch {
            try? handle.close()
            return .error(500, .serverError)
        }
        var headers = [HttpHeader("Content-Type", item.mime ?? "application/octet-stream"), HttpHeader("Accept-Ranges", "bytes")]
        if !partial {
            return LinkResponse(status: 200, headers: headers, payload: .file(handle, length: size))
        }
        headers.append(HttpHeader("Content-Range", "bytes \(start)-\(size - 1)/\(size)"))
        return LinkResponse(status: 206, headers: headers, payload: .file(handle, length: size - start))
    }

    private func acknowledge(_ request: LinkRequest, id: String, now: Date) -> LinkResponse {
        guard let device = authenticate(request, now: now) else { return LinkRouter.unauthorized() }
        outbox.acknowledge(device.id, id)
        return .empty(204)
    }

    private func changeAwaiting(by delta: Int) {
        lock.lock()
        awaiting += delta
        lock.unlock()
    }
}

import Foundation
import Security
import LazySendKit

/// The computer's side of the phone link, put together: the paired phones, what they sent, what waits for them
/// and the server. The app adds the certificate, the Bonjour advertisement, the approval prompt and its windows;
/// everything here runs without a screen, so the tests drive it over loopback.
public final class LinkService: @unchecked Sendable {
    private let clock: () -> Date
    private let lock = NSLock()
    private var session: PairingSession?

    public let settings: SendSettings
    public let devices: PairedDeviceStore
    public let gallery: GalleryIndex
    public let history: ReceivedHistory
    public let outbox: Outbox
    public let inbox: Inbox
    public let limiter: LinkRateLimiter
    public let router: LinkRouter
    public let server: LinkServer
    public let fingerprint: Data

    public init(paths: SendPaths, identity: SecIdentity, desktopId: String? = nil, options: LinkServerOptions? = nil, clock: @escaping () -> Date = { Date() },
                freeSpace: @escaping (URL) -> Int64 = Inbox.volumeFreeBytes) throws {
        guard let der = SelfSignedCertificate.der(of: identity), let fingerprint = SpkiFingerprint.of(der) else {
            throw LinkServerError.unusableIdentity
        }
        let settings = SendSettings(paths: paths)
        let devices = PairedDeviceStore(url: paths.devicesFile, desktopId: desktopId)
        let gallery = GalleryIndex(directory: paths.indexDirectory)
        let history = ReceivedHistory(url: paths.historyFile)
        let outbox = Outbox(url: paths.outboxFile, clock: clock)
        let inbox = Inbox(directory: paths.incomingDirectory, receiveRoot: { settings.receiveRoot }, index: gallery,
                          freeSpace: freeSpace, clock: clock)
        let limiter = LinkRateLimiter()
        let router = LinkRouter(devices: devices, inbox: inbox, history: history, outbox: outbox, gallery: gallery,
                                limiter: limiter, clock: clock)
        var serverOptions = options ?? LinkServerOptions()
        if options == nil {
            let subnets = CachedSubnets()
            serverOptions.allowPeer = { Peers.isAllowed($0, subnets: subnets.subnets, subnets6: subnets.subnets6) }
        }
        // What a phone had begun and what waited for it go with it; the gallery index stays, so pairing again
        // does not send a gallery twice.
        devices.onRemoved = { id in
            outbox.clear(id)
            inbox.removeDevice(id)
        }
        router.fingerprint = { fingerprint }
        self.clock = clock
        self.fingerprint = fingerprint
        self.settings = settings
        self.devices = devices
        self.gallery = gallery
        self.history = history
        self.outbox = outbox
        self.inbox = inbox
        self.limiter = limiter
        self.router = router
        server = LinkServer(identity: identity, router: router, limiter: limiter, options: serverOptions, clock: clock)
        router.currentPairing = { [weak self] in self?.pairing }
    }

    /// The pairing session open now; nil when none is (closed, used, or expired).
    public var pairing: PairingSession? {
        lock.lock()
        defer { lock.unlock() }
        guard let session = session, session.state(at: clock()) == .open else { return nil }
        return session
    }

    public var port: Int { server.port }

    /// Starts the server on `port`, or another free one; returns the port.
    @discardableResult
    public func start(port: Int = LinkProtocol.defaultPort) async throws -> Int {
        try await server.start(port: port)
    }

    public func stop() async {
        await server.stop()
    }

    /// Opens a pairing session (replacing any open one) and returns what the QR code carries. The server must be
    /// running; `addresses` default to the computer's own.
    public func openPairing(addresses: [String]? = nil) -> PairingCode {
        lock.lock()
        session?.close()
        let opened = PairingSession(opened: clock())
        session = opened
        lock.unlock()
        return code(for: opened, addresses: addresses)
    }

    /// The code of the pairing session that is open, with the computer's addresses as they are now (a USB tether
    /// that appeared since gives a new code with the same token); nil when no session is open.
    public func pairingCode(addresses: [String]? = nil) -> PairingCode? {
        pairing.map { code(for: $0, addresses: addresses) }
    }

    public func closePairing() {
        lock.lock()
        session?.close()
        lock.unlock()
    }

    private func code(for session: PairingSession, addresses: [String]?) -> PairingCode {
        let name = PairedDeviceStore.cleanName(router.desktopName())
        return PairingCode(desktopId: devices.desktopId, name: name.isEmpty ? "Computer" : name,
                           fingerprint: Base64Url.encode(fingerprint), addresses: addresses ?? Peers.pairingAddresses(),
                           port: server.port, token: session.token)
    }
}

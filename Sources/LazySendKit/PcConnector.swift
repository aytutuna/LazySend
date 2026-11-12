import Foundation

public struct Reached: Sendable {
    public let client: LinkClient
    public let host: String
    public let link: LinkKind
}

public enum Reach: Sendable {
    case reached(Reached)
    /// Nothing answered at any known address, by announcement or by looking around this phone's networks.
    case unreachable
    /// The computer answered and does not know this phone any more.
    case forgotten

    public var reached: Reached? {
        if case .reached(let value) = self { return value }
        return nil
    }
}

/// What looking around needs from the system; the app uses `live`, tests their own.
public struct Discovery: Sendable {
    public var announced: @Sendable (TimeInterval) async -> [String: [String]]
    public var subnets: @Sendable () -> [Subnet]
    public var probe: @Sendable ([String], Int) async -> [String]

    public init(announced: @escaping @Sendable (TimeInterval) async -> [String: [String]], subnets: @escaping @Sendable () -> [Subnet],
                probe: @escaping @Sendable ([String], Int) async -> [String]) {
        self.announced = announced
        self.subnets = subnets
        self.probe = probe
    }

    public static let live = Discovery(
        announced: { await ServiceBrowser.find(seconds: $0) },
        subnets: { LocalNetworks.current() },
        probe: { await LocalNetworks.probe($0, port: $1) })
}

/// Finds which address a paired computer answers on right now, and on which kind of link.
public actor PcConnector {
    private struct Search {
        let at: Date
        let announced: [String: [String]]
        let probed: [Int: [String]]
    }

    private let store: PcStore
    private let discovery: Discovery
    private let clock: @Sendable () -> Date
    private var sessions: [String: PinnedSession] = [:]
    private var lastSearch: Search?
    private var searching: Task<Search, Never>?
    private var failedSearches = 0

    public init(store: PcStore, discovery: Discovery = .live, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.discovery = discovery
        self.clock = clock
    }

    /// `userAction` is for a person waiting on the answer: it may look around again sooner than the background checks.
    public func connect(_ pc: PairedPc, search: Bool = true, userAction: Bool = false) async -> Reach {
        guard let secret = store.secret(for: pc.id), !pc.pin.isEmpty else { return .unreachable }
        let session = self.session(for: pc)
        let credentials = Credentials(deviceId: store.phoneId, secret: secret)
        let discovery = self.discovery
        let store = self.store
        let probe: @Sendable (String) async -> Reach? = { host in
            await PcConnector.attempt(pc, host: host, session: session, credentials: credentials, store: store, subnets: discovery.subnets())
        }
        var forgotten = false
        var tried = Set<String>()
        func attempt(_ hosts: [String]) async -> Reached? {
            let fresh = hosts.filter { !tried.contains($0) }
            tried.formUnion(hosts)
            let answer = await PcConnector.race(fresh, probe)
            if case .forgotten? = answer { forgotten = true }
            return answer?.reached
        }
        let known = AddressBook.order(lastAddress: pc.lastAddress, known: pc.addresses)
        if let reached = await attempt(known) {
            failedSearches = 0
            return .reached(reached)
        }
        if forgotten { return .forgotten }
        if !search { return .unreachable }
        let (around, fresh) = await lookAround(userAction: userAction)
        let announced = AddressBook.order(lastAddress: nil, known: around.announced[pc.id] ?? [])
        if let reached = await attempt(announced) {
            failedSearches = 0
            return .reached(reached)
        }
        let probed = AddressBook.order(lastAddress: nil, known: around.probed[pc.port] ?? [])
        if let reached = await attempt(probed) {
            failedSearches = 0
            return .reached(reached)
        }
        if fresh { failedSearches += 1 }
        return forgotten ? .forgotten : .unreachable
    }

    /// Waits, trying again every `every` seconds, until the computer answers; nil when it was forgotten there or removed here.
    public func awaitReachable(_ pcId: String, every: TimeInterval = 5) async throws -> Reached? {
        while true {
            guard let pc = store.get(pcId) else { return nil }
            switch await connect(pc) {
            case .reached(let reached): return reached
            case .forgotten: return nil
            case .unreachable: try await Task.sleep(nanoseconds: UInt64(every * 1_000_000_000))
            }
        }
    }

    /// The first of `addresses` that answers with the computer's key, for pairing; its client has no credentials yet.
    public func reachForPairing(addresses: [String], port: Int, pin: Data) async -> Reached? {
        let session = PinnedSession(pin: pin)
        let subnets = discovery.subnets()
        let probe: @Sendable (String) async -> Reach? = { host in
            let client = LinkClient(endpoint: Endpoint(host: host, port: port), session: session, credentials: nil)
            guard (try? await client.health()) != nil else { return nil }
            return .reached(Reached(client: client, host: host, link: LocalNetworks.kind(of: host, in: subnets)))
        }
        return await PcConnector.race(AddressBook.order(lastAddress: nil, known: addresses), probe)?.reached
    }

    private func session(for pc: PairedPc) -> PinnedSession {
        let key = pc.id + pc.fingerprint
        if let existing = sessions[key] { return existing }
        let made = PinnedSession(pin: pc.pin)
        sessions[key] = made
        return made
    }

    private func lookAround(userAction: Bool) async -> (Search, Bool) {
        let wait: TimeInterval = userAction ? 10 : [30, 60, 120, 300][min(failedSearches, 3)]
        if let last = lastSearch, clock().timeIntervalSince(last.at) < wait { return (last, false) }
        if let running = searching { return (await running.value, false) }
        let task = Task { await self.search() }
        searching = task
        let result = await task.value
        searching = nil
        lastSearch = result
        return (result, true)
    }

    private func search() async -> Search {
        let announced = await discovery.announced(2)
        let candidates = LocalNetworks.probeCandidates(discovery.subnets())
        var probed: [Int: [String]] = [:]
        for port in Set(store.pcs.map(\.port)) { probed[port] = await discovery.probe(candidates, port) }
        return Search(at: clock(), announced: announced, probed: probed)
    }

    private nonisolated static func attempt(_ pc: PairedPc, host: String, session: PinnedSession, credentials: Credentials,
                                            store: PcStore, subnets: [Subnet]) async -> Reach? {
        let client = LinkClient(endpoint: Endpoint(host: host, port: pc.port), session: session, credentials: credentials)
        let hello: Hello
        do {
            hello = try await client.hello()
        } catch let error as LinkError {
            return error.status == 401 ? .forgotten : nil
        } catch {
            return nil
        }
        store.update(pc.id) {
            $0.lastAddress = host
            $0.addresses = AddressBook.merged(hello: hello.addresses, known: $0.addresses)
        }
        return .reached(Reached(client: client, host: host, link: LocalNetworks.kind(of: host, in: subnets)))
    }

    /// Asks every host at once and takes the first that reached; forgotten only when none did and one said so.
    nonisolated static func race(_ hosts: [String], _ probe: @escaping @Sendable (String) async -> Reach?) async -> Reach? {
        guard !hosts.isEmpty else { return nil }
        return await withTaskGroup(of: Reach?.self) { group in
            for host in hosts { group.addTask { await probe(host) } }
            var forgotten = false
            while let answer = await group.next() {
                switch answer {
                case .reached?:
                    group.cancelAll()
                    return answer
                case .forgotten?: forgotten = true
                default: break
                }
            }
            return forgotten ? Reach.forgotten : nil
        }
    }
}

import Foundation

/// A paired computer. Its device secret is not here: it is in the SecretStore under the computer's id.
public struct PairedPc: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var fingerprint: String
    public var addresses: [String]
    public var port: Int
    public var lastAddress: String?

    public init(id: String, name: String, fingerprint: String, addresses: [String], port: Int, lastAddress: String? = nil) {
        self.id = id
        self.name = name
        self.fingerprint = fingerprint
        self.addresses = addresses
        self.port = port
        self.lastAddress = lastAddress
    }

    public var pin: Data { Base64Url.decode(fingerprint) ?? Data() }
}

/// Where secrets are kept: the Keychain on the phone, memory in tests.
public protocol SecretStore: Sendable {
    func save(_ data: Data, for key: String) throws
    func load(for key: String) throws -> Data?
    func delete(for key: String) throws
}

/// The paired computers in a JSON file and this phone's id and the computers' secrets in a SecretStore.
public final class PcStore: @unchecked Sendable {
    private static let phoneKey = "phone-id"

    private let file: URL
    private let secrets: SecretStore
    private let repairs: Bool
    private let lock = NSLock()
    private var list: [PairedPc]
    private var phone: String

    /// A store that `repairs` rewrites an unreadable state with a new phone id; one that does not (the share
    /// extension's) only reads, so a Keychain it cannot reach never costs the app its pairings.
    public init(file: URL, secrets: SecretStore, repairs: Bool = true) {
        self.file = file
        self.secrets = secrets
        self.repairs = repairs
        let saved = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        var pcs = saved?.pcs ?? []
        let stored = (try? secrets.load(for: PcStore.phoneKey)).flatMap { String(data: $0, encoding: .utf8) }
        let unreadable = pcs.contains { (try? secrets.load(for: $0.id)) == nil } || (stored == nil && !pcs.isEmpty)
        // A secret that cannot be opened means the file came from another phone or the Keychain was reset. Starting
        // over with a new id keeps this phone from sharing a gallery index on the computer with the one before.
        if unreadable {
            if repairs { pcs.forEach { try? secrets.delete(for: $0.id) } }
            pcs = []
        }
        list = pcs
        if let stored = stored, !unreadable {
            phone = stored
        } else {
            phone = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            if repairs {
                try? secrets.save(Data(phone.utf8), for: PcStore.phoneKey)
                save()
            }
        }
    }

    private struct Saved: Codable {
        var pcs: [PairedPc]
    }

    public var phoneId: String {
        lock.lock()
        defer { lock.unlock() }
        return phone
    }

    public var pcs: [PairedPc] {
        lock.lock()
        defer { lock.unlock() }
        return list
    }

    public func get(_ id: String) -> PairedPc? {
        pcs.first { $0.id == id }
    }

    public func secret(for id: String) -> String? {
        (try? secrets.load(for: id)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Pairing again with the same computer replaces its entry. The secret is written first, so a computer is
    /// listed only once its secret is kept; when the write fails nothing is recorded and the error is thrown.
    public func put(_ pc: PairedPc, secret: String) throws {
        try secrets.save(Data(secret.utf8), for: pc.id)
        lock.lock()
        list = list.filter { $0.id != pc.id } + [pc]
        lock.unlock()
        save()
    }

    public func update(_ id: String, _ change: (inout PairedPc) -> Void) {
        lock.lock()
        let before = list
        if let index = list.firstIndex(where: { $0.id == id }) { change(&list[index]) }
        let changed = list != before
        lock.unlock()
        if changed { save() }
    }

    public func remove(_ id: String) {
        lock.lock()
        list = list.filter { $0.id != id }
        lock.unlock()
        try? secrets.delete(for: id)
        save()
    }

    private func save() {
        guard repairs else { return }
        lock.lock()
        let data = try? JSONEncoder().encode(Saved(pcs: list))
        lock.unlock()
        guard let data = data else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}

/// The order addresses are tried in, and how a computer's own list of them is folded in.
public enum AddressBook {
    /// The address that worked last, then the rest. A scoped address (with `%`) cannot be put in a URL, so it goes.
    public static func order(lastAddress: String?, known: [String]) -> [String] {
        distinct((lastAddress.map { [$0] } ?? []) + known)
    }

    /// What `hello` lists goes first: it is the computer's own current view, which a cable or a hotspot may have changed.
    public static func merged(hello: [String], known: [String]) -> [String] {
        Array(distinct(hello + known).prefix(LinkProtocol.maxAddresses))
    }

    private static func distinct(_ addresses: [String]) -> [String] {
        var seen = Set<String>()
        return addresses.filter { !$0.contains("%") && seen.insert($0).inserted }
    }
}

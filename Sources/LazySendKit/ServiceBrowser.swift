import Foundation
import Network

/// A computer announcing `_lazysend._tcp`: its id and name from the TXT record, where it answered and on which port.
public struct NearbyHost: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var addresses: [String]
    public var port: Int

    public init(id: String, name: String, addresses: [String], port: Int) {
        self.id = id
        self.name = name
        self.addresses = addresses
        self.port = port
    }
}

/// Looks for computers announcing `_lazysend._tcp` and says where each one is now, by the id in its TXT record.
public enum ServiceBrowser {
    private final class Found: @unchecked Sendable {
        private let lock = NSLock()
        private var hosts: [String: NearbyHost] = [:]
        private var connections: [String: NWConnection] = [:]

        func start(_ key: String, _ connection: NWConnection) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if connections[key] != nil { return false }
            connections[key] = connection
            return true
        }

        func add(_ id: String, name: String, address: String, port: Int) {
            lock.lock()
            if var host = hosts[id] {
                host.addresses = AddressBook.merged(hello: host.addresses, known: [address])
                hosts[id] = host
            } else {
                hosts[id] = NearbyHost(id: id, name: name, addresses: [address], port: port)
            }
            lock.unlock()
        }

        func finish() -> [String: NearbyHost] {
            lock.lock()
            defer { lock.unlock() }
            connections.values.forEach { $0.cancel() }
            return hosts
        }
    }

    /// What was announced within `seconds`, by computer id. Link-local addresses with a zone are left out, as a
    /// host written with `%` cannot be put in an address. The name is the TXT record's, then the instance's, then "Computer".
    public static func find(seconds: TimeInterval) async -> [String: NearbyHost] {
        let queue = DispatchQueue(label: "lazysend.browse")
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: LinkProtocol.serviceType, domain: nil), using: .tcp)
        let found = Found()
        browser.browseResultsChangedHandler = { results, _ in
            for result in results {
                guard case let .bonjour(record) = result.metadata, let id = record[LinkProtocol.txtIdKey] else { continue }
                let connection = NWConnection(to: result.endpoint, using: .tcp)
                guard found.start("\(result.endpoint)", connection) else { continue }
                var label = ""
                if case let .service(instance, _, _, _) = result.endpoint { label = instance }
                let name = ServiceBrowser.nameOf(record[LinkProtocol.txtNameKey], label: label)
                connection.stateUpdateHandler = { state in
                    guard case .ready = state else { return }
                    if case let .hostPort(host, port)? = connection.currentPath?.remoteEndpoint {
                        let address = "\(host)"
                        if !address.contains("%") { found.add(id, name: name, address: address, port: Int(port.rawValue)) }
                    }
                    connection.cancel()
                }
                connection.start(queue: queue)
            }
        }
        browser.start(queue: queue)
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        browser.cancel()
        return found.finish()
    }

    /// The name comes from the network and ends up on screen and in a folder name.
    static func nameOf(_ announced: String?, label: String) -> String {
        let shown = DisplayName.clean(announced)
        if !shown.isEmpty { return shown }
        let fallback = DisplayName.clean(label)
        return fallback.isEmpty ? "Computer" : fallback
    }
}

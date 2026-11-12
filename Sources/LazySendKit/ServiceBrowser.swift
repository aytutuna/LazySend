import Foundation
import Network

/// Looks for computers announcing `_lazysend._tcp` and says where each one is now, by the id in its TXT record.
public enum ServiceBrowser {
    private final class Found: @unchecked Sendable {
        private let lock = NSLock()
        private var addresses: [String: [String]] = [:]
        private var connections: [String: NWConnection] = [:]

        func start(_ key: String, _ connection: NWConnection) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if connections[key] != nil { return false }
            connections[key] = connection
            return true
        }

        func add(_ id: String, _ address: String) {
            lock.lock()
            addresses[id, default: []].append(address)
            lock.unlock()
        }

        func finish() -> [String: [String]] {
            lock.lock()
            defer { lock.unlock() }
            connections.values.forEach { $0.cancel() }
            return addresses
        }
    }

    /// What was announced within `seconds`: computer id to the addresses its service resolved to. Link-local
    /// addresses with a zone are left out, as a host written with `%` cannot be put in an address.
    public static func find(seconds: TimeInterval) async -> [String: [String]] {
        let queue = DispatchQueue(label: "lazysend.browse")
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: LinkProtocol.serviceType, domain: nil), using: .tcp)
        let found = Found()
        browser.browseResultsChangedHandler = { results, _ in
            for result in results {
                guard case let .bonjour(record) = result.metadata, let id = record[LinkProtocol.txtIdKey] else { continue }
                let connection = NWConnection(to: result.endpoint, using: .tcp)
                guard found.start("\(result.endpoint)", connection) else { continue }
                connection.stateUpdateHandler = { state in
                    guard case .ready = state else { return }
                    if case let .hostPort(host, _)? = connection.currentPath?.remoteEndpoint {
                        let address = "\(host)"
                        if !address.contains("%") { found.add(id, address) }
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
}

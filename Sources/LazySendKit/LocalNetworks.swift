import Foundation
import Network

public enum LinkKind: String, Codable, Equatable, Sendable {
    case wifi
    case hotspot
    case other

    public var label: String {
        switch self {
        case .wifi: return "Wi-Fi"
        case .hotspot: return "Hotspot or USB"
        case .other: return "Network"
        }
    }
}

/// An IPv4 address of this phone on the interface `name`.
public struct Subnet: Equatable, Sendable {
    public var name: String
    public var address: UInt32
    public var prefix: Int

    public init(name: String, address: UInt32, prefix: Int) {
        self.name = name
        self.address = address
        self.prefix = prefix
    }

    var mask: UInt32 { prefix == 0 ? 0 : UInt32.max << UInt32(32 - prefix) }

    public func contains(_ host: UInt32) -> Bool {
        (address & mask) == (host & mask)
    }

    /// The phone's own interface for a Personal Hotspot is a bridge (USB included) or an ap; Wi-Fi is en0.
    public var kind: LinkKind {
        if name.hasPrefix("bridge") || name.hasPrefix("ap") { return .hotspot }
        if name == "en0" { return .wifi }
        return .other
    }

    /// Wi-Fi, wired and hotspot interfaces; never a mobile network, a VPN or the peer-to-peer ones.
    public var probeable: Bool {
        name.hasPrefix("en") || name.hasPrefix("bridge") || name.hasPrefix("ap")
    }
}

public func ipv4ToInt(_ text: String) -> UInt32? {
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else { return nil }
    var value: UInt32 = 0
    for part in parts {
        guard let n = UInt32(part), n <= 255 else { return nil }
        value = (value << 8) | n
    }
    return value
}

public func intToIpv4(_ value: UInt32) -> String {
    "\(value >> 24).\((value >> 16) & 255).\((value >> 8) & 255).\(value & 255)"
}

public enum LocalNetworks {
    /// The IPv4 addresses of the interfaces that are up, loopback left out.
    public static func current() -> [Subnet] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var result: [Subnet] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let item = cursor {
            cursor = item.pointee.ifa_next
            let flags = item.pointee.ifa_flags
            guard flags & UInt32(IFF_UP) != 0, flags & UInt32(IFF_LOOPBACK) == 0,
                  let address = item.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                  let netmask = item.pointee.ifa_netmask else { continue }
            let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            result.append(Subnet(name: String(cString: item.pointee.ifa_name), address: ip, prefix: mask.nonzeroBitCount))
        }
        return result
    }

    /// Which kind of link carries `host`, from the interface of this phone whose network it is on.
    public static func kind(of host: String, in subnets: [Subnet]) -> LinkKind {
        guard let address = ipv4ToInt(host) else { return .other }
        return subnets.first { $0.contains(address) }?.kind ?? .other
    }

    /// The hosts worth knocking on: up to a /24 around each probeable address of this phone, never the
    /// phone itself, at most `limit` of them.
    public static func probeCandidates(_ subnets: [Subnet], limit: Int = 512) -> [String] {
        var seen = Set<UInt32>()
        var hosts: [String] = []
        for subnet in subnets where subnet.probeable {
            let prefix = max(subnet.prefix, 24)
            let size = UInt32(1) << UInt32(32 - prefix)
            let base = subnet.address & (UInt32.max << UInt32(32 - prefix))
            guard size > 2 else { continue }
            for offset in 1..<(size - 1) {
                let host = base + offset
                if host != subnet.address, seen.insert(host).inserted { hosts.append(intToIpv4(host)) }
            }
        }
        return Array(hosts.prefix(limit))
    }

    /// The candidates that accept a connection on `port`, found with at most `limit` attempts at a time.
    public static func probe(_ hosts: [String], port: Int, limit: Int = 64,
                             connect: @escaping @Sendable (String, Int) async -> Bool = { await TcpProbe.canConnect($0, port: $1) }) async -> [String] {
        await withTaskGroup(of: String?.self) { group in
            var found: [String] = []
            var next = 0
            func launch() {
                guard next < hosts.count else { return }
                let host = hosts[next]
                next += 1
                group.addTask { await connect(host, port) ? host : nil }
            }
            for _ in 0..<min(limit, hosts.count) { launch() }
            while let answer = await group.next() {
                if let host = answer { found.append(host) }
                launch()
            }
            return found
        }
    }
}

public enum TcpProbe {
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false

        func first() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }

    public static func canConnect(_ host: String, port: Int, timeout: TimeInterval = 0.4) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let once = Once()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let queue = DispatchQueue(label: "lazysend.probe")
            func finish(_ ok: Bool) {
                guard once.first() else { return }
                connection.cancel()
                continuation.resume(returning: ok)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .cancelled: finish(false)
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }
}

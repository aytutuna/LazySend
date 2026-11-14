import Foundation
import Network
import LazySendKit

public enum Peers {
    /// A phone hosts only on Wi-Fi, wired and hotspot interfaces, never on the mobile network; a computer on all of them.
    public static let onPhone: Bool = {
#if os(iOS)
        true
#else
        false
#endif
    }()

    public static func hostSubnets(phone: Bool = Peers.onPhone) -> [Subnet] {
        let all = LocalNetworks.current()
        return phone ? all.filter { $0.probeable } : all
    }

    public static func hostSubnets6(phone: Bool = Peers.onPhone) -> [Subnet6] {
        let all = Subnet6.current()
        return phone ? all.filter { $0.probeable } : all
    }

    /// The address's bytes (4 or 16), an IPv4-mapped IPv6 address as its IPv4 address; nil for a name.
    static func bytes(_ host: NWEndpoint.Host) -> [UInt8]? {
        switch host {
        case .ipv4(let address):
            return [UInt8](address.rawValue)
        case .ipv6(let address):
            let b = [UInt8](address.rawValue)
            if b.count == 16 && b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xFF && b[11] == 0xFF {
                return Array(b[12..<16])
            }
            return b
        default:
            return nil
        }
    }

    /// Loopback, RFC 1918, link-local and unique-local. The shared 100.64.0.0/10 range (Tailscale, carrier NAT)
    /// counts only through the subnet of one of this computer's own addresses.
    public static func isLocal(_ host: NWEndpoint.Host) -> Bool {
        guard let b = bytes(host) else { return false }
        if b.count == 4 {
            return b[0] == 127 || b[0] == 10 || (b[0] == 172 && (b[1] & 0xF0) == 16) || (b[0] == 192 && b[1] == 168)
                || (b[0] == 169 && b[1] == 254)
        }
        let loopback = b[0..<15].allSatisfy { $0 == 0 } && b[15] == 1
        return loopback || (b[0] == 0xFE && (b[1] & 0xC0) == 0x80) || (b[0] & 0xFE) == 0xFC
    }

    public static func isAllowed(_ host: NWEndpoint.Host, subnets: [Subnet], subnets6: [Subnet6] = []) -> Bool {
        if isLocal(host) { return true }
        guard let b = bytes(host) else { return false }
        if b.count == 4 {
            let value = b.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            return subnets.contains { $0.contains(value) }
        }
        return subnets6.contains { $0.contains(b) }
    }

    /// Every interface that is up, a USB hotspot included: IPv4 addresses with self-assigned ones last, then the
    /// global and unique-local IPv6 ones, at most `LinkProtocol.maxAddresses`.
    public static func pairingAddresses(_ subnets: [Subnet] = Peers.hostSubnets(), _ subnets6: [Subnet6] = Peers.hostSubnets6()) -> [String] {
        let sorted = subnets.sorted { selfAssigned($0) < selfAssigned($1) }
        let v4 = sorted.map { intToIpv4($0.address) }
        return Array((v4 + subnets6.map(\.text)).prefix(LinkProtocol.maxAddresses))
    }

    private static func selfAssigned(_ subnet: Subnet) -> Int {
        subnet.address >> 16 == 0xA9FE ? 1 : 0
    }
}

/// An IPv6 address of this computer and the length of its prefix.
public struct Subnet6: Equatable, Sendable {
    public var name = ""
    public var address: [UInt8]
    public var prefix: Int

    public init(address: [UInt8], prefix: Int, name: String = "") {
        self.address = address
        self.prefix = prefix
        self.name = name
    }

    public var probeable: Bool {
        name.hasPrefix("en") || name.hasPrefix("bridge") || name.hasPrefix("ap")
    }

    public func contains(_ other: [UInt8]) -> Bool {
        guard other.count == 16, address.count == 16 else { return false }
        var bits = min(max(prefix, 0), 128)
        var i = 0
        while bits > 0 {
            let mask: UInt8 = bits >= 8 ? 0xFF : UInt8(truncatingIfNeeded: 0xFF << (8 - bits))
            if other[i] & mask != address[i] & mask { return false }
            i += 1
            bits -= 8
        }
        return true
    }

    public var text: String {
        var storage = in6_addr()
        withUnsafeMutableBytes(of: &storage) { $0.copyBytes(from: address) }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        inet_ntop(AF_INET6, &storage, &buffer, socklen_t(buffer.count))
        return String(cString: buffer)
    }

    /// Global and unique-local addresses of the interfaces that are up; link-local, loopback and multicast ones are
    /// left out.
    public static func current() -> [Subnet6] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var result: [Subnet6] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let item = cursor {
            cursor = item.pointee.ifa_next
            let flags = item.pointee.ifa_flags
            guard flags & UInt32(IFF_UP) != 0, flags & UInt32(IFF_LOOPBACK) == 0,
                  let address = item.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET6),
                  let netmask = item.pointee.ifa_netmask else { continue }
            let bytes = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                withUnsafeBytes(of: pointer.pointee.sin6_addr) { Array($0) }
            }
            let mask = netmask.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                withUnsafeBytes(of: pointer.pointee.sin6_addr) { Array($0) }
            }
            let isGlobal = (bytes[0] & 0xE0) == 0x20
            let isUniqueLocal = (bytes[0] & 0xFE) == 0xFC
            guard isGlobal || isUniqueLocal, !result.contains(where: { $0.address == bytes }) else { continue }
            result.append(Subnet6(address: bytes, prefix: mask.reduce(0) { $0 + $1.nonzeroBitCount }, name: String(cString: item.pointee.ifa_name)))
        }
        return result
    }
}

/// The subnets of this computer, read again at most every few seconds because every connection asks.
public final class CachedSubnets: @unchecked Sendable {
    private let lock = NSLock()
    private let read: () -> [Subnet]
    private let read6: () -> [Subnet6]
    private var cached: [Subnet] = []
    private var cached6: [Subnet6] = []
    private var when = Date.distantPast

    public init(read: @escaping () -> [Subnet] = { Peers.hostSubnets() }, read6: @escaping () -> [Subnet6] = { Peers.hostSubnets6() }) {
        self.read = read
        self.read6 = read6
    }

    public var subnets: [Subnet] { snapshot().0 }
    public var subnets6: [Subnet6] { snapshot().1 }

    private func snapshot() -> ([Subnet], [Subnet6]) {
        lock.lock()
        defer { lock.unlock() }
        if Date().timeIntervalSince(when) > 5 {
            cached = read()
            cached6 = read6()
            when = Date()
        }
        return (cached, cached6)
    }
}

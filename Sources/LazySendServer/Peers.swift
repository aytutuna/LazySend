import Foundation
import Network
import LazySendKit

public enum Peers {
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

    public static func isAllowed(_ host: NWEndpoint.Host, subnets: [Subnet]) -> Bool {
        if isLocal(host) { return true }
        guard let b = bytes(host), b.count == 4 else { return false }
        let value = b.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return subnets.contains { $0.contains(value) }
    }

    /// Every interface that is up, a USB hotspot included: IPv4 addresses with self-assigned ones last, at most
    /// `LinkProtocol.maxAddresses`.
    public static func pairingAddresses(_ subnets: [Subnet] = LocalNetworks.current()) -> [String] {
        let sorted = subnets.sorted { selfAssigned($0) < selfAssigned($1) }
        return sorted.prefix(LinkProtocol.maxAddresses).map { intToIpv4($0.address) }
    }

    private static func selfAssigned(_ subnet: Subnet) -> Int {
        subnet.address >> 16 == 0xA9FE ? 1 : 0
    }
}

/// The subnets of this computer, read again at most every few seconds because every connection asks.
public final class CachedSubnets: @unchecked Sendable {
    private let lock = NSLock()
    private let read: () -> [Subnet]
    private var cached: [Subnet] = []
    private var when = Date.distantPast

    public init(read: @escaping () -> [Subnet] = { LocalNetworks.current() }) {
        self.read = read
    }

    public var subnets: [Subnet] {
        lock.lock()
        defer { lock.unlock() }
        if Date().timeIntervalSince(when) > 5 {
            cached = read()
            when = Date()
        }
        return cached
    }
}

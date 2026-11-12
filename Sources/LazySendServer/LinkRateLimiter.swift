import Foundation
import Network

public final class LinkRateLimiter: @unchecked Sendable {
    public static let maxFailures = 10
    public static let maxRequestsPerWindow = 3000
    public static let maxTrackedAddresses = 1024
    public static let window: TimeInterval = 60

    private struct Entry {
        var failures: [Date] = []
        var requests: [Date] = []
        var lastUsed = Date.distantPast
    }

    private let lock = NSLock()
    private var entries: [[UInt8]: Entry] = [:]

    public init() {}

    public func isBlocked(_ address: NWEndpoint.Host, now: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let key = LinkRateLimiter.key(address)
        guard var entry = entries[key] else { return false }
        LinkRateLimiter.prune(&entry.failures, now: now)
        entries[key] = entry
        return entry.failures.count >= LinkRateLimiter.maxFailures
    }

    public func tryRequest(_ address: NWEndpoint.Host, now: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let key = LinkRateLimiter.key(address)
        var entry = entryFor(key, now: now)
        LinkRateLimiter.prune(&entry.failures, now: now)
        LinkRateLimiter.prune(&entry.requests, now: now)
        let allowed = entry.failures.count < LinkRateLimiter.maxFailures
            && entry.requests.count < LinkRateLimiter.maxRequestsPerWindow
        if allowed { entry.requests.append(now) }
        entries[key] = entry
        return allowed
    }

    public func recordFailure(_ address: NWEndpoint.Host, now: Date) {
        lock.lock()
        defer { lock.unlock() }
        let key = LinkRateLimiter.key(address)
        var entry = entryFor(key, now: now)
        LinkRateLimiter.prune(&entry.failures, now: now)
        entry.failures.append(now)
        if entry.failures.count > LinkRateLimiter.maxFailures {
            entry.failures.removeFirst(entry.failures.count - LinkRateLimiter.maxFailures)
        }
        entries[key] = entry
    }

    private func entryFor(_ key: [UInt8], now: Date) -> Entry {
        var entry: Entry
        if let found = entries[key] {
            entry = found
        } else {
            if entries.count >= LinkRateLimiter.maxTrackedAddresses,
               let oldest = entries.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key {
                entries.removeValue(forKey: oldest)
            }
            entry = Entry()
        }
        entry.lastUsed = now
        return entry
    }

    private static func prune(_ times: inout [Date], now: Date) {
        while let first = times.first, now.timeIntervalSince(first) >= window || first > now {
            times.removeFirst()
        }
    }

    private static func key(_ address: NWEndpoint.Host) -> [UInt8] {
        Peers.bytes(address) ?? []
    }
}

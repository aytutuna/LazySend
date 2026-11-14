import Foundation
import LazySendKit

public enum PairingSessionState: Equatable, Sendable {
    case open
    case used
    case expired
    case closed
}

public enum PairingRedeemResult: Equatable, Sendable {
    case accepted
    case wrongToken
    case expired
    case alreadyUsed
    case closed
}

public final class PairingSession: @unchecked Sendable {
    public static let tokenByteCount = 16
    public static let lifetime: TimeInterval = 5 * 60
    public static let maxFailedAttempts = 5
    public static let maxTotalFailedAttempts = 25
    public static let shortCodeLength = ShortCode.length

    private let lock = NSLock()
    private let tokenBytes: [UInt8]
    private var current: PairingSessionState = .open
    private var failed = 0
    private var failedByPeer: [[UInt8]: Int] = [:]

    public let token: String
    /// The short code: 8 characters of Crockford base32, no separator.
    public let shortCode: String
    public let opened: Date
    public let expires: Date

    public init(opened: Date, token: Data? = nil) {
        let bytes: [UInt8]
        if let token = token {
            precondition(token.count == PairingSession.tokenByteCount)
            bytes = [UInt8](token)
        } else {
            var generator = SystemRandomNumberGenerator()
            bytes = (0..<PairingSession.tokenByteCount).map { _ in UInt8.random(in: UInt8.min...UInt8.max, using: &generator) }
        }
        tokenBytes = bytes
        self.token = Base64Url.encode(Data(bytes))
        var codeGenerator = SystemRandomNumberGenerator()
        shortCode = String((0..<PairingSession.shortCodeLength).map { _ in
            ShortCode.alphabet.randomElement(using: &codeGenerator)!
        })
        self.opened = opened
        expires = opened.addingTimeInterval(PairingSession.lifetime)
    }

    /// The short code as shown, XXXX-XXXX.
    public var shortCodeText: String { "\(shortCode.prefix(4))-\(shortCode.suffix(4))" }

    public static func normalizeShortCode(_ text: String?) -> String? {
        ShortCode.normalize(text)
    }

    private static func sameBytes(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for i in 0..<a.count {
            difference |= a[i] ^ b[i]
        }
        return difference == 0
    }

    public var failedAttempts: Int {
        lock.lock()
        defer { lock.unlock() }
        return failed
    }

    public func state(at now: Date) -> PairingSessionState {
        lock.lock()
        defer { lock.unlock() }
        return current == .open && now >= expires ? .expired : current
    }

    public func remaining(at now: Date) -> TimeInterval {
        state(at: now) == .open ? expires.timeIntervalSince(now) : 0
    }

    public func redeem(_ token: String?, now: Date, peer: [UInt8] = []) -> PairingRedeemResult {
        lock.lock()
        defer { lock.unlock() }
        switch current {
        case .used: return .alreadyUsed
        case .closed: return .closed
        case .open, .expired: break
        }
        if now >= expires {
            current = .expired
            return .expired
        }
        if current == .expired { return .expired }
        let byPeer = failedByPeer[peer] ?? 0
        if byPeer >= PairingSession.maxFailedAttempts { return .closed }
        var matches = false
        if let presented = token.flatMap(Base64Url.decode), presented.count == PairingSession.tokenByteCount {
            matches = PairingSession.sameBytes([UInt8](presented), tokenBytes)
        }
        if let code = PairingSession.normalizeShortCode(token) {
            matches = PairingSession.sameBytes(Array(code.utf8), Array(shortCode.utf8))
        }
        if !matches {
            failed += 1
            failedByPeer[peer] = byPeer + 1
            if failed >= PairingSession.maxTotalFailedAttempts { current = .closed }
            return .wrongToken
        }
        current = .used
        return .accepted
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        if current == .open { current = .closed }
    }
}

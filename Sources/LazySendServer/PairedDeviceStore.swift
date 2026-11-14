import CryptoKit
import Foundation
import LazySendKit

public struct PairedDevice: Codable, Equatable, Identifiable, Sendable {
    public var id = ""
    public var name = ""
    public var platform = ""
    public var appVersion = ""
    /// SHA-256 of the phone's secret, lowercase hex. The secret itself is never stored, so a copy of the
    /// file does not let anyone pose as the phone.
    public var secretHash = ""
    public var paired: Date?
    public var lastSeen: Date?
}

struct DevicesFile: Codable {
    var desktopId = ""
    var devices: [PairedDevice] = []
}

public enum PairedDeviceError: Error, Equatable {
    case tooManyDevices
    case notSaved
}

/// The phones paired with this computer. Pairing makes a random 256-bit secret, hands it to the phone once and
/// keeps only its SHA-256; a request is accepted when its device id and secret match an entry.
public final class PairedDeviceStore: @unchecked Sendable {
    public static let secretByteCount = 32
    public static let lastSeenResolution: TimeInterval = 60

    private let url: URL
    private let lock = NSLock()
    private var file: DevicesFile

    public var onChange: (() -> Void)?
    public var onRemoved: ((String) -> Void)?

    /// `desktopId` is for a host that has an id already (a phone's own); it replaces the one in the file.
    public init(url: URL, desktopId: String? = nil) {
        self.url = url
        file = JsonFile.load(DevicesFile.self, from: url) ?? DevicesFile()
        if let desktopId = desktopId, isValidId(desktopId) {
            if file.desktopId != desktopId {
                file.desktopId = desktopId
                JsonFile.save(file, to: url)
            }
        } else if !isValidId(file.desktopId) {
            file.desktopId = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
            JsonFile.save(file, to: url)
        }
    }

    public var desktopId: String { file.desktopId }

    public var devices: [PairedDevice] {
        lock.lock()
        defer { lock.unlock() }
        return file.devices
    }

    /// Pairs the phone `id` (pairing again replaces its entry and secret) and returns its new secret, base64url of
    /// 32 bytes, to be sent to the phone once. A phone must not believe it is paired when it is not, so a pairing
    /// that cannot be saved throws.
    public func pair(id: String, name: String, platform: String, appVersion: String, now: Date) throws -> String {
        var generator = SystemRandomNumberGenerator()
        let secret = Data((0..<PairedDeviceStore.secretByteCount).map { _ in UInt8.random(in: 0...255, using: &generator) })
        lock.lock()
        let others = file.devices.filter { $0.id != id }
        guard others.count < Limits.maxDevices else {
            lock.unlock()
            throw PairedDeviceError.tooManyDevices
        }
        var device = PairedDevice()
        device.id = id
        device.name = PairedDeviceStore.cleanName(name)
        device.platform = PairedDeviceStore.cleanName(platform)
        device.appVersion = PairedDeviceStore.cleanName(appVersion)
        device.secretHash = PairedDeviceStore.hash(secret)
        device.paired = now
        device.lastSeen = now
        let previous = file.devices
        file.devices = others + [device]
        guard JsonFile.save(file, to: url) else {
            file.devices = previous
            lock.unlock()
            throw PairedDeviceError.notSaved
        }
        lock.unlock()
        onChange?()
        return Base64Url.encode(secret)
    }

    /// The paired phone `id` when `secret` is its secret (compared in constant time); nil otherwise.
    public func authenticate(id: String?, secret: String?, now: Date) -> PairedDevice? {
        guard let id = id, isValidId(id), let bytes = secret.flatMap(Base64Url.decode),
              bytes.count == PairedDeviceStore.secretByteCount else { return nil }
        let presented = Array(PairedDeviceStore.hash(bytes).utf8)
        lock.lock()
        defer { lock.unlock() }
        guard let index = file.devices.firstIndex(where: { $0.id == id }) else { return nil }
        let stored = Array(file.devices[index].secretHash.utf8)
        guard stored.count == 64 else { return nil }
        var difference: UInt8 = 0
        for (a, b) in zip(stored, presented) { difference |= a ^ b }
        guard difference == 0 else { return nil }
        if let seen = file.devices[index].lastSeen, now >= seen, now.timeIntervalSince(seen) < PairedDeviceStore.lastSeenResolution {
            return file.devices[index]
        }
        file.devices[index].lastSeen = now
        JsonFile.save(file, to: url)
        return file.devices[index]
    }

    /// Unpairs the phone `id`; it is refused from now on. False when it was not paired.
    @discardableResult
    public func remove(_ id: String) -> Bool {
        lock.lock()
        let before = file.devices.count
        file.devices.removeAll { $0.id == id }
        let removed = file.devices.count != before
        if removed { JsonFile.save(file, to: url) }
        lock.unlock()
        if removed {
            onRemoved?(id)
            onChange?()
        }
        return removed
    }

    static func hash(_ secret: Data) -> String {
        SHA256.hash(data: secret).map { String(format: "%02x", $0) }.joined()
    }

    /// A name as kept: control characters removed, trimmed, cut to `DisplayName.maxBytes` UTF-8 bytes.
    public static func cleanName(_ name: String?) -> String {
        DisplayName.clean(name)
    }
}

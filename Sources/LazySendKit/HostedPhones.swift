import Foundation

public struct HostedPhone: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
}

/// The phones paired with this phone as its host. The host keeps them in `devices.json` in its own folder of the
/// App Group container, which is how the share sheet knows who it can queue something for.
public enum HostedPhones {
    /// A phone's row and share target start with this, so they never meet the id of a computer of the same device.
    public static let prefix = "phone:"

    public static func target(_ id: String) -> String {
        prefix + id
    }

    public static func id(ofTarget target: String) -> String? {
        target.hasPrefix(prefix) ? String(target.dropFirst(prefix.count)) : nil
    }

    private struct Saved: Decodable {
        struct Device: Decodable {
            var id: String
            var name: String
        }

        var devices: [Device]
    }

    public static func read(in folder: URL) -> [HostedPhone] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("devices.json")),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return [] }
        return saved.devices.map { HostedPhone(id: $0.id, name: $0.name) }
    }
}

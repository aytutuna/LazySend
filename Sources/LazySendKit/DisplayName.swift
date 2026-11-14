import Foundation

/// Names that come from another device or from the network, made fit to show and to keep.
public enum DisplayName {
    public static let maxBytes = 128

    /// A name as kept: control characters removed, trimmed, cut to `maxBytes` UTF-8 bytes.
    public static func clean(_ name: String?, maxBytes: Int = DisplayName.maxBytes) -> String {
        var text = String.UnicodeScalarView()
        var bytes = 0
        for scalar in (name ?? "").unicodeScalars {
            if scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value) { continue }
            let length = String(scalar).utf8.count
            if bytes + length > maxBytes { break }
            bytes += length
            text.append(scalar)
        }
        return String(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

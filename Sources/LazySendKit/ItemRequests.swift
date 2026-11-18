import Foundation

public enum NoteError: Error, LocalizedError, Equatable {
    case empty
    case tooLarge

    public var errorDescription: String? {
        switch self {
        case .empty: return "There is nothing to send."
        case .tooLarge: return "That is more than the 1 MB a note can hold. Send it as a file instead."
        }
    }
}

/// A random id for one send, 22 characters of base64url, so a retry of it can be told from a new send.
public func newSendId() -> String {
    let bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max) }
    return Data(bytes).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

extension ItemRequest {
    /// A note: a lone http or https address goes as a link, anything else as text.
    public static func note(_ text: String, clip: Bool? = nil) throws -> ItemRequest {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw NoteError.empty }
        if text.utf8.count > LinkProtocol.maxTextBytes { throw NoteError.tooLarge }
        if trimmed.count <= 8192, trimmed.range(of: "^https?://\\S+$", options: .regularExpression) != nil {
            return ItemRequest(kind: "link", url: trimmed, clip: clip)
        }
        return ItemRequest(kind: "text", text: text, clip: clip)
    }

    public static func file(at url: URL, name: String, mime: String?, modified: Date?, sendId: String? = nil, clip: Bool? = nil) throws -> ItemRequest {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        return ItemRequest(kind: "file", name: name, size: size, mime: mime,
                           modified: modified.map { ISO8601DateFormatter().string(from: $0) }, sha256: try sha256Hex(of: url), sendId: sendId, clip: clip)
    }
}

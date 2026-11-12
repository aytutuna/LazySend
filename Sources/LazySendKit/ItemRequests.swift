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

extension ItemRequest {
    /// A note: a lone http or https address goes as a link, anything else as text.
    public static func note(_ text: String) throws -> ItemRequest {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw NoteError.empty }
        if text.utf8.count > LinkProtocol.maxTextBytes { throw NoteError.tooLarge }
        if trimmed.count <= 8192, trimmed.range(of: "^https?://\\S+$", options: .regularExpression) != nil {
            return ItemRequest(kind: "link", url: trimmed)
        }
        return ItemRequest(kind: "text", text: text)
    }

    public static func file(at url: URL, name: String, mime: String?, modified: Date?) throws -> ItemRequest {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        return ItemRequest(kind: "file", name: name, size: size, mime: mime,
                           modified: modified.map { ISO8601DateFormatter().string(from: $0) }, sha256: try sha256Hex(of: url))
    }
}

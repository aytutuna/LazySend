import Foundation
import UniformTypeIdentifiers

public enum SharedKind: Equatable, Sendable {
    case text
    case link
    case file
}

/// What the share sheet does with what it is given.
public enum ShareRouting {
    /// The most the share sheet sends itself; it has little memory and no time to spare, so more waits in the queue.
    public static let directLimit: Int64 = 8 * 1024 * 1024

    /// Decided from the type identifiers one shared item registers. A web page offers its address and its title as
    /// text, so an address wins over text; a photo or a PDF is a file even when it also offers a caption.
    public static func kind(of identifiers: [String]) -> SharedKind {
        let types = identifiers.compactMap { UTType($0) }
        if types.contains(where: { $0.conforms(to: .fileURL) }) { return .file }
        if types.contains(where: { $0.conforms(to: .url) }) { return .link }
        if types.contains(where: { $0.conforms(to: .image) || $0.conforms(to: .movie) || $0.conforms(to: .audio) || $0.conforms(to: .pdf) }) {
            return .file
        }
        if types.contains(where: { $0.conforms(to: .plainText) }) { return .text }
        return .file
    }

    /// `sizes` are the bytes of everything shared together (0 for text and addresses).
    public static func sendsDirectly(sizes: [Int64]) -> Bool {
        sizes.reduce(0, +) <= directLimit
    }
}

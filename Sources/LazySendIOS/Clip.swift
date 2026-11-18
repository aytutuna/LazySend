#if os(iOS)
import Foundation
import UIKit
import UniformTypeIdentifiers

/// What an item that arrived with the clip flag puts on the pasteboard.
enum ClipContent: Equatable {
    case text(String)
    case link(URL)
    case image(URL, UTType)
    case file(URL, UTType)

    static let maxFileBytes = 20 * 1024 * 1024
    static let maxImageBytes = 64 * 1024 * 1024

    /// Nil when there is nothing to put on it: no text, or a file that is too big or cannot be read.
    static func of(kind: String, text: String?, url: String?, file: URL?) -> ClipContent? {
        switch kind {
        case "text":
            guard let text = text, !text.isEmpty else { return nil }
            return .text(text)
        case "link":
            guard let address = url, !address.isEmpty else { return nil }
            if let link = URL(string: address) { return .link(link) }
            return .text(address)
        case "file":
            guard let file = file, let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
            let type = UTType(filenameExtension: file.pathExtension).flatMap { $0.isDynamic ? nil : $0 } ?? .data
            if type.conforms(to: .image) {
                return size <= maxImageBytes ? .image(file, type) : nil
            }
            return size <= maxFileBytes ? .file(file, type) : nil
        default:
            return nil
        }
    }

    /// A file, a picture too, goes as its own bytes under its type, which keeps its format, orientation and metadata.
    func write(to pasteboard: UIPasteboard = .general) {
        switch self {
        case .text(let text):
            pasteboard.string = text
        case .link(let url):
            pasteboard.url = url
        case .image(let url, let type), .file(let url, let type):
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return }
            pasteboard.setItems([[type.identifier: data]])
        }
    }
}

/// The names of what the camera and the clipboard send, with the time they were made.
enum ClipName {
    static func photo(_ date: Date = Date()) -> String {
        "Photo \(stamp(date)).jpg"
    }

    static func clipboard(_ date: Date = Date(), ext: String = "png") -> String {
        "Clipboard \(stamp(date)).\(ext)"
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.string(from: date)
    }
}
#endif

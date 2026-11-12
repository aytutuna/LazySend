#if os(iOS)
import Foundation
import SwiftUI
import UniformTypeIdentifiers

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

/// A photo or video from the picker, copied to a temp file of its own folder (keeping its name) so the
/// whole thing never sits in memory.
struct PickedMedia: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            PickedMedia(url: try PickedMedia.copy(received.file))
        }
        FileRepresentation(importedContentType: .movie) { received in
            PickedMedia(url: try PickedMedia.copy(received.file))
        }
    }

    private static func copy(_ file: URL) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lazysend-picked-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent(file.lastPathComponent)
        try FileManager.default.copyItem(at: file, to: copy)
        return copy
    }
}
#endif

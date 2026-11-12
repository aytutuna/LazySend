#if os(iOS)
import Foundation
import LazySendKit
import Photos
import UniformTypeIdentifiers

enum PhotoAccess: Equatable {
    case allowed
    case limited
    case denied
}

/// The photo library as the app uses it, so a test can stand in for it.
struct PhotoSource {
    var access: @Sendable () async -> PhotoAccess
    var items: @Sendable (_ skipping: Set<String>) async -> [GalleryItem]

    static let live = PhotoSource(access: { await PhotoLibrary.access() }, items: { await PhotoLibrary.items(skipping: $0) })

    static let none = PhotoSource(access: { .denied }, items: { _ in [] })
}

/// The photos and videos this app saved from the computer, by the library's identifier, so the gallery sync
/// does not send them back.
final class SavedAssets: @unchecked Sendable {
    private let file: URL
    private let lock = NSLock()
    private var ids: Set<String>

    init(file: URL) {
        self.file = file
        ids = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Set<String>.self, from: $0) } ?? []
    }

    var all: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return ids
    }

    func insert(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        ids.insert(id)
        guard let data = try? JSONEncoder().encode(ids) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}

/// One resource of an asset, as far as choosing what to send goes. `kind` is photo, video or pairedVideo for the
/// original files and anything else for edits, adjustments and the like.
struct ResourceInfo: Equatable {
    var localIdentifier: String
    var kind: String
    var filename: String
    var uti: String
    var creationDate: Date?
    var size: Int64
}

struct GalleryEntry: Equatable {
    var sourceId: String
    var kind: String
    var name: String
    var mime: String?
    var modified: Date?
    var sizeHint: Int64
}

/// The originals of one asset: its photo or video, and the video of a Live Photo. Edited versions are not sent,
/// nor are assets in `skipping`.
func galleryEntries(_ resources: [ResourceInfo], skipping: Set<String> = []) -> [GalleryEntry] {
    resources.filter { ["photo", "video", "pairedVideo"].contains($0.kind) && !skipping.contains($0.localIdentifier) }.map {
        GalleryEntry(sourceId: $0.localIdentifier + "#" + $0.kind, kind: $0.kind, name: $0.filename,
                     mime: UTType($0.uti)?.preferredMIMEType, modified: $0.creationDate, sizeHint: $0.size)
    }
}

enum PhotoLibrary {
    static func access() async -> PhotoAccess {
        switch await PHPhotoLibrary.requestAuthorization(for: .readWrite) {
        case .authorized: return .allowed
        case .limited: return .limited
        default: return .denied
        }
    }

    /// Everything the app may see, newest first. Reading a big library takes a while, so it is off the main thread.
    static func items(skipping: Set<String>) async -> [GalleryItem] {
        await Task.detached(priority: .utility) {
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            var found: [GalleryItem] = []
            PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in
                guard asset.mediaType == .image || asset.mediaType == .video else { return }
                let resources = PHAssetResource.assetResources(for: asset)
                let infos = resources.map {
                    ResourceInfo(localIdentifier: asset.localIdentifier, kind: kindName($0.type), filename: $0.originalFilename,
                                 uti: $0.uniformTypeIdentifier, creationDate: asset.creationDate, size: fileSize($0))
                }
                for entry in galleryEntries(infos, skipping: skipping) {
                    guard let resource = resources.first(where: { kindName($0.type) == entry.kind }) else { continue }
                    found.append(GalleryItem(sourceId: entry.sourceId, name: entry.name, mime: entry.mime, modified: entry.modified,
                                             sizeHint: entry.sizeHint, export: { try await export(resource) }))
                }
            }
            return found
        }.value
    }

    private static func kindName(_ type: PHAssetResourceType) -> String {
        switch type {
        case .photo: return "photo"
        case .video: return "video"
        case .pairedVideo: return "pairedVideo"
        default: return "other"
        }
    }

    // PhotoKit has no public size for a resource; this key is what everyone reads, and 0 only makes the progress rough.
    private static func fileSize(_ resource: PHAssetResource) -> Int64 {
        (resource.value(forKey: "fileSize") as? Int64) ?? 0
    }

    private static func export(_ resource: PHAssetResource) async throws -> ExportedFile {
        try Task.checkCancellation()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lazysend-gallery-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("original")
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        do {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                PHAssetResourceManager.default().writeData(for: resource, toFile: file, options: options) { error in
                    if let error = error {
                        done.resume(throwing: error)
                    } else {
                        done.resume()
                    }
                }
            }
            let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
            return ExportedFile(url: file, size: size, cleanup: { try? FileManager.default.removeItem(at: folder) })
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
}
#endif

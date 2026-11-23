import Foundation

/// The pages of a scan in a folder of the app's own, so they outlive the process: a folder per page holding its JPEG, its
/// photo as the camera wrote it and the rest in `page.json`, and `order.json` with the page ids in the order they go. Only
/// the pages are kept in memory; the photo is read back when a page is cut again.
///
/// A page is written into a folder of its own named `.tmp-…` and moved into place whole, so its JPEG and its `page.json`
/// always belong together. Nothing is deleted because it could not be read; only folders that are not a complete page, and
/// that `order.json` does not list, are cleaned up. The store does no locking: the caller uses it from one queue.
public final class ScanPageStore: @unchecked Sendable {
    private struct Meta: Codable {
        var corners: Quad
        var filter: CaptureFilter
        var width: Int
        var height: Int
        var dpi: Int
        var gray: Bool
    }

    private static let tempPrefix = ".tmp-"
    private static let parts = ["page.jpg", "source.jpg", "page.json"]

    private let folder: URL
    private let files = FileManager.default

    public init(folder: URL) {
        self.folder = folder
    }

    /// `source` is the photo the page was cut from; nil for a page the store already has, which keeps its photo. A page saved
    /// again (a cut again) keeps its place.
    public func save(_ page: ScanPage, source: Data?) throws {
        try prepareFolder()
        let dir = pageFolder(page.id)
        let temp = folder.appendingPathComponent(ScanPageStore.tempPrefix + UUID().uuidString)
        do {
            try files.createDirectory(at: temp, withIntermediateDirectories: true)
            if let source {
                try source.write(to: temp.appendingPathComponent("source.jpg"))
            } else {
                try files.copyItem(at: dir.appendingPathComponent("source.jpg"), to: temp.appendingPathComponent("source.jpg"))
            }
            try page.jpeg.write(to: temp.appendingPathComponent("page.jpg"))
            let meta = Meta(corners: page.corners, filter: page.filter, width: page.width, height: page.height, dpi: page.dpi,
                            gray: page.gray)
            try JSONEncoder().encode(meta).write(to: temp.appendingPathComponent("page.json"))
            if files.fileExists(atPath: dir.path) {
                _ = try files.replaceItemAt(dir, withItemAt: temp)
            } else {
                try files.moveItem(at: temp, to: dir)
            }
        } catch {
            try? files.removeItem(at: temp)
            throw error
        }
        var ids = order() ?? []
        if !ids.contains(page.id) {
            ids.append(page.id)
            try setOrder(ids)
        }
    }

    public func source(of id: UUID) -> Data? {
        try? Data(contentsOf: pageFolder(id).appendingPathComponent("source.jpg"))
    }

    /// The pages in order. A page `order.json` lists but that cannot be read is left out of the result and stays on disk and in
    /// the list. A complete page it does not list (it was lost from the list, or the process ended between the two writes) is
    /// added at the end. With a list that was read, folders that are not a complete page, and the temporary ones, are removed.
    public func load() -> [ScanPage] {
        let listed = order()
        let ids = listed ?? []
        var pages = ids.compactMap(read)
        var adopted: [UUID] = []
        var strays: [URL] = []
        let names = (try? files.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names {
            let url = folder.appendingPathComponent(name)
            guard let id = UUID(uuidString: name) else {
                if name.hasPrefix(ScanPageStore.tempPrefix) { strays.append(url) }
                continue
            }
            guard !ids.contains(id) else { continue }
            if isComplete(id) {
                adopted.append(id)
            } else {
                strays.append(url)
            }
        }
        adopted.sort { modified($0) < modified($1) }
        pages += adopted.compactMap(read)
        if listed != nil {
            if !adopted.isEmpty { try? setOrder(ids + adopted) }
            for url in strays { try? files.removeItem(at: url) }
        }
        return pages
    }

    public func setOrder(_ ids: [UUID]) throws {
        try prepareFolder()
        try JSONEncoder().encode(ids).write(to: orderFile, options: .atomic)
    }

    /// The folder goes first: a kill before the list is written leaves a listed id with no folder, which a load skips,
    /// where the other way round would leave a whole folder the next load takes in again.
    public func remove(_ id: UUID) {
        try? files.removeItem(at: pageFolder(id))
        if let ids = order() { try? setOrder(ids.filter { $0 != id }) }
    }

    public func removeAll() {
        try? files.removeItem(at: folder)
    }

    private var orderFile: URL { folder.appendingPathComponent("order.json") }

    private func pageFolder(_ id: UUID) -> URL {
        folder.appendingPathComponent(id.uuidString)
    }

    /// The folder exists and is left out of backups: the pages are a scan in progress.
    private func prepareFolder() throws {
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        var url = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// nil when the file is not there or cannot be read, which is not the same as an empty list.
    private func order() -> [UUID]? {
        guard let raw = try? Data(contentsOf: orderFile) else { return nil }
        return try? JSONDecoder().decode([UUID].self, from: raw)
    }

    private func isComplete(_ id: UUID) -> Bool {
        ScanPageStore.parts.allSatisfy { files.fileExists(atPath: pageFolder(id).appendingPathComponent($0).path) }
    }

    private func modified(_ id: UUID) -> Date {
        let values = try? pageFolder(id).resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate ?? .distantPast
    }

    private func read(_ id: UUID) -> ScanPage? {
        let dir = pageFolder(id)
        guard let jpeg = try? Data(contentsOf: dir.appendingPathComponent("page.jpg")),
              let raw = try? Data(contentsOf: dir.appendingPathComponent("page.json")),
              let meta = try? JSONDecoder().decode(Meta.self, from: raw) else { return nil }
        return ScanPage(id: id, corners: meta.corners, filter: meta.filter, jpeg: jpeg, width: meta.width, height: meta.height,
                        dpi: meta.dpi, gray: meta.gray)
    }
}

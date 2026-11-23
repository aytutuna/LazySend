import Foundation

/// The pages of a scan in a folder of the app's own, so they outlive the process: a folder per page holding its JPEG, its
/// photo as the camera wrote it and the rest in `page.json`, and `order.json` with the page ids in the order they go. Only
/// the pages are kept in memory; the photo is read back when a page is cut again.
public final class ScanPageStore {
    private struct Meta: Codable {
        var corners: Quad
        var filter: CaptureFilter
        var width: Int
        var height: Int
        var dpi: Int
        var gray: Bool
    }

    private let folder: URL
    private let files = FileManager.default

    public init(folder: URL) {
        self.folder = folder
    }

    /// `save` writes the photo with the page; a page saved again (a cut again) keeps its place.
    public func save(_ page: ScanPage, source: Data) throws {
        let dir = pageFolder(page.id)
        try files.createDirectory(at: dir, withIntermediateDirectories: true)
        try source.write(to: dir.appendingPathComponent("source.jpg"), options: .atomic)
        try page.jpeg.write(to: dir.appendingPathComponent("page.jpg"), options: .atomic)
        let meta = Meta(corners: page.corners, filter: page.filter, width: page.width, height: page.height, dpi: page.dpi,
                        gray: page.gray)
        try JSONEncoder().encode(meta).write(to: dir.appendingPathComponent("page.json"), options: .atomic)
        var ids = order()
        if !ids.contains(page.id) {
            ids.append(page.id)
            try setOrder(ids)
        }
    }

    public func source(of id: UUID) -> Data? {
        try? Data(contentsOf: pageFolder(id).appendingPathComponent("source.jpg"))
    }

    /// The pages in order. A folder `order.json` does not list (a save the process did not finish) or that cannot be read is
    /// removed.
    public func load() -> [ScanPage] {
        let decoder = JSONDecoder()
        var pages: [ScanPage] = []
        for id in order() {
            let dir = pageFolder(id)
            guard let jpeg = try? Data(contentsOf: dir.appendingPathComponent("page.jpg")),
                  let raw = try? Data(contentsOf: dir.appendingPathComponent("page.json")),
                  let meta = try? decoder.decode(Meta.self, from: raw) else { continue }
            pages.append(ScanPage(id: id, corners: meta.corners, filter: meta.filter, jpeg: jpeg, width: meta.width,
                                  height: meta.height, dpi: meta.dpi, gray: meta.gray))
        }
        let kept = Set(pages.map(\.id))
        try? setOrder(pages.map(\.id))
        for name in (try? files.contentsOfDirectory(atPath: folder.path)) ?? [] where UUID(uuidString: name).map(kept.contains) == false {
            try? files.removeItem(at: folder.appendingPathComponent(name))
        }
        return pages
    }

    public func setOrder(_ ids: [UUID]) throws {
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(ids).write(to: orderFile, options: .atomic)
    }

    public func remove(_ id: UUID) {
        try? setOrder(order().filter { $0 != id })
        try? files.removeItem(at: pageFolder(id))
    }

    public func removeAll() {
        try? files.removeItem(at: folder)
    }

    private var orderFile: URL { folder.appendingPathComponent("order.json") }

    private func pageFolder(_ id: UUID) -> URL {
        folder.appendingPathComponent(id.uuidString)
    }

    private func order() -> [UUID] {
        guard let raw = try? Data(contentsOf: orderFile) else { return [] }
        return (try? JSONDecoder().decode([UUID].self, from: raw)) ?? []
    }
}

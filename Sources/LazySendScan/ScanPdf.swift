import Foundation

/// Writes a scan's pages as one PDF: each page's JPEG is embedded as it is, on a page the size it prints at
/// (`ScanPage.dpi`).
public enum ScanPdf {
    public static func make(_ pages: [ScanPage]) -> Data {
        var out = Data()
        // Nothing here throws: the pages are in memory and the sink only appends.
        try! write(count: pages.count, page: { pages[$0] }, sink: { out.append($0) })
        return out
    }

    /// Writes the PDF to `url`, taking each page from `page` just when it is written and handing it on in pieces, so a long scan
    /// is never held whole in memory.
    public static func write(count: Int, to url: URL, page: (Int) throws -> ScanPage) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try write(count: count, page: page, sink: { try handle.write(contentsOf: $0) })
    }

    public static func write(count: Int, page: (Int) throws -> ScanPage, sink: (Data) throws -> Void) throws {
        var written = 0
        var offsets: [Int] = []

        func put(_ data: Data) throws {
            written += data.count
            try sink(data)
        }
        func add(_ text: String) throws { try put(Data(text.utf8)) }
        func begin(_ number: Int) throws {
            offsets.append(written)
            try add("\(number) 0 obj\n")
        }

        // The second line is four high bytes, which tells file transfer tools that the file is binary.
        try add("%PDF-1.4\n%")
        try put(Data([0xE2, 0xE3, 0xCF, 0xD3, 0x0A]))
        // Object 1 is the catalog and 2 the page tree; page i is object 3 + 3i, followed by its content and its image.
        try begin(1)
        try add("<< /Type /Catalog /Pages 2 0 R >>\nendobj\n")
        try begin(2)
        let kids = (0..<count).map { "\(3 + 3 * $0) 0 R" }.joined(separator: " ")
        try add("<< /Type /Pages /Count \(count) /Kids [\(kids)] >>\nendobj\n")
        for i in 0..<count {
            let scanned = try page(i)
            let first = 3 + 3 * i
            let w = Double(scanned.width) * 72 / Double(scanned.dpi)
            let h = Double(scanned.height) * 72 / Double(scanned.dpi)
            let size = "\(points(w)) \(points(h))"
            try begin(first)
            try add("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(size)] /Resources << /XObject << /Im0 \(first + 2) 0 R >> >> /Contents \(first + 1) 0 R >>\nendobj\n")
            let content = "q \(points(w)) 0 0 \(points(h)) 0 0 cm /Im0 Do Q\n"
            try begin(first + 1)
            try add("<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream\nendobj\n")
            try begin(first + 2)
            let space = scanned.gray ? "/DeviceGray" : "/DeviceRGB"
            try add("<< /Type /XObject /Subtype /Image /Width \(scanned.width) /Height \(scanned.height) /ColorSpace \(space) /BitsPerComponent 8 /Filter /DCTDecode /Length \(scanned.jpeg.count) >>\nstream\n")
            try put(scanned.jpeg)
            try add("\nendstream\nendobj\n")
        }
        let table = written
        try add("xref\n0 \(offsets.count + 1)\n0000000000 65535 f \n")
        for offset in offsets { try add(String(format: "%010d 00000 n \n", offset)) }
        try add("trailer\n<< /Size \(offsets.count + 1) /Root 1 0 R >>\nstartxref\n\(table)\n%%EOF\n")
    }

    private static func points(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

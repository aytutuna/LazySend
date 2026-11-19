import Foundation

/// Writes a scan's pages as one PDF: each page's JPEG is embedded as it is, on a page the size it prints at
/// (`ScanPage.dpi`).
public enum ScanPdf {
    public static func make(_ pages: [ScanPage]) -> Data {
        var out = Data()
        var offsets: [Int] = []

        func add(_ text: String) { out.append(Data(text.utf8)) }
        func begin(_ number: Int) {
            offsets.append(out.count)
            add("\(number) 0 obj\n")
        }

        // The second line is four high bytes, which tells file transfer tools that the file is binary.
        out.append(Data("%PDF-1.4\n%".utf8))
        out.append(contentsOf: [0xE2, 0xE3, 0xCF, 0xD3, 0x0A])
        // Object 1 is the catalog and 2 the page tree; page i is object 3 + 3i, followed by its content and its image.
        begin(1)
        add("<< /Type /Catalog /Pages 2 0 R >>\nendobj\n")
        begin(2)
        let kids = pages.indices.map { "\(3 + 3 * $0) 0 R" }.joined(separator: " ")
        add("<< /Type /Pages /Count \(pages.count) /Kids [\(kids)] >>\nendobj\n")
        for (i, page) in pages.enumerated() {
            let first = 3 + 3 * i
            let w = Double(page.width) * 72 / Double(page.dpi)
            let h = Double(page.height) * 72 / Double(page.dpi)
            let size = "\(points(w)) \(points(h))"
            begin(first)
            add("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(size)] /Resources << /XObject << /Im0 \(first + 2) 0 R >> >> /Contents \(first + 1) 0 R >>\nendobj\n")
            let content = "q \(size) 0 0 cm /Im0 Do Q\n"
            begin(first + 1)
            add("<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream\nendobj\n")
            begin(first + 2)
            let space = page.gray ? "/DeviceGray" : "/DeviceRGB"
            add("<< /Type /XObject /Subtype /Image /Width \(page.width) /Height \(page.height) /ColorSpace \(space) /BitsPerComponent 8 /Filter /DCTDecode /Length \(page.jpeg.count) >>\nstream\n")
            out.append(page.jpeg)
            add("\nendstream\nendobj\n")
        }
        let table = out.count
        add("xref\n0 \(offsets.count + 1)\n0000000000 65535 f \n")
        for offset in offsets { add(String(format: "%010d 00000 n \n", offset)) }
        add("trailer\n<< /Size \(offsets.count + 1) /Root 1 0 R >>\nstartxref\n\(table)\n%%EOF\n")
        return out
    }

    private static func points(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

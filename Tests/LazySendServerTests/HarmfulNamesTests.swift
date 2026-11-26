import Foundation
import XCTest
@testable import LazySendServer

// Reads testdata/harmful-names.json, shared with the Windows and Android tests.
final class HarmfulNamesTests: XCTestCase {
    private func load() throws -> [String: Any] {
        var folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: folder.appendingPathComponent("testdata/harmful-names.json").path) {
            let parent = folder.deletingLastPathComponent()
            guard parent != folder else { throw CocoaError(.fileNoSuchFile) }
            folder = parent
        }
        let data = try Data(contentsOf: folder.appendingPathComponent("testdata/harmful-names.json"))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testEveryHarmfulNameComesOutSafe() throws {
        let data = try load()
        let maxBytes = try XCTUnwrap(data["maxFileNameBytes"] as? Int)
        let cases = try XCTUnwrap(data["names"] as? [[String: Any]])
        var failures: [String] = []
        for item in cases {
            let name = try XCTUnwrap(item["name"] as? String)
            let clean = FileNames.clean(name)
            let label = "\"\(name)\" became \"\(clean)\""
            if clean.isEmpty || clean.utf8.count > maxBytes { failures.append("\(label): empty or too long") }
            if clean.allSatisfy({ $0 == "." }) { failures.append("\(label): only dots") }
            if clean.unicodeScalars.contains(where: { "/\\:".unicodeScalars.contains($0) || $0.value < 0x20 || (0x7F...0x9F).contains($0.value) }) {
                failures.append("\(label): a separator or control character is left")
            }
            if clean.hasSuffix(".") || clean.hasSuffix(" ") { failures.append("\(label): ends with a dot or space") }
            if let keep = item["keep"] as? String, !clean.hasSuffix(keep) { failures.append("\(label): lost the extension") }
            if let exact = item["exact"] as? String, clean != exact { failures.append("\(label): expected \(exact)") }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }
}

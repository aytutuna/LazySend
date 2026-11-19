import CoreGraphics
import Foundation
import ImageIO
@testable import LazySendScan

// The SmartDoc frames in Fixtures/Pages (found next to this file, on the Mac and in the iOS Simulator alike) and their
// corners.json.

/// A photo among the page fixtures and its page's corners in its pixels, named by position (`Quad.fromCorners`).
struct PagePhoto {
    let file: String
    let width: Int
    let height: Int
    let truth: Quad
}

struct PageFixtureError: Error, CustomStringConvertible {
    let description: String
}

enum PageFixtures {
    /// Tests/LazySendScanModelTests/Fixtures/Pages in the repository.
    static var folder: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // LazySendScanModelTests
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("Pages", isDirectory: true)
    }

    private struct Entry: Decodable {
        let file: String
        let width: Int
        let height: Int
        let topLeft: [Double]
        let topRight: [Double]
        let bottomRight: [Double]
        let bottomLeft: [Double]
    }

    /// The photos listed in corners.json, in its order.
    static func all() throws -> [PagePhoto] {
        let data: Data = try Data(contentsOf: folder.appendingPathComponent("corners.json"))
        let entries: [Entry] = try JSONDecoder().decode([Entry].self, from: data)
        var photos: [PagePhoto] = []
        for entry in entries {
            var corners: [CGPoint] = []
            for pair in [entry.topLeft, entry.topRight, entry.bottomRight, entry.bottomLeft] {
                guard pair.count == 2 else { throw PageFixtureError(description: "\(entry.file): a corner is not x, y") }
                corners.append(CGPoint(x: pair[0], y: pair[1]))
            }
            photos.append(PagePhoto(file: entry.file, width: entry.width, height: entry.height,
                                    truth: Quad.fromCorners(corners)))
        }
        return photos
    }

    /// The photo's pixels, read with ImageIO.
    static func read(_ photo: PagePhoto) throws -> RgbaImage {
        let url: URL = folder.appendingPathComponent(photo.file)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let pixels = RgbaImage(cgImage: image) else {
            throw PageFixtureError(description: "\(photo.file) could not be read")
        }
        return pixels
    }
}

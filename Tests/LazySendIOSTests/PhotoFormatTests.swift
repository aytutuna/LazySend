#if os(iOS)
import ImageIO
import LazySendKit
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import LazySendIOS

@MainActor
final class PhotoFormatTests: XCTestCase {
    private func cgImage(width: Int = 8, height: Int = 4) -> CGImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return format
        }())
        let image = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return image.cgImage!
    }

    private func encoded(_ type: UTType, orientation: Int? = nil) -> Data? {
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        var properties: [CFString: Any] = [:]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, cgImage(), properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }

    private func write(_ name: String, _ data: Data) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("format-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func isPNG(_ data: Data) -> Bool { data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]) }

    private func isJPEG(_ data: Data) -> Bool { data.prefix(2) == Data([0xFF, 0xD8]) }

    func testAJpegBecomesAPngAndTheOriginalGoes() throws {
        let url = try write("Photo 1.jpg", try XCTUnwrap(encoded(.jpeg)))
        let made = PhotoFormatting.prepare(url, as: .png)
        XCTAssertEqual(made.lastPathComponent, "Photo 1.png")
        XCTAssertTrue(isPNG(try Data(contentsOf: made)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testAPngBecomesAJpegWithTheNameChanged() throws {
        let url = try write("shot.png", try XCTUnwrap(encoded(.png)))
        let made = PhotoFormatting.prepare(url, as: .jpeg)
        XCTAssertEqual(made.lastPathComponent, "shot.jpg")
        XCTAssertTrue(isJPEG(try Data(contentsOf: made)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testAHeicBecomesAJpeg() throws {
        guard let heic = encoded(.heic) else { throw XCTSkip("this Simulator does not write HEIC") }
        let url = try write("IMG_0001.HEIC", heic)
        let made = PhotoFormatting.prepare(url, as: .jpeg)
        XCTAssertEqual(made.lastPathComponent, "IMG_0001.jpg")
        XCTAssertTrue(isJPEG(try Data(contentsOf: made)))
    }

    func testOriginalAndAPictureAlreadyInTheFormatAreLeftAlone() throws {
        let jpeg = try XCTUnwrap(encoded(.jpeg))
        let url = try write("a.jpg", jpeg)
        XCTAssertEqual(PhotoFormatting.prepare(url, as: .original), url)
        XCTAssertEqual(PhotoFormatting.prepare(url, as: .jpeg), url)
        XCTAssertEqual(try Data(contentsOf: url), jpeg)
    }

    func testGifsVideosAndOtherFilesAreNeverConverted() throws {
        for name in ["loop.gif", "clip.mov", "film.mp4", "notes.txt", "report.pdf"] {
            let url = try write(name, Data("not converted".utf8))
            XCTAssertFalse(PhotoFormatting.isConvertible(url), name)
            XCTAssertEqual(PhotoFormatting.prepare(url, as: .png), url, name)
            XCTAssertEqual(PhotoFormatting.prepare(url, as: .jpeg), url, name)
            XCTAssertEqual(try Data(contentsOf: url), Data("not converted".utf8), name)
        }
    }

    func testRawAndAvifPicturesAreNeverConverted() throws {
        for name in ["IMG_0001.dng", "IMG_0002.DNG", "photo.avif"] {
            let url = try write(name, try XCTUnwrap(encoded(.jpeg)))
            XCTAssertFalse(PhotoFormatting.isConvertible(url), name)
            XCTAssertEqual(PhotoFormatting.prepare(url, as: .png), url, name)
        }
    }

    func testAPictureOfSeveralFramesIsNotConverted() throws {
        let out = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 2, nil))
        CGImageDestinationAddImage(destination, cgImage(), nil)
        CGImageDestinationAddImage(destination, cgImage(), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let url = try write("moving.png", out as Data)
        let frames = CGImageSourceCreateWithURL(url as CFURL, nil).map { CGImageSourceGetCount($0) } ?? 0
        XCTAssertEqual(PhotoFormatting.isConvertible(url), frames == 1)
    }

    func testAPictureThatCannotBeReadIsLeftAlone() throws {
        let url = try write("broken.jpg", Data("not a picture".utf8))
        XCTAssertEqual(PhotoFormatting.prepare(url, as: .png), url)
    }

    func testAPngMadeFromAShotHasItsTurnInThePixels() throws {
        let turned = try XCTUnwrap(encoded(.jpeg, orientation: 6))
        let png = try XCTUnwrap(PhotoFormatting.png(fromPhoto: turned))
        XCTAssertTrue(isPNG(png))
        let image = try XCTUnwrap(UIImage(data: png))
        XCTAssertEqual(Int(image.size.width * image.scale), 4)
        XCTAssertEqual(Int(image.size.height * image.scale), 8)
    }

    func testTheFormatIsKeptAcrossLaunches() {
        let env = AppEnvironment.temporary()
        let model = AppModel(env: env)
        XCTAssertEqual(model.photoFormat, .jpeg)
        model.setPhotoFormat(.png)
        XCTAssertEqual(AppModel(env: env).photoFormat, .png)
    }

    func testFilesListsFilesAndGalleriesAndClipboardListsTextsAndLinks() {
        func entry(_ id: String, _ kind: EntryKind, _ direction: Direction = .sent) -> TimelineEntry {
            TimelineEntry(id: id, direction: direction, kind: kind, pcName: "Office PC", title: id)
        }
        let all = [entry("a", .text), entry("b", .file), entry("c", .link, .received), entry("d", .gallery), entry("e", .file, .received),
                   entry("f", .text, .received)]
        XCTAssertEqual(EntryFilter.files(all).map(\.id), ["b", "d", "e"])
        XCTAssertEqual(EntryFilter.texts(all).map(\.id), ["a", "c", "f"])
    }
}
#endif

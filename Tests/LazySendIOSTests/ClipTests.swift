#if os(iOS)
import LazySendKit
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import LazySendIOS
@testable import LazySendServer

private final class Clips: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ClipContent] = []

    func add(_ item: ClipContent) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }

    var all: [ClipContent] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

@MainActor
final class ClipTests: XCTestCase {
    private func temp(_ name: String, _ data: Data) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("clip-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func png() throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4))
        return renderer.pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }

    func testPhotoAndClipboardNamesCarryTheTime() {
        var parts = DateComponents()
        parts.year = 2026
        parts.month = 11
        parts.day = 18
        parts.hour = 14
        parts.minute = 3
        parts.second = 22
        let date = Calendar(identifier: .gregorian).date(from: parts) ?? Date()
        XCTAssertEqual(ClipName.photo(date), "Photo 2026-11-18 14.03.22.jpg")
        XCTAssertEqual(ClipName.clipboard(date), "Clipboard 2026-11-18 14.03.22.png")
        XCTAssertEqual(ClipName.clipboard(date, ext: "jpg"), "Clipboard 2026-11-18 14.03.22.jpg")
    }

    func testTextAndLinksAreChosenByKind() {
        XCTAssertEqual(ClipContent.of(kind: "text", text: "hello", url: nil, file: nil), .text("hello"))
        XCTAssertNil(ClipContent.of(kind: "text", text: "", url: nil, file: nil))
        XCTAssertEqual(ClipContent.of(kind: "link", text: nil, url: "https://alazy.app/send/", file: nil), .link(URL(string: "https://alazy.app/send/")!))
        XCTAssertNil(ClipContent.of(kind: "link", text: nil, url: nil, file: nil))
        XCTAssertNil(ClipContent.of(kind: "gallery", text: "x", url: nil, file: nil))
    }

    func testPicturesAreImagesAndOtherFilesKeepTheirType() throws {
        let picture = try temp("shot.png", try png())
        XCTAssertEqual(ClipContent.of(kind: "file", text: nil, url: nil, file: picture), .image(picture, .png))
        let note = try temp("notes.txt", Data("hello".utf8))
        XCTAssertEqual(ClipContent.of(kind: "file", text: nil, url: nil, file: note), .file(note, .plainText))
        let unknown = try temp("blob.zzqq", Data("x".utf8))
        XCTAssertEqual(ClipContent.of(kind: "file", text: nil, url: nil, file: unknown), .file(unknown, .data))
        XCTAssertNil(ClipContent.of(kind: "file", text: nil, url: nil, file: nil))
        XCTAssertNil(ClipContent.of(kind: "file", text: nil, url: nil, file: note.appendingPathExtension("gone")))
    }

    func testAFileOverTheLimitIsNotChosen() throws {
        let big = try temp("big.bin", Data(count: ClipContent.maxFileBytes + 1))
        XCTAssertNil(ClipContent.of(kind: "file", text: nil, url: nil, file: big))
        let edge = try temp("edge.bin", Data(count: ClipContent.maxFileBytes))
        XCTAssertNotNil(ClipContent.of(kind: "file", text: nil, url: nil, file: edge))
    }

    func testWritingPutsEachKindOnThePasteboard() throws {
        let board = UIPasteboard(name: UIPasteboard.Name("lazysend.tests." + UUID().uuidString), create: true)!
        ClipContent.text("hello").write(to: board)
        XCTAssertEqual(board.string, "hello")
        ClipContent.link(URL(string: "https://alazy.app")!).write(to: board)
        XCTAssertEqual(board.url, URL(string: "https://alazy.app"))
        let data = try png()
        ClipContent.image(try temp("shot.png", data), .png).write(to: board)
        XCTAssertEqual(board.data(forPasteboardType: UTType.png.identifier), data)
        ClipContent.file(try temp("notes.txt", Data("hi".utf8)), .plainText).write(to: board)
        XCTAssertEqual(board.data(forPasteboardType: UTType.plainText.identifier), Data("hi".utf8))
    }

    private func makeHandler(_ clips: Clips) -> (ReceiveHandler, URL) {
        let env = AppEnvironment.temporary()
        let timeline = Timeline(file: env.support.appendingPathComponent("timeline.json"))
        let handler = ReceiveHandler(pcId: "office-pc-0001", pcName: "Office PC", timeline: timeline, folder: env.documents, notifier: .silent,
                                     defaults: env.defaults, saved: SavedAssets(file: env.support.appendingPathComponent("saved-assets.json")),
                                     gallery: GalleryIndex(directory: env.support.appendingPathComponent("guest-index")),
                                     onClip: { clips.add($0) })
        return (handler, env.documents)
    }

    func testAGuestPutsAClipNoteOnThePasteboardButNotAPlainOne() async {
        let clips = Clips()
        let (handler, _) = makeHandler(clips)
        await handler.receiveNote(OutboxEntry(id: "note-0001", kind: "text", text: "plain"))
        XCTAssertTrue(clips.all.isEmpty)
        await handler.receiveNote(OutboxEntry(id: "note-0002", kind: "text", text: "copy me", clip: true))
        await handler.receiveNote(OutboxEntry(id: "note-0003", kind: "link", url: "https://alazy.app", clip: true))
        XCTAssertEqual(clips.all, [.text("copy me"), .link(URL(string: "https://alazy.app")!)])
    }

    func testAGuestPutsAClipFileOnThePasteboardOnlyWhenItArrivesWhole() async throws {
        let clips = Clips()
        let (handler, folder) = makeHandler(clips)
        let item = OutboxEntry(id: "item-0001", kind: "file", name: "shot.png", size: 4, mime: "image/png", clip: true)
        _ = try await handler.prepareFile(item)
        XCTAssertTrue(clips.all.isEmpty)
        try handler.write(Data("abcd".utf8), for: item)
        try await handler.finishFile(item)
        XCTAssertEqual(clips.all, [.image(folder.appendingPathComponent("shot.png"), .png)])
    }

    func testAFileThatWentOnFromAnEarlierPartDoesNotTakeThePasteboard() async throws {
        let clips = Clips()
        let (handler, folder) = makeHandler(clips)
        let item = OutboxEntry(id: "item-0001", kind: "file", name: "notes.txt", size: 8, mime: "text/plain", clip: true)
        _ = try await handler.prepareFile(item)
        try handler.write(Data("abcd".utf8), for: item)
        await handler.pause(item)
        let have = try await handler.prepareFile(item)
        XCTAssertEqual(have, 4)
        try handler.write(Data("efgh".utf8), for: item)
        try await handler.finishFile(item)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("notes.txt").path))
        XCTAssertTrue(clips.all.isEmpty)
    }
}
#endif

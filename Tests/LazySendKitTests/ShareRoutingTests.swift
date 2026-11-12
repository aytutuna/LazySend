import XCTest
@testable import LazySendKit

final class ShareRoutingTests: XCTestCase {
    func testPlainTextIsText() {
        XCTAssertEqual(ShareRouting.kind(of: ["public.utf8-plain-text", "public.plain-text"]), .text)
    }

    func testAWebPageIsALinkEvenWithItsTitleAsText() {
        XCTAssertEqual(ShareRouting.kind(of: ["public.url", "public.utf8-plain-text"]), .link)
    }

    func testFilesFromTheFilesAppAreFiles() {
        XCTAssertEqual(ShareRouting.kind(of: ["com.adobe.pdf", "public.file-url"]), .file)
        XCTAssertEqual(ShareRouting.kind(of: ["public.file-url", "public.plain-text"]), .file)
    }

    func testPhotosAndMoviesAreFilesEvenWithACaption() {
        XCTAssertEqual(ShareRouting.kind(of: ["public.heic", "public.jpeg"]), .file)
        XCTAssertEqual(ShareRouting.kind(of: ["public.png", "public.plain-text"]), .file)
        XCTAssertEqual(ShareRouting.kind(of: ["com.apple.quicktime-movie"]), .file)
    }

    func testUnknownTypesAreFiles() {
        XCTAssertEqual(ShareRouting.kind(of: ["dyn.ah62d4rv4ge81k5pc"]), .file)
        XCTAssertEqual(ShareRouting.kind(of: []), .file)
    }

    func testSmallThingsGoDirectlyAndBigOnesWait() {
        XCTAssertTrue(ShareRouting.sendsDirectly(sizes: []))
        XCTAssertTrue(ShareRouting.sendsDirectly(sizes: [0, 4 * 1024 * 1024, 4 * 1024 * 1024]))
        XCTAssertFalse(ShareRouting.sendsDirectly(sizes: [4 * 1024 * 1024, 4 * 1024 * 1024 + 1]))
        XCTAssertFalse(ShareRouting.sendsDirectly(sizes: [200_000_000]))
    }
}

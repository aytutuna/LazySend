#if os(iOS)
import CoreGraphics
import ImageIO
import LazySendKit
import LazySendScan
import XCTest
@testable import LazySendIOS

@MainActor
final class ScanModelTests: XCTestCase {
    private func photo(_ shade: UInt8 = 120) -> RgbaImage {
        RgbaImage.filled(width: 120, height: 160, r: shade, g: shade, b: shade)
    }

    private func page(_ shade: UInt8 = 120, id: UUID = UUID()) throws -> ScanPage {
        try XCTUnwrap(PagePipeline.wholePage(photo: photo(shade), source: Data([shade]), filter: .original, id: id))
    }

    private func model(with shades: [UInt8]) throws -> ScanModel {
        let scan = ScanModel()
        for shade in shades { scan.add(try page(shade)) }
        return scan
    }

    /// The work of an answer runs off the main thread.
    private func wait(for condition: @MainActor () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    func testPagesAreShownInTheOrderTheyWereTaken() throws {
        let scan = try model(with: [10, 20, 30])
        XCTAssertEqual(scan.pages.map(\.source), [Data([10]), Data([20]), Data([30])])
    }

    func testAPageMovesEarlierAndLaterAndStopsAtTheEnds() throws {
        let scan = try model(with: [10, 20, 30])
        let second = scan.pages[1].id
        scan.shift(second, by: -1)
        XCTAssertEqual(scan.pages.map(\.source), [Data([20]), Data([10]), Data([30])])
        scan.shift(second, by: -1)
        XCTAssertEqual(scan.pages.map(\.source), [Data([20]), Data([10]), Data([30])])
        scan.shift(second, by: 1)
        scan.shift(second, by: 1)
        scan.shift(second, by: 1)
        XCTAssertEqual(scan.pages.map(\.source), [Data([10]), Data([30]), Data([20])])
    }

    func testPagesCanBeDraggedAndDeleted() throws {
        let scan = try model(with: [10, 20, 30])
        scan.move(from: IndexSet(integer: 0), to: 3)
        XCTAssertEqual(scan.pages.map(\.source), [Data([20]), Data([30]), Data([10])])
        scan.delete(scan.pages[1].id)
        XCTAssertEqual(scan.pages.map(\.source), [Data([20]), Data([10])])
    }

    func testAPageCutAgainKeepsItsPlaceAndTakesTheNewCorners() async throws {
        let scan = try model(with: [10, 20, 30])
        let target = scan.pages[1]
        let corners = Quad(topLeft: CGPoint(x: 10, y: 10), topRight: CGPoint(x: 100, y: 14),
                           bottomRight: CGPoint(x: 96, y: 150), bottomLeft: CGPoint(x: 12, y: 140))
        let request = CornerRequest(photo: photo(20), source: target.source, corners: target.corners, filter: .original, replacing: target.id)
        scan.pageEditing = request
        scan.answer(request, .use(corners))
        XCTAssertNil(scan.pageEditing)
        await wait { scan.pages[1].corners == corners }
        XCTAssertEqual(scan.pages.count, 3)
        XCTAssertEqual(scan.pages[1].id, target.id)
        XCTAssertEqual(scan.pages[1].corners, corners)
        XCTAssertNotEqual(scan.pages[1].width, target.width)
    }

    func testUseWholePhotoMakesTheWholePhotoThePage() async throws {
        let scan = ScanModel()
        let request = CornerRequest(photo: photo(), source: Data([1]), corners: PageFinder.startCorners(width: 120, height: 160),
                                    filter: .original, replacing: nil)
        scan.shotEditing = request
        scan.answer(request, .whole)
        await wait { !scan.pages.isEmpty }
        XCTAssertNil(scan.shotEditing)
        XCTAssertEqual(scan.pages.count, 1)
        XCTAssertEqual(scan.pages[0].width, 120)
        XCTAssertEqual(scan.pages[0].height, 160)
    }

    func testALeftOutShotAddsNoPage() throws {
        let scan = try model(with: [10])
        let request = CornerRequest(photo: photo(), source: Data([1]), corners: PageFinder.startCorners(width: 120, height: 160),
                                    filter: .original, replacing: nil)
        scan.shotEditing = request
        scan.answer(request, .cancel)
        XCTAssertNil(scan.shotEditing)
        XCTAssertEqual(scan.pages.count, 1)
    }

    func testSendingTheScanEmptiesThePagesAndKeepsTheFileName() throws {
        let scan = try model(with: [10, 20])
        scan.sent("Scan 2026-11-18 14.05.pdf")
        XCTAssertTrue(scan.pages.isEmpty)
        XCTAssertEqual(scan.lastName, "Scan 2026-11-18 14.05.pdf")
        // The next page it takes clears the line about the last scan.
        scan.add(try page())
        XCTAssertNil(scan.lastName)
    }

    func testFramesFollowOnlyInScanModeOnTheActiveCameraTabWithNothingOverIt() {
        XCTAssertTrue(ScanModel.follows(active: true, scanning: true, covered: false, cameraReady: true))
        // Another tab or an app that is not active: the camera is stopped, so the frames are too.
        XCTAssertFalse(ScanModel.follows(active: false, scanning: true, covered: false, cameraReady: true))
        // Photo mode takes no frames.
        XCTAssertFalse(ScanModel.follows(active: true, scanning: false, covered: false, cameraReady: true))
        // The pages sheet or the corner editor over it.
        XCTAssertFalse(ScanModel.follows(active: true, scanning: true, covered: true, cameraReady: true))
        // No camera, no permission, an interruption.
        XCTAssertFalse(ScanModel.follows(active: true, scanning: true, covered: false, cameraReady: false))
    }

    func testThePagesFilterIsKeptForALaterCut() throws {
        let scan = ScanModel()
        let gray = try XCTUnwrap(PagePipeline.wholePage(photo: photo(), source: Data(), filter: .grayscale))
        scan.add(gray)
        XCTAssertEqual(scan.pages[0].filter, .grayscale)
        XCTAssertTrue(scan.pages[0].gray)
        XCTAssertNotNil(scan.thumbnail(scan.pages[0]))
    }
}

@MainActor
final class ScanSendTests: XCTestCase {
    private func pairedModel() throws -> (AppModel, AppModel.Target) {
        let model = AppModel(env: .temporary())
        let pc = PairedPc(id: "office-pc-1", name: "Office PC", fingerprint: Base64Url.encode(Data(repeating: 3, count: 32)),
                          addresses: [], port: 52734)
        try model.store.put(pc, secret: "secret")
        model.refreshPcs()
        return (model, AppModel.Target(id: pc.id, name: pc.name, phone: false))
    }

    private func page(_ shade: UInt8) throws -> ScanPage {
        let photo = RgbaImage.filled(width: 60, height: 80, r: shade, g: shade, b: shade)
        return try XCTUnwrap(PagePipeline.wholePage(photo: photo, source: Data(), filter: .original))
    }

    func testOnePageGoesAsAnImageForTheClipboard() async throws {
        let (model, target) = try pairedModel()
        let one = try page(100)
        let name = try await model.sendScan([one], to: target)
        XCTAssertTrue(name.hasPrefix("Scan 2"), name)
        XCTAssertTrue(name.hasSuffix(".jpg"), name)
        await model.waitForSends()
        let entry = try XCTUnwrap(model.timeline.entries.first { $0.title == name })
        XCTAssertEqual(entry.kind, .file)
        XCTAssertEqual(entry.direction, .sent)
        XCTAssertEqual(entry.clip, true)
    }

    func testSeveralPagesGoAsOnePdfThatIsNotPutOnTheClipboard() async throws {
        let (model, target) = try pairedModel()
        let name = try await model.sendScan([try page(100), try page(200)], to: target)
        XCTAssertTrue(name.hasSuffix(".pdf"), name)
        await model.waitForSends()
        let entry = try XCTUnwrap(model.timeline.entries.first { $0.title == name })
        XCTAssertEqual(entry.kind, .file)
        XCTAssertNotEqual(entry.clip, true)
    }

    func testASecondScanInTheSameMinuteGetsAnotherName() async throws {
        let (model, target) = try pairedModel()
        let first = try await model.sendScan([try page(100)], to: target)
        let second = try await model.sendScan([try page(110)], to: target)
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(second.hasPrefix("Scan 2"), second)
    }

    func testAScanForADeviceThatIsGoneIsRefused() async throws {
        let model = AppModel(env: .temporary())
        do {
            _ = try await model.sendScan([try page(100)], to: AppModel.Target(id: "gone", name: "Gone", phone: false))
            XCTFail("the send should have been refused")
        } catch {
            XCTAssertEqual(error as? HostSendError, .notPaired)
        }
        XCTAssertTrue(model.timeline.entries.isEmpty)
    }

    func testScanNamesAreDatedToTheMinute() {
        var parts = DateComponents()
        parts.year = 2026
        parts.month = 11
        parts.day = 18
        parts.hour = 14
        parts.minute = 5
        parts.second = 41
        let date = Calendar(identifier: .gregorian).date(from: parts) ?? Date()
        XCTAssertEqual(ClipName.scan(date, ext: "pdf"), "Scan 2026-11-18 14.05.pdf")
        XCTAssertEqual(ClipName.scan(date, milliseconds: true, ext: "jpg"), "Scan 2026-11-18 14.05.41.000.jpg")
    }
}
#endif

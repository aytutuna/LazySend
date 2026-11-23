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
        try XCTUnwrap(PagePipeline.wholePage(photo: photo(shade), filter: .original, id: id))
    }

    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("scan-model-" + UUID().uuidString)
    }

    private func model(with shades: [UInt8], store: ScanPageStore? = nil) throws -> ScanModel {
        let scan = ScanModel(store: store)
        for shade in shades { scan.add(try page(shade), source: Data([shade])) }
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
        let store = ScanPageStore(folder: folder())
        let kept = try model(with: [10, 20, 30], store: store)
        XCTAssertEqual(store.load().map(\.id), kept.pages.map(\.id))
        XCTAssertEqual(kept.pages.compactMap { store.source(of: $0.id) }, [Data([10]), Data([20]), Data([30])])
    }

    func testAPageMovesEarlierAndLaterAndStopsAtTheEnds() throws {
        let scan = try model(with: [10, 20, 30])
        let ids = scan.pages.map(\.id)
        let second = ids[1]
        scan.shift(second, by: -1)
        XCTAssertEqual(scan.pages.map(\.id), [ids[1], ids[0], ids[2]])
        scan.shift(second, by: -1)
        XCTAssertEqual(scan.pages.map(\.id), [ids[1], ids[0], ids[2]])
        scan.shift(second, by: 1)
        scan.shift(second, by: 1)
        scan.shift(second, by: 1)
        XCTAssertEqual(scan.pages.map(\.id), [ids[0], ids[2], ids[1]])
    }

    func testPagesCanBeDraggedAndDeleted() throws {
        let scan = try model(with: [10, 20, 30])
        let ids = scan.pages.map(\.id)
        scan.move(from: IndexSet(integer: 0), to: 3)
        XCTAssertEqual(scan.pages.map(\.id), [ids[1], ids[2], ids[0]])
        scan.delete(scan.pages[1].id)
        XCTAssertEqual(scan.pages.map(\.id), [ids[1], ids[0]])
    }

    func testPagesComeBackInOrderWhenTheModelIsMadeAgain() throws {
        let store = ScanPageStore(folder: folder())
        let scan = try model(with: [10, 20, 30], store: store)
        let ids = scan.pages.map(\.id)
        scan.shift(ids[0], by: 1)
        let again = ScanModel(store: store)
        XCTAssertEqual(again.pages.map(\.id), [ids[1], ids[0], ids[2]])
        XCTAssertEqual(again.pages[0].jpeg, scan.pages[0].jpeg)
        XCTAssertNotNil(again.thumbnail(again.pages[0]))
    }

    func testADeletedPageStaysGoneAfterARelaunch() throws {
        let store = ScanPageStore(folder: folder())
        let scan = try model(with: [10, 20, 30], store: store)
        let ids = scan.pages.map(\.id)
        scan.delete(ids[1])
        XCTAssertNil(store.source(of: ids[1]))
        XCTAssertEqual(ScanModel(store: store).pages.map(\.id), [ids[0], ids[2]])
    }

    func testADraggedOrderIsKeptAfterARelaunch() throws {
        let store = ScanPageStore(folder: folder())
        let scan = try model(with: [10, 20, 30], store: store)
        let ids = scan.pages.map(\.id)
        scan.move(from: IndexSet(integer: 0), to: 3)
        XCTAssertEqual(ScanModel(store: store).pages.map(\.id), [ids[1], ids[2], ids[0]])
    }

    func testARecutReadsThePhotoFromTheStoreAndKeepsItsPlace() async throws {
        let store = ScanPageStore(folder: folder())
        let scan = ScanModel(store: store)
        let photo = photo(20)
        let page = try XCTUnwrap(PagePipeline.wholePage(photo: photo, filter: .original))
        scan.add(page, source: try XCTUnwrap(JpegEncoder.encode(photo, gray: false)))
        let again = ScanModel(store: store)
        again.recut(again.pages[0])
        await wait { again.pageEditing != nil }
        let request = try XCTUnwrap(again.pageEditing)
        XCTAssertEqual(request.replacing, page.id)
        XCTAssertEqual(request.photo.width, 120)
        XCTAssertEqual(request.photo.height, 160)
    }

    func testAPageCutAgainKeepsItsPlaceAndTakesTheNewCorners() async throws {
        let scan = try model(with: [10, 20, 30])
        let target = scan.pages[1]
        let corners = Quad(topLeft: CGPoint(x: 10, y: 10), topRight: CGPoint(x: 100, y: 14),
                           bottomRight: CGPoint(x: 96, y: 150), bottomLeft: CGPoint(x: 12, y: 140))
        let request = CornerRequest(photo: photo(20), source: Data([20]), corners: target.corners, filter: .original, replacing: target.id)
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
        scan.add(try page(), source: Data([1]))
        XCTAssertNil(scan.lastName)
    }

    func testSendingTheScanClearsTheStore() throws {
        let store = ScanPageStore(folder: folder())
        let scan = try model(with: [10, 20], store: store)
        let ids = scan.pages.map(\.id)
        scan.sent("Scan.pdf")
        XCTAssertTrue(store.load().isEmpty)
        XCTAssertNil(store.source(of: ids[0]))
        XCTAssertTrue(ScanModel(store: store).pages.isEmpty)
    }

    func testTheCameraTakesFramesOnlyInScanModeOnTheActiveCameraTab() {
        XCTAssertTrue(ScanModel.attaches(active: true, scanning: true, cameraReady: true))
        // Another tab or an app that is not active: the camera is stopped, so the frames are too.
        XCTAssertFalse(ScanModel.attaches(active: false, scanning: true, cameraReady: true))
        // Photo mode takes no frames.
        XCTAssertFalse(ScanModel.attaches(active: true, scanning: false, cameraReady: true))
        // No camera, no permission, an interruption.
        XCTAssertFalse(ScanModel.attaches(active: true, scanning: true, cameraReady: false))
    }

    func testASheetOrTheEditorOnlyStopsTheFrames() {
        XCTAssertTrue(ScanModel.flows(attached: true, covered: false))
        XCTAssertFalse(ScanModel.flows(attached: true, covered: true))
        XCTAssertFalse(ScanModel.flows(attached: false, covered: false))
    }

    private func update(shouldCapture: Bool) -> LiveQuadUpdate {
        LiveQuadUpdate(outline: nil, state: .captured, progress: 1, timestampMs: 0, shouldCapture: shouldCapture)
    }

    func testADecisionThatCannotBeActedOnIsForgottenSoThePageCanBeDecidedOnAgain() {
        // Taken when Auto is on and a photo can be taken.
        XCTAssertEqual(ScanModel.autoShot(update(shouldCapture: true), auto: true, canShoot: true, inGrace: false), .take)
        // A shot being made, no device, or the wait after the camera started: forgotten, not left as taken.
        XCTAssertEqual(ScanModel.autoShot(update(shouldCapture: true), auto: true, canShoot: false, inGrace: false), .forget)
        XCTAssertEqual(ScanModel.autoShot(update(shouldCapture: true), auto: true, canShoot: true, inGrace: true), .forget)
        // Auto off: the decision stands for when it is turned on. No decision: nothing.
        XCTAssertEqual(ScanModel.autoShot(update(shouldCapture: true), auto: false, canShoot: true, inGrace: false), .none)
        XCTAssertEqual(ScanModel.autoShot(update(shouldCapture: false), auto: true, canShoot: false, inGrace: false), .none)
    }

    func testThePagesFilterIsKeptForALaterCut() throws {
        let scan = ScanModel()
        let gray = try XCTUnwrap(PagePipeline.wholePage(photo: photo(), filter: .grayscale))
        scan.add(gray, source: Data())
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
        return try XCTUnwrap(PagePipeline.wholePage(photo: photo, filter: .original))
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

#if os(iOS)
import CoreMedia
import XCTest
@testable import LazySendIOS

final class CameraSessionTests: XCTestCase {
    private func size(_ width: Int32, _ height: Int32) -> CMVideoDimensions {
        CMVideoDimensions(width: width, height: height)
    }

    func testThePhotoSizeIsTheWantedOneWhenTheFormatListsIt() {
        let listed = [size(1920, 1080), size(4032, 3024), size(8064, 6048)]
        let picked = CameraSession.photoSize(from: listed, wanted: size(4032, 3024))
        XCTAssertEqual(picked?.width, 4032)
        XCTAssertEqual(picked?.height, 3024)
    }

    func testThePhotoSizeIsTheLargestBelowTheWantedOneWhenItIsNotListed() {
        let picked = CameraSession.photoSize(from: [size(1920, 1080), size(3264, 2448), size(8064, 6048)], wanted: size(4032, 3024))
        XCTAssertEqual(picked?.width, 3264)
    }

    func testThereIsNoPhotoSizeWhenEveryOneListedIsLarger() {
        XCTAssertNil(CameraSession.photoSize(from: [size(8064, 6048)], wanted: size(4032, 3024)))
        XCTAssertNil(CameraSession.photoSize(from: [], wanted: size(4032, 3024)))
    }

    func testOnlyA48MegapixelSizeCountsAsHighResolution() {
        XCTAssertTrue(CameraSession.hasHighResolution([size(4032, 3024), size(8064, 6048)]))
        XCTAssertFalse(CameraSession.hasHighResolution([size(1920, 1080), size(4032, 3024)]))
        XCTAssertFalse(CameraSession.hasHighResolution([]))
    }

    func testZoomIsHeldToTheRangeOfTheFormat() {
        XCTAssertEqual(CameraSession.clampZoom(0.5, lowest: 1, highest: 15), 1)
        XCTAssertEqual(CameraSession.clampZoom(30, lowest: 1, highest: 15), 15)
        XCTAssertEqual(CameraSession.clampZoom(2, lowest: 1, highest: 15), 2)
        XCTAssertEqual(CameraSession.clampZoom(3, lowest: 2, highest: 1), 2)
    }
}
#endif

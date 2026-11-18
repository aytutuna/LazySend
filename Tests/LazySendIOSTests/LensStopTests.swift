#if os(iOS)
import XCTest
@testable import LazySendIOS

final class LensStopTests: XCTestCase {
    private func values(_ base: Double, _ lowest: Double, _ highest: Double, _ telephoto: Double?) -> [Double] {
        CameraModel.lensStops(base: base, lowest: lowest, highest: highest, telephoto: telephoto).map(\.value)
    }

    func testATripleCameraHasTheUltraWideTheMainLensAndTheTelephotoRatio() {
        XCTAssertEqual(values(2, 1, 20, 6), [0.5, 1, 3])
        XCTAssertEqual(values(2, 1, 20, 10), [0.5, 1, 5])
    }

    func testADualWideCameraHasNoTelephotoSoItGetsTheDoubledMainLens() {
        XCTAssertEqual(values(2, 1, 20, nil), [0.5, 1, 2])
    }

    func testAWideCameraAndTheFrontCameraHaveTheMainLensAndPossiblyTwice() {
        XCTAssertEqual(values(1, 1, 5, nil), [1, 2])
        XCTAssertEqual(values(1, 1, 1.5, nil), [1])
    }

    func testADualCameraShowsItsTelephotoAtItsRealRatio() {
        XCTAssertEqual(values(1, 1, 10, 2), [1, 2])
    }

    func testATelephotoBeyondTheZoomRangeIsLeftOut() {
        XCTAssertEqual(values(2, 1, 5, 6), [0.5, 1])
    }
}
#endif

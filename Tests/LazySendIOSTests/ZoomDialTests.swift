#if os(iOS)
import XCTest
@testable import LazySendIOS

final class ZoomDialTests: XCTestCase {
    private let wide: ClosedRange<Double> = 0.5...10

    func testTheWheelEndsAtTheFormatTopTenTimesOrFiveTimesTheLongestLens() {
        XCTAssertEqual(ZoomDial.range(stops: [0.5, 1, 3], top: 50), 0.5...10)
        XCTAssertEqual(ZoomDial.range(stops: [0.5, 1, 2], top: 50), 0.5...10)
        XCTAssertEqual(ZoomDial.range(stops: [1, 2], top: 50), 1...10)
        XCTAssertEqual(ZoomDial.range(stops: [1], top: 3), 1...3)
        XCTAssertEqual(ZoomDial.range(stops: [1], top: 50), 1...5)
    }

    func testEqualDragsDoubleTheZoomSoHalfToOneTravelsAsFarAsOneToTwo() {
        let step = ZoomDial.pointsPerDoubling
        XCTAssertEqual(ZoomDial.zoom(from: 0.5, dragged: -step, in: wide), 1, accuracy: 0.0001)
        XCTAssertEqual(ZoomDial.zoom(from: 1, dragged: -step, in: wide), 2, accuracy: 0.0001)
        XCTAssertEqual(ZoomDial.zoom(from: 2, dragged: step, in: wide), 1, accuracy: 0.0001)
    }

    func testTheDragStopsAtTheEndsOfTheWheel() {
        XCTAssertEqual(ZoomDial.zoom(from: 1, dragged: 1000, in: wide), 0.5)
        XCTAssertEqual(ZoomDial.zoom(from: 1, dragged: -1000, in: wide), 10)
    }

    func testTheOffsetOnTheWheelIsTheInverseOfTheDrag() {
        XCTAssertEqual(ZoomDial.offset(of: 2, from: 1), ZoomDial.pointsPerDoubling, accuracy: 0.001)
        XCTAssertEqual(ZoomDial.offset(of: 0.5, from: 1), -ZoomDial.pointsPerDoubling, accuracy: 0.001)
        XCTAssertEqual(ZoomDial.offset(of: 1.4, from: 1.4), 0)
    }

    func testAStopIsCrossedInEitherDirectionAndAlsoReached() {
        XCTAssertTrue(ZoomDial.crossesStop(from: 0.9, to: 1.1, stops: [0.5, 1, 2]))
        XCTAssertTrue(ZoomDial.crossesStop(from: 2.1, to: 1.9, stops: [0.5, 1, 2]))
        XCTAssertTrue(ZoomDial.crossesStop(from: 1.5, to: 2, stops: [0.5, 1, 2]))
        XCTAssertFalse(ZoomDial.crossesStop(from: 1.2, to: 1.8, stops: [0.5, 1, 2]))
        XCTAssertFalse(ZoomDial.crossesStop(from: 1, to: 1.2, stops: [0.5, 1, 2]))
    }

    func testVoiceOverStepsFromStopToStop() {
        let stops = [0.5, 1, 2, 5]
        XCTAssertEqual(ZoomDial.step(from: 1, stops: stops, up: true), 2)
        XCTAssertEqual(ZoomDial.step(from: 1.4, stops: stops, up: true), 2)
        XCTAssertEqual(ZoomDial.step(from: 1.4, stops: stops, up: false), 1)
        XCTAssertNil(ZoomDial.step(from: 5, stops: stops, up: true))
        XCTAssertNil(ZoomDial.step(from: 0.5, stops: stops, up: false))
    }

    func testTheActiveLabelHasTheTimesSignAndOneDecimalBetweenStops() {
        let us = Locale(identifier: "en_US")
        XCTAssertEqual(ZoomDial.label(1, active: true, locale: us), "1×")
        XCTAssertEqual(ZoomDial.label(1.4, active: true, locale: us), "1.4×")
        XCTAssertEqual(ZoomDial.label(0.5, active: true, locale: us), "0.5×")
        XCTAssertEqual(ZoomDial.label(1.96, active: true, locale: us), "2×")
    }

    func testAnInactiveLabelIsTheBareNumberWithoutALeadingZero() {
        let us = Locale(identifier: "en_US")
        XCTAssertEqual(ZoomDial.label(0.5, active: false, locale: us), ".5")
        XCTAssertEqual(ZoomDial.label(2, active: false, locale: us), "2")
        XCTAssertEqual(ZoomDial.label(5, active: false, locale: us), "5")
        XCTAssertEqual(ZoomDial.label(0.5, active: false, locale: Locale(identifier: "tr_TR")), ",5")
    }

    func testTheWheelHasMarksEveryTenthThenHalvesThenWholesAndEveryStop() {
        let marks = ZoomDial.ticks(in: 0.5...10, stops: [0.5, 1, 2, 3])
        XCTAssertEqual(marks.first, 0.5)
        XCTAssertEqual(marks.last, 10)
        XCTAssertTrue(marks.contains(1.3))
        XCTAssertTrue(marks.contains(2.5))
        XCTAssertFalse(marks.contains(2.3))
        XCTAssertTrue(marks.contains(7))
        XCTAssertEqual(marks, marks.sorted())
        XCTAssertEqual(marks.filter { abs($0 - 3) < 0.001 }.count, 1)
    }
}
#endif

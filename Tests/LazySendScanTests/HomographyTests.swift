import CoreGraphics
import XCTest
@testable import LazySendScan

private let tilted = Quad(topLeft: CGPoint(x: 105, y: 90), topRight: CGPoint(x: 258, y: 86),
                          bottomRight: CGPoint(x: 310, y: 418), bottomLeft: CGPoint(x: 48, y: 414))

private func assertNear(_ expected: CGPoint, _ actual: CGPoint, _ tolerance: Double,
                        file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertLessThanOrEqual(Quad.distance(expected, actual), tolerance,
                             "expected (\(expected.x), \(expected.y)), got (\(actual.x), \(actual.y))", file: file, line: line)
}

/// The corners of a w × h rectangle seen by a pinhole camera (focal f, centered on a cw × ch photo).
func cameraView(_ w: Double, _ h: Double, _ tiltX: Double, _ tiltY: Double, _ turn: Double, _ distance: Double,
                _ f: Double, _ cw: Double, _ ch: Double) -> Quad {
    let ax = tiltX * .pi / 180, ay = tiltY * .pi / 180, az = turn * .pi / 180
    var corners: [CGPoint] = []
    for (u, v) in [(-w / 2, -h / 2), (w / 2, -h / 2), (w / 2, h / 2), (-w / 2, h / 2)] {
        // Turn in the plane, tilt about x, then about y, then push away from the camera.
        let x = u * cos(az) - v * sin(az), y = u * sin(az) + v * cos(az), z = 0.0
        let y1 = y * cos(ax) - z * sin(ax), z1 = y * sin(ax) + z * cos(ax)
        let x2 = x * cos(ay) + z1 * sin(ay)
        var z2 = -x * sin(ay) + z1 * cos(ay)
        z2 += distance
        corners.append(CGPoint(x: cw / 2 + f * x2 / z2, y: ch / 2 + f * y1 / z2))
    }
    return Quad.fromCorners(corners)
}

final class HomographyTests: XCTestCase {
    func testSquareToQuadMapsTheUnitSquareOntoTheCorners() throws {
        let m = try XCTUnwrap(Homography.squareToQuad(tilted))
        assertNear(tilted.topLeft, m.map(CGPoint(x: 0, y: 0)), 1e-9)
        assertNear(tilted.topRight, m.map(CGPoint(x: 1, y: 0)), 1e-9)
        assertNear(tilted.bottomRight, m.map(CGPoint(x: 1, y: 1)), 1e-9)
        assertNear(tilted.bottomLeft, m.map(CGPoint(x: 0, y: 1)), 1e-9)
    }

    func testRectToQuadAndQuadToRectUndoEachOther() throws {
        let forward = try XCTUnwrap(Homography.rectToQuad(width: 210, height: 297, quad: tilted))
        let back = try XCTUnwrap(Homography.quadToRect(tilted, width: 210, height: 297))
        assertNear(tilted.bottomRight, forward.map(CGPoint(x: 210, y: 297)), 1e-9)
        let rng = TestPages.Rng(0x40A0_A001)
        for _ in 0..<50 {
            let px = Double(rng.below(2100)) / 10.0
            let py = Double(rng.below(2970)) / 10.0
            let p = CGPoint(x: px, y: py)
            assertNear(p, back.map(forward.map(p)), 1e-9)
        }
    }

    func testSolvingTheEquationsGivesTheClosedForm() throws {
        let closed = try XCTUnwrap(Homography.rectToQuad(width: 210, height: 297, quad: tilted))
        let solved = try XCTUnwrap(Homography.fromCorrespondences(
            [CGPoint(x: 0, y: 0), CGPoint(x: 210, y: 0), CGPoint(x: 210, y: 297), CGPoint(x: 0, y: 297)], tilted.corners))
        let rng = TestPages.Rng(0x40A0_A002)
        for _ in 0..<50 {
            let px = Double(rng.below(2100)) / 10.0
            let py = Double(rng.below(2970)) / 10.0
            let p = CGPoint(x: px, y: py)
            assertNear(closed.map(p), solved.map(p), 1e-7)
        }
    }

    func testInverseAndProductCompose() throws {
        let a = try XCTUnwrap(Homography.rectToQuad(width: 100, height: 100, quad: tilted))
        let b = Homography(1.5, 0.2, 10, -0.1, 0.9, 5, 0.0004, -0.0002, 1)
        let ab = Homography.multiply(a, b)
        let inverse = try XCTUnwrap(ab.inverse())
        let p = CGPoint(x: 37.5, y: 61.25)
        assertNear(a.map(b.map(p)), ab.map(p), 1e-9)
        assertNear(p, inverse.map(ab.map(p)), 1e-9)
        assertNear(p, Homography.multiply(ab, inverse).map(p), 1e-9)
        assertNear(p, Homography.identity.map(p), 0)
    }

    func testThreeCornersInLineHaveNoMap() {
        let flat = Quad(topLeft: CGPoint(x: 0, y: 0), topRight: CGPoint(x: 10, y: 0),
                        bottomRight: CGPoint(x: 20, y: 0), bottomLeft: CGPoint(x: 5, y: 10))
        XCTAssertNil(Homography.fromCorrespondences(flat.corners, tilted.corners))
        XCTAssertNil(Homography(1, 2, 3, 2, 4, 6, 0, 0, 1).inverse())
        XCTAssertNil(Homography.rectToQuad(width: 0, height: 10, quad: tilted))
    }

    func testCornersAreNamedClockwiseFromTheTopLeft() {
        // Counterclockwise, starting at the bottom-right corner.
        let q = Quad.fromCorners([tilted.bottomRight, tilted.topRight, tilted.topLeft, tilted.bottomLeft])
        XCTAssertEqual(tilted, q)
        XCTAssertTrue(q.isConvex)
        XCTAssertGreaterThan(q.signedArea, 0)
        // A diamond: the top edge is the higher of the two upper edges' midpoints, the left one on a tie.
        let diamond = Quad.fromCorners([CGPoint(x: 50, y: 0), CGPoint(x: 100, y: 50), CGPoint(x: 50, y: 100), CGPoint(x: 0, y: 50)])
        XCTAssertEqual(CGPoint(x: 0, y: 50), diamond.topLeft)
        XCTAssertEqual(CGPoint(x: 50, y: 0), diamond.topRight)
    }

    func testQuadMeasures() {
        let square = Quad(topLeft: CGPoint(x: 0, y: 0), topRight: CGPoint(x: 10, y: 0),
                          bottomRight: CGPoint(x: 10, y: 10), bottomLeft: CGPoint(x: 0, y: 10))
        XCTAssertEqual(100, square.area)
        XCTAssertEqual(CGPoint(x: 5, y: 5), square.centroid)
        XCTAssertTrue(square.contains(CGPoint(x: 5, y: 5)))
        XCTAssertFalse(square.contains(CGPoint(x: 11, y: 5)))
        XCTAssertTrue(square.contains(CGPoint(x: 11, y: 5), tolerance: 1.5))
        XCTAssertTrue(square.isInside(width: 10, height: 10))
        XCTAssertFalse(square.isInside(width: 9, height: 10))
        let bowtie = Quad(topLeft: CGPoint(x: 0, y: 0), topRight: CGPoint(x: 10, y: 10),
                          bottomRight: CGPoint(x: 10, y: 0), bottomLeft: CGPoint(x: 0, y: 10))
        XCTAssertFalse(bowtie.isConvex)
        XCTAssertEqual(5, square.maxCornerDistance(square.scaled(1.5, 1)), accuracy: 1e-9)
    }

    func testTheSheetsShapeIsRecoveredFromATiltedView() throws {
        // An A4 sheet tilted 30° and 15°, turned 10°, by a camera with a 900 px focal length.
        let view = cameraView(210, 297, 30, 15, 10, 520, 900, 1200, 1600)
        let estimate = PerspectiveCorrector.estimateAspect(view, imageWidth: 1200, imageHeight: 1600)
        let focal = try XCTUnwrap(estimate.focalLength)
        XCTAssertTrue((891.0...909.0).contains(focal), "focal \(focal)")
        XCTAssertTrue((1.414 * 0.995...1.414 * 1.005).contains(estimate.longOverShort), "\(estimate.longOverShort)")
        XCTAssertEqual(PerspectiveCorrector.matchPaper(estimate.longOverShort)?.size, PaperSize.a4)

        // An ID card tilted 35°.
        let card = cameraView(85.6, 53.98, 35, 0, 5, 160, 1000, 1500, 2000)
        let cardEstimate = PerspectiveCorrector.estimateAspect(card, imageWidth: 1500, imageHeight: 2000)
        XCTAssertTrue((1.586 * 0.99...1.586 * 1.01).contains(cardEstimate.longOverShort), "\(cardEstimate.longOverShort)")
    }

    func testASheetSeenStraightOnTakesItsEdgeLengths() {
        let straight = Quad(topLeft: CGPoint(x: 100, y: 100), topRight: CGPoint(x: 400, y: 100),
                            bottomRight: CGPoint(x: 400, y: 300), bottomLeft: CGPoint(x: 100, y: 300))
        let estimate = PerspectiveCorrector.estimateAspect(straight, imageWidth: 800, imageHeight: 600)
        XCTAssertNil(estimate.focalLength)
        XCTAssertEqual(1.5, estimate.widthOverHeight, accuracy: 1e-9)
    }

    func testPaperSizesMatchWithinThreePercent() {
        XCTAssertEqual(PerspectiveCorrector.matchPaper(1.40)?.size, PaperSize.a4)
        XCTAssertEqual(PerspectiveCorrector.matchPaper(1.30)?.size, PaperSize.letter)
        XCTAssertEqual(PerspectiveCorrector.matchPaper(1.64)?.size, PaperSize.legal)
        XCTAssertNil(PerspectiveCorrector.matchPaper(1.59))
        XCTAssertNil(PerspectiveCorrector.matchPaper(1.50))
        XCTAssertNil(PerspectiveCorrector.matchPaper(2.5))
        XCTAssertNil(PerspectiveCorrector.matchPaper(1.0))
    }
}

import CoreGraphics
import Foundation
import XCTest
@testable import LazySendScan

/// A corner model that answers with four spots on the corners it is given (shares of the photo).
private struct SpotModel: CornerModel {
    let corners: [CGPoint]
    let peak: Double
    static let size = 64

    func heatmaps(_ input: [Float]) -> CornerHeatmaps? {
        var heat = DrawnHeatmap(size: SpotModel.size)
        for (channel, corner) in corners.enumerated() {
            heat.spot(channel, x: Double(corner.x) * Double(SpotModel.size), y: Double(corner.y) * Double(SpotModel.size), peak: peak)
        }
        return CornerHeatmaps(values: heat.values, width: SpotModel.size, height: SpotModel.size)
    }
}

private struct NoModel: CornerModel {
    func heatmaps(_ input: [Float]) -> CornerHeatmaps? { nil }
}

final class PageFinderTests: XCTestCase {
    private let truth = PhotoScenes.woodMap.corners(PhotoScenes.pageWidth, PhotoScenes.pageHeight)

    private func shares(of quad: Quad) -> [CGPoint] {
        quad.corners.map { CGPoint(x: Double($0.x) / Double(PhotoScenes.width), y: Double($0.y) / Double(PhotoScenes.height)) }
    }

    func testAPageTheModelIsSureOfIsMovedOntoThePhotosEdges() {
        let photo = PhotoScenes.woodScene()
        let found = PageFinder.find(photo, model: SpotModel(corners: shares(of: truth), peak: 0.9))
        let diagonal = Double(PhotoScenes.width * PhotoScenes.width + PhotoScenes.height * PhotoScenes.height).squareRoot()
        let named = Quad.fromCorners(found.corners.corners)
        for corner in 0..<4 {
            let dx = Double(named[corner].x) - Double(truth[corner].x)
            let dy = Double(named[corner].y) - Double(truth[corner].y)
            XCTAssertLessThan((dx * dx + dy * dy).squareRoot() / diagonal, 0.02, "corner \(corner)")
        }
        XCTAssertTrue(PageFinder.canUseCorners(found.corners))
    }

    func testWithoutAModelOrANoticedPageTheEditorStartsFromAnInsetRectangle() {
        let photo = PhotoScenes.woodScene()
        let start = PageFinder.startCorners(width: photo.width, height: photo.height)
        XCTAssertEqual(PageFinder.find(photo, model: nil), PageFound(corners: start, clear: false))
        XCTAssertEqual(PageFinder.find(photo, model: NoModel()), PageFound(corners: start, clear: false))
        let unsure = PageFinder.find(photo, model: SpotModel(corners: shares(of: truth), peak: 0.4))
        XCTAssertEqual(unsure, PageFound(corners: start, clear: false))
        XCTAssertEqual(start.topLeft, CGPoint(x: 36, y: 48))
        XCTAssertEqual(start.bottomRight, CGPoint(x: 324, y: 432))
    }

    func testALivePageIsAcceptedOnlyWhenSureLargeAndShapedLikeAPage() {
        let page = Quad(topLeft: CGPoint(x: 80, y: 40), topRight: CGPoint(x: 240, y: 40),
                        bottomRight: CGPoint(x: 240, y: 200), bottomLeft: CGPoint(x: 80, y: 200))
        XCTAssertEqual(PageFinder.accepted(QuadCandidate(quad: page, confidence: 0.9), width: 320, height: 240), page)
        XCTAssertNil(PageFinder.accepted(QuadCandidate(quad: page, confidence: 0.4), width: 320, height: 240))
        let sliver = Quad(topLeft: CGPoint(x: 10, y: 20), topRight: CGPoint(x: 300, y: 20),
                          bottomRight: CGPoint(x: 300, y: 30), bottomLeft: CGPoint(x: 10, y: 30))
        XCTAssertNil(PageFinder.accepted(QuadCandidate(quad: sliver, confidence: 0.9), width: 320, height: 240))
        let small = Quad(topLeft: CGPoint(x: 100, y: 80), topRight: CGPoint(x: 150, y: 80),
                         bottomRight: CGPoint(x: 150, y: 130), bottomLeft: CGPoint(x: 100, y: 130))
        XCTAssertNil(PageFinder.accepted(QuadCandidate(quad: small, confidence: 0.9), width: 320, height: 240))
        // A bow tie is no page.
        let twisted = Quad(topLeft: CGPoint(x: 80, y: 40), topRight: CGPoint(x: 240, y: 200),
                           bottomRight: CGPoint(x: 240, y: 40), bottomLeft: CGPoint(x: 80, y: 200))
        XCTAssertNil(PageFinder.accepted(QuadCandidate(quad: twisted, confidence: 0.9), width: 320, height: 240))
    }

    func testACornerMovedOutsideThePhotoStaysInsideAndOneThatBreaksThePageStays() {
        let start = PageFinder.startCorners(width: 400, height: 300)
        let pulled = PageFinder.movedCorner(start, index: 0, to: CGPoint(x: -50, y: -20), width: 400, height: 300)
        XCTAssertEqual(pulled.topLeft, CGPoint(x: 0, y: 0))
        XCTAssertEqual(pulled.topRight, start.topRight)
        // Dragged across the opposite corner: the outline would fold, so the corner stays.
        let folded = PageFinder.movedCorner(start, index: 0, to: CGPoint(x: 380, y: 280), width: 400, height: 300)
        XCTAssertEqual(folded, start)
        // Dragged onto its neighbour: an edge under the least length, so it stays.
        let squeezed = PageFinder.movedCorner(start, index: 0, to: CGPoint(x: 355, y: 31), width: 400, height: 300)
        XCTAssertEqual(squeezed, start)
    }

    func testOutlinesOutsideThePhotoAreClampedAndTheWholePhotoIsItsFourCorners() {
        let outside = Quad(topLeft: CGPoint(x: -20, y: -10), topRight: CGPoint(x: 420, y: -10),
                           bottomRight: CGPoint(x: 420, y: 320), bottomLeft: CGPoint(x: -20, y: 320))
        XCTAssertEqual(PageFinder.clamped(outside, width: 400, height: 300), PageFinder.wholePhoto(width: 400, height: 300))
        let line = Quad(topLeft: CGPoint(x: 10, y: 10), topRight: CGPoint(x: 10, y: 10),
                        bottomRight: CGPoint(x: 10, y: 10), bottomLeft: CGPoint(x: 10, y: 10))
        XCTAssertEqual(PageFinder.clamped(line, width: 400, height: 300), PageFinder.startCorners(width: 400, height: 300))
        XCTAssertFalse(PageFinder.canUseCorners(line))
    }

    func testTheFrameCandidateIsTurnedBackOntoTheSensorsPixels() throws {
        // The model sees the upright frame; the page it finds is returned in the frame as the sensor gave it.
        let frame = RgbaImage.filled(width: 64, height: 48, r: 120, g: 120, b: 120)
        // In the frame turned a quarter (48 x 64) the page spans x 0.2...0.8, y 0.1...0.9.
        let upright = [CGPoint(x: 0.2, y: 0.1), CGPoint(x: 0.8, y: 0.1), CGPoint(x: 0.8, y: 0.9), CGPoint(x: 0.2, y: 0.9)]
        let candidate = try XCTUnwrap(PageFinder.frameCandidate(frame, turn: 90, model: SpotModel(corners: upright, peak: 0.9)))
        let sensor = candidate.quad
        // A quarter back: x' = y, y' = 1 - x, as shares, then scaled to the 64 x 48 frame.
        XCTAssertEqual(Double(sensor.topLeft.x), 0.1 * 64, accuracy: 2)
        XCTAssertEqual(Double(sensor.topLeft.y), 0.2 * 48, accuracy: 2)
        XCTAssertEqual(Double(sensor.bottomRight.x), 0.9 * 64, accuracy: 2)
        XCTAssertEqual(Double(sensor.bottomRight.y), 0.8 * 48, accuracy: 2)
        XCTAssertEqual(candidate.confidence, 0.9, accuracy: 0.05)
    }
}

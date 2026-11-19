import CoreGraphics
import XCTest
@testable import LazySendScan

private let diagonal = (Double(PhotoScenes.width * PhotoScenes.width + PhotoScenes.height * PhotoScenes.height)).squareRoot()

private func truth(_ map: PhotoScenes.IntHomography) -> Quad {
    map.corners(PhotoScenes.pageWidth, PhotoScenes.pageHeight)
}

/// `quad` with every corner moved 1 % of the diagonal, each its own way (four patterns).
private func off(_ quad: Quad, _ pattern: Int) -> Quad {
    let corners = quad.corners
    var moved: [CGPoint] = []
    for i in 0..<4 {
        let angle = Double(i) * 1.7 + Double(pattern) * 2.3
        moved.append(CGPoint(x: Double(corners[i].x) + 0.01 * diagonal * cos(angle),
                             y: Double(corners[i].y) + 0.01 * diagonal * sin(angle)))
    }
    return Quad(topLeft: moved[0], topRight: moved[1], bottomRight: moved[2], bottomLeft: moved[3])
}

/// `quad` with every corner moved 2 % of the diagonal away from its middle.
private func grown(_ quad: Quad) -> Quad {
    let c = quad.centroid
    var moved: [CGPoint] = []
    for corner in quad.corners {
        let dx = Double(corner.x) - Double(c.x), dy = Double(corner.y) - Double(c.y)
        let len = (dx * dx + dy * dy).squareRoot()
        moved.append(CGPoint(x: Double(corner.x) + 0.02 * diagonal * dx / len, y: Double(corner.y) + 0.02 * diagonal * dy / len))
    }
    return Quad(topLeft: moved[0], topRight: moved[1], bottomRight: moved[2], bottomLeft: moved[3])
}

/// An upright page (231 × 327 px) at (60, 50).
private let upright = PhotoScenes.IntHomography(1100000, 0, 60 * 1048576, 0, 1100000, 50 * 1048576, 0, 0, 1048576)

/// The upright page on a plain sheet of one color reaching 9 to 18 px beyond it on every side (within the band,
/// beyond its outward reach), on a dark desk.
private func onASheet(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> RgbaImage {
    let folder = PhotoScenes.IntHomography(1205862, 0, 48 * 1048576, 0, 1205862, 38 * 1048576, 0, 0, 1048576)
    var plain = [UInt8](repeating: 0, count: PhotoScenes.pageWidth * PhotoScenes.pageHeight * 3)
    var i = 0
    while i < plain.count {
        plain[i] = r
        plain[i + 1] = g
        plain[i + 2] = b
        i += 3
    }
    return PhotoScenes.scene(.dark, 0x3D00_D010, PhotoScenes.Lighting(acrossX: 0, downY: 0, shadow: nil, glare: nil), [
        PhotoScenes.Sheet(rgb: plain, sheetWidth: PhotoScenes.pageWidth, sheetHeight: PhotoScenes.pageHeight, map: folder),
        PhotoScenes.Sheet(rgb: PhotoScenes.pageRaster(0x9A6E_0010), sheetWidth: PhotoScenes.pageWidth,
                          sheetHeight: PhotoScenes.pageHeight, map: upright),
    ])
}

final class QuadRefinerTests: XCTestCase {
    func testAnOutlineOffThePageIsMovedBackOntoItsEdges() {
        let scenes: [(String, RgbaImage, Quad)] = [
            ("wood", PhotoScenes.woodScene(), truth(PhotoScenes.woodMap)),
            ("dark", PhotoScenes.darkScene(), truth(PhotoScenes.darkMap)),
            ("light", PhotoScenes.lightScene(), truth(PhotoScenes.lightMap)),
            ("similar", PhotoScenes.similarScene(), truth(PhotoScenes.similarMap)),
            ("roundTrip", PhotoScenes.roundTripScene(), truth(PhotoScenes.roundTripMap)),
            ("bottomGap", PhotoScenes.bottomGapScene(8), truth(PhotoScenes.bottomGapMap(8))),
            ("rightGap", PhotoScenes.rightGapScene(4), truth(PhotoScenes.rightGapMap(4))),
        ]
        for (name, photo, page) in scenes {
            // The page's own outline is backed by its edges all round; one 2 % too large is not. Inward the
            // whole band is searched, outward a third of it.
            XCTAssertGreaterThanOrEqual(QuadRefiner.supportOf(photo, page), 0.95, name)
            let large = grown(page)
            XCTAssertLessThan(QuadRefiner.supportOf(photo, large), 0.7, name)
            var starts: [Quad] = []
            // Not where growing it crosses the frame's edge (the pages near the frame's border).
            if large.isInside(width: Double(photo.width), height: Double(photo.height)) {
                starts.append(large)
            }
            for pattern in 0..<4 {
                starts.append(off(page, pattern))
            }
            for (pattern, start) in starts.enumerated() {
                let result = QuadRefiner.refine(photo, start)
                XCTAssertTrue(result.refined, "\(name) \(pattern)")
                XCTAssertLessThanOrEqual(result.quad.maxCornerDistance(page), 0.003 * diagonal,
                                         "\(name) \(pattern): refined to \(result.quad)")
                XCTAssertGreaterThanOrEqual(result.support, 0.95, "\(name) \(pattern)")
            }
        }
    }

    func testAHeaderBarJustInsideThePageDoesNotPullItsTopEdge() {
        // Moved straight down 1 %: the header bar's top edge lies nearer than the page's top edge.
        let photo = PhotoScenes.darkScene()
        let page = truth(PhotoScenes.darkMap)
        var start = page
        start.topLeft = CGPoint(x: Double(page.topLeft.x), y: Double(page.topLeft.y) + 0.01 * diagonal)
        start.topRight = CGPoint(x: Double(page.topRight.x), y: Double(page.topRight.y) + 0.01 * diagonal)
        let result = QuadRefiner.refine(photo, start)
        XCTAssertLessThanOrEqual(result.quad.maxCornerDistance(page), 0.003 * diagonal, "\(result.quad)")
    }

    func testAPageAlreadyOnItsEdgesIsNotPushedOntoAFolderUnderIt() {
        let photo = onASheet(200, 170, 110)
        let page = truth(upright)
        let result = QuadRefiner.refine(photo, page)
        XCTAssertLessThanOrEqual(result.quad.maxCornerDistance(page), 0.5, "\(result.quad)")
        XCTAssertGreaterThanOrEqual(result.support, 0.95)
    }

    func testAnEquallySharpEdgeJustOutsideDoesNotTakeTheSide() {
        // A gray card under the page: its edges are as sharp as the page's. Vision's outline 2 px inside the
        // page moves onto the page's edges, not the card's.
        let photo = onASheet(128, 128, 128)
        let page = truth(upright)
        let inside = Quad(topLeft: CGPoint(x: Double(page.topLeft.x) + 2, y: Double(page.topLeft.y) + 2),
                          topRight: CGPoint(x: Double(page.topRight.x) - 2, y: Double(page.topRight.y) + 2),
                          bottomRight: CGPoint(x: Double(page.bottomRight.x) - 2, y: Double(page.bottomRight.y) - 2),
                          bottomLeft: CGPoint(x: Double(page.bottomLeft.x) + 2, y: Double(page.bottomLeft.y) - 2))
        let result = QuadRefiner.refine(photo, inside)
        XCTAssertTrue(result.refined)
        XCTAssertLessThanOrEqual(result.quad.maxCornerDistance(page), 1, "\(result.quad)")
        XCTAssertGreaterThanOrEqual(result.support, 0.95)
    }

    func testATableWithNoPageLeavesTheOutlineAlone() {
        let photo = PhotoScenes.plainScene()
        let start = off(truth(PhotoScenes.woodMap), 0)
        let result = QuadRefiner.refine(photo, start)
        XCTAssertFalse(result.refined)
        XCTAssertEqual(result.quad, start)
        XCTAssertLessThan(result.support, 0.2)
    }

    func testALargePhotoIsSearchedSmall_andTheCornersComeBackInItsPixels() {
        // The wood scene three times as large (1080 × 1440): searched at 1000 px long, answered in its own pixels.
        let small = PhotoScenes.woodScene()
        let photo = small.resized(width: small.width * 3, height: small.height * 3)
        let page = truth(PhotoScenes.woodMap).scaled(3, 3)
        let result = QuadRefiner.refine(photo, off(page, 1))
        XCTAssertTrue(result.refined)
        XCTAssertLessThanOrEqual(result.quad.maxCornerDistance(page), 0.003 * 3 * diagonal, "\(result.quad)")
    }
}

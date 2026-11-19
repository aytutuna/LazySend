import CoreGraphics
import Foundation
import XCTest
@testable import LazySendScan

/// The warp's test photos, shared with `CapturePageTests`.
enum WarpFixtures {
    /// The golden fixture: a w × h photo whose every byte comes from integer arithmetic on (x, y).
    static func photo(_ w: Int, _ h: Int) -> RgbaImage {
        var p = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                p[i] = UInt8((x * 37 + y * 11) % 256)
                let checker = (x / 4 + y / 4) % 2 == 0
                p[i + 1] = UInt8(checker ? 40 + (x * 3) % 160 : 220 - (y * 5) % 120)
                p[i + 2] = UInt8((x * y + 3 * x + 7 * y) % 256)
                p[i + 3] = 255
            }
        }
        return RgbaImage(width: w, height: h, pixels: p)
    }

    /// A quad from its corners clockwise from the top-left.
    static func quad(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double,
                     _ x2: Double, _ y2: Double, _ x3: Double, _ y3: Double) -> Quad {
        Quad(topLeft: CGPoint(x: x0, y: y0), topRight: CGPoint(x: x1, y: y1),
             bottomRight: CGPoint(x: x2, y: y2), bottomLeft: CGPoint(x: x3, y: y3))
    }

    /// The peak signal-to-noise ratio of R, G and B in dB, leaving out `border` px all around.
    static func psnr(_ a: RgbaImage, _ b: RgbaImage, border: Int) -> Double {
        XCTAssertEqual(a.width, b.width)
        XCTAssertEqual(a.height, b.height)
        var sum = 0.0
        var count = 0
        for y in border..<(a.height - border) {
            for x in border..<(a.width - border) {
                let i = (y * a.width + x) * 4
                for c in 0..<3 {
                    let d = Double(a.pixels[i + c]) - Double(b.pixels[i + c])
                    sum += d * d
                }
                count += 3
            }
        }
        let mse = sum / Double(count)
        return mse == 0 ? 99 : 10 * log10(255.0 * 255.0 / mse)
    }
}

private func pixel(_ image: RgbaImage, _ x: Int, _ y: Int) -> [UInt8] {
    let i = (y * image.width + x) * 4
    return Array(image.pixels[i..<(i + 4)])
}

/// The dots of `dottedPage`: 7 × 7 black squares centered 24.5 px in from each corner.
private let dotCenters: [CGPoint] = [CGPoint(x: 24.5, y: 24.5), CGPoint(x: 275.5, y: 24.5),
                                     CGPoint(x: 275.5, y: 375.5), CGPoint(x: 24.5, y: 375.5)]

/// A 300 × 400 page: soft color ramps, a checkerboard of 15 px squares in blue and the four dots.
private func dottedPage() -> RgbaImage {
    let w = 300, h = 400
    var p = [UInt8](repeating: 0, count: w * h * 4)
    for y in 0..<h {
        for x in 0..<w {
            let i = (y * w + x) * 4
            p[i] = UInt8(230 - x * 60 / w)
            p[i + 1] = UInt8(220 - y * 80 / h)
            p[i + 2] = UInt8(120 + (x / 15 + y / 15) % 2 * 80)
            p[i + 3] = 255
        }
    }
    for center in dotCenters {
        let cx = Int(center.x), cy = Int(center.y)
        for y in (cy - 3)...(cy + 3) {
            for x in (cx - 3)...(cx + 3) {
                let i = (y * w + x) * 4
                p[i] = 0
                p[i + 1] = 0
                p[i + 2] = 0
            }
        }
    }
    return RgbaImage(width: w, height: h, pixels: p)
}

/// The page's place in the 640 × 480 photo of the round trip.
private let photoQuad = WarpFixtures.quad(130.5, 60.25, 470, 95.5, 500.75, 430, 95, 400.5)

/// The centroid of the pixels darker than 60 (by their darkness) within `radius` px of (cx, cy), in
/// continuous pixels; nil when there are none.
private func darkCentroid(_ image: RgbaImage, _ cx: Double, _ cy: Double, radius: Int) -> CGPoint? {
    var sx = 0.0, sy = 0.0, sw = 0.0
    let x0 = max(0, Int(cx) - radius), x1 = min(image.width - 1, Int(cx) + radius)
    let y0 = max(0, Int(cy) - radius), y1 = min(image.height - 1, Int(cy) + radius)
    if x0 > x1 || y0 > y1 { return nil }
    for y in y0...y1 {
        for x in x0...x1 {
            let i = (y * image.width + x) * 4
            let luma = (Int(image.pixels[i]) * 299 + Int(image.pixels[i + 1]) * 587 + Int(image.pixels[i + 2]) * 114) / 1000
            if luma >= 60 { continue }
            let weight = Double(60 - luma)
            sx += weight * (Double(x) + 0.5)
            sy += weight * (Double(y) + 0.5)
            sw += weight
        }
    }
    if sw <= 0 { return nil }
    return CGPoint(x: sx / sw, y: sy / sw)
}

private func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
    let dx = Double(a.x) - Double(b.x), dy = Double(a.y) - Double(b.y)
    return (dx * dx + dy * dy).squareRoot()
}

final class PerspectiveWarpTests: XCTestCase {
    // MARK: - Golden bytes

    func testWarpedBytesAreTheSameOnBothPlatforms() throws {
        let supersampled = try XCTUnwrap(PerspectiveWarp.warp(
            WarpFixtures.photo(96, 72), quad: WarpFixtures.quad(10.25, 6.5, 85.75, 12, 80.5, 66.25, 6, 60.75),
            width: 40, height: 30))
        XCTAssertEqual(PhotoScenes.checksum(supersampled), 0xA255_D919)
        XCTAssertEqual(pixel(supersampled, 0, 0), [209, 163, 155, 255])
        XCTAssertEqual(pixel(supersampled, 7, 5), [55, 130, 69, 255])
        XCTAssertEqual(pixel(supersampled, 19, 13), [227, 174, 62, 255])

        let prefiltered = try XCTUnwrap(PerspectiveWarp.warp(
            WarpFixtures.photo(240, 180), quad: WarpFixtures.quad(20.5, 15.25, 220, 30.75, 205.25, 170.5, 12, 150),
            width: 48, height: 36))
        XCTAssertEqual(PhotoScenes.checksum(prefiltered), 0xB7EA_788D)
        XCTAssertEqual(pixel(prefiltered, 0, 0), [161, 131, 90, 255])
        XCTAssertEqual(pixel(prefiltered, 7, 5), [154, 162, 139, 255])
        XCTAssertEqual(pixel(prefiltered, 19, 13), [142, 201, 145, 255])

        let enlarged = try XCTUnwrap(PerspectiveWarp.warp(
            WarpFixtures.photo(32, 24), quad: WarpFixtures.quad(-4, -3, 30, 1, 36, 26, 2, 22), width: 50, height: 40))
        XCTAssertEqual(PhotoScenes.checksum(enlarged), 0x685B_8D2E)
        XCTAssertEqual(pixel(enlarged, 0, 0), [255, 255, 255, 255])
        XCTAssertEqual(pixel(enlarged, 7, 5), [46, 32, 0, 255])
        XCTAssertEqual(pixel(enlarged, 19, 13), [223, 202, 148, 255])
    }

    func testThePrefilterStartsAboveTwiceSmallerAndTakesTheWholePart() {
        let quad = WarpFixtures.quad(20.5, 15.25, 220, 30.75, 205.25, 170.5, 12, 150)
        XCTAssertEqual(PerspectiveWarp.prefilterFactor(quad, width: 48, height: 36), 4)
        XCTAssertEqual(PerspectiveWarp.prefilterFactor(quad, width: 120, height: 90), 1)
        XCTAssertEqual(PerspectiveWarp.prefilterFactor(quad, width: 90, height: 60), 2)
        XCTAssertEqual(PerspectiveWarp.prefilterFactor(quad, width: 400, height: 300), 1)
        XCTAssertEqual(PerspectiveWarp.prefilterFactor(quad, width: 0, height: 36), 1)
        // Exactly twice smaller is not more than twice.
        let square = WarpFixtures.quad(0, 0, 100, 0, 100, 100, 0, 100)
        XCTAssertEqual(PerspectiveWarp.prefilterFactor(square, width: 50, height: 50), 1)
        XCTAssertEqual(PerspectiveWarp.prefilterFactor(square, width: 49, height: 49), 2)
        XCTAssertEqual(PerspectiveWarp.prefilterFactor(square, width: 33, height: 50), 3)
    }

    func testBoxReducedAveragesWholeAndEdgeBlocksRoundingHalfUp() {
        // 5 × 3, blocks of 2: a 3 × 2 result whose last column and row hold fewer pixels.
        var p = [UInt8](repeating: 0, count: 5 * 3 * 4)
        for i in 0..<15 {
            p[i * 4] = UInt8(i * 10)
            p[i * 4 + 1] = UInt8(i % 2)
            p[i * 4 + 2] = 255
            p[i * 4 + 3] = i == 0 ? 0 : 255
        }
        let reduced = PerspectiveWarp.boxReduced(RgbaImage(width: 5, height: 3, pixels: p), factor: 2)
        XCTAssertEqual(reduced.width, 3)
        XCTAssertEqual(reduced.height, 2)
        // Block (0, 0): pixels 0, 1, 5, 6 → R 30, G 0.5 → 1, A 191.25 → 191.
        XCTAssertEqual(pixel(reduced, 0, 0), [30, 1, 255, 191])
        XCTAssertEqual(pixel(reduced, 2, 0), [65, 1, 255, 255])
        XCTAssertEqual(pixel(reduced, 1, 1), [125, 1, 255, 255])
        XCTAssertEqual(pixel(reduced, 2, 1), [140, 0, 255, 255])
        let image = WarpFixtures.photo(7, 5)
        XCTAssertEqual(PerspectiveWarp.boxReduced(image, factor: 1), image)
    }

    func testWithoutPrefilterTheWarpIsTheCorrectorsOwn() throws {
        let photo = WarpFixtures.photo(96, 72)
        let quad = WarpFixtures.quad(10.25, 6.5, 85.75, 12, 80.5, 66.25, 6, 60.75)
        var options = PerspectiveOptions()
        options.outputWidth = 40
        options.outputHeight = 30
        options.snapToPaper = false
        let plan = try XCTUnwrap(PerspectiveCorrector.plan(quad, imageWidth: 96, imageHeight: 72, options: options))
        let warped = try XCTUnwrap(PerspectiveWarp.warp(photo, quad: quad, width: 40, height: 30))
        XCTAssertEqual(PerspectiveCorrector.warp(photo, plan: plan, options: options).pixels, warped.pixels)
        var dark = PerspectiveOptions()
        dark.fillR = 10
        dark.fillG = 20
        dark.fillB = 30
        let filled = try XCTUnwrap(PerspectiveWarp.warp(WarpFixtures.photo(32, 24),
                                                        quad: WarpFixtures.quad(-4, -3, 30, 1, 36, 26, 2, 22),
                                                        width: 50, height: 40, options: dark))
        XCTAssertEqual(pixel(filled, 0, 0), [10, 20, 30, 255])
    }

    func testNoWarpForAnOutlineThatIsNotConvexOrASizeOutOfRange() {
        let photo = WarpFixtures.photo(32, 24)
        XCTAssertNil(PerspectiveWarp.warp(photo, quad: WarpFixtures.quad(0, 0, 30, 0, 10, 5, 0, 20), width: 10, height: 10))
        XCTAssertNil(PerspectiveWarp.warp(photo, quad: WarpFixtures.quad(0, 20, 30, 20, 30, 0, 0, 0), width: 10, height: 10))
        XCTAssertNil(PerspectiveWarp.warp(photo, quad: WarpFixtures.quad(0, 0, 30, 0, 30, 20, 0, 20), width: 0, height: 10))
        XCTAssertNil(PerspectiveWarp.warp(photo, quad: WarpFixtures.quad(0, 0, 30, 0, 30, 20, 0, 20), width: 10,
                                          height: PerspectiveCorrector.maxOutputSide + 1))
    }

    // MARK: - Round trip

    func testAPagePhotographedAndWarpedBackKeepsItsCornersAndLooks() throws {
        let page = dottedPage()
        let toPhoto = try XCTUnwrap(Homography.rectToQuad(width: 300, height: 400, quad: photoQuad))
        let back = try XCTUnwrap(toPhoto.inverse())
        // The photo: every photo pixel looks up the page through the inverse map (dark table around it).
        let photoCorners = Quad.fromCorners([back.map(CGPoint(x: 0, y: 0)), back.map(CGPoint(x: 640, y: 0)),
                                             back.map(CGPoint(x: 640, y: 480)), back.map(CGPoint(x: 0, y: 480))])
        XCTAssertTrue(photoCorners.isConvex)
        var table = PerspectiveOptions()
        table.fillR = 40
        table.fillG = 40
        table.fillB = 40
        let photo = try XCTUnwrap(PerspectiveWarp.warp(page, quad: photoCorners, width: 640, height: 480, options: table))

        // The page's corners land where the map says, within 1 px.
        for center in dotCenters {
            let expected = toPhoto.map(center)
            let found = try XCTUnwrap(darkCentroid(photo, Double(expected.x), Double(expected.y), radius: 8))
            XCTAssertLessThanOrEqual(distance(found, expected), 1, "photo dot at \(found), expected \(expected)")
        }

        // Warped back along the page's corners, it is the page again.
        let recovered = try XCTUnwrap(PerspectiveWarp.warp(photo, quad: photoQuad, width: 300, height: 400))
        let psnr = WarpFixtures.psnr(page, recovered, border: 3)
        XCTAssertGreaterThanOrEqual(psnr, 30, "PSNR \(psnr) dB")
        for center in dotCenters {
            let found = try XCTUnwrap(darkCentroid(recovered, Double(center.x), Double(center.y), radius: 8))
            XCTAssertLessThanOrEqual(distance(found, center), 1, "page dot at \(found), expected \(center)")
        }
    }

    func testAPageMadeMuchSmallerIsAveragedNotAliased() throws {
        // A fine 2 px checkerboard seen 4 times larger than the output: averaged it is an even gray.
        let w = 400, h = 300
        var p = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let v: UInt8 = (x / 2 + y / 2) % 2 == 0 ? 30 : 230
                p[i] = v
                p[i + 1] = v
                p[i + 2] = v
                p[i + 3] = 255
            }
        }
        let photo = RgbaImage(width: w, height: h, pixels: p)
        let quad = WarpFixtures.quad(10, 10, 390, 18, 385, 290, 14, 284)
        let warped = try XCTUnwrap(PerspectiveWarp.warp(photo, quad: quad, width: 90, height: 66))
        XCTAssertEqual(PerspectiveWarp.prefilterFactor(quad, width: 90, height: 66), 4)
        var options = PerspectiveOptions()
        options.outputWidth = 90
        options.outputHeight = 66
        options.snapToPaper = false
        let plan = try XCTUnwrap(PerspectiveCorrector.plan(quad, imageWidth: w, imageHeight: h, options: options))
        let plain = PerspectiveCorrector.warp(photo, plan: plan)
        let gray = RgbaImage.filled(width: 90, height: 66, r: 130, g: 130, b: 130)
        let prefilteredPsnr = WarpFixtures.psnr(gray, warped, border: 2)
        let plainPsnr = WarpFixtures.psnr(gray, plain, border: 2)
        XCTAssertGreaterThanOrEqual(prefilteredPsnr, 30, "prefiltered PSNR \(prefilteredPsnr) dB")
        XCTAssertGreaterThan(prefilteredPsnr, plainPsnr + 6, "prefiltered \(prefilteredPsnr) dB, plain \(plainPsnr) dB")
    }

    func testRowBandsCoverEveryRowOnce() {
        for rows in [0, 1, 2, 7, 64, 1000] {
            var visits = [Int](repeating: 0, count: rows)
            visits.withUnsafeMutableBufferPointer { counts in
                RowBands.perform(rows: rows) { range in
                    for row in range { counts[row] += 1 }
                }
            }
            XCTAssertEqual(visits, [Int](repeating: 1, count: rows), "\(rows) rows")
        }
    }
}

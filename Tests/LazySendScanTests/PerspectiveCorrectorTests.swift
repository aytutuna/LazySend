import CoreGraphics
import XCTest
@testable import LazySendScan

private var roundTripQuad: Quad { PhotoScenes.roundTripMap.corners(PhotoScenes.pageWidth, PhotoScenes.pageHeight) }

/// The mean absolute difference of R, G and B, leaving out `border` px all around.
private func meanDifference(_ a: RgbaImage, _ b: RgbaImage, _ border: Int) -> Double {
    XCTAssertEqual(a.width, b.width)
    XCTAssertEqual(a.height, b.height)
    var sum = 0, count = 0
    for y in border..<(a.height - border) {
        for x in border..<(a.width - border) {
            let i = (y * a.width + x) * 4
            for c in 0..<3 { sum += abs(Int(a.pixels[i + c]) - Int(b.pixels[i + c])) }
            count += 3
        }
    }
    return Double(sum) / Double(count)
}

private func forcedOptions(_ supersample: Supersampling) -> PerspectiveOptions {
    var options = PerspectiveOptions()
    options.outputWidth = PhotoScenes.pageWidth
    options.outputHeight = PhotoScenes.pageHeight
    options.supersample = supersample
    return options
}

final class PerspectiveCorrectorTests: XCTestCase {
    func testCorrectingAWarpedSheetGivesItBack() throws {
        let sheet = PhotoScenes.sheetImage(PhotoScenes.blockRaster(0x9A6E_000C))
        let corrected = try XCTUnwrap(PerspectiveCorrector.correct(PhotoScenes.roundTripScene(), quad: roundTripQuad,
                                                                   options: forcedOptions(.on)))
        XCTAssertEqual(corrected.image.width, PhotoScenes.pageWidth)
        XCTAssertEqual(corrected.image.height, PhotoScenes.pageHeight)
        let difference = meanDifference(sheet, corrected.image, 2)
        XCTAssertLessThanOrEqual(difference, 6, "mean difference \(difference)")
        // Every block's center is its own color.
        var by = 5
        while by < PhotoScenes.pageHeight {
            var bx = 5
            while bx < PhotoScenes.pageWidth {
                let i = (by * PhotoScenes.pageWidth + bx) * 4
                for c in 0..<3 {
                    let delta = Int(corrected.image.pixels[i + c]) - Int(sheet.pixels[i + c])
                    XCTAssertTrue((-6...6).contains(delta), "block (\(bx), \(by)) channel \(c): \(delta)")
                }
                bx += 10
            }
            by += 10
        }
    }

    func testCorrectedBytesAreTheSameOnBothPlatforms() throws {
        let on = try XCTUnwrap(PerspectiveCorrector.correct(PhotoScenes.roundTripScene(), quad: roundTripQuad,
                                                            options: forcedOptions(.on)))
        XCTAssertEqual(PhotoScenes.checksum(on.image), 0xF8DE_2BA5)
        let off = try XCTUnwrap(PerspectiveCorrector.correct(PhotoScenes.roundTripScene(), quad: roundTripQuad,
                                                             options: forcedOptions(.off)))
        XCTAssertEqual(PhotoScenes.checksum(off.image), 0x9950_9981)
        let wood = try XCTUnwrap(PerspectiveCorrector.correct(PhotoScenes.woodScene(),
                                                              quad: PhotoScenes.woodMap.corners(PhotoScenes.pageWidth, PhotoScenes.pageHeight)))
        XCTAssertEqual(wood.image.width, 235)
        XCTAssertEqual(wood.image.height, 333)
        XCTAssertEqual(wood.plan.paper?.size, PaperSize.a4)
        XCTAssertEqual(PhotoScenes.checksum(wood.image), 0x32B3_6A66)
    }

    func testTheOutputTakesTheLongerEdgesAndNeverMore() throws {
        let quad = Quad(topLeft: CGPoint(x: 100, y: 100), topRight: CGPoint(x: 300, y: 120),
                        bottomRight: CGPoint(x: 320, y: 400), bottomLeft: CGPoint(x: 90, y: 380))
        var unsnapped = PerspectiveOptions()
        unsnapped.snapToPaper = false
        let plan = try XCTUnwrap(PerspectiveCorrector.plan(quad, imageWidth: 1000, imageHeight: 1000, options: unsnapped))
        let longest = max(max(quad.edgeLength(0), quad.edgeLength(2)), max(quad.edgeLength(1), quad.edgeLength(3)))
        XCTAssertEqual(max(plan.width, plan.height), Int((longest + 0.5).rounded(.down)))
        XCTAssertNil(plan.paper)
        XCTAssertNil(plan.dpi)
        var cappedOptions = unsnapped
        cappedOptions.maxLongSide = 100
        let capped = try XCTUnwrap(PerspectiveCorrector.plan(quad, imageWidth: 1000, imageHeight: 1000, options: cappedOptions))
        XCTAssertEqual(max(capped.width, capped.height), 100)
        XCTAssertTrue(capped.supersampled)
        var singleOptions = cappedOptions
        singleOptions.supersample = .off
        let single = try XCTUnwrap(PerspectiveCorrector.plan(quad, imageWidth: 1000, imageHeight: 1000, options: singleOptions))
        XCTAssertFalse(single.supersampled)
    }

    func testAKnownPaperSizeSetsTheShapeAndTheResolution() throws {
        // An A4 sheet tilted 25° in a 3000 × 4000 photo: the output is √2 and about as large as the near edge.
        let view = cameraView(210, 297, 25, -10, 4, 420, 3100, 3000, 4000)
        let plan = try XCTUnwrap(PerspectiveCorrector.plan(view, imageWidth: 3000, imageHeight: 4000))
        XCTAssertEqual(plan.paper?.size, PaperSize.a4)
        let ratio = Double(plan.height) / Double(plan.width)
        XCTAssertTrue((1.410...1.418).contains(ratio), "\(ratio)")
        let dpi = try XCTUnwrap(plan.dpi)
        XCTAssertEqual(dpi, Double(plan.height) / 11.6929, accuracy: 0.01)
    }

    func testOutsideThePhotoIsFilled() throws {
        let image = RgbaImage.filled(width: 100, height: 100, r: 10, g: 20, b: 30)
        let quad = Quad(topLeft: CGPoint(x: -50, y: 0), topRight: CGPoint(x: 50, y: 0),
                        bottomRight: CGPoint(x: 50, y: 100), bottomLeft: CGPoint(x: -50, y: 100))
        var options = PerspectiveOptions()
        options.fillR = 255
        options.fillG = 0
        options.fillB = 0
        options.snapToPaper = false
        let result = try XCTUnwrap(PerspectiveCorrector.correct(image, quad: quad, options: options))
        XCTAssertEqual(result.image.width, 100)
        let left = Array(result.image.pixels[(10 * 100 + 10) * 4..<(10 * 100 + 10) * 4 + 4])
        let right = Array(result.image.pixels[(10 * 100 + 90) * 4..<(10 * 100 + 90) * 4 + 4])
        XCTAssertEqual(left, [255, 0, 0, 255])
        XCTAssertEqual(right, [10, 20, 30, 255])
    }

    func testOnePixelStripesKeepTheirContrastAtOneToOne() throws {
        // Black and white columns one pixel wide, read a quarter pixel off at 1:1: Catmull-Rom gives
        // 40 and 215; bilinear would give 0.25 · 255 and 0.75 · 255, 64 and 191.
        let size: Int = 40
        var p: [UInt8] = [UInt8](repeating: 255, count: size * size * 4)
        for y in 0..<size {
            for x in stride(from: 0, to: size, by: 2) {
                let i: Int = (y * size + x) * 4
                p[i] = 0
                p[i + 1] = 0
                p[i + 2] = 0
            }
        }
        let stripes = RgbaImage(width: size, height: size, pixels: p)
        let side: Double = Double(size) + 0.25
        let quad = Quad(topLeft: CGPoint(x: 0.25, y: 0), topRight: CGPoint(x: side, y: 0),
                        bottomRight: CGPoint(x: side, y: Double(size)), bottomLeft: CGPoint(x: 0.25, y: Double(size)))
        var options = PerspectiveOptions()
        options.outputWidth = size
        options.outputHeight = size
        options.snapToPaper = false
        let result = try XCTUnwrap(PerspectiveCorrector.correct(stripes, quad: quad, options: options))
        XCTAssertFalse(result.plan.supersampled)
        var dark: Int = 255
        var light: Int = 0
        for x in 4..<(size - 4) {
            let value: Int = Int(result.image.pixels[(size / 2 * size + x) * 4])
            XCTAssertEqual(value, x % 2 == 0 ? 40 : 215, "column \(x)")
            dark = min(dark, value)
            light = max(light, value)
        }
        XCTAssertGreaterThan(light - dark, 191 - 64)
    }

    func testAQuadFarOutsideThePhotoGivesABoundedOutput() throws {
        func square(_ a: Double, _ b: Double) -> Quad {
            Quad(topLeft: CGPoint(x: a, y: a), topRight: CGPoint(x: b, y: a),
                 bottomRight: CGPoint(x: b, y: b), bottomLeft: CGPoint(x: a, y: b))
        }
        var unsnapped = PerspectiveOptions()
        unsnapped.snapToPaper = false
        // A corner editor's quad a million pixels across on a 4000 × 3000 photo: the long side is cut
        // to twice the photo's diagonal (10000 px), and the output can be made.
        let plan = try XCTUnwrap(PerspectiveCorrector.plan(square(0, 1e6), imageWidth: 4000, imageHeight: 3000,
                                                           options: unsnapped))
        XCTAssertEqual(plan.width, 10000)
        XCTAssertEqual(plan.height, 10000)
        XCTAssertTrue(plan.supersampled)
        // Even larger photos stop at maxOutputSide, whose RGBA bytes still fit in one array.
        let capped = try XCTUnwrap(PerspectiveCorrector.plan(square(0, 1e19), imageWidth: 100000, imageHeight: 100000,
                                                             options: unsnapped))
        XCTAssertEqual(capped.width, PerspectiveCorrector.maxOutputSide)
        XCTAssertLessThanOrEqual(Int64(capped.width) * Int64(capped.height) * 4, 0x7FFF_FFC7)
        // A size the caller gives beyond the limit, or a photo without pixels, has no plan.
        var forced = PerspectiveOptions()
        forced.outputWidth = 50000
        forced.outputHeight = 50000
        XCTAssertNil(PerspectiveCorrector.plan(square(10, 90), imageWidth: 100, imageHeight: 100, options: forced))
        XCTAssertNil(PerspectiveCorrector.plan(square(10, 90), imageWidth: 0, imageHeight: 0))
        // A small photo with a quad dragged outside it: the output stays near the photo's size.
        let dragged = Quad(topLeft: CGPoint(x: -500, y: -400), topRight: CGPoint(x: 600, y: -300),
                           bottomRight: CGPoint(x: 700, y: 900), bottomLeft: CGPoint(x: -450, y: 800))
        let near = try XCTUnwrap(PerspectiveCorrector.plan(dragged, imageWidth: 100, imageHeight: 100, options: unsnapped))
        XCTAssertLessThanOrEqual(max(near.width, near.height), 283, "\(near.width) × \(near.height)")
    }

    func testANonConvexQuadIsRefused() {
        let bowtie = Quad(topLeft: CGPoint(x: 0, y: 0), topRight: CGPoint(x: 10, y: 10),
                          bottomRight: CGPoint(x: 10, y: 0), bottomLeft: CGPoint(x: 0, y: 10))
        XCTAssertNil(PerspectiveCorrector.correct(RgbaImage.filled(width: 20, height: 20, r: 0, g: 0, b: 0), quad: bowtie))
    }
}

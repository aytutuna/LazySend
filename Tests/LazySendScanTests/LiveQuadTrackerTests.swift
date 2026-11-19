import CoreGraphics
import Foundation
import XCTest
@testable import LazySendScan

/// Live frames of 320 x 240 like the camera's (small, as searched): a wooden table and a blank sheet from (80, 40) to
/// (240, 200), blurred by a box of (2 * blur + 1)^2 pixels and darkened to dim/255, if asked. Measured over the sheet
/// found (+-1 px): a sharpness of about 690 sharp, 17 blurred by 2 (blurry); a brightness of about 195, 30 dimmed to 40
/// (dark).
enum LiveFrames {
    static let width: Int = 320
    static let height: Int = 240
    static let sheet = Quad(topLeft: CGPoint(x: 80, y: 40), topRight: CGPoint(x: 240, y: 40),
                            bottomRight: CGPoint(x: 240, y: 200), bottomLeft: CGPoint(x: 80, y: 200))

    static func frame(blur: Int = 0, dim: Int = 255) -> RgbaImage {
        var r = [Int](repeating: 88, count: width * height)
        var g = [Int](repeating: 80, count: width * height)
        var b = [Int](repeating: 72, count: width * height)
        for y in 40..<200 {
            for x in 80..<240 {
                let i = y * width + x
                r[i] = 205
                g[i] = 200
                b[i] = 192
            }
        }
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                var sr = 0, sg = 0, sb = 0, n = 0
                for yy in max(0, y - blur)..<min(height, y + blur + 1) {
                    for xx in max(0, x - blur)..<min(width, x + blur + 1) {
                        let i = yy * width + xx
                        sr += r[i]
                        sg += g[i]
                        sb += b[i]
                        n += 1
                    }
                }
                let o = (y * width + x) * 4
                pixels[o] = UInt8(((sr + n / 2) / n * dim + 127) / 255)
                pixels[o + 1] = UInt8(((sg + n / 2) / n * dim + 127) / 255)
                pixels[o + 2] = UInt8(((sb + n / 2) / n * dim + 127) / 255)
            }
        }
        return RgbaImage(width: width, height: height, pixels: pixels)
    }

    /// The sheet moved `dx` px to the right.
    static func sheetMoved(_ dx: Double) -> Quad {
        Quad(topLeft: CGPoint(x: 80 + dx, y: 40), topRight: CGPoint(x: 240 + dx, y: 40),
             bottomRight: CGPoint(x: 240 + dx, y: 200), bottomLeft: CGPoint(x: 80 + dx, y: 200))
    }
}

/// `image` with a dark band across the sheet, as another page's text would make.
func barred(_ image: RgbaImage) -> RgbaImage {
    var pixels = image.pixels
    for y in 90..<150 {
        for x in 80..<240 {
            let o = (y * image.width + x) * 4
            pixels[o] = 40
            pixels[o + 1] = 40
            pixels[o + 2] = 40
        }
    }
    return RgbaImage(width: image.width, height: image.height, pixels: pixels)
}

private let goodReadings: LiveQuadTracker.QualityMeasure = { _, _ in
    FrameQualityReading(sharpness: 1000, brightness: 200)
}

/// A frame at `index` (100 ms apart) in which the model finds the sheet `dx` px to the right, surely.
private func sheetFrame(_ image: RgbaImage, _ index: Int, dx: Double, from start: Double = 0) -> ScanFrame {
    ScanFrame(image: image, timestampMs: start + Double(index) * 100,
              page: QuadCandidate(quad: LiveFrames.sheetMoved(dx), confidence: 1))
}

/// A frame of `width` x `height` of one grey, with the model's `page` if any.
private func plainFrame(_ t: Double, width: Int = 64, height: Int = 48, page: QuadCandidate? = nil) -> ScanFrame {
    ScanFrame(image: RgbaImage.filled(width: width, height: height, r: 90, g: 90, b: 90), timestampMs: t, page: page)
}

/// A page outline in a 64 x 48 frame.
private let stubQuad = Quad(topLeft: CGPoint(x: 10, y: 8), topRight: CGPoint(x: 50, y: 8),
                            bottomRight: CGPoint(x: 50, y: 40), bottomLeft: CGPoint(x: 10, y: 40))

private func assertQuad(_ a: Quad?, _ b: Quad, accuracy: Double, file: StaticString = #filePath, line: UInt = #line) {
    guard let quad = a else {
        XCTFail("No outline", file: file, line: line)
        return
    }
    for index in 0..<4 {
        XCTAssertEqual(Double(quad[index].x), Double(b[index].x), accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(Double(quad[index].y), Double(b[index].y), accuracy: accuracy, file: file, line: line)
    }
}

final class LiveQuadTrackerTests: XCTestCase {
    func testTheShutterFiresOnlyForAPageHeldStillOnASharpLitFrame() {
        // The sheet held still (+-1 px) at 10 frames a second: blurred while the camera focuses (frames 0-14), then too
        // dark (15-24), then sharp and lit (25-40). Each frame is measured for real (`FrameQuality`, over the page found).
        let blurred = LiveFrames.frame(blur: 2)
        let dark = LiveFrames.frame(dim: 40)
        let sharp = LiveFrames.frame()
        let tracker = LiveQuadTracker()
        var updates: [LiveQuadUpdate] = []
        for index in 0..<41 {
            let image = index < 15 ? blurred : (index < 25 ? dark : sharp)
            if let update = tracker.process(sheetFrame(image, index, dx: index % 2 == 0 ? 1 : -1)) {
                updates.append(update)
            }
        }
        XCTAssertEqual(updates.count, 41)
        let fired = updates.indices.filter { updates[$0].shouldCapture }
        // Held still from frame 1, long enough by frame 7: it waits through the blurred and dark frames, and the first
        // sharp, lit frame is taken, once.
        XCTAssertEqual(fired, [25])
        XCTAssertEqual(updates[7].state, CaptureState.steadying)
        XCTAssertEqual(updates[7].quality, CaptureQuality.blurry)
        XCTAssertEqual(updates[14].progress, 1)
        XCTAssertEqual(updates[15].quality, CaptureQuality.dark)
        XCTAssertEqual(updates[25].quality, CaptureQuality.good)
        XCTAssertEqual(updates[40].state, CaptureState.captured)
        // The outline's colour says nothing of the shutter: green while waiting, never a shot.
        XCTAssertTrue(updates[10].isSteady)
        XCTAssertFalse(updates[10].shouldCapture)
    }

    func testAMovingPageIsNeverTakenHoweverSharp() {
        let tracker = LiveQuadTracker()
        let sharp = LiveFrames.frame()
        for index in 0..<40 {
            // 8 px a frame: never within the 4 px to hold still.
            guard let update = tracker.process(sheetFrame(sharp, index, dx: Double((index % 5) * 8))) else { continue }
            XCTAssertFalse(update.shouldCapture)
            XCTAssertNotEqual(update.state, CaptureState.steadying)
        }
    }

    func testAPhotoTakenCountsThePageAsTakenUntilANewPageComes() {
        let tracker = LiveQuadTracker(quality: goodReadings)
        let sharp = LiveFrames.frame()
        var fired: [Int] = []
        for index in 0..<60 {
            var dx: Double = index % 2 == 0 ? 1 : -1
            if index >= 40 { dx += 100 }               // the next page laid 100 px aside
            if let update = tracker.process(sheetFrame(sharp, index, dx: dx)), update.shouldCapture {
                fired.append(index)
            }
            // Taken by hand while the page holds still, before the shutter would have fired.
            if index == 3 {
                tracker.markCaptured()
            }
        }
        // Never taken again until the next page came: its jump believed on its second sighting (41), steady from 42,
        // taken at 48.
        XCTAssertEqual(fired, [48])
    }

    func testAPauseKeepsThePageTakenWhileAResetForgetsIt() {
        let tracker = LiveQuadTracker(quality: goodReadings)
        let sharp = LiveFrames.frame()
        func run(from start: Double) -> Int {
            var shots = 0
            for index in 0..<20 {
                if let update = tracker.process(sheetFrame(sharp, index, dx: index % 2 == 0 ? 1 : -1, from: start)),
                   update.shouldCapture {
                    shots += 1
                }
            }
            return shots
        }
        XCTAssertEqual(run(from: 0), 1)
        // Paused (the corner editor was open) with the same page still in view: not taken again.
        tracker.pause()
        XCTAssertEqual(run(from: 5000), 0)
        // Reset (the screen closed): forgotten, so the page is taken again.
        tracker.reset()
        XCTAssertEqual(run(from: 10000), 1)
    }

    func testAFrameTooSoonIsPassedOverAndAClockThatStartsOverStartsAgain() {
        let tracker = LiveQuadTracker()
        XCTAssertNotNil(tracker.process(plainFrame(1000)))
        XCTAssertNil(tracker.process(plainFrame(1033)))
        XCTAssertNil(tracker.process(plainFrame(1066)))
        XCTAssertNil(tracker.process(plainFrame(1089.9)))
        XCTAssertNotNil(tracker.process(plainFrame(1090)))
        // The camera started again: its clock begins anew, and so does the tracker.
        XCTAssertNotNil(tracker.process(plainFrame(20)))
        XCTAssertNil(tracker.process(plainFrame(40)))
        // A frame of another size starts over too.
        XCTAssertNotNil(tracker.process(plainFrame(200, width: 48, height: 64)))
    }

    func testTheModelsPageIsFollowedWhenSureAndKeptForAMomentWhenMissed() {
        let tracker = LiveQuadTracker(quality: goodReadings)
        let sure = QuadCandidate(quad: stubQuad, confidence: 0.9)
        let expected = LiveQuadTracker.normalized(stubQuad, width: 64, height: 48)
        // Drawn from the second sighting.
        XCTAssertNil(tracker.process(plainFrame(0, page: sure))?.outline)
        XCTAssertEqual(tracker.process(plainFrame(100, page: sure))?.outline, expected)
        // Too unsure, a sliver or nothing: the outline is held for 300 ms after the page was last found, then gone.
        XCTAssertEqual(tracker.process(plainFrame(200, page: QuadCandidate(quad: stubQuad, confidence: 0.3)))?.outline, expected)
        let sliver = Quad(topLeft: CGPoint(x: 10, y: 20), topRight: CGPoint(x: 54, y: 20),
                          bottomRight: CGPoint(x: 54, y: 24), bottomLeft: CGPoint(x: 10, y: 24))
        XCTAssertEqual(tracker.process(plainFrame(300, page: QuadCandidate(quad: sliver, confidence: 0.9)))?.outline, expected)
        XCTAssertEqual(tracker.process(plainFrame(400))?.outline, expected)
        XCTAssertNil(tracker.process(plainFrame(500))?.outline)
        // Less sure than holding still needs (0.6): never drawn.
        XCTAssertNil(tracker.process(plainFrame(600, page: QuadCandidate(quad: stubQuad, confidence: 0.55)))?.outline)
        XCTAssertNil(tracker.process(plainFrame(700, page: QuadCandidate(quad: stubQuad, confidence: 0.55)))?.outline)
    }

    func testAPageTheModelFlickersOnIsOutlinedWithoutShaking() {
        let tracker = LiveQuadTracker(quality: goodReadings)
        let image = LiveFrames.frame()
        let page = QuadCandidate(quad: LiveFrames.sheet, confidence: 0.9)
        var outlines: [Quad?] = []
        for index in 0..<20 {
            let seen: QuadCandidate? = index < 2 || index % 2 == 1 ? page : nil
            outlines.append(tracker.process(ScanFrame(image: image, timestampMs: Double(index) * 100, page: seen))?.outline)
        }
        let sheet = LiveQuadTracker.normalized(LiveFrames.sheet, width: 320, height: 240)
        for index in 1..<20 {
            XCTAssertEqual(outlines[index], sheet, "at \(index)")
        }
    }

    func testAPageUnderAFifthOfTheFrameIsFarAndOneAtTheEdgeIsCutOff() {
        let tracker = LiveQuadTracker(quality: goodReadings)
        let image = LiveFrames.frame()
        let far = Quad(topLeft: CGPoint(x: 110, y: 70), topRight: CGPoint(x: 210, y: 70),
                       bottomRight: CGPoint(x: 210, y: 170), bottomLeft: CGPoint(x: 110, y: 170))
        var last: LiveQuadUpdate?
        for index in 0..<4 {
            last = tracker.process(ScanFrame(image: image, timestampMs: Double(index) * 100,
                                             page: QuadCandidate(quad: far, confidence: 1)))
        }
        XCTAssertEqual(last?.placement, CapturePlacement.far)
        let edge = Quad(topLeft: CGPoint(x: 0, y: 10), topRight: CGPoint(x: 230, y: 10),
                        bottomRight: CGPoint(x: 230, y: 200), bottomLeft: CGPoint(x: 0, y: 200))
        let other = LiveQuadTracker(quality: goodReadings)
        for index in 0..<4 {
            last = other.process(ScanFrame(image: image, timestampMs: Double(index) * 100,
                                           page: QuadCandidate(quad: edge, confidence: 1)))
        }
        XCTAssertEqual(last?.placement, CapturePlacement.cutOff)
    }

    func testTheFilterDampsJitter() throws {
        // 320 x 240 (diagonal 400 px): corners tremble +-2 px about the sheet (within the 4 px of jitter).
        var filter = LiveQuadFilter()
        for index in 0..<12 {
            let dx: Double = index % 2 == 0 ? 2 : -2
            let out = filter.update(LiveFrames.sheetMoved(dx), atMs: Double(index) * 100, diagonal: 400)
            if index == 0 {
                XCTAssertNil(out.shown)
                XCTAssertEqual(out.page, LiveFrames.sheetMoved(2))
            } else {
                let shown = try XCTUnwrap(out.shown)
                XCTAssertEqual(out.page, shown)
                if index >= 3 {
                    XCTAssertLessThanOrEqual(shown.maxCornerDistance(LiveFrames.sheet), 1.0, "at \(index)")
                }
            }
        }
    }

    func testTheFilterFollowsARealMoveAndBelievesAJumpOnItsSecondSighting() {
        var filter = LiveQuadFilter()
        _ = filter.update(LiveFrames.sheet, atMs: 0, diagonal: 400)
        _ = filter.update(LiveFrames.sheet, atMs: 100, diagonal: 400)
        // Slid 10 px (more than jitter, less than a jump): followed at once.
        let slid = filter.update(LiveFrames.sheetMoved(10), atMs: 200, diagonal: 400)
        XCTAssertEqual(slid.shown, LiveFrames.sheetMoved(10))
        XCTAssertEqual(slid.page, LiveFrames.sheetMoved(10))
        // Jumped 40 px (10 %): passed over once, then followed when found there again.
        let jumped = filter.update(LiveFrames.sheetMoved(50), atMs: 300, diagonal: 400)
        XCTAssertNil(jumped.page)
        XCTAssertEqual(jumped.shown, LiveFrames.sheetMoved(10))
        let again = filter.update(LiveFrames.sheetMoved(51), atMs: 400, diagonal: 400)
        XCTAssertEqual(again.shown, LiveFrames.sheetMoved(51))
        XCTAssertEqual(again.page, LiveFrames.sheetMoved(51))
        // A jump seen once only (a stray outline) changes nothing.
        _ = filter.update(LiveFrames.sheetMoved(51), atMs: 500, diagonal: 400)
        let stray = filter.update(LiveFrames.sheetMoved(-60), atMs: 600, diagonal: 400)
        XCTAssertNil(stray.page)
        XCTAssertEqual(stray.shown, LiveFrames.sheetMoved(51))
        // Corners named from another edge are the same page, not a jump.
        let sheet = LiveFrames.sheetMoved(51)
        let renamed = Quad(topLeft: sheet.bottomLeft, topRight: sheet.topLeft, bottomRight: sheet.topRight,
                           bottomLeft: sheet.bottomRight)
        XCTAssertEqual(filter.update(renamed, atMs: 700, diagonal: 400).shown, sheet)
    }

    func testTheFilterHoldsALostPageThenClearsIt() {
        var filter = LiveQuadFilter()
        _ = filter.update(LiveFrames.sheet, atMs: 0, diagonal: 400)
        _ = filter.update(LiveFrames.sheet, atMs: 100, diagonal: 400)
        // Missed: kept for 300 ms after it was last found, with no page for the shutter.
        for t in [200.0, 300.0, 400.0] {
            let missed = filter.update(nil, atMs: t, diagonal: 400)
            XCTAssertNil(missed.page)
            XCTAssertEqual(missed.shown, LiveFrames.sheet, "at \(t)")
        }
        XCTAssertNil(filter.update(nil, atMs: 500, diagonal: 400).shown)
        // Found again after that: a new page, drawn from its second sighting.
        let first = filter.update(LiveFrames.sheet, atMs: 600, diagonal: 400)
        XCTAssertNil(first.shown)
        XCTAssertEqual(first.page, LiveFrames.sheet)
        XCTAssertEqual(filter.update(LiveFrames.sheet, atMs: 700, diagonal: 400).shown, LiveFrames.sheet)
    }

    func testTheFrameScalerAveragesFourPixelsOfEachBlockAndTurnsBGRAIntoRGBA() throws {
        // 8 x 6 BGRA, 40 bytes a row (8 bytes of padding): blue = x, green = y, red = 10x + y.
        let width = 8, height = 6, bytesPerRow = 40
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        for y in 0..<height {
            for x in 0..<width {
                let o = y * bytesPerRow + x * 4
                bytes[o] = UInt8(x)
                bytes[o + 1] = UInt8(y)
                bytes[o + 2] = UInt8(10 * x + y)
                bytes[o + 3] = 255
            }
        }
        // At most 4 px long: blocks of 2 x 2, all four pixels averaged.
        let small = bytes.withUnsafeBytes {
            FrameScaler.downscaled(bgra: $0, width: width, height: height, bytesPerRow: bytesPerRow, maxLongSide: 4)
        }
        let image = try XCTUnwrap(small)
        XCTAssertEqual(image.width, 4)
        XCTAssertEqual(image.height, 3)
        // Pixel (1, 2) covers x 2...3, y 4...5: red (24 + 34 + 25 + 35) / 4 = 29.5, half up.
        let o = (2 * 4 + 1) * 4
        XCTAssertEqual(image.pixels[o], 30)
        XCTAssertEqual(image.pixels[o + 1], 5)
        XCTAssertEqual(image.pixels[o + 2], 3)
        XCTAssertEqual(image.pixels[o + 3], 255)
        // Small enough already: kept pixel for pixel.
        let same = bytes.withUnsafeBytes {
            FrameScaler.downscaled(bgra: $0, width: width, height: height, bytesPerRow: bytesPerRow, maxLongSide: 480)
        }
        let whole = try XCTUnwrap(same)
        XCTAssertEqual(whole.width, 8)
        XCTAssertEqual(whole.height, 6)
        let p = (3 * 8 + 5) * 4
        XCTAssertEqual(whole.pixels[p], 53)
        XCTAssertEqual(whole.pixels[p + 1], 3)
        XCTAssertEqual(whole.pixels[p + 2], 5)
        // Too few bytes, or rows too short: refused.
        XCTAssertNil(bytes.withUnsafeBytes {
            FrameScaler.downscaled(bgra: $0, width: width, height: height + 1, bytesPerRow: bytesPerRow, maxLongSide: 4)
        })
        XCTAssertNil(bytes.withUnsafeBytes {
            FrameScaler.downscaled(bgra: $0, width: width, height: height, bytesPerRow: 16, maxLongSide: 4)
        })
    }

    func testALiveOutlineIsTurnedIntoTheUprightPhoto() {
        let outline = Quad(topLeft: CGPoint(x: 0.1, y: 0.2), topRight: CGPoint(x: 0.5, y: 0.2),
                           bottomRight: CGPoint(x: 0.5, y: 0.6), bottomLeft: CGPoint(x: 0.1, y: 0.6))
        assertQuad(LiveQuadTracker.photoOutline(outline, rotationDegrees: 0), outline, accuracy: 1e-12)
        assertQuad(LiveQuadTracker.photoOutline(outline, rotationDegrees: 360), outline, accuracy: 1e-12)
        // A quarter clockwise (the phone held upright): the sensor's top left is the photo's top right.
        let quarter = Quad(topLeft: CGPoint(x: 0.4, y: 0.1), topRight: CGPoint(x: 0.8, y: 0.1),
                           bottomRight: CGPoint(x: 0.8, y: 0.5), bottomLeft: CGPoint(x: 0.4, y: 0.5))
        assertQuad(LiveQuadTracker.photoOutline(outline, rotationDegrees: 90), quarter, accuracy: 1e-12)
        assertQuad(LiveQuadTracker.photoOutline(outline, rotationDegrees: -270), quarter, accuracy: 1e-12)
        let half = Quad(topLeft: CGPoint(x: 0.5, y: 0.4), topRight: CGPoint(x: 0.9, y: 0.4),
                        bottomRight: CGPoint(x: 0.9, y: 0.8), bottomLeft: CGPoint(x: 0.5, y: 0.8))
        assertQuad(LiveQuadTracker.photoOutline(outline, rotationDegrees: 180), half, accuracy: 1e-12)
        let threeQuarters = Quad(topLeft: CGPoint(x: 0.2, y: 0.5), topRight: CGPoint(x: 0.6, y: 0.5),
                                 bottomRight: CGPoint(x: 0.6, y: 0.9), bottomLeft: CGPoint(x: 0.2, y: 0.9))
        assertQuad(LiveQuadTracker.photoOutline(outline, rotationDegrees: 270), threeQuarters, accuracy: 1e-12)
        // Any other turn is not a photo's.
        XCTAssertNil(LiveQuadTracker.photoOutline(outline, rotationDegrees: 45))
    }

    // The frame turned upright by `RgbaImage.rotatedQuarterTurns` for the model and the corners turned back by
    // `photoOutline` land on the same pixels.
    func testCornersFoundOnTheUprightFrameTurnBackOntoTheSensorsPixels() throws {
        let width = 48, height = 36
        let marks: [(x: Int, y: Int)] = [(5, 4), (40, 7), (37, 30), (8, 27)]
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for (index, mark) in marks.enumerated() {
            let at = (mark.y * width + mark.x) * 4
            pixels[at] = UInt8(100 + index * 40)
            pixels[at + 3] = 255
        }
        let frame = RgbaImage(width: width, height: height, pixels: pixels)
        for turn in [0, 90, 180, 270] {
            let upright = frame.rotatedQuarterTurns(turn / 90)
            var found: [CGPoint] = []
            for index in 0..<4 {
                let wanted = UInt8(100 + index * 40)
                for at in 0..<(upright.width * upright.height) where upright.pixels[at * 4] == wanted {
                    found.append(CGPoint(x: (Double(at % upright.width) + 0.5) / Double(upright.width),
                                         y: (Double(at / upright.width) + 0.5) / Double(upright.height)))
                }
            }
            XCTAssertEqual(found.count, 4, "turn \(turn)")
            let back = try XCTUnwrap(LiveQuadTracker.photoOutline(Quad.fromCorners(found), rotationDegrees: (360 - turn) % 360))
            let sensor = back.scaled(Double(width), Double(height))
            for mark in marks {
                let centre = CGPoint(x: Double(mark.x) + 0.5, y: Double(mark.y) + 0.5)
                let nearest = sensor.corners.map { corner -> Double in
                    let dx = Double(corner.x - centre.x), dy = Double(corner.y - centre.y)
                    return (dx * dx + dy * dy).squareRoot()
                }.min() ?? Double.infinity
                XCTAssertLessThan(nearest, 1e-6, "turn \(turn), mark \(mark)")
            }
        }
    }
}

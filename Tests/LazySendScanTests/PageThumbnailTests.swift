import XCTest
@testable import LazySendScan

final class PageThumbnailTests: XCTestCase {
    func testThePageSeenAgainMatchesEvenInAnotherExposure() {
        let sharp = PageThumbnail(LiveFrames.frame(), page: LiveFrames.sheet)
        let shifted = PageThumbnail(LiveFrames.frame(), page: LiveFrames.sheetMoved(2))
        let dimmed = PageThumbnail(LiveFrames.frame(dim: 150), page: LiveFrames.sheet)
        XCTAssertTrue(sharp.matches(sharp))
        XCTAssertTrue(sharp.matches(shifted))
        XCTAssertTrue(sharp.matches(dimmed))
    }

    func testAnotherPageDoesNotMatch() {
        let frame: RgbaImage = LiveFrames.frame()
        let written: RgbaImage = barred(frame)
        let blank = PageThumbnail(frame, page: LiveFrames.sheet)
        let text = PageThumbnail(written, page: LiveFrames.sheet)
        XCTAssertFalse(blank.matches(text))
        XCTAssertFalse(text.matches(blank))
    }

    func testTwoSparsePagesWithTheirTextAtOtherHeightsDoNotMatch() {
        let high = PageThumbnail(textLine(at: 70), page: LiveFrames.sheet)
        let low = PageThumbnail(textLine(at: 150), page: LiveFrames.sheet)
        XCTAssertTrue(high.matches(PageThumbnail(textLine(at: 70), page: LiveFrames.sheetMoved(2))))
        XCTAssertFalse(high.matches(low))
        XCTAssertFalse(low.matches(high))
    }

    func testABlankSheetSeenCloserUpStillMatches() {
        let far = PageThumbnail(sheetFrame(x: 80, y: 40, width: 160, height: 160, paper: 200, table: 80),
                                page: quad(x: 80, y: 40, width: 160, height: 160))
        let near = PageThumbnail(sheetFrame(x: 50, y: 20, width: 220, height: 200, paper: 200, table: 80),
                                 page: quad(x: 50, y: 20, width: 220, height: 200))
        XCTAssertTrue(far.matches(near))
        XCTAssertTrue(near.matches(far))
    }

    func testWhiteAndKraftSheetsOnADarkTableDoNotMatch() {
        let white = PageThumbnail(sheetFrame(x: 26, y: 20, width: 268, height: 200, paper: 230, table: 40),
                                  page: quad(x: 26, y: 20, width: 268, height: 200))
        let kraft = PageThumbnail(sheetFrame(x: 26, y: 20, width: 268, height: 200, paper: 150, table: 40),
                                  page: quad(x: 26, y: 20, width: 268, height: 200))
        XCTAssertFalse(white.matches(kraft))
        XCTAssertFalse(kraft.matches(white))
    }

    func testBlankLooksMatchByBrightness() {
        let grey = PageThumbnail(RgbaImage.filled(width: 64, height: 48, r: 90, g: 90, b: 90), page: nil)
        let nearGrey = PageThumbnail(RgbaImage.filled(width: 64, height: 48, r: 96, g: 96, b: 96), page: nil)
        let white = PageThumbnail(RgbaImage.filled(width: 64, height: 48, r: 230, g: 230, b: 230), page: nil)
        XCTAssertTrue(grey.matches(nearGrey))
        XCTAssertFalse(grey.matches(white))
    }
}

private func quad(x: Double, y: Double, width: Double, height: Double) -> Quad {
    Quad(topLeft: CGPoint(x: x, y: y), topRight: CGPoint(x: x + width, y: y),
         bottomRight: CGPoint(x: x + width, y: y + height), bottomLeft: CGPoint(x: x, y: y + height))
}

/// A `LiveFrames`-sized frame of a plain `table` with a plain sheet of `paper` luma on it.
private func sheetFrame(x: Int, y: Int, width: Int, height: Int, paper: UInt8, table: UInt8) -> RgbaImage {
    var pixels: [UInt8] = []
    for row in 0..<LiveFrames.height {
        for col in 0..<LiveFrames.width {
            let onSheet: Bool = col >= x && col < x + width && row >= y && row < y + height
            let v: UInt8 = onSheet ? paper : table
            pixels += [v, v, v, 255]
        }
    }
    return RgbaImage(width: LiveFrames.width, height: LiveFrames.height, pixels: pixels)
}

/// The plain sheet with one dark line of print, 4 px tall, across it at row `y`.
private func textLine(at y: Int) -> RgbaImage {
    let frame: RgbaImage = LiveFrames.frame()
    var pixels: [UInt8] = frame.pixels
    for row in y..<y + 4 {
        for x in 100..<220 {
            let o: Int = (row * frame.width + x) * 4
            pixels[o] = 40
            pixels[o + 1] = 40
            pixels[o + 2] = 40
        }
    }
    return RgbaImage(width: frame.width, height: frame.height, pixels: pixels)
}

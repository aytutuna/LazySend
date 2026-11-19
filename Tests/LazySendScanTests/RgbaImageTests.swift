import CoreGraphics
import XCTest
@testable import LazySendScan

final class RgbaImageTests: XCTestCase {
    /// An image whose red channel holds the given values, green and blue 0, opaque.
    private func reds(_ width: Int, _ height: Int, _ values: [UInt8]) -> RgbaImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for (i, value) in values.enumerated() {
            pixels[i * 4] = value
            pixels[i * 4 + 3] = 255
        }
        return RgbaImage(width: width, height: height, pixels: pixels)
    }

    private func redsOf(_ image: RgbaImage) -> [UInt8] {
        (0..<(image.width * image.height)).map { image.pixels[$0 * 4] }
    }

    private func channel(_ image: RgbaImage, _ c: Int) -> [UInt8] {
        (0..<(image.width * image.height)).map { image.pixels[$0 * 4 + c] }
    }

    func test_filled_isOpaqueAndOneColor() {
        let image = RgbaImage.filled(width: 2, height: 1, r: 10, g: 20, b: 30)
        XCTAssertEqual(image.pixels, [10, 20, 30, 255, 10, 20, 30, 255])
    }

    func test_resized_minifying_averagesTheCoveredPixels_roundingDown() {
        // 4 × 2 → 2 × 1: each output pixel is the mean of a 2 × 2 block.
        let image = reds(4, 2, [0, 10, 20, 31, 40, 50, 60, 70])
        XCTAssertEqual(redsOf(image.resized(width: 2, height: 1)), [25, 45])
        // 3 × 1 → 2 × 1: the blocks overlap (columns 0–1 and 1–2).
        XCTAssertEqual(redsOf(reds(3, 1, [10, 20, 40]).resized(width: 2, height: 1)), [15, 30])
        // Alpha is averaged too.
        XCTAssertEqual(image.resized(width: 2, height: 1).pixels[3], 255)
    }

    func test_resized_magnifying_isBilinear_withWhiteOutside_andRoundsHalfToEven() {
        // 2 × 1 → 4 × 1: samples at x = -0.25, 0.25, 0.75, 1.25.
        let image = RgbaImage(width: 2, height: 1, pixels: [0, 10, 0, 255, 2, 20, 0, 255]).resized(width: 4, height: 1)
        XCTAssertEqual(redsOf(image), [64, 0, 2, 65])            // 0.5 → 0, 1.5 → 2
        XCTAssertEqual(channel(image, 1), [71, 12, 18, 79])      // 12.5 → 12, 17.5 → 18
        XCTAssertEqual(channel(image, 2), [64, 0, 0, 64])
    }

    func test_resized_sameSize_isTheSameImage() {
        let image = reds(2, 2, [1, 2, 3, 4])
        XCTAssertEqual(image.resized(width: 2, height: 2), image)
    }

    func test_rotatedQuarterTurns_turnsClockwise() {
        // 2 wide × 3 tall:  0 1 / 2 3 / 4 5
        let image = reds(2, 3, [0, 1, 2, 3, 4, 5])
        let once = image.rotatedQuarterTurns(1)
        XCTAssertEqual(once.width, 3)
        XCTAssertEqual(once.height, 2)
        XCTAssertEqual(redsOf(once), [4, 2, 0, 5, 3, 1])
        XCTAssertEqual(redsOf(image.rotatedQuarterTurns(2)), [5, 4, 3, 2, 1, 0])
        XCTAssertEqual(redsOf(image.rotatedQuarterTurns(3)), [1, 3, 5, 0, 2, 4])
        XCTAssertEqual(image.rotatedQuarterTurns(3), image.rotatedQuarterTurns(-1))
        XCTAssertEqual(image.rotatedQuarterTurns(4), image)
    }

    func test_cropped_clampsToTheImage_andRoundsOutward() throws {
        let image = reds(3, 3, [0, 1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertEqual(redsOf(try XCTUnwrap(image.cropped(CGRect(x: 1, y: 1, width: 2, height: 2)))), [4, 5, 7, 8])
        XCTAssertEqual(redsOf(try XCTUnwrap(image.cropped(CGRect(x: 0.5, y: 0.5, width: 1, height: 1)))), [0, 1, 3, 4])
        XCTAssertEqual(redsOf(try XCTUnwrap(image.cropped(CGRect(x: 2, y: 2, width: 5, height: 5)))), [8])
        XCTAssertNil(image.cropped(CGRect(x: 3, y: 0, width: 2, height: 2)))
    }

    func test_extractRotated_uprightRegion_copiesThePixels() throws {
        let image = reds(3, 3, [0, 1, 2, 3, 4, 5, 6, 7, 8])
        let same = try XCTUnwrap(image.extractRotated(center: CGPoint(x: 1.5, y: 1.5),
                                                      size: CGSize(width: 3, height: 3), angleDegrees: 0))
        XCTAssertEqual(same.pixels, image.pixels)
        // A region a quarter turn clockwise comes out turned back: the image a quarter turn counterclockwise.
        let turned = try XCTUnwrap(image.extractRotated(center: CGPoint(x: 1.5, y: 1.5),
                                                        size: CGSize(width: 3, height: 3), angleDegrees: 90))
        XCTAssertEqual(redsOf(turned), redsOf(image.rotatedQuarterTurns(3)))
        // Outside the image: the fill color.
        let outside = try XCTUnwrap(image.extractRotated(center: CGPoint(x: 10, y: 10), size: CGSize(width: 1, height: 1),
                                                         angleDegrees: 0, fillR: 7, fillG: 8, fillB: 9))
        XCTAssertEqual(outside.pixels, [7, 8, 9, 255])
        XCTAssertNil(image.extractRotated(center: CGPoint(x: 1, y: 1), size: CGSize(width: 0.4, height: 2), angleDegrees: 0))
    }

    func test_extractRotated_onePixelStripes_keepTheirContrast() throws {
        // Black and white columns one pixel wide, read a quarter pixel off: Catmull-Rom gives 40 and
        // 215; bilinear would give 64 and 191.
        let columns: [UInt8] = (0..<40).map { $0 % 2 == 0 ? 0 : 255 }
        let image = reds(40, 3, columns + columns + columns)
        let shifted = try XCTUnwrap(image.extractRotated(center: CGPoint(x: 20.25, y: 1.5),
                                                         size: CGSize(width: 40, height: 3), angleDegrees: 0))
        let row = redsOf(shifted)[40..<80]
        for x in 4..<36 {
            XCTAssertEqual(row[40 + x], x % 2 == 0 ? 40 : 215)
        }
    }

    func test_copy_isIndependent() {
        let image = reds(1, 1, [9])
        var copy = image
        copy.pixels[0] = 1
        XCTAssertEqual(image.pixels[0], 9)
    }

    func test_cgImageRoundTrip_keepsThePixels() throws {
        let image = reds(3, 2, [0, 50, 100, 150, 200, 250])
        let cgImage = try XCTUnwrap(image.makeCGImage())
        XCTAssertEqual(cgImage.width, 3)
        XCTAssertEqual(cgImage.height, 2)
        XCTAssertEqual(try XCTUnwrap(RgbaImage(cgImage: cgImage)), image)
    }
}

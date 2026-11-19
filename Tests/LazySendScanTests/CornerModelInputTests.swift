import XCTest
@testable import LazySendScan

/// A `width` × `height` photo whose pixel (x, y) is `color(x, y)` (red, green, blue), opaque.
private func photo(_ width: Int, _ height: Int, _ color: (Int, Int) -> (Int, Int, Int)) -> RgbaImage {
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let (r, g, b) = color(x, y)
            let i = (y * width + x) * 4
            pixels[i] = UInt8(r)
            pixels[i + 1] = UInt8(g)
            pixels[i + 2] = UInt8(b)
        }
    }
    return RgbaImage(width: width, height: height, pixels: pixels)
}

private let plane = CornerModelInput.side * CornerModelInput.side

/// The input's value in `channel` (0 blue, 1 green, 2 red) at (x, y).
private func inputValue(_ input: [Float], _ channel: Int, _ x: Int, _ y: Int) -> Float {
    input[channel * plane + y * CornerModelInput.side + x]
}

final class CornerModelInputTests: XCTestCase {
    func testTheInputIsBlueGreenAndRedPlanesFromZeroToOne() {
        let input = CornerModelInput.make(RgbaImage.filled(width: 300, height: 200, r: 255, g: 128, b: 0))
        XCTAssertEqual(input.count, 3 * 256 * 256)
        for (x, y) in [(0, 0), (255, 0), (17, 93), (255, 255)] {
            XCTAssertEqual(inputValue(input, 0, x, y), 0)
            XCTAssertEqual(inputValue(input, 1, x, y), Float(128.0 / 255))
            XCTAssertEqual(inputValue(input, 2, x, y), 1)
        }
    }

    func testHalvingTakesTheMeanOfEachPairOfPixels() {
        // 512 wide: input column x reads photo columns 2x and 2x + 1 half and half; 256 high: rows 1 to 1.
        let input = CornerModelInput.make(photo(512, 256) { x, y in (x & 255, y, 0) })
        XCTAssertEqual(inputValue(input, 2, 10, 7), Float(20.5 / 255))
        XCTAssertEqual(inputValue(input, 2, 127, 7), Float(254.5 / 255))
        XCTAssertEqual(inputValue(input, 2, 128, 7), Float(0.5 / 255))
        XCTAssertEqual(inputValue(input, 2, 200, 7), Float(144.5 / 255))
        XCTAssertEqual(inputValue(input, 1, 10, 7), Float(7.0 / 255))
        XCTAssertEqual(inputValue(input, 1, 10, 255), 1)
    }

    func testEnlargingBlendsTheNearestPixelsAndClampsAtTheEdges() {
        // 2 × 2: red 0 on the left and 255 on the right, green 0 at the top and 255 at the bottom.
        let input = CornerModelInput.make(photo(2, 2) { x, y in (255 * x, 255 * y, 0) })
        XCTAssertEqual(inputValue(input, 2, 0, 0), 0)
        XCTAssertEqual(inputValue(input, 2, 63, 0), 0)
        XCTAssertEqual(inputValue(input, 2, 64, 0), Float(0.99609375 / 255))
        XCTAssertEqual(inputValue(input, 2, 128, 0), Float(128.49609375 / 255))
        XCTAssertEqual(inputValue(input, 2, 255, 0), 1)
        XCTAssertEqual(inputValue(input, 1, 0, 128), Float(128.49609375 / 255))
        XCTAssertEqual(inputValue(input, 1, 0, 255), 1)
    }

    func testAnOddSizedPhotoGivesTheSameNumbersOnBothPlatforms() {
        let input = CornerModelInput.make(photo(300, 200) { x, y in ((x * 7 + y * 3) & 255, (x * y) & 255, (x + 2 * y) & 255) })
        XCTAssertEqual(input[0], 0.00033700981293804944)
        XCTAssertEqual(input[1], 0.00493259821087122)
        XCTAssertEqual(input[255], 0.16829043626785278)
        XCTAssertEqual(input[25637], 0.7822610139846802)
        XCTAssertEqual(input[131071], 0.4466605484485626)
        XCTAssertEqual(input[163969], 0.30775123834609985)
        var sum: Double = 0
        for v in input {
            sum += Double(v)
        }
        XCTAssertEqual(sum, 96996.50867031487)
    }
}

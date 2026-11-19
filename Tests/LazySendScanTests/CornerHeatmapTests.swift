import CoreGraphics
import Foundation
import XCTest
@testable import LazySendScan

/// Four channels of `size` × `size` values, all 0 until spots are added.
struct DrawnHeatmap {
    let size: Int
    var values: [Float]

    init(size: Int) {
        self.size = size
        self.values = [Float](repeating: 0, count: size * size * 4)
    }

    /// A Gaussian spot of `peak` and `sigma` (in values) centred on (`x`, `y`), in the values' own units
    /// (value i covers [i, i + 1)), added to `channel`.
    mutating func spot(_ channel: Int, x: Double, y: Double, peak: Double = 0.9, sigma: Double = 2) {
        var row: Int = 0
        while row < size {
            var column: Int = 0
            while column < size {
                let dx: Double = Double(column) + 0.5 - x
                let dy: Double = Double(row) + 0.5 - y
                let value: Double = peak * exp(-(dx * dx + dy * dy) / (2 * sigma * sigma))
                let index: Int = channel * size * size + row * size + column
                values[index] = max(values[index], Float(value))
                column += 1
            }
            row += 1
        }
    }

    /// The highest value drawn in `channel`. Spots centred between values peak lower than asked.
    func peak(_ channel: Int) -> Double {
        Double(values[channel * size * size ..< (channel + 1) * size * size].max() ?? 0)
    }

    var weakestPeak: Double {
        min(peak(0), peak(1), peak(2), peak(3))
    }
}

final class CornerHeatmapTests: XCTestCase {
    private let size: Int = 64
    /// A page a little turned, its corners in the values' units.
    private let page: [CGPoint] = [CGPoint(x: 12, y: 10), CGPoint(x: 50, y: 14), CGPoint(x: 48, y: 56),
                                   CGPoint(x: 9, y: 52)]

    private func drawnPage(peaks: [Double] = [0.9, 0.9, 0.9, 0.9]) -> DrawnHeatmap {
        var heat = DrawnHeatmap(size: size)
        var channel: Int = 0
        while channel < 4 {
            heat.spot(channel, x: Double(page[channel].x), y: Double(page[channel].y), peak: peaks[channel])
            channel += 1
        }
        return heat
    }

    func test_fourSpots_giveTheCornersInOrder_asSharesOfTheImage() throws {
        let heat: DrawnHeatmap = drawnPage()
        let found: QuadCandidate = try XCTUnwrap(CornerHeatmap.decode(heat.values, width: size, height: size))
        let expected: [CGPoint] = page
        var index: Int = 0
        for corner in found.quad.corners {
            XCTAssertEqual(Double(corner.x) * Double(size), Double(expected[index].x), accuracy: 0.01, "corner \(index)")
            XCTAssertEqual(Double(corner.y) * Double(size), Double(expected[index].y), accuracy: 0.01, "corner \(index)")
            index += 1
        }
        XCTAssertEqual(found.confidence, heat.weakestPeak, accuracy: 1e-6)
    }

    func test_theConfidence_isTheWeakestChannelsPeak() throws {
        let heat: DrawnHeatmap = drawnPage(peaks: [0.95, 0.6, 0.8, 0.9])
        let found: QuadCandidate = try XCTUnwrap(CornerHeatmap.decode(heat.values, width: size, height: size))
        XCTAssertEqual(found.confidence, heat.peak(1), accuracy: 1e-6)
    }

    func test_theLargestBlob_winsOverASmallerBrighterOne() throws {
        var heat: DrawnHeatmap = drawnPage()
        // A small bright spot far from the top-left corner's wide one.
        heat.spot(0, x: 40.5, y: 40.5, peak: 1.0, sigma: 0.8)
        let found: QuadCandidate = try XCTUnwrap(CornerHeatmap.decode(heat.values, width: size, height: size))
        XCTAssertEqual(Double(found.quad.topLeft.x) * Double(size), 12, accuracy: 0.01)
        XCTAssertEqual(Double(found.quad.topLeft.y) * Double(size), 10, accuracy: 0.01)
        XCTAssertEqual(found.confidence, heat.weakestPeak, accuracy: 1e-6)
    }

    func test_anEmptyChannel_givesNothing() {
        var heat = DrawnHeatmap(size: size)
        heat.spot(0, x: 12, y: 10)
        heat.spot(1, x: 50, y: 14)
        heat.spot(3, x: 9, y: 52)
        XCTAssertNil(CornerHeatmap.decode(heat.values, width: size, height: size))
        // A channel whose values all stay under the threshold is as empty.
        heat.spot(2, x: 48, y: 56, peak: 0.25)
        XCTAssertNil(CornerHeatmap.decode(heat.values, width: size, height: size))
    }

    func test_cornersOutOfOrder_giveNothing() {
        var heat = DrawnHeatmap(size: size)
        heat.spot(0, x: 12, y: 10)
        heat.spot(1, x: 48, y: 56)
        heat.spot(2, x: 50, y: 14)
        heat.spot(3, x: 9, y: 52)
        XCTAssertNil(CornerHeatmap.decode(heat.values, width: size, height: size))
    }

    func test_aSpotBetweenValues_isFoundToAFractionOfAValue() throws {
        var heat = DrawnHeatmap(size: size)
        heat.spot(0, x: 20.25, y: 10.75)
        heat.spot(1, x: 50.6, y: 14.3)
        heat.spot(2, x: 48, y: 56)
        heat.spot(3, x: 9, y: 52)
        let found: QuadCandidate = try XCTUnwrap(CornerHeatmap.decode(heat.values, width: size, height: size))
        let x: Double = Double(found.quad.topLeft.x) * Double(size)
        let y: Double = Double(found.quad.topLeft.y) * Double(size)
        XCTAssertEqual(x, 20.25, accuracy: 0.1)
        XCTAssertEqual(y, 10.75, accuracy: 0.1)
        XCTAssertEqual(Double(found.quad.topRight.x) * Double(size), 50.6, accuracy: 0.1)
        XCTAssertEqual(Double(found.quad.topRight.y) * Double(size), 14.3, accuracy: 0.1)
    }

    func test_aNonSquareHeatmap_isReadAsSharesOfEachSide() throws {
        let width: Int = 32
        let height: Int = 16
        var values = [Float](repeating: 0, count: width * height * 4)
        let spots: [(Int, Int)] = [(4, 3), (27, 3), (27, 12), (4, 12)]
        var channel: Int = 0
        while channel < 4 {
            values[channel * width * height + spots[channel].1 * width + spots[channel].0] = 0.8
            channel += 1
        }
        let found: QuadCandidate = try XCTUnwrap(CornerHeatmap.decode(values, width: width, height: height))
        XCTAssertEqual(Double(found.quad.topLeft.x), 4.5 / 32, accuracy: 1e-9)
        XCTAssertEqual(Double(found.quad.topLeft.y), 3.5 / 16, accuracy: 1e-9)
        XCTAssertEqual(Double(found.quad.bottomRight.x), 27.5 / 32, accuracy: 1e-9)
        XCTAssertEqual(Double(found.quad.bottomRight.y), 12.5 / 16, accuracy: 1e-9)
        XCTAssertNil(CornerHeatmap.decode(Array(values.prefix(10)), width: width, height: height))
    }
}

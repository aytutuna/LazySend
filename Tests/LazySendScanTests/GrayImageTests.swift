import XCTest
@testable import LazySendScan

final class GrayImageTests: XCTestCase {

    func test_luma_usesRoundedRec601Luma() {
        let rgba: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255]
        let gray = GrayImage.luma(RgbaImage(width: 4, height: 1, pixels: rgba))
        XCTAssertEqual(gray.pixels, [76, 150, 29, 255])
        XCTAssertEqual(gray.dpi, 100)
        XCTAssertEqual(gray.scale, 1)
    }

    func test_downsampled_averagesTheCoveredPixels_roundingDown() {
        let gray = GrayImage(width: 4, height: 2, pixels: [0, 10, 20, 31, 40, 50, 60, 70], dpi: 200)
        let half = gray.downsampled(width: 2, height: 1)
        XCTAssertEqual(half.pixels, [25, 45])
        XCTAssertEqual(half.dpi, 100)
        XCTAssertEqual(half.scale, 0.5)
        XCTAssertEqual(GrayImage(width: 3, height: 1, pixels: [10, 20, 40]).downsampled(width: 2, height: 1).pixels, [15, 30])
        XCTAssertEqual(gray.downsampled(width: 4, height: 2), gray)
        XCTAssertEqual(gray.downsampled(width: 9, height: 9), gray)
    }

    func test_downsampled_matchesRgbaImageResized() {
        let rng = TestPages.Rng(77)
        var pixels = [UInt8](repeating: 0, count: 37 * 23)
        for i in 0..<pixels.count { pixels[i] = UInt8(rng.below(256)) }
        let gray = GrayImage(width: 37, height: 23, pixels: pixels)
        let rgba = gray.toRgba()
        for (w, h) in [(10, 7), (36, 22), (1, 1), (19, 23)] {
            XCTAssertEqual(GrayImage.luma(rgba.resized(width: w, height: h)).pixels, gray.downsampled(width: w, height: h).pixels)
        }
    }

    func test_fromAScan_isAtTheAnalysisResolution() {
        let scan = TestPages.enlarged(GrayImage(width: 3, height: 2, pixels: [0, 50, 100, 150, 200, 250]), 3)
        let gray = GrayImage.from(scan, sourceDPI: 300)
        XCTAssertEqual(gray.width, 3)
        XCTAssertEqual(gray.height, 2)
        XCTAssertEqual(gray.dpi, 100)
        XCTAssertEqual(gray.scale, 1.0 / 3, accuracy: 1e-12)
        XCTAssertEqual(gray.pixels, [0, 50, 100, 150, 200, 250])
        // No finer than the analysis resolution: kept as it is.
        let coarse = GrayImage.from(scan, sourceDPI: 75)
        XCTAssertEqual(coarse.width, 9)
        XCTAssertEqual(coarse.height, 6)
        XCTAssertEqual(coarse.dpi, 75)
        XCTAssertEqual(coarse.scale, 1)
        XCTAssertEqual(coarse.atResolution(100), coarse)
    }

    func test_subscript_filledAndToRgba() {
        XCTAssertEqual(GrayImage.filled(width: 2, height: 2, value: 9).pixels, [9, 9, 9, 9])
        let image = GrayImage(width: 2, height: 1, pixels: [3, 4])
        XCTAssertEqual(image[1, 0], 4)
        XCTAssertEqual(image.toRgba().pixels, [3, 3, 3, 255, 4, 4, 4, 255])
    }

    // MARK: - BackgroundMap

    func test_percentile_isTheSmallestValueWithEnoughBelowIt() {
        var histogram = [Int](repeating: 0, count: 256)
        for v in 0..<10 { histogram[v] = 1 }
        XCTAssertEqual(BackgroundMap.percentile(histogram, count: 10, fraction: 0.9), 8)
        XCTAssertEqual(BackgroundMap.percentile(histogram, count: 10, fraction: 0.5), 4)
        XCTAssertEqual(BackgroundMap.percentile(histogram, count: 10, fraction: 1.0), 9)
        XCTAssertEqual(BackgroundMap.percentile(histogram, count: 10, fraction: 0), 0)
    }

    /// 100 × 50: left half 200, right half 100.
    private func halves(withSpecks: Bool) -> GrayImage {
        var pixels = [UInt8](repeating: 0, count: 100 * 50)
        for y in 0..<50 {
            for x in 0..<100 { pixels[y * 100 + x] = x < 50 ? 200 : 100 }
        }
        if withSpecks {
            pixels[10 * 100 + 10] = 0
            pixels[10 * 100 + 60] = 0
        }
        return GrayImage(width: 100, height: 50, pixels: pixels)
    }

    func test_estimate_tilesTheAreaWithWholeTiles() throws {
        let gray = halves(withSpecks: true)
        let map = try XCTUnwrap(BackgroundMap.estimate(gray, x: 0, y: 0, width: 100, height: 50, tileSize: 50))
        XCTAssertEqual(map.columns, 2)
        XCTAssertEqual(map.rows, 1)
        XCTAssertEqual(map.tiles, [200, 100])
        // Tiles of 30 over 100 × 50: three of 33–34 across, one down.
        let odd = try XCTUnwrap(BackgroundMap.estimate(gray, x: 0, y: 0, width: 100, height: 50, tileSize: 30))
        XCTAssertEqual(odd.columns, 3)
        XCTAssertEqual(odd.rows, 1)
        XCTAssertEqual(odd.tiles, [200, 200, 100])
        // The area is clamped to the image; an empty one has no map.
        let clamped = try XCTUnwrap(BackgroundMap.estimate(gray, x: 50, y: -5, width: 80, height: 80, tileSize: 25))
        XCTAssertEqual([clamped.x, clamped.y, clamped.width, clamped.height, clamped.columns, clamped.rows],
                       [50, 0, 50, 50, 2, 2])
        XCTAssertNil(BackgroundMap.estimate(gray, x: 100, y: 0, width: 10, height: 10, tileSize: 5))
    }

    func test_valueAt_interpolatesBetweenTileCenters() throws {
        let map = try XCTUnwrap(BackgroundMap.estimate(halves(withSpecks: false), x: 0, y: 0, width: 100, height: 50, tileSize: 50))
        XCTAssertEqual(map.valueAt(x: 0, y: 0), 200)
        XCTAssertEqual(map.valueAt(x: 24, y: 49), 200)
        XCTAssertEqual(map.valueAt(x: 25, y: 0), 199, accuracy: 1e-9)   // center 25.5 is 0.5 px past the first tile's center (25)
        XCTAssertEqual(map.valueAt(x: 49, y: 0), 151, accuracy: 1e-9)
        XCTAssertEqual(map.valueAt(x: 50, y: 0), 149, accuracy: 1e-9)
        XCTAssertEqual(map.valueAt(x: 75, y: 0), 100)
        XCTAssertEqual(map.valueAt(x: 99, y: 49), 100)
        XCTAssertEqual(map.valueAt(x: 500, y: 500), 100)   // outside: the nearest edge of the area
    }

    func test_maxSmoothed_takesTheBrightestNeighbor_clampedBelow_raisesTheFloor() throws {
        // 3 × 3 tiles of 10 px with values 10, 20, … 90 row by row.
        var pixels = [UInt8](repeating: 0, count: 30 * 30)
        for y in 0..<30 {
            for x in 0..<30 { pixels[y * 30 + x] = UInt8(10 * (1 + (y / 10) * 3 + x / 10)) }
        }
        let map = try XCTUnwrap(BackgroundMap.estimate(GrayImage(width: 30, height: 30, pixels: pixels),
                                                       x: 0, y: 0, width: 30, height: 30, tileSize: 10))
        XCTAssertEqual(map.tiles, [10, 20, 30, 40, 50, 60, 70, 80, 90])
        XCTAssertEqual(map.medianTile(), 50)
        XCTAssertEqual(map.maxSmoothed().tiles, [50, 60, 60, 80, 90, 90, 80, 90, 90])
        XCTAssertEqual(map.minSmoothed().tiles, [10, 10, 20, 10, 10, 20, 40, 40, 50])
        XCTAssertEqual(map.clampedBelow(45).tiles, [45, 45, 45, 45, 50, 60, 70, 80, 90])
        XCTAssertEqual(map.tiles, [10, 20, 30, 40, 50, 60, 70, 80, 90])   // unchanged
    }

    func test_inkMask_marksPixelsClearlyDarkerThanThePaper() throws {
        // Paper 200: 141 is 70.5 % of it (not ink), 139 is 69.5 % (ink).
        var pixels = [UInt8](repeating: 200, count: 40 * 40)
        pixels[5 * 40 + 5] = 141
        pixels[5 * 40 + 6] = 139
        pixels[30 * 40 + 30] = 0
        let gray = GrayImage(width: 40, height: 40, pixels: pixels)
        let map = try XCTUnwrap(BackgroundMap.estimate(gray, x: 0, y: 0, width: 40, height: 40, tileSize: 20))
        let mask = map.inkMask(gray, contrast: 0.30)
        XCTAssertEqual(mask.filter { $0 == 1 }.count, 2)
        XCTAssertEqual(mask[5 * 40 + 6], 1)
        XCTAssertEqual(mask[30 * 40 + 30], 1)
        XCTAssertEqual(mask[5 * 40 + 5], 0)
        // A map of part of the image: the mask covers that part only.
        let part = try XCTUnwrap(BackgroundMap.estimate(gray, x: 20, y: 20, width: 20, height: 20, tileSize: 10))
        let partMask = part.inkMask(gray, contrast: 0.30)
        XCTAssertEqual(partMask.count, 400)
        XCTAssertEqual(partMask[10 * 20 + 10], 1)
        XCTAssertEqual(partMask.filter { $0 == 1 }.count, 1)
    }
}

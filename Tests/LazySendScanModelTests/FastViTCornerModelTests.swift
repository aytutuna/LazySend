import CoreGraphics
import Foundation
import XCTest
@testable import LazySendScan
@testable import LazySendScanModel

// DocAligner's FastViT-T8 on the SmartDoc frames in Fixtures/Pages, with Core ML in front and on the CPU alone: every
// corner within 1.5 % of the photo's diagonal of the ground truth, and the page finder within 4 %. Skipped when
// scripts/fetch_docaligner.sh has not fetched the model, unless LAZYSEND_REQUIRE_CORNER_MODEL=1 (CI fetches it), where a
// missing model fails.

final class FastViTCornerModelTests: XCTestCase {
    /// The farthest a corner may lie from the ground truth, as a share of the photo's diagonal.
    private let tolerance: Double = 0.015
    /// The finder moves the model's corners onto the photo's edges, which on the cluttered desk can be a ruled line or a second sheet
    /// near the page's edge, so it is held to less: close enough that the corner editor starts at the page.
    private let finderTolerance: Double = 0.04

    func testEveryPagePhotoReadsAtItsSizeWithItsPageInIt() throws {
        let photos: [PagePhoto] = try PageFixtures.all()
        XCTAssertEqual(photos.count, 6)
        for photo in photos {
            let image: RgbaImage = try PageFixtures.read(photo)
            XCTAssertEqual(image.width, photo.width, photo.file)
            XCTAssertEqual(image.height, photo.height, photo.file)
            XCTAssertTrue(photo.truth.isConvex, photo.file)
            XCTAssertTrue(photo.truth.isInside(width: Double(image.width), height: Double(image.height)), photo.file)
        }
    }

    func testFastViTFindsEveryPageWithinOnePointFivePercentOfTheDiagonal() throws {
        guard FastViTCornerModel.isAvailable else {
            if ProcessInfo.processInfo.environment["LAZYSEND_REQUIRE_CORNER_MODEL"] == "1" {
                XCTFail("The corner model is not in LazySendScanModel's bundle")
                return
            }
            throw XCTSkip("The corner model is not fetched (scripts/fetch_docaligner.sh)")
        }
        let photos: [PagePhoto] = try PageFixtures.all()
        for model in [FastViTCornerModel(), FastViTCornerModel(coreML: false)] {
            let engine: String = model.coreML ? "Core ML" : "CPU"
            for photo in photos {
                let image: RgbaImage = try PageFixtures.read(photo)
                let heat: CornerHeatmaps = try model.run(CornerModelInput.make(image))
                let found: QuadCandidate = try XCTUnwrap(CornerHeatmap.decode(heat.values, width: heat.width,
                                                                               height: heat.height),
                                                         "\(engine): no page in \(photo.file)")
                let w: Double = Double(image.width)
                let h: Double = Double(image.height)
                let diagonal: Double = (w * w + h * h).squareRoot()
                let quad: Quad = Quad.fromCorners(found.quad.scaled(w, h).corners)
                var errors: [String] = []
                var index: Int = 0
                while index < 4 {
                    let dx: Double = Double(quad[index].x) - Double(photo.truth[index].x)
                    let dy: Double = Double(quad[index].y) - Double(photo.truth[index].y)
                    let error: Double = (dx * dx + dy * dy).squareRoot() / diagonal
                    XCTAssertLessThan(error, tolerance, "\(engine): \(photo.file) corner \(index)")
                    errors.append(String(format: "%.2f", error * 100))
                    index += 1
                }
                let page = PageFinder.find(image, model: model)
                let named = Quad.fromCorners(page.corners.corners)
                var moved = 0.0
                for corner in 0..<4 {
                    let dx = Double(named[corner].x) - Double(photo.truth[corner].x)
                    let dy = Double(named[corner].y) - Double(photo.truth[corner].y)
                    moved = max(moved, (dx * dx + dy * dy).squareRoot() / diagonal)
                }
                XCTAssertLessThan(moved, finderTolerance, "\(engine): the page finder missed the page in \(photo.file)")
                print(String(format: "%@ %@: confidence %.3f, corner errors %@ %% of the diagonal; finder %@",
                             engine, photo.file, found.confidence, errors.joined(separator: " "),
                             page.clear ? "cuts it out" : "asks"))
            }
            if let problem = model.coreMLProblem {
                print("Core ML was not used: \(problem)")
            }
        }
    }

    func testAnInputOfTheWrongSizeIsRefused() {
        XCTAssertThrowsError(try FastViTCornerModel(coreML: false).run([0, 0, 0])) { (error: Error) -> Void in
            XCTAssertEqual(error as? CornerModelError, CornerModelError.unreadable)
        }
        XCTAssertNil(FastViTCornerModel(coreML: false).heatmaps([]))
    }
}

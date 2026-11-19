import CoreGraphics
import Foundation
import XCTest
@testable import LazySendScan

private func judged(_ frame: RgbaImage) -> CaptureQuality {
    let reading: FrameQualityReading = FrameQuality.measure(frame, region: QualityFrames.sheet)
    return CaptureStability.judge(sharpness: reading.sharpness, brightness: reading.brightness)
}

/// The sheet moved `dx` px to the right.
private func sheetMoved(_ dx: Double) -> Quad {
    let s: Quad = QualityFrames.sheet
    return Quad(topLeft: CGPoint(x: Double(s.topLeft.x) + dx, y: Double(s.topLeft.y)),
                topRight: CGPoint(x: Double(s.topRight.x) + dx, y: Double(s.topRight.y)),
                bottomRight: CGPoint(x: Double(s.bottomRight.x) + dx, y: Double(s.bottomRight.y)),
                bottomLeft: CGPoint(x: Double(s.bottomLeft.x) + dx, y: Double(s.bottomLeft.y)))
}

final class FrameQualityTests: XCTestCase {
    func testTheFramesAreTheSharedPixels() {
        XCTAssertEqual(PhotoScenes.checksum(QualityFrames.frame()), 0x44CA_3AC5)
        XCTAssertEqual(PhotoScenes.checksum(QualityFrames.frame(printed: false)), 0x4DC7_DDC5)
        XCTAssertEqual(PhotoScenes.checksum(QualityFrames.frame(printed: false, blur: 2)), 0x1EB2_5E85)
        XCTAssertEqual(PhotoScenes.checksum(QualityFrames.frame(blur: 2)), 0xCA5C_90C9)
        XCTAssertEqual(PhotoScenes.checksum(QualityFrames.frame(dim: 40)), 0xCCAC_DE45)
    }

    func testTheReadingsAreTakenOverThePage() {
        let printed: FrameQualityReading = FrameQuality.measure(QualityFrames.frame(), region: QualityFrames.sheet)
        XCTAssertEqual(printed.sharpness, 8481.175490779298, accuracy: 1e-9)
        XCTAssertEqual(printed.brightness, 172.04818560380727, accuracy: 1e-9)
        let whole: FrameQualityReading = FrameQuality.measure(QualityFrames.frame())
        XCTAssertEqual(whole.sharpness, 3013.975159875271, accuracy: 1e-9)
        XCTAssertEqual(whole.brightness, 112.88583333333334, accuracy: 1e-9)
        let blank: FrameQualityReading = FrameQuality.measure(QualityFrames.frame(printed: false), region: QualityFrames.sheet)
        XCTAssertEqual(blank.sharpness, 689.5895300416419, accuracy: 1e-9)
        XCTAssertEqual(blank.brightness, 195.2177275431291, accuracy: 1e-9)
        let blurred: FrameQualityReading = FrameQuality.measure(QualityFrames.frame(printed: false, blur: 2),
                                                                region: QualityFrames.sheet)
        XCTAssertEqual(blurred.sharpness, 13.418652532892908, accuracy: 1e-9)
        XCTAssertEqual(blurred.brightness, 195.2177275431291, accuracy: 1e-9)
        let dim: FrameQualityReading = FrameQuality.measure(QualityFrames.frame(dim: 40), region: QualityFrames.sheet)
        XCTAssertEqual(dim.sharpness, 189.7358715050565, accuracy: 1e-9)
        XCTAssertEqual(dim.brightness, 26.668054729327782, accuracy: 1e-9)
    }

    func testASharpLitPageIsGood_ABlurredOneBlurry_ADarkOneDark() {
        XCTAssertEqual(judged(QualityFrames.frame()), .good)
        // A blank page is sharp by its own edges.
        XCTAssertEqual(judged(QualityFrames.frame(printed: false)), .good)
        XCTAssertEqual(judged(QualityFrames.frame(printed: false, blur: 2)), .blurry)
        XCTAssertEqual(judged(QualityFrames.frame(dim: 40)), .dark)
    }

    func testTheAreaIsThePagesBoxWithAMargin() {
        XCTAssertEqual(FrameQuality.area(QualityFrames.sheet, width: 320, height: 240),
                       FrameQualityArea(x0: 78, y0: 38, x1: 242, y1: 202))
        let tilted = Quad(topLeft: CGPoint(x: 10.5, y: -4), topRight: CGPoint(x: 300.2, y: 20),
                          bottomRight: CGPoint(x: 330, y: 230.1), bottomLeft: CGPoint(x: 4, y: 250))
        XCTAssertEqual(FrameQuality.area(tilted, width: 320, height: 240), FrameQualityArea(x0: 2, y0: 0, x1: 320, y1: 240))
        let inside = Quad(topLeft: CGPoint(x: 100.4, y: 50.6), topRight: CGPoint(x: 150, y: 50.6),
                          bottomRight: CGPoint(x: 150, y: 90.2), bottomLeft: CGPoint(x: 100.4, y: 90.2))
        XCTAssertEqual(FrameQuality.area(inside, width: 320, height: 240), FrameQualityArea(x0: 98, y0: 48, x1: 152, y1: 93))
        XCTAssertEqual(FrameQuality.area(nil, width: 320, height: 240), FrameQualityArea(x0: 0, y0: 0, x1: 320, y1: 240))
        // Nothing of it in the frame, or not a number: the whole frame.
        let outside = Quad(topLeft: CGPoint(x: 400, y: 300), topRight: CGPoint(x: 500, y: 300),
                           bottomRight: CGPoint(x: 500, y: 400), bottomLeft: CGPoint(x: 400, y: 400))
        XCTAssertEqual(FrameQuality.area(outside, width: 320, height: 240), FrameQualityArea(x0: 0, y0: 0, x1: 320, y1: 240))
        let broken = Quad(topLeft: CGPoint(x: Double.nan, y: 0), topRight: CGPoint(x: 10, y: 0),
                          bottomRight: CGPoint(x: 10, y: 10), bottomLeft: CGPoint(x: 0, y: 10))
        XCTAssertEqual(FrameQuality.area(broken, width: 320, height: 240), FrameQualityArea(x0: 0, y0: 0, x1: 320, y1: 240))
    }

    func testTheSharpnessIsTheVarianceOfTheLaplacian() {
        // One bright pixel in the middle of 5 × 5: over the 3 × 3 inner pixels the Laplacian is 400 at the
        // middle, −100 at its four neighbors and 0 at the corners: mean 0, variance 200000 / 9.
        var pixels: [UInt8] = [UInt8](repeating: 0, count: 25)
        pixels[12] = 100
        let reading: FrameQualityReading = FrameQuality.measure(GrayImage(width: 5, height: 5, pixels: pixels))
        XCTAssertEqual(reading.sharpness, 200_000.0 / 9.0, accuracy: 1e-9)
        XCTAssertEqual(reading.brightness, 4.0, accuracy: 1e-9)
        // A flat frame has none; a frame too small for a neighborhood has none either.
        XCTAssertEqual(FrameQuality.measure(GrayImage.filled(width: 8, height: 6, value: 90)).sharpness, 0)
        XCTAssertEqual(FrameQuality.measure(GrayImage.filled(width: 2, height: 2, value: 90)).sharpness, 0)
        XCTAssertEqual(FrameQuality.measure(GrayImage.filled(width: 2, height: 2, value: 90)).brightness, 90)
    }

    func testTheShutterFiresOnlyWhenThePageIsSteadySharpAndLit() {
        // The sheet held still (±1 px) through a scripted sequence at 10 frames a second: blurred while the
        // camera focuses (frames 0–11), then too dark (12–17), then sharp and lit (18–29), then the same page
        // still there (30–39), then moved away and held still again (40–59). Each frame is measured as the
        // camera's frames are, over the page found.
        let blurred: RgbaImage = QualityFrames.frame(printed: false, blur: 2)
        let dark: RgbaImage = QualityFrames.frame(dim: 40)
        let sharp: RgbaImage = QualityFrames.frame()
        var stability = CaptureStability()
        var fired: [Int] = []
        var log: [CaptureDecision] = []
        for i in 0..<60 {
            var frame: RgbaImage = sharp
            if i < 12 {
                frame = blurred
            } else if i < 18 {
                frame = dark
            }
            var dx: Double = (i % 2 == 0) ? 1 : -1
            if i >= 40 { dx += 70 }
            let quad: Quad = sheetMoved(dx)
            let reading: FrameQualityReading = FrameQuality.measure(frame, region: quad)
            let observation = CaptureObservation(quad: quad, confidence: 0.9, timestampMs: Double(i) * 100.0,
                                                 frameWidth: QualityFrames.width, frameHeight: QualityFrames.height,
                                                 sharpness: reading.sharpness, brightness: reading.brightness)
            let decision: CaptureDecision = stability.update(observation)
            log.append(decision)
            if decision.shouldCapture { fired.append(i) }
        }
        // Held still from frame 1, long enough by frame 7: blurred and then dark, it waits; the first sharp,
        // lit frame is taken; the same page is not taken again; moved 70 px (more than 15 % of the 400 px
        // diagonal), it is a new page: steady from 41, taken at 47.
        XCTAssertEqual(fired, [18, 47])
        XCTAssertEqual(log[7].quality, .blurry)
        XCTAssertEqual(log[11].state, .steadying)
        XCTAssertEqual(log[11].progress, 1)
        XCTAssertEqual(log[12].quality, .dark)
        XCTAssertEqual(log[17].state, .steadying)
        XCTAssertEqual(log[30].state, .captured)
    }
}

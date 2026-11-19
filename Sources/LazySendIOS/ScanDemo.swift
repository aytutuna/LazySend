#if os(iOS)
import CoreGraphics
import Foundation
import LazySendScan
import SwiftUI
import UIKit

/// What scan mode shows under `-demoScan`, where the Simulator has no camera: one drawn frame of a page on a dark table with
/// its outline, and that same frame as every shot, found by a stand-in for the corner model, so the UI tests and the
/// screenshots can go through the whole scan from the shutter to Done. `-demoScanUnsure` finds no page, so each shot opens the
/// corner editor. Nothing else uses it.
enum ScanDemo {
    private static let arguments = ProcessInfo.processInfo.arguments
    static let isOn = arguments.contains("-demoScan")
    static let unsure = arguments.contains("-demoScanUnsure")

    static let width = 360
    static let height = 480
    private static let cosine = 0.99619469809174555
    private static let sine = 0.087155742747658166
    private static let halfWidth = 130.0
    private static let halfHeight = 180.0

    static let frame: RgbaImage = drawn()

    /// The page in `frame`, in its pixels.
    static let outline: Quad = {
        var corners: [CGPoint] = []
        for (sx, sy) in [(-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)] {
            let u = sx * halfWidth, v = sy * halfHeight
            corners.append(CGPoint(x: Double(width) / 2 + u * cosine - v * sine, y: Double(height) / 2 + u * sine + v * cosine))
        }
        return Quad.fromCorners(corners)
    }()

    /// The frame as a shot.
    static let photo: Data = JpegEncoder.encode(frame, gray: false) ?? Data()

    static let picture: UIImage = {
        guard let image = frame.makeCGImage() else { return UIImage() }
        return UIImage(cgImage: image)
    }()

    /// What the tracker would say of a page that holds still, for the status line and the shutter's ring.
    static var update: LiveQuadUpdate {
        LiveQuadUpdate(outline: LiveQuadTracker.normalized(outline, width: width, height: height), state: .steadying,
                       progress: 0.7, timestampMs: 0, isSteady: true)
    }

    /// The model's stand-in: four spots on the page's corners.
    static var finder: CornerModel? { unsure ? nil : Model() }

    private struct Model: CornerModel {
        static let side = 64

        func heatmaps(_ input: [Float]) -> CornerHeatmaps? {
            let side = Model.side
            var values = [Float](repeating: 0, count: side * side * 4)
            for (channel, corner) in ScanDemo.outline.corners.enumerated() {
                let cx = Double(corner.x) / Double(ScanDemo.width) * Double(side)
                let cy = Double(corner.y) / Double(ScanDemo.height) * Double(side)
                for row in 0..<side {
                    for column in 0..<side {
                        let dx = Double(column) + 0.5 - cx, dy = Double(row) + 0.5 - cy
                        values[channel * side * side + row * side + column] = Float(0.9 * exp(-(dx * dx + dy * dy) / 8))
                    }
                }
            }
            return CornerHeatmaps(values: values, width: side, height: side)
        }
    }

    private static func sample(_ px: Double, _ py: Double) -> (Int, Int, Int) {
        let dx = px - Double(width) / 2
        let dy = py - Double(height) / 2
        let u = dx * cosine + dy * sine
        let v = -dx * sine + dy * cosine
        if !(abs(u) < halfWidth && abs(v) < halfHeight) { return (38, 40, 46) }
        let top = v + halfHeight
        let left = u + halfWidth
        let inside = left >= 24 && left < 2 * halfWidth - 24
        if top >= 14 && top < 30 && inside { return (60, 70, 110) }
        if top >= 44 && top < 330 && inside && (Int(top) - 44) % 20 < 7 { return (70, 70, 78) }
        return (238, 236, 230)
    }

    private static func drawn() -> RgbaImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                var red = 0, green = 0, blue = 0
                for k in 0..<4 {
                    let color = sample(Double(x) + 0.25 + 0.5 * Double(k & 1), Double(y) + 0.25 + 0.5 * Double(k >> 1))
                    red += color.0
                    green += color.1
                    blue += color.2
                }
                let o = (y * width + x) * 4
                pixels[o] = UInt8((red + 2) / 4)
                pixels[o + 1] = UInt8((green + 2) / 4)
                pixels[o + 2] = UInt8((blue + 2) / 4)
            }
        }
        return RgbaImage(width: width, height: height, pixels: pixels)
    }
}

/// The demo frame fitted in the viewfinder with its outline in the colour of a page that holds still.
struct DemoCameraFrame: View {
    var body: some View {
        Image(uiImage: ScanDemo.picture)
            .resizable()
            .scaledToFit()
            .overlay {
                GeometryReader { proxy in
                    outline(in: proxy.size)
                        .stroke(Color.green, style: StrokeStyle(lineWidth: 3, lineJoin: .round))
                }
            }
            .accessibilityHidden(true)
    }

    private func outline(in size: CGSize) -> Path {
        var path = Path()
        let corners = LiveQuadTracker.normalized(ScanDemo.outline, width: ScanDemo.width, height: ScanDemo.height).corners
        guard let first = corners.first else { return path }
        path.move(to: CGPoint(x: first.x * size.width, y: first.y * size.height))
        for corner in corners.dropFirst() {
            path.addLine(to: CGPoint(x: corner.x * size.width, y: corner.y * size.height))
        }
        path.closeSubpath()
        return path
    }
}
#endif

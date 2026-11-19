import CoreGraphics
import Foundation

/// A live frame's readings (`FrameQuality.measure`).
public struct FrameQualityReading: Equatable, Sendable {
    /// The variance of the luma's 4-neighbour Laplacian over the area: high for crisp edges and print, low
    /// when blurred.
    public var sharpness: Double
    /// The mean luma over the area, 0...255.
    public var brightness: Double

    public init(sharpness: Double, brightness: Double) {
        self.sharpness = sharpness
        self.brightness = brightness
    }
}

/// The pixels a frame is measured over: [x0, x1) × [y0, y1).
public struct FrameQualityArea: Equatable, Sendable {
    public var x0: Int
    public var y0: Int
    public var x1: Int
    public var y1: Int

    public init(x0: Int, y0: Int, x1: Int, y1: Int) {
        self.x0 = x0
        self.y0 = y0
        self.x1 = x1
        self.y1 = y1
    }
}

/// How sharp and how bright a live camera frame is, for the automatic shutter (`CaptureStability.judge`):
/// measured on the small frame the page search reads, over the page's bounding box widened by `margin`
/// pixels and kept within the frame (so the page's own edges are in it, and a blank page still has
/// something to be sharp), or the whole frame when no page is given. Sharpness is the variance of
/// 4·p − (up + down + left + right) over the area's pixels that have all four neighbours in the frame;
/// brightness the mean luma (`ColorAnalysis.grayPixels`) over the area. Both come from integer sums,
/// divided once.
public enum FrameQuality {
    /// The page's bounding box is widened by this many pixels each way.
    public static let margin: Int = 2

    /// The readings of `frame` over `region` (see the type).
    public static func measure(_ frame: RgbaImage, region: Quad? = nil) -> FrameQualityReading {
        let gray: GrayImage = GrayImage.luma(frame)
        return measureGray(gray, region: region)
    }

    /// The readings of `gray` over `region` (see the type).
    public static func measure(_ gray: GrayImage, region: Quad? = nil) -> FrameQualityReading {
        measureGray(gray, region: region)
    }

    /// The area measured: the quad's bounding box widened by `margin` (its sides rounded outwards) and kept
    /// within the frame; the whole frame without a quad, or with one that leaves nothing of the frame.
    public static func area(_ region: Quad?, width: Int, height: Int) -> FrameQualityArea {
        let whole = FrameQualityArea(x0: 0, y0: 0, x1: width, y1: height)
        guard let quad = region else { return whole }
        var minX: Double = Double.greatestFiniteMagnitude
        var minY: Double = Double.greatestFiniteMagnitude
        var maxX: Double = -Double.greatestFiniteMagnitude
        var maxY: Double = -Double.greatestFiniteMagnitude
        for corner in quad.corners {
            let x: Double = Double(corner.x)
            let y: Double = Double(corner.y)
            if !x.isFinite || !y.isFinite { return whole }
            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, x)
            maxY = max(maxY, y)
        }
        let edge: Double = Double(margin)
        let x0: Int = Int(min(max(floor(minX) - edge, 0), Double(width)))
        let y0: Int = Int(min(max(floor(minY) - edge, 0), Double(height)))
        let x1: Int = Int(min(max(ceil(maxX) + edge, 0), Double(width)))
        let y1: Int = Int(min(max(ceil(maxY) + edge, 0), Double(height)))
        if x1 <= x0 || y1 <= y0 { return whole }
        return FrameQualityArea(x0: x0, y0: y0, x1: x1, y1: y1)
    }

    private static func measureGray(_ gray: GrayImage, region: Quad?) -> FrameQualityReading {
        let w: Int = gray.width
        let h: Int = gray.height
        let pixels: [UInt8] = gray.pixels
        let box: FrameQualityArea = FrameQuality.area(region, width: w, height: h)
        var sum: Int = 0
        var count: Int = 0
        var y: Int = box.y0
        while y < box.y1 {
            let row: Int = y * w
            var x: Int = box.x0
            while x < box.x1 {
                sum += Int(pixels[row + x])
                x += 1
            }
            count += box.x1 - box.x0
            y += 1
        }
        var brightness: Double = 0
        if count > 0 {
            brightness = Double(sum) / Double(count)
        }

        var lapSum: Int = 0
        var lapSquares: Int = 0
        var n: Int = 0
        let ly0: Int = max(box.y0, 1)
        let ly1: Int = min(box.y1, h - 1)
        let lx0: Int = max(box.x0, 1)
        let lx1: Int = min(box.x1, w - 1)
        y = ly0
        while y < ly1 {
            let row: Int = y * w
            var x: Int = lx0
            while x < lx1 {
                let i: Int = row + x
                let center: Int = Int(pixels[i])
                let up: Int = Int(pixels[i - w])
                let down: Int = Int(pixels[i + w])
                let left: Int = Int(pixels[i - 1])
                let right: Int = Int(pixels[i + 1])
                let l: Int = 4 * center - up - down - left - right
                lapSum += l
                lapSquares += l * l
                n += 1
                x += 1
            }
            y += 1
        }
        var sharpness: Double = 0
        if n > 0 {
            let mean: Double = Double(lapSum) / Double(n)
            sharpness = max(0, Double(lapSquares) / Double(n) - mean * mean)
        }
        return FrameQualityReading(sharpness: sharpness, brightness: brightness)
    }
}

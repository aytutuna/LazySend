import CoreGraphics
import Foundation

/// An 8-bit luminance bitmap: row-major, top-left origin, y down, one byte per pixel (0 = black).
/// The page analyses (blank pages, and later page edges, separator sheets and receipts) work on
/// it at a fixed analysis resolution (`analysisDPI`), so their pixel constants mean the same
/// physical size on every scan.
public struct GrayImage: Equatable, Sendable {
    /// The resolution the page analyses work at.
    public static let analysisDPI = 100

    public let width: Int
    public let height: Int
    /// Count = width * height.
    public var pixels: [UInt8]
    /// The resolution of these pixels, in dots per inch.
    public let dpi: Double
    /// These pixels per pixel of the image they were made from (below 1 when downsampled):
    /// multiply a source coordinate by it to land here, divide to go back.
    public let scale: Double

    /// The dimensions must be positive and `pixels` must hold width * height bytes.
    public init(width: Int, height: Int, pixels: [UInt8], dpi: Double = Double(GrayImage.analysisDPI), scale: Double = 1) {
        precondition(width > 0 && height > 0, "Image dimensions must be positive.")
        precondition(pixels.count == width * height,
                     "Pixel buffer must be \(width * height) bytes, got \(pixels.count).")
        self.width = width
        self.height = height
        self.pixels = pixels
        self.dpi = dpi
        self.scale = scale
    }

    /// A width x height image of one gray value.
    public static func filled(width: Int, height: Int, value: UInt8,
                              dpi: Double = Double(GrayImage.analysisDPI)) -> GrayImage {
        GrayImage(width: width, height: height, pixels: [UInt8](repeating: value, count: width * height), dpi: dpi)
    }

    /// The pixel at (x, y).
    public subscript(x: Int, y: Int) -> UInt8 {
        pixels[y * width + x]
    }

    /// `image` as gray at its own size: Rec. 601 luma, rounded (`ColorAnalysis.grayPixels`).
    public static func luma(_ image: RgbaImage, dpi: Double = Double(GrayImage.analysisDPI)) -> GrayImage {
        GrayImage(width: image.width, height: image.height,
                  pixels: ColorAnalysis.grayPixels(rgba: image.pixels, width: image.width, height: image.height),
                  dpi: dpi)
    }

    /// `image`, scanned at `sourceDPI`, as gray at `analysisDPI`: the luma of every pixel, then a
    /// box filter (each gray pixel is the mean of the pixels it covers). An image no finer than
    /// `analysisDPI` is kept at its own resolution.
    public static func from(_ image: RgbaImage, sourceDPI: Int,
                            analysisDPI: Int = GrayImage.analysisDPI) -> GrayImage {
        luma(image, dpi: Double(max(1, sourceDPI))).atResolution(analysisDPI)
    }

    /// The chroma of `image` (max − min of R, G, B per pixel), scanned at `sourceDPI`, at
    /// `analysisDPI`: the same size and box filter as `from(_:sourceDPI:analysisDPI:)`.
    public static func chroma(_ image: RgbaImage, sourceDPI: Int,
                              analysisDPI: Int = GrayImage.analysisDPI) -> GrayImage {
        let pixels = ColorAnalysis.chromaPixels(rgba: image.pixels, width: image.width, height: image.height)
        return GrayImage(width: image.width, height: image.height, pixels: pixels,
                         dpi: Double(max(1, sourceDPI))).atResolution(analysisDPI)
    }

    /// `image`, scanned at `sourceDPI`, as gray at `analysisDPI`, read in bands of rows so the
    /// whole page is never held as RGBA: the same luma and box filter as `from(_:sourceDPI:analysisDPI:)`
    /// on the pixels `RgbaImage(cgImage:)` would read. nil when no bitmap context can be made.
    public init?(cgImage: CGImage, sourceDPI: Int, analysisDPI: Int = GrayImage.analysisDPI) {
        guard let planes = GrayImage.read(cgImage, sourceDPI: sourceDPI, analysisDPI: analysisDPI, withChroma: false) else {
            return nil
        }
        self = planes.luma
    }

    private static func read(_ cgImage: CGImage, sourceDPI: Int, analysisDPI: Int,
                             withChroma: Bool) -> (luma: GrayImage, chroma: GrayImage?)? {
        let width = cgImage.width, height = cgImage.height
        guard width > 0, height > 0 else { return nil }
        var gray = [UInt8](repeating: 0, count: width * height)
        var chroma = [UInt8](repeating: 0, count: withChroma ? width * height : 0)
        let band = max(1, min(height, 4_000_000 / max(1, width * 4) + 1))
        var buffer = [UInt8](repeating: 0, count: width * band * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var top = 0
        while top < height {
            let rows = min(band, height - top)
            let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
                guard let ctx = CGContext(data: raw.baseAddress, width: width, height: rows,
                                          bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                    return false
                }
                let bandRect = CGRect(x: 0, y: 0, width: width, height: rows)
                ctx.interpolationQuality = .none
                ctx.setFillColor(gray: 1, alpha: 1)
                ctx.fill(bandRect)
                // The image's rows top ..< top + rows land in this band: its top row at the
                // context's top (CG's y axis points up).
                ctx.draw(cgImage, in: CGRect(x: 0, y: rows + top - height, width: width, height: height))
                return true
            }
            guard drawn else { return nil }
            let part = ColorAnalysis.grayPixels(rgba: buffer, width: width, height: rows)
            for i in 0..<(width * rows) {
                gray[top * width + i] = part[i]
            }
            if withChroma {
                let colors = ColorAnalysis.chromaPixels(rgba: buffer, width: width, height: rows)
                for i in 0..<(width * rows) {
                    chroma[top * width + i] = colors[i]
                }
            }
            top += rows
        }
        let dpi = Double(max(1, sourceDPI))
        let luma = GrayImage(width: width, height: height, pixels: gray, dpi: dpi).atResolution(analysisDPI)
        var colors: GrayImage?
        if withChroma {
            colors = GrayImage(width: width, height: height, pixels: chroma, dpi: dpi).atResolution(analysisDPI)
        }
        return (luma, colors)
    }

    /// This image at `dpi` (box filter); itself when it is no finer. The `scale` of the result maps
    /// back to the image this one was made from.
    public func atResolution(_ dpi: Int) -> GrayImage {
        if dpi <= 0 || self.dpi <= Double(dpi) { return self }
        let w = max(1, Int((Double(width) * Double(dpi) / self.dpi).rounded()))
        let h = max(1, Int((Double(height) * Double(dpi) / self.dpi).rounded()))
        let small = downsampled(width: w, height: h)
        return GrayImage(width: small.width, height: small.height, pixels: small.pixels,
                         dpi: Double(dpi), scale: scale * Double(w) / Double(width))
    }

    /// A smaller copy: each pixel is the mean (rounded down) of the source rectangle it covers,
    /// the same box filter as `RgbaImage.resized`. Sizes not smaller than this one on both axes
    /// return this image.
    public func downsampled(width newWidthAsked: Int, height newHeightAsked: Int) -> GrayImage {
        precondition(newWidthAsked > 0 && newHeightAsked > 0, "Target dimensions must be positive.")
        if newWidthAsked >= width && newHeightAsked >= height { return self }
        let newWidth = min(newWidthAsked, width)
        let newHeight = min(newHeightAsked, height)

        var output = [UInt8](repeating: 0, count: newWidth * newHeight)
        let xRatio = Double(width) / Double(newWidth)
        let yRatio = Double(height) / Double(newHeight)
        // The source columns of each destination column, worked out once.
        var x0s = [Int](repeating: 0, count: newWidth)
        var x1s = [Int](repeating: 0, count: newWidth)
        for dx in 0..<newWidth {
            x0s[dx] = Int(Double(dx) * xRatio)
            x1s[dx] = max(x0s[dx] + 1, min(width, Int((Double(dx + 1) * xRatio).rounded(.up))))
        }
        for dy in 0..<newHeight {
            let sy0 = Int(Double(dy) * yRatio)
            let sy1 = max(sy0 + 1, min(height, Int((Double(dy + 1) * yRatio).rounded(.up))))
            for dx in 0..<newWidth {
                let sx0 = x0s[dx], sx1 = x1s[dx]
                var sum = 0
                for sy in sy0..<sy1 {
                    let row = sy * width
                    for sx in sx0..<sx1 { sum += Int(pixels[row + sx]) }
                }
                let count = (sy1 - sy0) * (sx1 - sx0)
                output[dy * newWidth + dx] = UInt8(sum / count)
            }
        }
        return GrayImage(width: newWidth, height: newHeight, pixels: output,
                         dpi: dpi * Double(newWidth) / Double(width),
                         scale: scale * Double(newWidth) / Double(width))
    }

    /// The image as opaque RGBA (R = G = B = the gray value), for display and saving.
    public func toRgba() -> RgbaImage {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for p in 0..<pixels.count {
            let i = p * 4
            rgba[i] = pixels[p]
            rgba[i + 1] = pixels[p]
            rgba[i + 2] = pixels[p]
        }
        return RgbaImage(width: width, height: height, pixels: rgba)
    }
}

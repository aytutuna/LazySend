import CoreGraphics
import Foundation

/// A plain RGBA8 bitmap: row-major, top-left origin, y down, 4 bytes per pixel (R, G, B, A).
/// CoreGraphics is met at the edges only (`init?(cgImage:)`, `makeCGImage()`).
/// A value type: a copy is independent, so there is no `clone()`.
public struct RgbaImage: Equatable, Sendable {
    public let width: Int
    public let height: Int
    /// Count = width * height * 4.
    public var pixels: [UInt8]

    /// The dimensions must be positive and `pixels` must hold width * height * 4 bytes.
    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(width > 0 && height > 0, "Image dimensions must be positive.")
        precondition(pixels.count == width * height * 4,
                     "Pixel buffer must be \(width * height * 4) bytes, got \(pixels.count).")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// A width x height image filled with an opaque color.
    public static func filled(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) -> RgbaImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        var i = 0
        while i < pixels.count {
            pixels[i] = r
            pixels[i + 1] = g
            pixels[i + 2] = b
            i += 4
        }
        return RgbaImage(width: width, height: height, pixels: pixels)
    }

    /// Scaled copy. Minification uses box-filter averaging (each destination pixel is the mean,
    /// rounded down, of the source pixels it covers); magnification uses bilinear sampling with
    /// white outside the image. The same size returns the image itself.
    public func resized(width newWidth: Int, height newHeight: Int) -> RgbaImage {
        precondition(newWidth > 0 && newHeight > 0, "Target dimensions must be positive.")
        if newWidth == width && newHeight == height { return self }

        var output = [UInt8](repeating: 0, count: newWidth * newHeight * 4)
        let minifying = newWidth <= width && newHeight <= height
        if minifying {
            // Box filter: average the source rectangle covered by each destination pixel.
            let xRatio = Double(width) / Double(newWidth)
            let yRatio = Double(height) / Double(newHeight)
            for dy in 0..<newHeight {
                let sy0 = Int(Double(dy) * yRatio)
                let sy1 = max(sy0 + 1, min(height, Int((Double(dy + 1) * yRatio).rounded(.up))))
                for dx in 0..<newWidth {
                    let sx0 = Int(Double(dx) * xRatio)
                    let sx1 = max(sx0 + 1, min(width, Int((Double(dx + 1) * xRatio).rounded(.up))))
                    var r = 0, g = 0, b = 0, a = 0
                    var count = 0
                    for sy in sy0..<sy1 {
                        var row = (sy * width + sx0) * 4
                        for _ in sx0..<sx1 {
                            r += Int(pixels[row])
                            g += Int(pixels[row + 1])
                            b += Int(pixels[row + 2])
                            a += Int(pixels[row + 3])
                            row += 4
                            count += 1
                        }
                    }
                    let di = (dy * newWidth + dx) * 4
                    output[di] = UInt8(r / count)
                    output[di + 1] = UInt8(g / count)
                    output[di + 2] = UInt8(b / count)
                    output[di + 3] = UInt8(a / count)
                }
            }
        } else {
            for dy in 0..<newHeight {
                let sy = (Double(dy) + 0.5) * Double(height) / Double(newHeight) - 0.5
                for dx in 0..<newWidth {
                    let sx = (Double(dx) + 0.5) * Double(width) / Double(newWidth) - 0.5
                    let di = (dy * newWidth + dx) * 4
                    sampleBilinear(sx, sy, into: &output, at: di, bgR: 255, bgG: 255, bgB: 255)
                }
            }
        }
        return RgbaImage(width: newWidth, height: newHeight, pixels: output)
    }

    /// Axis-aligned crop, clamped to the image bounds and rounded outward to whole pixels. nil
    /// when the clamped rectangle is empty (as `CGImage.cropping(to:)`).
    public func cropped(_ rect: CGRect) -> RgbaImage? {
        let r = rect.standardized.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !r.isNull else { return nil }
        let x = Int(r.minX), y = Int(r.minY), w = Int(r.width), h = Int(r.height)
        guard w >= 1, h >= 1 else { return nil }
        var output = [UInt8](repeating: 0, count: w * h * 4)
        for row in 0..<h {
            let source = ((y + row) * width + x) * 4
            let target = row * w * 4
            for k in 0..<(w * 4) {
                output[target + k] = pixels[source + k]
            }
        }
        return RgbaImage(width: w, height: h, pixels: output)
    }

    /// A rotated rectangle extracted as an upright image: the center of output pixel (u, v) in the
    /// rectangle's local frame samples the source at
    ///   ix = center.x + u*cos(a) - v*sin(a)
    ///   iy = center.y + u*sin(a) + v*cos(a)
    /// — the `DetectedPhotoRegion` corner convention (top-left origin, y down, positive angle
    /// clockwise on screen). Samples bicubically (Catmull-Rom, as `PerspectiveCorrector`, so one-pixel
    /// strokes keep their contrast); areas outside the source are the fill color
    /// (white by default). nil when the rounded size is empty.
    public func extractRotated(center: CGPoint, size: CGSize, angleDegrees: Double,
                               fillR: UInt8 = 255, fillG: UInt8 = 255, fillB: UInt8 = 255) -> RgbaImage? {
        // .rounded() rounds halves away from zero (300.5 -> 301).
        let outW = Int(Double(size.width).rounded())
        let outH = Int(Double(size.height).rounded())
        guard outW > 0, outH > 0 else { return nil }

        let a = angleDegrees * .pi / 180
        let c = cos(a), s = sin(a)
        let cx = Double(center.x), cy = Double(center.y)
        var output = [UInt8](repeating: 0, count: outW * outH * 4)
        for oy in 0..<outH {
            let v = Double(oy) - Double(outH - 1) / 2
            for ox in 0..<outW {
                let u = Double(ox) - Double(outW - 1) / 2
                let sx = cx + u * c - v * s
                let sy = cy + u * s + v * c
                // Region coordinates are continuous (pixel i spans [i, i+1), center i + 0.5);
                // The samplers index pixel centers, hence the half-pixel shift.
                sampleCatmullRom(sx - 0.5, sy - 0.5, into: &output, at: (oy * outW + ox) * 4,
                                 bgR: fillR, bgG: fillG, bgB: fillB)
            }
        }
        return RgbaImage(width: outW, height: outH, pixels: output)
    }

    /// Lossless 90° steps, clockwise on screen. `quarterTurns` is taken modulo 4.
    public func rotatedQuarterTurns(_ quarterTurns: Int) -> RgbaImage {
        let turns = ((quarterTurns % 4) + 4) % 4
        if turns == 0 { return self }

        let w = width, h = height
        let swaps = turns % 2 == 1
        let nw = swaps ? h : w
        let nh = swaps ? w : h
        var output = [UInt8](repeating: 0, count: nw * nh * 4)
        for dy in 0..<nh {
            for dx in 0..<nw {
                // Map each destination pixel back to its source pixel (y-down coordinates;
                // turns = 1 is 90° clockwise on screen: source top-left → destination top-right).
                let sx: Int, sy: Int
                switch turns {
                case 1: sx = dy; sy = h - 1 - dx
                case 2: sx = w - 1 - dx; sy = h - 1 - dy
                default: sx = w - 1 - dy; sy = dx   // 3 = 90° counterclockwise
                }
                let si = (sy * w + sx) * 4, di = (dy * nw + dx) * 4
                output[di] = pixels[si]
                output[di + 1] = pixels[si + 1]
                output[di + 2] = pixels[si + 2]
                output[di + 3] = pixels[si + 3]
            }
        }
        return RgbaImage(width: nw, height: nh, pixels: output)
    }

    /// Bilinear sample at (sx, sy) into dest[destIndex...destIndex+3]; coordinates outside the
    /// image blend toward the given background color (opaque). Rounds halves to even.
    private func sampleBilinear(_ sx: Double, _ sy: Double, into dest: inout [UInt8], at destIndex: Int,
                                bgR: UInt8, bgG: UInt8, bgB: UInt8) {
        let x0 = Int(sx.rounded(.down)), y0 = Int(sy.rounded(.down))
        let fx = sx - Double(x0), fy = sy - Double(y0)

        var acc0 = 0.0, acc1 = 0.0, acc2 = 0.0, acc3 = 0.0
        for corner in 0..<4 {
            let cx = x0 + (corner & 1), cy = y0 + (corner >> 1)
            let weight = ((corner & 1) == 0 ? 1 - fx : fx) * ((corner >> 1) == 0 ? 1 - fy : fy)
            if weight == 0 { continue }
            if cx >= 0 && cx < width && cy >= 0 && cy < height {
                let si = (cy * width + cx) * 4
                acc0 += weight * Double(pixels[si])
                acc1 += weight * Double(pixels[si + 1])
                acc2 += weight * Double(pixels[si + 2])
                acc3 += weight * Double(pixels[si + 3])
            } else {
                acc0 += weight * Double(bgR)
                acc1 += weight * Double(bgG)
                acc2 += weight * Double(bgB)
                acc3 += weight * 255
            }
        }
        dest[destIndex] = RgbaImage.clampedByte(acc0)
        dest[destIndex + 1] = RgbaImage.clampedByte(acc1)
        dest[destIndex + 2] = RgbaImage.clampedByte(acc2)
        dest[destIndex + 3] = RgbaImage.clampedByte(acc3)
    }

    /// Catmull-Rom sample (4 × 4 taps) at (sx, sy) into dest[destIndex...destIndex+3]; taps outside
    /// the image are the given background color (opaque). Rounds halves to even.
    private func sampleCatmullRom(_ sx: Double, _ sy: Double, into dest: inout [UInt8], at destIndex: Int,
                                  bgR: UInt8, bgG: UInt8, bgB: UInt8) {
        let fx0 = sx.rounded(.down), fy0 = sy.rounded(.down)
        let x0 = Int(fx0) - 1, y0 = Int(fy0) - 1
        let kx: SIMD4<Double> = PerspectiveCorrector.catmullRom(sx - fx0)
        let ky: SIMD4<Double> = PerspectiveCorrector.catmullRom(sy - fy0)

        var acc0 = 0.0, acc1 = 0.0, acc2 = 0.0, acc3 = 0.0
        for j in 0..<4 {
            let cy = y0 + j
            for i in 0..<4 {
                let cx = x0 + i
                let weight: Double = kx[i] * ky[j]
                if cx >= 0 && cx < width && cy >= 0 && cy < height {
                    let si = (cy * width + cx) * 4
                    acc0 += weight * Double(pixels[si])
                    acc1 += weight * Double(pixels[si + 1])
                    acc2 += weight * Double(pixels[si + 2])
                    acc3 += weight * Double(pixels[si + 3])
                } else {
                    acc0 += weight * Double(bgR)
                    acc1 += weight * Double(bgG)
                    acc2 += weight * Double(bgB)
                    acc3 += weight * 255
                }
            }
        }
        dest[destIndex] = RgbaImage.clampedByte(acc0)
        dest[destIndex + 1] = RgbaImage.clampedByte(acc1)
        dest[destIndex + 2] = RgbaImage.clampedByte(acc2)
        dest[destIndex + 3] = RgbaImage.clampedByte(acc3)
    }

    private static func clampedByte(_ value: Double) -> UInt8 {
        UInt8(min(255, max(0, value.rounded(.toNearestOrEven))))
    }
}

// MARK: - CoreGraphics

extension RgbaImage {
    /// The image's pixels as sRGB RGBA8 (drawn over white at its own size, row 0 = top); nil when
    /// no bitmap context can be made.
    public init?(cgImage: CGImage) {
        guard let rgba = ColorAnalysis.rgbaPixels(of: cgImage) else { return nil }
        self.init(width: cgImage.width, height: cgImage.height, pixels: rgba)
    }

    /// The image as an sRGB CGImage (premultiplied alpha; scans are opaque).
    public func makeCGImage() -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

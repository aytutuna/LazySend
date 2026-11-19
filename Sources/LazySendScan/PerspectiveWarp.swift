import CoreGraphics
import Foundation

/// The reference warp of camera pages: the page a `Quad` outlines in a photo, made into an upright
/// `width × height` rectangle. When the page is made more than `prefilterAbove` times smaller than
/// the photo shows it, the photo is first averaged down in k × k blocks (k the whole part of that
/// factor, `prefilterFactor`), so no detail is skipped over; then `PerspectiveCorrector.warp` samples
/// it bicubically (Catmull-Rom), 2 × 2 per pixel when the page is still made smaller by more than
/// `PerspectiveCorrector.supersampleAbove`. Faster platform paths (Core Image on the iPhone) are
/// checked against it.
public enum PerspectiveWarp {
    /// The photo is averaged down first when the page is made smaller than this.
    public static let prefilterAbove = 2.0

    /// How many photo pixels across each block averaged before sampling holds: the whole part of how
    /// many times smaller the page is made (the longer of each pair of opposite edges against `width`
    /// and `height`) when that is more than `prefilterAbove`; 1 otherwise, and for a size without pixels.
    public static func prefilterFactor(_ quad: Quad, width: Int, height: Int) -> Int {
        if width < 1 || height < 1 { return 1 }
        let w0: Double = max(quad.edgeLength(0), quad.edgeLength(2))
        let h0: Double = max(quad.edgeLength(1), quad.edgeLength(3))
        let shrink: Double = max(w0 / Double(width), h0 / Double(height))
        if !(shrink > prefilterAbove) || !shrink.isFinite { return 1 }
        let whole: Double = min(shrink.rounded(.down), Double(PerspectiveCorrector.maxOutputSide))
        return Int(whole)
    }

    /// `image` averaged in `factor` × `factor` blocks from its top-left corner: ⌈W / k⌉ × ⌈H / k⌉
    /// pixels, each the mean of the pixels of its block inside the image (the last row and column may
    /// hold fewer), rounded half up in integers. A factor of 1 or less gives the image itself.
    public static func boxReduced(_ image: RgbaImage, factor: Int) -> RgbaImage {
        if factor <= 1 { return image }
        let w = image.width, h = image.height
        let rw = (w + factor - 1) / factor
        let rh = (h + factor - 1) / factor
        var output = [UInt8](repeating: 0, count: rw * rh * 4)
        let pixels = image.pixels
        output.withUnsafeMutableBufferPointer { out in
            RowBands.perform(rows: rh) { rows in
                for oy in rows {
                    let y0 = oy * factor
                    let y1 = min(h, y0 + factor)
                    for ox in 0..<rw {
                        let x0 = ox * factor
                        let x1 = min(w, x0 + factor)
                        var r = 0, g = 0, b = 0, a = 0
                        for y in y0..<y1 {
                            var si = (y * w + x0) * 4
                            for _ in x0..<x1 {
                                r += Int(pixels[si])
                                g += Int(pixels[si + 1])
                                b += Int(pixels[si + 2])
                                a += Int(pixels[si + 3])
                                si += 4
                            }
                        }
                        let count = (y1 - y0) * (x1 - x0)
                        let half = count / 2
                        let di = (oy * rw + ox) * 4
                        out[di] = UInt8((r + half) / count)
                        out[di + 1] = UInt8((g + half) / count)
                        out[di + 2] = UInt8((b + half) / count)
                        out[di + 3] = UInt8((a + half) / count)
                    }
                }
            }
        }
        return RgbaImage(width: rw, height: rh, pixels: output)
    }

    /// The page `quad` outlines in `image` (its corners in the image's continuous pixels, clockwise
    /// from the top-left), upright at `width` × `height`: averaged down first by `prefilterFactor` (the
    /// quad scaled by 1 / k with it), then sampled as `PerspectiveCorrector.warp` does with `options`'
    /// supersampling and fill color (its size and paper options do not apply). nil for a quad that is
    /// not convex or a size outside 1 to `PerspectiveCorrector.maxOutputSide`.
    public static func warp(_ image: RgbaImage, quad: Quad, width: Int, height: Int,
                            options: PerspectiveOptions = .default) -> RgbaImage? {
        let limit = PerspectiveCorrector.maxOutputSide
        if !quad.isConvex || width < 1 || height < 1 || width > limit || height > limit { return nil }
        let factor = prefilterFactor(quad, width: width, height: height)
        var source = image
        var sourceQuad = quad
        if factor > 1 {
            source = boxReduced(image, factor: factor)
            let scale: Double = 1.0 / Double(factor)
            sourceQuad = quad.scaled(scale, scale)
        }
        var planOptions = options
        planOptions.outputWidth = width
        planOptions.outputHeight = height
        planOptions.snapToPaper = false
        planOptions.maxLongSide = 0
        guard let plan = PerspectiveCorrector.plan(sourceQuad, imageWidth: source.width, imageHeight: source.height,
                                                   options: planOptions) else { return nil }
        return PerspectiveCorrector.warp(source, plan: plan, options: planOptions)
    }
}

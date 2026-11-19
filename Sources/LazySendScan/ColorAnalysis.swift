import CoreGraphics
import Foundation

/// Color facts about a page, used to store pages scanned in color as gray when they have no
/// color.
public enum ColorAnalysis {
    /// Every `sampleStep`-th pixel of every `sampleStep`-th row is looked at.
    public static let sampleStep = 4

    /// A sample is colored when max(R, G, B) − min(R, G, B) is above this.
    public static let chromaThreshold = 32

    /// The page is gray when fewer than this share of the samples are colored. The limit is
    /// low on purpose, so a small stamp, signature in blue ink or highlighter mark keeps the
    /// page in color.
    public static let maxColoredFraction = 0.001

    /// True when the page has (next to) no color: a document scanned in color that would look
    /// the same stored in gray. The scanner's slight tint on white paper (chroma up to
    /// `chromaThreshold`) does not count as color. False when the image cannot be read.
    public static func isEffectivelyGray(_ image: CGImage) -> Bool {
        guard let rgba = rgbaPixels(of: image) else { return false }
        return isEffectivelyGray(rgba: rgba, width: image.width, height: image.height)
    }

    /// `isEffectivelyGray(_:)` on a raw RGBA8 buffer (row-major, 4 bytes per pixel).
    public static func isEffectivelyGray(rgba: [UInt8], width: Int, height: Int) -> Bool {
        var samples = 0
        var colored = 0
        for y in stride(from: 0, to: height, by: sampleStep) {
            let row = y * width * 4
            for x in stride(from: 0, to: width, by: sampleStep) {
                let i = row + x * 4
                let r = Int(rgba[i]), g = Int(rgba[i + 1]), b = Int(rgba[i + 2])
                let chroma = max(r, max(g, b)) - min(r, min(g, b))
                samples += 1
                if chroma > chromaThreshold { colored += 1 }
            }
        }
        return samples > 0 && Double(colored) < maxColoredFraction * Double(samples)
    }

    /// The page as 8-bit gray (one byte per pixel, row-major): Rec. 601 luma
    /// 0.299 R + 0.587 G + 0.114 B, rounded — the weights the image pipeline uses.
    public static func grayPixels(rgba: [UInt8], width: Int, height: Int) -> [UInt8] {
        let count = width * height
        var gray = [UInt8](repeating: 0, count: count)
        for p in 0..<count {
            let i = p * 4
            // Integer form of the luma weights (×1000), rounded half up.
            let y = (299 * Int(rgba[i]) + 587 * Int(rgba[i + 1]) + 114 * Int(rgba[i + 2]) + 500) / 1000
            gray[p] = UInt8(min(255, y))
        }
        return gray
    }

    /// The chroma of every pixel (one byte per pixel, row-major): max(R, G, B) − min(R, G, B).
    public static func chromaPixels(rgba: [UInt8], width: Int, height: Int) -> [UInt8] {
        let count = width * height
        var chroma = [UInt8](repeating: 0, count: count)
        for p in 0..<count {
            let i = p * 4
            let r = rgba[i], g = rgba[i + 1], b = rgba[i + 2]
            chroma[p] = max(r, max(g, b)) - min(r, min(g, b))
        }
        return chroma
    }

    /// The image as tightly packed sRGB RGBA8 pixels (row 0 = top of the image), drawn over
    /// white at its own size; nil when no bitmap context can be made.
    public static func rgbaPixels(of image: CGImage) -> [UInt8]? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            let rect = CGRect(x: 0, y: 0, width: width, height: height)
            ctx.interpolationQuality = .none
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(rect)
            ctx.draw(image, in: rect)
            return true
        }
        return drawn ? buffer : nil
    }
}

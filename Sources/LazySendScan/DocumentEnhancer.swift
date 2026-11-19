import CoreGraphics
import Foundation

/// How a page taken by a camera is cleaned up (`DocumentEnhancer`).
public enum DocumentEnhanceMode: String, CaseIterable, Codable, Sendable {
    /// As `.color`, then gray when the page has no color left (`ColorAnalysis.isEffectivelyGray`).
    case auto
    /// The lighting evened out, the paper made white, a slight tint taken out, the print stretched to black, in color.
    case color
    /// As `.color`, in gray.
    case gray
    /// The gray page thresholded: black print on white paper, every pixel 0 or 255.
    case blackAndWhite
    /// A photo: its levels stretched as a whole, nothing evened out.
    case photo
    /// As `.color`, with the print left as dark as it is and its colors made stronger: a board of marker.
    case whiteboard
}

/// The look of a document page taken by a camera, chosen page by page: cleaned up (`DocumentEnhancer` in
/// `.auto`), as the camera saw it (cut out, nothing else), cleaned up in gray or in black and white, or cleaned
/// up as a whiteboard (`.whiteboard`). Stored
/// by its raw value; the first is the default and the fallback.
public enum CaptureFilter: String, CaseIterable, Codable, Sendable {
    case enhanced
    case original
    case grayscale
    case blackAndWhite
    case whiteboard

    /// The order the filters are offered in.
    public static let displayOrder: [CaptureFilter] = [.original, .enhanced, .whiteboard, .grayscale, .blackAndWhite]

    /// The clean-up this filter runs; nil for `.original`.
    public var mode: DocumentEnhanceMode? {
        switch self {
        case .enhanced: return .auto
        case .original: return nil
        case .grayscale: return .gray
        case .blackAndWhite: return .blackAndWhite
        case .whiteboard: return .whiteboard
        }
    }

    /// The filter of a page cleaned up in `mode` as asked for (before `.auto` is resolved); nil for a photo,
    /// which has no filter.
    public init?(mode: DocumentEnhanceMode) {
        switch mode {
        case .auto, .color: self = .enhanced
        case .gray: self = .grayscale
        case .blackAndWhite: self = .blackAndWhite
        case .whiteboard: self = .whiteboard
        case .photo: return nil
        }
    }
}

/// A page cleaned up: its pixels and the mode applied (`.auto` resolved to color or gray).
public struct DocumentEnhancement: Sendable {
    public let image: RgbaImage
    public let mode: DocumentEnhanceMode

    public init(image: RgbaImage, mode: DocumentEnhanceMode) {
        self.image = image
        self.mode = mode
    }
}

/// The paper's color as gains per channel: a channel times its gain is the paper's luma.
public struct PaperWhiteBalance: Equatable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    public static let neutral = PaperWhiteBalance(r: 1, g: 1, b: 1)
}

/// Cleans up a page taken by a camera, after it was cut out of its photo: the lighting evened out, so a
/// shadow across the sheet or a lamp's falloff leaves the paper one white, a slight tint of the paper taken out, and
/// the print stretched to black. How bright the paper is everywhere is estimated in large tiles
/// (`tileSize`: about a sixteenth of the page's long side), each tile's paper the `backgroundPercentile`
/// of its luma (`BackgroundMap`), tiles much darker than the paper beside them (a picture, a black bar)
/// filled in from it (`BackgroundMap.raisedDarkTiles` at `darkTileShare`; a dark region that reaches the
/// page's edge is a shadow cast across it and is evened out instead), every tile at least
/// `minBackgroundShare` of the median tile and `minBackground`, and interpolated between tile centers.
/// Each pixel is then divided by the paper there, as a level of `levels`: its luma for gray, each channel
/// times the paper's white balance (`whiteBalance`: the paper's mean luma over each channel's mean, over
/// the pixels at least `paperShare` of the paper there, within `minGain`...`maxGain`) for color, at most 1.
/// The levels are stretched linearly: `whitePoint` and above becomes white, the black point (the
/// `blackPercentile` of the sampled luma levels, at most `maxBlackPoint`) and below black. Black and white
/// makes a pixel black when its level is below `bilevelShare` (not when its stretched value is below
/// `Bilevel.threshold`, which would drop pale print); since the levels are against the paper where each
/// pixel is, the threshold follows the lighting, and print in a shadow stays black. Photos are only
/// stretched as a whole (`.photo`). A page whose ground is dark with light print on it (a chalkboard, a
/// dark flyer, a slide: `isLightOnDark`) has no paper to even out against, so it is stretched as a whole
/// like a photo and then made gray or black and white as the mode says. A whiteboard (`.whiteboard`) is
/// evened out in color but not stretched to a black point, so a marker keeps its own darkness, and each
/// channel is then pushed away from the pixel's luma by `whiteboardSaturation`. The samples (white balance, black
/// point, light on dark) are every `sampleStep`-th pixel of every `sampleStep`-th row.
public enum DocumentEnhancer {
    /// The paper is estimated in tiles of about the long side over this.
    public static let tilesAlongLongSide: Int = 16
    /// The smallest tile, in pixels.
    public static let minTileSize: Int = 8
    /// A tile's paper is this percentile of its luma (the paper between the print).
    public static let backgroundPercentile: Double = 0.9
    /// A tile darker than this share of its brightest neighbor is no paper and is filled from it.
    public static let darkTileShare: Double = 0.7
    /// Every tile is at least this share of the median tile…
    public static let minBackgroundShare: Double = 0.4
    /// …and at least this luma, so a dark area is not blown up.
    public static let minBackground: Int = 32
    /// A pixel at least this share of the paper there counts as paper for the white balance.
    public static let paperShare: Double = 0.9
    /// The white balance's gains are kept within minGain...maxGain.
    public static let minGain: Double = 0.87
    public static let maxGain: Double = 1.15
    /// Levels at or above this share of the paper become white.
    public static let whitePoint: Double = 0.9
    /// The share of the sampled levels taken as the darkest print.
    public static let blackPercentile: Double = 0.005
    /// Black and white makes a pixel black when it is darker than this share of the paper there.
    public static let bilevelShare: Double = 0.78
    /// The black and white threshold setting that gives exactly `bilevelShare` and `Bilevel.threshold`.
    public static let defaultThreshold: Double = 0.5
    /// The black point is at most this level, so a page with little print is not stretched into noise.
    public static let maxBlackPoint: Double = 0.5
    /// The steps a level is counted in.
    public static let levels: Int = 1024
    /// The samples are every sampleStep-th pixel of every sampleStep-th row.
    public static let sampleStep: Int = 2
    /// A photo's levels are stretched from this share of its pixels at the dark end to as many at the
    /// bright end…
    public static let photoClip: Double = 0.005
    /// …when those two lumas are at least this far apart; a flatter photo is left as it is.
    public static let minPhotoRange: Int = 64
    /// A photo's stretch gains at most this much: a narrower range is widened to it (see `photoRange`).
    public static let maxPhotoGain: Double = 1.3
    /// The ground of a page, to tell light print on a dark ground, is this percentile of each tile's luma.
    public static let groundPercentile: Double = 0.5
    /// A pixel this many times as bright as the ground there is light print; this many times darker, dark print.
    public static let lightContrast: Double = 1.5
    /// A page is light on dark only with at least this share of the samples light print.
    public static let minLightShare: Double = 0.005
    /// A whiteboard's channels are moved this many times as far from the pixel's luma.
    public static let whiteboardSaturation: Double = 1.5

    /// The tile the paper is estimated in, for a page of `width` × `height`.
    public static func tileSize(width: Int, height: Int) -> Int {
        max(minTileSize, max(width, height) / tilesAlongLongSide)
    }

    /// How bright the paper is across `gray` (see the type); nil only for an image without pixels.
    public static func paperMap(_ gray: GrayImage) -> BackgroundMap? {
        let size: Int = tileSize(width: gray.width, height: gray.height)
        guard let raw = BackgroundMap.estimate(gray, x: 0, y: 0, width: gray.width, height: gray.height,
                                               tileSize: size, percentile: backgroundPercentile) else { return nil }
        let filled: BackgroundMap = raw.raisedDarkTiles(share: darkTileShare)
        let median: Double = Double(filled.medianTile())
        let floorValue: Int = max(minBackground, Int(floor(median * minBackgroundShare)))
        return filled.clampedBelow(UInt8(min(255, floorValue)))
    }

    /// Whether `gray` is light print on a dark ground (a chalkboard, a dark flyer with white text, a slide),
    /// whose ground no division by the paper can make white: the ground is the `groundPercentile` of each
    /// tile (`BackgroundMap`, tiles as for the paper). A sampled pixel at least `lightContrast` times the
    /// brightest ground of its tile and the eight around it (`BackgroundMap.maxSmoothed`, interpolated, at
    /// least `minBackground`) is light print; one at most the darkest of them (`BackgroundMap.minSmoothed`,
    /// at least `minBackground`) over `lightContrast` dark print. So the paper beside a hard step (the edge
    /// of a shadow, a dark picture), which is the ground of a tile next to it, counts as neither. Light on
    /// dark when there is more light print than dark, and at least `minLightShare` of the samples.
    public static func isLightOnDark(_ gray: GrayImage) -> Bool {
        let w: Int = gray.width
        let h: Int = gray.height
        let size: Int = tileSize(width: w, height: h)
        guard let ground = BackgroundMap.estimate(gray, x: 0, y: 0, width: w, height: h, tileSize: size,
                                                  percentile: groundPercentile) else { return false }
        let highest: BackgroundMap = ground.maxSmoothed()
        let lowest: BackgroundMap = ground.minSmoothed()
        let lumas: [UInt8] = gray.pixels
        var light: Int = 0
        var dark: Int = 0
        var samples: Int = 0
        var y: Int = 0
        while y < h {
            var x: Int = 0
            while x < w {
                let luma: Double = Double(lumas[y * w + x])
                let above: Double = max(highest.valueAt(x: x, y: y), Double(minBackground))
                let below: Double = max(lowest.valueAt(x: x, y: y), Double(minBackground))
                if luma >= above * lightContrast {
                    light += 1
                } else if luma * lightContrast <= below {
                    dark += 1
                }
                samples += 1
                x += sampleStep
            }
            y += sampleStep
        }
        return light > dark && Double(light) >= minLightShare * Double(samples)
    }

    /// The paper's white balance: over the sampled pixels at least `paperShare` of the paper there, each
    /// channel's gain is the luma's sum over that channel's sum, within `minGain`...`maxGain`; neutral when
    /// no paper is seen.
    public static func whiteBalance(_ image: RgbaImage, gray: GrayImage, paper: BackgroundMap) -> PaperWhiteBalance {
        let w: Int = image.width
        let h: Int = image.height
        let src: [UInt8] = image.pixels
        let lumas: [UInt8] = gray.pixels
        var sumR: Int = 0
        var sumG: Int = 0
        var sumB: Int = 0
        var sumL: Int = 0
        var y: Int = 0
        while y < h {
            var x: Int = 0
            while x < w {
                let p: Int = y * w + x
                let luma: Int = Int(lumas[p])
                let background: Double = paper.valueAt(x: x, y: y)
                if Double(luma) >= background * paperShare {
                    sumR += Int(src[p * 4])
                    sumG += Int(src[p * 4 + 1])
                    sumB += Int(src[p * 4 + 2])
                    sumL += luma
                }
                x += sampleStep
            }
            y += sampleStep
        }
        if sumL == 0 || sumR == 0 || sumG == 0 || sumB == 0 { return PaperWhiteBalance.neutral }
        return PaperWhiteBalance(r: gain(sumL, sumR), g: gain(sumL, sumG), b: gain(sumL, sumB))
    }

    /// The black point: the `blackPercentile` of the sampled pixels' luma levels against the paper there,
    /// at most `maxBlackPoint`.
    public static func blackPoint(_ gray: GrayImage, paper: BackgroundMap) -> Double {
        let w: Int = gray.width
        let h: Int = gray.height
        let lumas: [UInt8] = gray.pixels
        var histogram: [Int] = [Int](repeating: 0, count: levels + 1)
        var samples: Int = 0
        var y: Int = 0
        while y < h {
            var x: Int = 0
            while x < w {
                let k: Int = level(Double(lumas[y * w + x]), paper.valueAt(x: x, y: y))
                histogram[k] += 1
                samples += 1
                x += sampleStep
            }
            y += sampleStep
        }
        let darkest: Int = percentile(histogram, count: samples, fraction: blackPercentile)
        return min(Double(darkest) / Double(levels), maxBlackPoint)
    }

    /// The share of the paper black and white makes black at the setting `threshold` (0 ... 1): `bilevelShare`
    /// at `defaultThreshold`, none at 0 and all of it at 1, linear between.
    public static func blackShare(threshold: Double) -> Double {
        let t: Double = min(max(threshold, 0), 1)
        if t <= defaultThreshold {
            return bilevelShare * t / defaultThreshold
        }
        return bilevelShare + (1 - bilevelShare) * (t - defaultThreshold) / (1 - defaultThreshold)
    }

    /// `image` cleaned up as `mode` says (see the type); black and white cuts at `threshold`
    /// (`blackShare(threshold:)`).
    public static func enhance(_ image: RgbaImage, mode: DocumentEnhanceMode,
                               threshold: Double = defaultThreshold) -> DocumentEnhancement {
        if mode == .photo {
            return DocumentEnhancement(image: photo(image), mode: .photo)
        }
        let w: Int = image.width
        let h: Int = image.height
        let gray: GrayImage = GrayImage.luma(image)
        if isLightOnDark(gray) {
            return lightOnDark(image, mode: mode, threshold: threshold)
        }
        guard let paper = paperMap(gray) else {
            let resolved: DocumentEnhanceMode = mode == .auto ? DocumentEnhanceMode.color : mode
            return DocumentEnhancement(image: image, mode: resolved)
        }
        let black: Double = mode == .whiteboard ? 0 : blackPoint(gray, paper: paper)
        let lut: [UInt8] = stretch(black, whitePoint)
        let color: Bool = mode == .auto || mode == .color || mode == .whiteboard
        var balance: PaperWhiteBalance = PaperWhiteBalance.neutral
        if color {
            balance = whiteBalance(image, gray: gray, paper: paper)
        }
        let src: [UInt8] = image.pixels
        let lumas: [UInt8] = gray.pixels
        let blackBelow: Int = Int(floor(blackShare(threshold: threshold) * Double(levels) + 0.5))
        var output: [UInt8] = [UInt8](repeating: 0, count: w * h * 4)
        output.withUnsafeMutableBufferPointer { out in
            RowBands.perform(rows: h) { rows in
                for y in rows {
                    for x in 0..<w {
                        let p: Int = y * w + x
                        let i: Int = p * 4
                        let background: Double = paper.valueAt(x: x, y: y)
                        if color {
                            out[i] = lut[level(Double(src[i]) * balance.r, background)]
                            out[i + 1] = lut[level(Double(src[i + 1]) * balance.g, background)]
                            out[i + 2] = lut[level(Double(src[i + 2]) * balance.b, background)]
                            if mode == .whiteboard {
                                let luma: Int = (299 * Int(out[i]) + 587 * Int(out[i + 1]) + 114 * Int(out[i + 2]) + 500) / 1000
                                out[i] = saturated(out[i], around: luma)
                                out[i + 1] = saturated(out[i + 1], around: luma)
                                out[i + 2] = saturated(out[i + 2], around: luma)
                            }
                        } else {
                            let share: Int = level(Double(lumas[p]), background)
                            var v: UInt8 = lut[share]
                            if mode == .blackAndWhite {
                                v = share < blackBelow ? 0 : 255
                            }
                            out[i] = v
                            out[i + 1] = v
                            out[i + 2] = v
                        }
                        out[i + 3] = 255
                    }
                }
            }
        }
        if mode == .auto {
            if !ColorAnalysis.isEffectivelyGray(rgba: output, width: w, height: h) {
                return DocumentEnhancement(image: RgbaImage(width: w, height: h, pixels: output), mode: .color)
            }
            // No color left: the gray page, as the gray mode makes it.
            var y: Int = 0
            while y < h {
                var x: Int = 0
                while x < w {
                    let p: Int = y * w + x
                    let i: Int = p * 4
                    let v: UInt8 = lut[level(Double(lumas[p]), paper.valueAt(x: x, y: y))]
                    output[i] = v
                    output[i + 1] = v
                    output[i + 2] = v
                    x += 1
                }
                y += 1
            }
            return DocumentEnhancement(image: RgbaImage(width: w, height: h, pixels: output), mode: .gray)
        }
        return DocumentEnhancement(image: RgbaImage(width: w, height: h, pixels: output), mode: mode)
    }

    /// A light on dark page (`isLightOnDark`) in `mode`: stretched as a whole (`photo`), in color for `.color`
    /// and for `.auto` where it has color; else its luma, thresholded at `threshold` of 255 (`Bilevel.threshold`
    /// at `defaultThreshold`) for `.blackAndWhite`.
    private static func lightOnDark(_ image: RgbaImage, mode: DocumentEnhanceMode,
                                    threshold setting: Double) -> DocumentEnhancement {
        let stretched: RgbaImage = photo(image, capped: false)
        let w: Int = stretched.width
        let h: Int = stretched.height
        if mode == .color || mode == .whiteboard {
            return DocumentEnhancement(image: stretched, mode: mode)
        }
        if mode == .auto && !ColorAnalysis.isEffectivelyGray(rgba: stretched.pixels, width: w, height: h) {
            return DocumentEnhancement(image: stretched, mode: .color)
        }
        let lumas: [UInt8] = GrayImage.luma(stretched).pixels
        let threshold: Int = Int(floor(min(max(setting, 0), 1) * 255 + 0.5))
        var output: [UInt8] = [UInt8](repeating: 0, count: w * h * 4)
        var p: Int = 0
        while p < w * h {
            var v: UInt8 = lumas[p]
            if mode == .blackAndWhite {
                v = Int(v) < threshold ? 0 : 255
            }
            output[p * 4] = v
            output[p * 4 + 1] = v
            output[p * 4 + 2] = v
            output[p * 4 + 3] = 255
            p += 1
        }
        let applied: DocumentEnhanceMode = mode == .auto ? .gray : mode
        return DocumentEnhancement(image: RgbaImage(width: w, height: h, pixels: output), mode: applied)
    }

    /// A photo's levels stretched as a whole, the same for each channel: the `photoClip` and 1 − `photoClip`
    /// percentiles of its luma become 0 and 255, as far as `photoRange` allows (`capped` false: all the way);
    /// a photo whose two are less than `minPhotoRange` apart is returned as it is.
    public static func photo(_ image: RgbaImage, capped: Bool = true) -> RgbaImage {
        let gray: GrayImage = GrayImage.luma(image)
        var histogram: [Int] = [Int](repeating: 0, count: 256)
        for value in gray.pixels {
            histogram[Int(value)] += 1
        }
        let count: Int = image.width * image.height
        let lo: Int = Int(BackgroundMap.percentile(histogram, count: count, fraction: photoClip))
        let hi: Int = Int(BackgroundMap.percentile(histogram, count: count, fraction: 1 - photoClip))
        if hi - lo < minPhotoRange { return image }
        let range: ClosedRange<Double> = photoRange(lo: lo, hi: hi, capped: capped)
        let span: Double = range.upperBound - range.lowerBound
        var lut: [UInt8] = [UInt8](repeating: 0, count: 256)
        var index: Int = 0
        while index < 256 {
            let stretched: Double = floor((Double(index) - range.lowerBound) * 255.0 / span + 0.5)
            lut[index] = UInt8(min(max(stretched, 0), 255))
            index += 1
        }
        let src: [UInt8] = image.pixels
        var output: [UInt8] = [UInt8](repeating: 0, count: src.count)
        var i: Int = 0
        while i < src.count {
            output[i] = lut[Int(src[i])]
            output[i + 1] = lut[Int(src[i + 1])]
            output[i + 2] = lut[Int(src[i + 2])]
            output[i + 3] = src[i + 3]
            i += 4
        }
        return RgbaImage(width: image.width, height: image.height, pixels: output)
    }

    /// The levels that become 0 and 255 for a photo whose percentiles are `lo` and `hi`: those two, unless the
    /// gain would pass `maxPhotoGain`, then the range is widened to 255 / `maxPhotoGain` levels, each end moving
    /// out in proportion to the room it has before 0 or 255, so the photo's own tones stay where they were.
    public static func photoRange(lo: Int, hi: Int, capped: Bool = true) -> ClosedRange<Double> {
        let range: Double = Double(hi - lo)
        let span: Double = capped ? max(range, 255.0 / maxPhotoGain) : range
        let extra: Double = span - range
        if extra <= 0 { return Double(lo)...Double(hi) }
        let low: Double = Double(lo) - extra * Double(lo) / (255.0 - range)
        return low...(low + span)
    }

    /// `value` against the paper's `background`, as a level 0...`levels` (at most the paper's own).
    public static func level(_ value: Double, _ background: Double) -> Int {
        let share: Double = min(1.0, value / background)
        return Int(floor(share * Double(levels) + 0.5))
    }

    /// The levels 0...`levels` stretched linearly from `lo` (black) to `hi` (white).
    public static func stretch(_ lo: Double, _ hi: Double) -> [UInt8] {
        var lut: [UInt8] = [UInt8](repeating: 0, count: levels + 1)
        var k: Int = 0
        while k <= levels {
            let raw: Double = (Double(k) / Double(levels) - lo) / (hi - lo)
            let v: Double = min(max(raw, 0), 1)
            lut[k] = UInt8(floor(v * 255 + 0.5))
            k += 1
        }
        return lut
    }

    /// `value` moved `whiteboardSaturation` times as far from `luma`, within 0...255.
    private static func saturated(_ value: UInt8, around luma: Int) -> UInt8 {
        let moved: Double = Double(luma) + floor(Double(Int(value) - luma) * whiteboardSaturation + 0.5)
        return UInt8(min(max(moved, 0), 255))
    }

    private static func gain(_ luma: Int, _ channel: Int) -> Double {
        min(max(Double(luma) / Double(channel), minGain), maxGain)
    }

    /// The smallest level with at least ⌈fraction × count⌉ values at or below it.
    private static func percentile(_ histogram: [Int], count: Int, fraction: Double) -> Int {
        let rank: Int = min(max(Int((fraction * Double(count)).rounded(.up)), 1), max(1, count))
        var seen: Int = 0
        var k: Int = 0
        while k < histogram.count {
            seen += histogram[k]
            if seen >= rank { return k }
            k += 1
        }
        return histogram.count - 1
    }
}

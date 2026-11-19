import CoreGraphics
import Foundation
@testable import LazySendScan

/// A colour of a fixture page.
struct FixtureColor {
    let r: Int
    let g: Int
    let b: Int
}

/// Pages a camera took, after the warp: a sheet of warm paper with lines of print, a red stamp and, if
/// asked, a large dark picture, under a shadow that darkens it from full light at the top left to about
/// 37 % at the bottom right (255 − 130·x/(W − 1) − 30·y/(H − 1), integer divisions).
enum EnhancerPages {
    static let paper = FixtureColor(r: 232, g: 226, b: 212)
    static let ink = FixtureColor(r: 40, g: 38, b: 44)
    static let stamp = FixtureColor(r: 196, g: 48, b: 44)
    static let dark = FixtureColor(r: 70, g: 74, b: 80)

    static func isInk(_ x: Int, _ y: Int, width: Int, height: Int) -> Bool {
        guard x >= 24 && x < width - 24 && y >= 70 && y < height - 30 else { return false }
        return (y - 70) % 12 < 3 && ((x - 24) / 18) % 5 != 4
    }

    static func isStamp(_ x: Int, _ y: Int) -> Bool {
        x >= 150 && x < 200 && y >= 24 && y < 52
    }

    static func isPicture(_ x: Int, _ y: Int) -> Bool {
        x >= 40 && x < 140 && y >= 200 && y < 290
    }

    /// The light at (x, y), out of 255.
    static func light(_ x: Int, _ y: Int, width: Int, height: Int) -> Int {
        255 - 130 * x / (width - 1) - 30 * y / (height - 1)
    }

    /// What the pixel at (x, y) shows: 0 paper, 1 print, 2 the stamp, 3 the picture.
    static func kind(_ x: Int, _ y: Int, width: Int, height: Int, stamp: Bool, picture: Bool) -> Int {
        var kind: Int = 0
        if isInk(x, y, width: width, height: height) { kind = 1 }
        if stamp && isStamp(x, y) { kind = 2 }
        if picture && isPicture(x, y) { kind = 3 }
        return kind
    }

    static func shadowed(width: Int = 240, height: Int = 320, stamp: Bool = true, picture: Bool = false) -> RgbaImage {
        var pixels: [UInt8] = [UInt8](repeating: 0, count: width * height * 4)
        var y: Int = 0
        while y < height {
            var x: Int = 0
            while x < width {
                let shown: Int = kind(x, y, width: width, height: height, stamp: stamp, picture: picture)
                var c: FixtureColor = paper
                if shown == 1 {
                    c = ink
                } else if shown == 2 {
                    c = EnhancerPages.stamp
                } else if shown == 3 {
                    c = dark
                }
                let s: Int = light(x, y, width: width, height: height)
                let o: Int = (y * width + x) * 4
                pixels[o] = UInt8((c.r * s + 127) / 255)
                pixels[o + 1] = UInt8((c.g * s + 127) / 255)
                pixels[o + 2] = UInt8((c.b * s + 127) / 255)
                pixels[o + 3] = 255
                x += 1
            }
            y += 1
        }
        return RgbaImage(width: width, height: height, pixels: pixels)
    }

    /// Where the light print of `darkGround` is: 1 px lines every 12 px, words of 18 px with every fifth left out.
    static func isLightPrint(_ x: Int, _ y: Int, width: Int, height: Int) -> Bool {
        guard x >= 24 && x < width - 24 && y >= 70 && y < height - 30 else { return false }
        return (y - 70) % 12 < 1 && ((x - 24) / 18) % 5 != 4
    }

    /// A page with no paper to whiten: a dark ground (luma 55) with sparse light print (235) on it, as a
    /// chalkboard or a dark flyer.
    static func darkGround(width: Int = 240, height: Int = 320) -> RgbaImage {
        var pixels: [UInt8] = [UInt8](repeating: 0, count: width * height * 4)
        var y: Int = 0
        while y < height {
            var x: Int = 0
            while x < width {
                let v: UInt8 = isLightPrint(x, y, width: width, height: height) ? 235 : 55
                let o: Int = (y * width + x) * 4
                pixels[o] = v
                pixels[o + 1] = v
                pixels[o + 2] = v
                pixels[o + 3] = 255
                x += 1
            }
            y += 1
        }
        return RgbaImage(width: width, height: height, pixels: pixels)
    }

    /// A gray page in even light: paper of luma `paper` with the lines of `isInk` (or the 1 px lines of
    /// `isLightPrint` when `thin`) at luma `ink`, as pencil or faded thermal print.
    static func faint(paper: Int, ink: Int, thin: Bool, width: Int = 240, height: Int = 320) -> RgbaImage {
        var pixels: [UInt8] = [UInt8](repeating: 0, count: width * height * 4)
        var y: Int = 0
        while y < height {
            var x: Int = 0
            while x < width {
                let print: Bool = thin ? isLightPrint(x, y, width: width, height: height) : isInk(x, y, width: width, height: height)
                let v: UInt8 = UInt8(print ? ink : paper)
                let o: Int = (y * width + x) * 4
                pixels[o] = v
                pixels[o + 1] = v
                pixels[o + 2] = v
                pixels[o + 3] = 255
                x += 1
            }
            y += 1
        }
        return RgbaImage(width: width, height: height, pixels: pixels)
    }

    /// Where the hard shadow of `hardShadow` starts: everything right of it is in shadow (mid-tile, not on a
    /// tile's edge).
    static let shadowEdge: Int = 130
    /// The light in the hard shadow, out of 255 (45 %).
    static let shadowLight: Int = 115

    /// How much print `hardShadow` has.
    enum ShadowPrint {
        /// The lines of `isInk`.
        case lines
        /// Five 2 px lines (`isFewLines`): a short note.
        case fewLines
        /// None: a blank sheet.
        case blank
    }

    /// Where the print of a short note is: 2 px lines every 12 px from y = 70 to 130, words as `isInk`.
    static func isFewLines(_ x: Int, _ y: Int, width: Int, height: Int) -> Bool {
        guard x >= 24 && x < width - 24 && y >= 70 && y < 130 else { return false }
        return (y - 70) % 12 < 2 && ((x - 24) / 18) % 5 != 4
    }

    /// Whether (x, y) is print on a `hardShadow` page with `print`.
    static func isPrint(_ x: Int, _ y: Int, width: Int, height: Int, print: ShadowPrint) -> Bool {
        switch print {
        case .lines:
            return isInk(x, y, width: width, height: height)
        case .fewLines:
            return isFewLines(x, y, width: width, height: height)
        case .blank:
            return false
        }
    }

    /// The warm paper with `print` in full light, under a hard-edged shadow (a phone or a hand under one
    /// lamp) from `edge` (`shadowEdge`) to the right edge at `shadowLight`.
    static func hardShadow(width: Int = 240, height: Int = 320, print: ShadowPrint = .lines,
                           edge: Int = EnhancerPages.shadowEdge) -> RgbaImage {
        var pixels: [UInt8] = [UInt8](repeating: 0, count: width * height * 4)
        var y: Int = 0
        while y < height {
            var x: Int = 0
            while x < width {
                let c: FixtureColor = isPrint(x, y, width: width, height: height, print: print) ? ink : paper
                let s: Int = x < edge ? 255 : shadowLight
                let o: Int = (y * width + x) * 4
                pixels[o] = UInt8((c.r * s + 127) / 255)
                pixels[o + 1] = UInt8((c.g * s + 127) / 255)
                pixels[o + 2] = UInt8((c.b * s + 127) / 255)
                pixels[o + 3] = 255
                x += 1
            }
            y += 1
        }
        return RgbaImage(width: width, height: height, pixels: pixels)
    }

    /// Where the picture of `pictureWithCaption` is (mid-tile on every side).
    static func isBigPicture(_ x: Int, _ y: Int) -> Bool {
        x >= 30 && x < 210 && y >= 50 && y < 230
    }

    /// Where the caption of `pictureWithCaption` is: two 2 px lines under the picture.
    static func isCaption(_ x: Int, _ y: Int) -> Bool {
        guard x >= 40 && x < 200 && y >= 262 && y < 290 else { return false }
        return (y - 262) % 12 < 2 && ((x - 40) / 18) % 5 != 4
    }

    /// A 240 × 320 page in full light that is mostly a dark picture (`dark`, `isBigPicture`) with a short
    /// caption under it (`ink`, `isCaption`) on the warm paper.
    static func pictureWithCaption(width: Int = 240, height: Int = 320) -> RgbaImage {
        var pixels: [UInt8] = [UInt8](repeating: 0, count: width * height * 4)
        var y: Int = 0
        while y < height {
            var x: Int = 0
            while x < width {
                var c: FixtureColor = paper
                if isBigPicture(x, y) {
                    c = dark
                } else if isCaption(x, y) {
                    c = ink
                }
                let o: Int = (y * width + x) * 4
                pixels[o] = UInt8(c.r)
                pixels[o + 1] = UInt8(c.g)
                pixels[o + 2] = UInt8(c.b)
                pixels[o + 3] = 255
                x += 1
            }
            y += 1
        }
        return RgbaImage(width: width, height: height, pixels: pixels)
    }

    /// Where `onATable` lays the sheet in its photo.
    static let tableQuad = Quad(topLeft: CGPoint(x: 100, y: 60), topRight: CGPoint(x: 340, y: 60),
                                bottomRight: CGPoint(x: 340, y: 380), bottomLeft: CGPoint(x: 100, y: 380))

    /// A 240 × 320 `sheet` laid on a dark table (30, 32, 36) at `tableQuad`, in a 440 × 440 photo.
    static func onATable(_ sheet: RgbaImage) -> RgbaImage {
        var pixels: [UInt8] = [UInt8](repeating: 0, count: 440 * 440 * 4)
        var y: Int = 0
        while y < 440 {
            var x: Int = 0
            while x < 440 {
                let o: Int = (y * 440 + x) * 4
                if x >= 100 && x < 340 && y >= 60 && y < 380 {
                    let s: Int = ((y - 60) * 240 + (x - 100)) * 4
                    pixels[o] = sheet.pixels[s]
                    pixels[o + 1] = sheet.pixels[s + 1]
                    pixels[o + 2] = sheet.pixels[s + 2]
                } else {
                    pixels[o] = 30
                    pixels[o + 1] = 32
                    pixels[o + 2] = 36
                }
                pixels[o + 3] = 255
                x += 1
            }
            y += 1
        }
        return RgbaImage(width: 440, height: 440, pixels: pixels)
    }
}

/// Live frames as the page search reads them, 320 × 240: a wooden table and a sheet from (80, 40) to
/// (240, 200), with fine lines of print if asked (2 px lines every 4 px, words of 7 px every 10 px);
/// blurred by a box of (2·blur + 1)² pixels (kept within the frame, rounded half up) and darkened to
/// dim/255 (rounded), if asked.
enum QualityFrames {
    static let width: Int = 320
    static let height: Int = 240

    static let sheet = Quad(topLeft: CGPoint(x: 80, y: 40), topRight: CGPoint(x: 240, y: 40),
                            bottomRight: CGPoint(x: 240, y: 200), bottomLeft: CGPoint(x: 80, y: 200))

    static func frame(printed: Bool = true, blur: Int = 0, dim: Int = 255) -> RgbaImage {
        let count: Int = width * height
        var r: [Int] = [Int](repeating: 0, count: count)
        var g: [Int] = [Int](repeating: 0, count: count)
        var b: [Int] = [Int](repeating: 0, count: count)
        var y: Int = 0
        while y < height {
            var x: Int = 0
            while x < width {
                var c = FixtureColor(r: 88, g: 80, b: 72)
                if x >= 80 && x < 240 && y >= 40 && y < 200 {
                    var inked: Bool = printed && x >= 96 && x < 224 && y >= 56 && y < 184
                    if inked {
                        inked = (y - 56) % 4 < 2 && (x - 96) % 10 < 7
                    }
                    c = inked ? FixtureColor(r: 95, g: 92, b: 100) : FixtureColor(r: 205, g: 200, b: 192)
                }
                let i: Int = y * width + x
                r[i] = c.r
                g[i] = c.g
                b[i] = c.b
                x += 1
            }
            y += 1
        }
        var pixels: [UInt8] = [UInt8](repeating: 0, count: count * 4)
        y = 0
        while y < height {
            var x: Int = 0
            while x < width {
                var sr: Int = 0
                var sg: Int = 0
                var sb: Int = 0
                var n: Int = 0
                var yy: Int = max(0, y - blur)
                while yy < min(height, y + blur + 1) {
                    var xx: Int = max(0, x - blur)
                    while xx < min(width, x + blur + 1) {
                        let i: Int = yy * width + xx
                        sr += r[i]
                        sg += g[i]
                        sb += b[i]
                        n += 1
                        xx += 1
                    }
                    yy += 1
                }
                let o: Int = (y * width + x) * 4
                pixels[o] = UInt8(((sr + n / 2) / n * dim + 127) / 255)
                pixels[o + 1] = UInt8(((sg + n / 2) / n * dim + 127) / 255)
                pixels[o + 2] = UInt8(((sb + n / 2) / n * dim + 127) / 255)
                pixels[o + 3] = 255
                x += 1
            }
            y += 1
        }
        return RgbaImage(width: width, height: height, pixels: pixels)
    }
}

import CoreGraphics
import Foundation
@testable import LazySendScan

/// Synthetic phone photos of a page (360 × 480 RGBA): an A4-shaped sheet (210 × 297 page pixels, one
/// per millimetre, with a header bar, lines of glyphs and a picture) laid on a backdrop under a known
/// perspective, each photo pixel the mean of 2 × 2 samples, then lit: a gradient across the frame,
/// the phone's soft shadow and a glare spot.
enum PhotoScenes {
    static let width = 360
    static let height = 480
    static let pageWidth = 210
    static let pageHeight = 297

    /// The page-to-photo map x = (a u + b v + c) / (g u + h v + i), y = (d u + e v + f) / (g u + h v + i),
    /// page pixels (u, v) to photo pixels, in integers.
    struct IntHomography {
        let a: Int, b: Int, c: Int, d: Int, e: Int, f: Int, g: Int, h: Int, i: Int

        init(_ a: Int, _ b: Int, _ c: Int, _ d: Int, _ e: Int, _ f: Int, _ g: Int, _ h: Int, _ i: Int) {
            self.a = a; self.b = b; self.c = c
            self.d = d; self.e = e; self.f = f
            self.g = g; self.h = h; self.i = i
        }

        /// Where page point (u, v) lands in the photo.
        func map(_ u: Double, _ v: Double) -> CGPoint {
            let w = Double(g) * u + Double(h) * v + Double(i)
            let x = (Double(a) * u + Double(b) * v + Double(c)) / w
            let y = (Double(d) * u + Double(e) * v + Double(f)) / w
            return CGPoint(x: x, y: y)
        }

        /// The page's outline in the photo.
        func corners(_ pageWidth: Int, _ pageHeight: Int) -> Quad {
            Quad.fromCorners([map(0, 0), map(Double(pageWidth), 0), map(Double(pageWidth), Double(pageHeight)),
                              map(0, Double(pageHeight))])
        }
    }

    static let woodMap = IntHomography(1155332, -122914, 81788928, 177335, 930372, 75497472, 485, -598, 1048576)
    static let darkMap = IntHomography(739319, -271102, 110100480, -28187, 541359, 94371840, -96, -1455, 1048576)
    static let lightMap = IntHomography(1121991, 12060, 62914560, -46867, 1041969, 62914560, 272, -332, 1048576)
    static let similarMap = IntHomography(1095194, -44778, 73400320, -50732, 1055747, 83886080, -11, -267, 1048576)
    static let cutOffMap = IntHomography(1228481, -108457, 157286400, 195764, 1313578, 41943040, -50, 298, 1048576)
    static let underMap = IntHomography(806253, 18023, 31457280, -48774, 760787, 41943040, 39, -88, 1048576)
    static let topMap = IntHomography(1053725, -86609, 125829120, 102517, 953472, 157286400, 16, -160, 1048576)
    static let leftMap = IntHomography(741204, 21217, 20971520, -45071, 763036, 125829120, -46, 1, 1048576)
    static let rightMap = IntHomography(748983, -21183, 199229440, 29959, 766131, 120586240, 0, 0, 1048576)
    static let roundTripMap = IntHomography(1454408, -35269, 41943040, 82485, 1426885, 37748736, 50, 1, 1048576)

    /// An upright page 1.4 photo pixels per page pixel (294 × 415.8) whose bottom edge lies `gap` px
    /// above the frame's bottom (below it when negative: cut off).
    static func bottomGapMap(_ gap: Int) -> IntHomography {
        IntHomography(1468006, 0, 33 * 1048576, 0, 1468006, (height - gap) * 1048576 - 1468006 * pageHeight, 0, 0, 1048576)
    }

    /// The same page with its right edge `gap` px from the frame's right side.
    static func rightGapMap(_ gap: Int) -> IntHomography {
        IntHomography(1468006, 0, (width - gap) * 1048576 - 1468006 * pageWidth, 0, 1468006, 30 * 1048576, 0, 0, 1048576)
    }

    enum Backdrop { case wood, dark, light, similar, plain }

    /// A soft ellipse darkened by `depth` ‰, fading out to 2.5 × its size (in squared terms).
    struct Shadow { let cx: Int, cy: Int, rx: Int, ry: Int, depth: Int }

    /// A spot brightened toward white by up to `strength` ‰, fading quadratically to its radius.
    struct Glare { let cx: Int, cy: Int, r: Int, strength: Int }

    /// The light: dimmed by up to `acrossX` ‰ toward the right and `downY` ‰ toward the bottom.
    struct Lighting { let acrossX: Int, downY: Int, shadow: Shadow?, glare: Glare? }

    /// A sheet laid in the photo: its own pixels (RGB) and its map.
    struct Sheet { let rgb: [UInt8], sheetWidth: Int, sheetHeight: Int, map: IntHomography }

    // MARK: - The scenes

    static func woodScene() -> RgbaImage {
        scene(.wood, 0x3D00_D001, Lighting(acrossX: 180, downY: 0, shadow: nil, glare: nil),
              [Sheet(rgb: pageRaster(0x9A6E_0001), sheetWidth: pageWidth, sheetHeight: pageHeight, map: woodMap)])
    }

    static func darkScene() -> RgbaImage {
        scene(.dark, 0x3D00_D002, Lighting(acrossX: 0, downY: 120, shadow: nil, glare: Glare(cx: 280, cy: 120, r: 70, strength: 900)),
              [Sheet(rgb: pageRaster(0x9A6E_0002), sheetWidth: pageWidth, sheetHeight: pageHeight, map: darkMap)])
    }

    static func lightScene() -> RgbaImage {
        scene(.light, 0x3D00_D003,
              Lighting(acrossX: 0, downY: 0, shadow: Shadow(cx: 40, cy: 470, rx: 220, ry: 260, depth: 380), glare: nil),
              [Sheet(rgb: pageRaster(0x9A6E_0003), sheetWidth: pageWidth, sheetHeight: pageHeight, map: lightMap)])
    }

    static func similarScene() -> RgbaImage {
        scene(.similar, 0x3D00_D004, Lighting(acrossX: 100, downY: 60, shadow: nil, glare: Glare(cx: 180, cy: 250, r: 55, strength: 800)),
              [Sheet(rgb: pageRaster(0x9A6E_0004), sheetWidth: pageWidth, sheetHeight: pageHeight, map: similarMap)])
    }

    static func noPageScene() -> RgbaImage {
        scene(.wood, 0x3D00_D005,
              Lighting(acrossX: 150, downY: 0, shadow: Shadow(cx: 300, cy: 100, rx: 150, ry: 120, depth: 350),
                       glare: Glare(cx: 120, cy: 300, r: 60, strength: 900)),
              [])
    }

    static func plainScene() -> RgbaImage {
        scene(.plain, 0x3D00_D006, Lighting(acrossX: 0, downY: 0, shadow: nil, glare: nil), [])
    }

    static func cutOffScene() -> RgbaImage {
        scene(.dark, 0x3D00_D007, Lighting(acrossX: 0, downY: 0, shadow: nil, glare: nil),
              [Sheet(rgb: pageRaster(0x9A6E_0007), sheetWidth: pageWidth, sheetHeight: pageHeight, map: cutOffMap)])
    }

    /// A smaller sheet of cream paper with a larger white one lying over its lower right part.
    static func overlapScene() -> RgbaImage {
        scene(.dark, 0x3D00_D008, Lighting(acrossX: 0, downY: 0, shadow: nil, glare: nil),
              [Sheet(rgb: pageRaster(0x9A6E_0008, 232, 226, 210), sheetWidth: pageWidth, sheetHeight: pageHeight, map: underMap),
               Sheet(rgb: pageRaster(0x9A6E_0009), sheetWidth: pageWidth, sheetHeight: pageHeight, map: topMap)])
    }

    /// Two sheets of the same size side by side.
    static func twoPagesScene() -> RgbaImage {
        scene(.light, 0x3D00_D00A, Lighting(acrossX: 0, downY: 0, shadow: nil, glare: nil),
              [Sheet(rgb: pageRaster(0x9A6E_000A), sheetWidth: pageWidth, sheetHeight: pageHeight, map: leftMap),
               Sheet(rgb: pageRaster(0x9A6E_000B), sheetWidth: pageWidth, sheetHeight: pageHeight, map: rightMap)])
    }

    /// The colored blocks of `blockRaster` filling most of the frame, for the round trip.
    static func roundTripScene() -> RgbaImage {
        scene(.dark, 0x3D00_D00C, Lighting(acrossX: 0, downY: 0, shadow: nil, glare: nil),
              [Sheet(rgb: blockRaster(0x9A6E_000C), sheetWidth: pageWidth, sheetHeight: pageHeight, map: roundTripMap)])
    }

    /// A page on wood filling the frame down to `gap` px from its bottom (`bottomGapMap`).
    static func bottomGapScene(_ gap: Int) -> RgbaImage {
        scene(.wood, 0x3D00_D00D, Lighting(acrossX: 120, downY: 0, shadow: nil, glare: nil),
              [Sheet(rgb: pageRaster(0x9A6E_000D), sheetWidth: pageWidth, sheetHeight: pageHeight, map: bottomGapMap(gap))])
    }

    /// A page on wood reaching to `gap` px from the frame's right side (`rightGapMap`).
    static func rightGapScene(_ gap: Int) -> RgbaImage {
        scene(.wood, 0x3D00_D00E, Lighting(acrossX: 120, downY: 0, shadow: nil, glare: nil),
              [Sheet(rgb: pageRaster(0x9A6E_000E), sheetWidth: pageWidth, sheetHeight: pageHeight, map: rightGapMap(gap))])
    }

    // MARK: - Sheets

    /// A page: paper (white, 246, 244, 238, unless given) with noise, a dark blue-gray header bar,
    /// 15 lines of glyphs every 14 px and a picture block.
    static func pageRaster(_ seed: UInt32, _ paperR: Int = 246, _ paperG: Int = 244, _ paperB: Int = 238) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: pageWidth * pageHeight * 3)
        let rng = TestPages.Rng(seed)
        for i in 0..<(pageWidth * pageHeight) {
            let n = rng.noise()
            p[i * 3] = TestPages.clamp(paperR + n)
            p[i * 3 + 1] = TestPages.clamp(paperG + n)
            p[i * 3 + 2] = TestPages.clamp(paperB + n)
        }
        fillRgb(&p, 20, 18, 170, 14, 52, 64, 92)
        let text = TestPages.Rng(seed ^ 0x5A5A_5A5A)
        let picks = [0b00111, 0b01011, 0b01101, 0b01110, 0b10011, 0b10101, 0b10110, 0b11001, 0b11010, 0b11100]
        for line in 0..<15 {
            let y = 46 + line * 14
            let maxWidth = line % 5 == 4 ? 90 : 170
            var cx = 20
            while true {
                let glyphs = 2 + text.below(7)
                if cx + glyphs * 7 > 20 + maxWidth { break }
                for _ in 0..<glyphs {
                    let bits = picks[text.below(10)]
                    if bits & 1 != 0 { fillRgb(&p, cx, y, 1, 9, 40, 40, 46) }
                    if bits & 2 != 0 { fillRgb(&p, cx + 4, y, 1, 9, 40, 40, 46) }
                    if bits & 4 != 0 { fillRgb(&p, cx, y, 5, 1, 40, 40, 46) }
                    if bits & 8 != 0 { fillRgb(&p, cx, y + 4, 5, 1, 40, 40, 46) }
                    if bits & 16 != 0 { fillRgb(&p, cx, y + 8, 5, 1, 40, 40, 46) }
                    cx += 7
                }
                cx += 7
            }
        }
        for y in 262..<286 {
            for x in 120..<190 {
                let i = (y * pageWidth + x) * 3
                let v = 70 + (x * 7 + y * 13) % 120
                p[i] = UInt8(v)
                p[i + 1] = UInt8(v * 9 / 10)
                p[i + 2] = UInt8(v * 7 / 10)
            }
        }
        return p
    }

    /// A sheet of 10 × 10 px blocks in random colors (each channel 40...239), for the round trip.
    static func blockRaster(_ seed: UInt32) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: pageWidth * pageHeight * 3)
        let rng = TestPages.Rng(seed)
        var by = 0
        while by < pageHeight {
            var bx = 0
            while bx < pageWidth {
                let r = 40 + rng.below(200)
                let g = 40 + rng.below(200)
                let b = 40 + rng.below(200)
                fillRgb(&p, bx, by, 10, 10, UInt8(r), UInt8(g), UInt8(b))
                bx += 10
            }
            by += 10
        }
        return p
    }

    /// The sheet's pixels as an RGBA image (to compare a corrected page with).
    static func sheetImage(_ rgb: [UInt8]) -> RgbaImage {
        var rgba = [UInt8](repeating: 255, count: pageWidth * pageHeight * 4)
        for i in 0..<(pageWidth * pageHeight) {
            rgba[i * 4] = rgb[i * 3]
            rgba[i * 4 + 1] = rgb[i * 3 + 1]
            rgba[i * 4 + 2] = rgb[i * 3 + 2]
        }
        return RgbaImage(width: pageWidth, height: pageHeight, pixels: rgba)
    }

    private static func fillRgb(_ p: inout [UInt8], _ x: Int, _ y: Int, _ w: Int, _ h: Int,
                                _ r: UInt8, _ g: UInt8, _ b: UInt8) {
        let y0 = max(0, y), y1 = min(pageHeight, y + h)
        let x0 = max(0, x), x1 = min(pageWidth, x + w)
        if y0 >= y1 || x0 >= x1 { return }
        for py in y0..<y1 {
            for px in x0..<x1 {
                let i = (py * pageWidth + px) * 3
                p[i] = r
                p[i + 1] = g
                p[i + 2] = b
            }
        }
    }

    // MARK: - Drawing

    /// The photo: for every pixel the backdrop (with noise from `seed`, one draw per pixel), the
    /// topmost sheet at each of its 2 × 2 sample points (quarter-pixel positions 1 and 3) or the
    /// backdrop, averaged (rounding half up), then dimmed by the light and brightened by the glare.
    static func scene(_ backdrop: Backdrop, _ seed: UInt32, _ light: Lighting, _ sheets: [Sheet]) -> RgbaImage {
        let rng = TestPages.Rng(seed)
        var adj = [Int](repeating: 0, count: sheets.count * 9)
        for s in 0..<sheets.count {
            let m = sheets[s].map
            adj[s * 9 + 0] = m.e * m.i - m.f * m.h
            adj[s * 9 + 1] = m.c * m.h - m.b * m.i
            adj[s * 9 + 2] = m.b * m.f - m.c * m.e
            adj[s * 9 + 3] = m.f * m.g - m.d * m.i
            adj[s * 9 + 4] = m.a * m.i - m.c * m.g
            adj[s * 9 + 5] = m.c * m.d - m.a * m.f
            adj[s * 9 + 6] = m.d * m.h - m.e * m.g
            adj[s * 9 + 7] = m.b * m.g - m.a * m.h
            adj[s * 9 + 8] = m.a * m.e - m.b * m.d
        }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let back = backdropColor(backdrop, x, y, rng)
                var sr = 0, sg = 0, sb = 0
                for sample in 0..<4 {
                    let qx = 4 * x + ((sample & 1) == 0 ? 1 : 3)
                    let qy = 4 * y + ((sample >> 1) == 0 ? 1 : 3)
                    var cr = back.r, cg = back.g, cb = back.b
                    for s in 0..<sheets.count {
                        let k = s * 9
                        var u = adj[k] * qx + adj[k + 1] * qy + adj[k + 2] * 4
                        var v = adj[k + 3] * qx + adj[k + 4] * qy + adj[k + 5] * 4
                        var w = adj[k + 6] * qx + adj[k + 7] * qy + adj[k + 8] * 4
                        if w < 0 {
                            u = -u
                            v = -v
                            w = -w
                        }
                        let sheet = sheets[s]
                        if w == 0 || u < 0 || v < 0 || u >= sheet.sheetWidth * w || v >= sheet.sheetHeight * w { continue }
                        let i = ((v / w) * sheet.sheetWidth + u / w) * 3
                        cr = Int(sheet.rgb[i])
                        cg = Int(sheet.rgb[i + 1])
                        cb = Int(sheet.rgb[i + 2])
                    }
                    sr += cr
                    sg += cg
                    sb += cb
                }
                var r = (sr + 2) / 4, g = (sg + 2) / 4, b = (sb + 2) / 4
                var dim = 1000 - light.acrossX * x / width - light.downY * y / height
                if let sh = light.shadow {
                    let dx = x - sh.cx, dy = y - sh.cy
                    let rx2 = sh.rx * sh.rx, ry2 = sh.ry * sh.ry
                    let t = (dx * dx * ry2 + dy * dy * rx2) * 1000 / (rx2 * ry2)
                    if t <= 1000 {
                        dim -= sh.depth
                    } else if t < 2500 {
                        dim -= sh.depth * (2500 - t) / 1500
                    }
                }
                r = r * dim / 1000
                g = g * dim / 1000
                b = b * dim / 1000
                if let gl = light.glare {
                    let dx = x - gl.cx, dy = y - gl.cy
                    let t = (dx * dx + dy * dy) * 1000 / (gl.r * gl.r)
                    if t < 1000 {
                        let k = gl.strength * (1000 - t) / 1000
                        r += (255 - r) * k / 1000
                        g += (255 - g) * k / 1000
                        b += (255 - b) * k / 1000
                    }
                }
                let o = (y * width + x) * 4
                pixels[o] = TestPages.clamp(r)
                pixels[o + 1] = TestPages.clamp(g)
                pixels[o + 2] = TestPages.clamp(b)
                pixels[o + 3] = 255
            }
        }
        return RgbaImage(width: width, height: height, pixels: pixels)
    }

    /// The backdrop's color at (x, y), clamped to 0...255; one noise draw.
    private static func backdropColor(_ backdrop: Backdrop, _ x: Int, _ y: Int, _ rng: TestPages.Rng) -> (r: Int, g: Int, b: Int) {
        let n = rng.noise()
        var r: Int, g: Int, b: Int
        switch backdrop {
        case .wood:
            // Grain bands warped across the frame, and the seams between planks every 150 px.
            let k = (x + 3 * y / 7) % 240
            let tri = k < 120 ? 120 - k : k - 120
            let phase = 2 * y + tri / 2
            let band = phase / 9 % 7
            var shade = band == 0 ? -26 : band == 1 ? -12 : band == 3 ? -6 : 0
            if (x + 75) % 150 < 2 { shade -= 40 }
            r = 150 + shade + 2 * n
            g = 104 + shade * 3 / 4 + 2 * n
            b = 64 + shade / 2 + 2 * n
        case .dark:
            r = 38 + 2 * n; g = 40 + 2 * n; b = 46 + 2 * n
        case .light:
            r = 196 + n; g = 198 + n; b = 200 + n
        case .similar:
            r = 228 + n; g = 222 + n; b = 210 + n
        case .plain:
            r = 128 + n; g = 128 + n; b = 128 + n
        }
        return (Int(TestPages.clamp(r)), Int(TestPages.clamp(g)), Int(TestPages.clamp(b)))
    }

    /// FNV-1a of the RGBA bytes: one number per photo.
    static func checksum(_ image: RgbaImage) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for b in image.pixels {
            hash ^= UInt32(b)
            hash = hash &* 16_777_619
        }
        return hash
    }
}

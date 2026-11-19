import Foundation
@testable import LazySendScan

/// What the page fixtures are drawn with: integer arithmetic only and one xorshift32 generator, so a fixture is the
/// same pixels on every run (the checksums in the tests pin them).
enum TestPages {
    /// xorshift32 (13, 17, 5).
    final class Rng {
        private var state: UInt32

        init(_ seed: UInt32) {
            state = seed == 0 ? 1 : seed
        }

        func next() -> UInt32 {
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            return state
        }

        /// 0 ..< n.
        func below(_ n: Int) -> Int {
            Int(next() % UInt32(n))
        }

        /// Scanner noise: the sum of four uniform 0...6 values minus 12 (sigma = 4 levels).
        func noise() -> Int {
            let a = below(7)
            let b = below(7)
            let c = below(7)
            let d = below(7)
            return a + b + c + d - 12
        }
    }

    static func clamp(_ value: Int) -> UInt8 {
        UInt8(min(255, max(0, value)))
    }

    /// A gray page as an RGBA scan at `factor` times the resolution (each pixel repeated).
    static func enlarged(_ page: GrayImage, _ factor: Int) -> RgbaImage {
        let w = page.width * factor, h = page.height * factor
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let v = page.pixels[(y / factor) * page.width + x / factor]
                let i = (y * w + x) * 4
                rgba[i] = v
                rgba[i + 1] = v
                rgba[i + 2] = v
            }
        }
        return RgbaImage(width: w, height: h, pixels: rgba)
    }
}

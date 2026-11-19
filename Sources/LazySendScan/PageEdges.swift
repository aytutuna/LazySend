import CoreGraphics
import Foundation

/// The edge field of a photo and the straight lines fitted to it, which `QuadRefiner` moves a page's outline onto.
enum PageEdges {
    /// The photo is searched with its long side at most this many pixels.
    static let analysisLongSide = 1000
    /// A pixel is an edge when its gradient is at least this many levels per pixel (after smoothing).
    static let edgeThreshold = 3.0
    /// An edge pixel's vote is its gradient, at most this.
    static let voteCap = 20.0

    /// The smoothed colors and the gradient of the analysis image.
    final class Field {
        let w: Int
        let h: Int
        /// Smoothed channels, 256 × the level.
        var r: [Int] = []
        var g: [Int] = []
        var b: [Int] = []
        /// The strongest channel's gradient, in levels per pixel (0 on the outermost pixels).
        var gx: [Double] = []
        var gy: [Double] = []
        var mag: [Double] = []

        init(w: Int, h: Int) {
            self.w = w
            self.h = h
        }

        var diagonal: Double { (Double(w) * Double(w) + Double(h) * Double(h)).squareRoot() }

        static func build(_ image: RgbaImage) -> Field {
            let w = image.width, h = image.height
            let f = Field(w: w, h: h)
            f.r = smooth(image.pixels, w, h, 0)
            f.g = smooth(image.pixels, w, h, 1)
            f.b = smooth(image.pixels, w, h, 2)
            var gxs = [Double](repeating: 0, count: w * h)
            var gys = [Double](repeating: 0, count: w * h)
            var mags = [Double](repeating: 0, count: w * h)
            let channels = [f.r, f.g, f.b]
            if h >= 3 && w >= 3 {
                for y in 1..<(h - 1) {
                    for x in 1..<(w - 1) {
                        let i = y * w + x
                        var bestX = 0, bestY = 0
                        var bestM = -1
                        for c in 0..<3 {
                            let ch = channels[c]
                            let right: Int = ch[i - w + 1] + 2 * ch[i + 1] + ch[i + w + 1]
                            let left: Int = ch[i - w - 1] + 2 * ch[i - 1] + ch[i + w - 1]
                            let below: Int = ch[i + w - 1] + 2 * ch[i + w] + ch[i + w + 1]
                            let above: Int = ch[i - w - 1] + 2 * ch[i - w] + ch[i - w + 1]
                            let gx = right - left
                            let gy = below - above
                            let m = gx * gx + gy * gy
                            if m > bestM {
                                bestM = m
                                bestX = gx
                                bestY = gy
                            }
                        }
                        let dx = Double(bestX) / 2048.0, dy = Double(bestY) / 2048.0
                        gxs[i] = dx
                        gys[i] = dy
                        mags[i] = (dx * dx + dy * dy).squareRoot()
                    }
                }
            }
            f.gx = gxs
            f.gy = gys
            f.mag = mags
            return f
        }

        /// Channel `channel` smoothed by 1-4-6-4-1 across and down (edges repeated): 256 × the level.
        private static func smooth(_ rgba: [UInt8], _ w: Int, _ h: Int, _ channel: Int) -> [Int] {
            // Each row smoothed across into rows 2...h+1 of a buffer padded by two repeated rows above and below.
            var row = [Int](repeating: 0, count: w + 4)
            var across = [Int](repeating: 0, count: w * (h + 4))
            for y in 0..<h {
                let src = y * w
                for x in 0..<w { row[x + 2] = Int(rgba[(src + x) * 4 + channel]) }
                row[0] = row[2]
                row[1] = row[2]
                row[w + 2] = row[w + 1]
                row[w + 3] = row[w + 1]
                let dst = (y + 2) * w
                for x in 0..<w {
                    let s: Int = row[x] + 4 * row[x + 1] + 6 * row[x + 2] + 4 * row[x + 3] + row[x + 4]
                    across[dst + x] = s
                }
            }
            for x in 0..<w {
                across[x] = across[2 * w + x]
                across[w + x] = across[2 * w + x]
                across[(h + 2) * w + x] = across[(h + 1) * w + x]
                across[(h + 3) * w + x] = across[(h + 1) * w + x]
            }
            var output = [Int](repeating: 0, count: w * h)
            for y in 0..<h {
                let a = y * w, b = a + w, c = b + w, d = c + w, e = d + w
                for x in 0..<w {
                    let s: Int = across[a + x] + 4 * across[b + x] + 6 * across[c + x] + 4 * across[d + x] + across[e + x]
                    output[a + x] = s
                }
            }
            return output
        }

        /// The gradient at a continuous point, bilinear between pixel centers (clamped inside the gradient's area).
        func gradientAt(_ x: Double, _ y: Double) -> (gx: Double, gy: Double) {
            let fx = x - 0.5, fy = y - 0.5
            let cx = min(max(fx, 1), Double(w) - 2.000001), cy = min(max(fy, 1), Double(h) - 2.000001)
            let x0f = cx.rounded(.down), y0f = cy.rounded(.down)
            let x0 = Int(x0f), y0 = Int(y0f)
            let tx = cx - x0f, ty = cy - y0f
            let i = y0 * w + x0
            let gxTop = gx[i] * (1 - tx) + gx[i + 1] * tx
            let gxBottom = gx[i + w] * (1 - tx) + gx[i + w + 1] * tx
            let gyTop = gy[i] * (1 - tx) + gy[i + 1] * tx
            let gyBottom = gy[i + w] * (1 - tx) + gy[i + w + 1] * tx
            return (gxTop * (1 - ty) + gxBottom * ty, gyTop * (1 - ty) + gyBottom * ty)
        }
    }

    /// A straight line n · p = rho with a unit normal.
    struct Line: Equatable {
        var nx: Double
        var ny: Double
        var rho: Double

        func distance(_ x: Double, _ y: Double) -> Double { nx * x + ny * y - rho }

        static func through(_ p: CGPoint, _ q: CGPoint) -> Line {
            let px = Double(p.x), py = Double(p.y)
            let dx = Double(q.x) - px, dy = Double(q.y) - py
            let len = (dx * dx + dy * dy).squareRoot()
            let nx = dy / len, ny = -dx / len
            return Line(nx: nx, ny: ny, rho: nx * px + ny * py)
        }

        static func intersect(_ a: Line, _ b: Line) -> CGPoint? {
            let det = a.nx * b.ny - a.ny * b.nx
            if abs(det) < 1e-9 { return nil }
            return CGPoint(x: (a.rho * b.ny - b.rho * a.ny) / det, y: (a.nx * b.rho - b.nx * a.rho) / det)
        }
    }


    /// The total-least-squares line through `points`, refitted twice without the points farther from
    /// it than 2.5 times the median distance (and 0.75 px).
    static func fitLine(_ points: [CGPoint]) -> Line {
        var current = points
        var line = fit(current)
        for _ in 0..<2 {
            var distances = [Double](repeating: 0, count: current.count)
            for i in 0..<current.count { distances[i] = abs(line.distance(Double(current[i].x), Double(current[i].y))) }
            let sorted = distances.sorted()
            let limit = max(0.75, 2.5 * sorted[sorted.count / 2])
            var kept: [CGPoint] = []
            for i in 0..<current.count where distances[i] <= limit { kept.append(current[i]) }
            if kept.count < 4 || kept.count == current.count { break }
            current = kept
            line = fit(current)
        }
        return line
    }

    private static func fit(_ points: [CGPoint]) -> Line {
        var mx = 0.0, my = 0.0
        for p in points {
            mx += Double(p.x)
            my += Double(p.y)
        }
        mx /= Double(points.count)
        my /= Double(points.count)
        var sxx = 0.0, sxy = 0.0, syy = 0.0
        for p in points {
            let dx = Double(p.x) - mx, dy = Double(p.y) - my
            sxx += dx * dx
            sxy += dx * dy
            syy += dy * dy
        }
        // The direction of largest spread: the eigenvector of the larger eigenvalue.
        let half = (sxx - syy) / 2
        let lambda = (sxx + syy) / 2 + (half * half + sxy * sxy).squareRoot()
        let ax = lambda - syy, ay = sxy
        let bx = sxy, by = lambda - sxx
        var dirX: Double, dirY: Double
        if abs(ax) + abs(ay) >= abs(bx) + abs(by) {
            dirX = ax
            dirY = ay
        } else {
            dirX = bx
            dirY = by
        }
        var len = (dirX * dirX + dirY * dirY).squareRoot()
        if len == 0 {
            dirX = 1
            dirY = 0
            len = 1
        }
        let nx = -dirY / len, ny = dirX / len
        return Line(nx: nx, ny: ny, rho: nx * mx + ny * my)
    }
}

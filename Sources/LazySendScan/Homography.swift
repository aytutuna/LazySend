import CoreGraphics
import Foundation

/// A plane-to-plane projective map (3 × 3, row-major): (x, y) goes to
/// ((m00 x + m01 y + m02) / w, (m10 x + m11 y + m12) / w) with w = m20 x + m21 y + m22.
/// Coordinates are continuous pixels (see `Quad`).
public struct Homography: Equatable, Sendable {
    public var m00: Double, m01: Double, m02: Double
    public var m10: Double, m11: Double, m12: Double
    public var m20: Double, m21: Double, m22: Double

    public init(_ m00: Double, _ m01: Double, _ m02: Double,
                _ m10: Double, _ m11: Double, _ m12: Double,
                _ m20: Double, _ m21: Double, _ m22: Double) {
        self.m00 = m00; self.m01 = m01; self.m02 = m02
        self.m10 = m10; self.m11 = m11; self.m12 = m12
        self.m20 = m20; self.m21 = m21; self.m22 = m22
    }

    public static let identity = Homography(1, 0, 0, 0, 1, 0, 0, 0, 1)

    /// Where `p` lands (infinite or NaN when it maps to the line at infinity).
    public func map(_ p: CGPoint) -> CGPoint {
        let x = Double(p.x), y = Double(p.y)
        let w = m20 * x + m21 * y + m22
        return CGPoint(x: (m00 * x + m01 * y + m02) / w, y: (m10 * x + m11 * y + m12) / w)
    }

    /// The homogeneous weight w at `p`: positive on the side of the plane that is seen.
    public func weight(_ p: CGPoint) -> Double {
        m20 * Double(p.x) + m21 * Double(p.y) + m22
    }

    /// The determinant of the matrix.
    public var determinant: Double {
        m00 * (m11 * m22 - m12 * m21) - m01 * (m10 * m22 - m12 * m20) + m02 * (m10 * m21 - m11 * m20)
    }

    /// The map back (the adjugate over the determinant); nil when the matrix is singular.
    public func inverse() -> Homography? {
        let det = determinant
        if det == 0 || !det.isFinite { return nil }
        return Homography(
            (m11 * m22 - m12 * m21) / det, (m02 * m21 - m01 * m22) / det, (m01 * m12 - m02 * m11) / det,
            (m12 * m20 - m10 * m22) / det, (m00 * m22 - m02 * m20) / det, (m02 * m10 - m00 * m12) / det,
            (m10 * m21 - m11 * m20) / det, (m01 * m20 - m00 * m21) / det, (m00 * m11 - m01 * m10) / det)
    }

    /// `a` × `b`: the map that applies `b` first, then `a`.
    public static func multiply(_ a: Homography, _ b: Homography) -> Homography {
        Homography(
            a.m00 * b.m00 + a.m01 * b.m10 + a.m02 * b.m20,
            a.m00 * b.m01 + a.m01 * b.m11 + a.m02 * b.m21,
            a.m00 * b.m02 + a.m01 * b.m12 + a.m02 * b.m22,
            a.m10 * b.m00 + a.m11 * b.m10 + a.m12 * b.m20,
            a.m10 * b.m01 + a.m11 * b.m11 + a.m12 * b.m21,
            a.m10 * b.m02 + a.m11 * b.m12 + a.m12 * b.m22,
            a.m20 * b.m00 + a.m21 * b.m10 + a.m22 * b.m20,
            a.m20 * b.m01 + a.m21 * b.m11 + a.m22 * b.m21,
            a.m20 * b.m02 + a.m21 * b.m12 + a.m22 * b.m22)
    }

    /// The map of the unit square onto `quad`: (0, 0) to the top-left corner, (1, 0) top-right,
    /// (1, 1) bottom-right, (0, 1) bottom-left (Heckbert's closed form). nil when three corners
    /// are in line.
    public static func squareToQuad(_ quad: Quad) -> Homography? {
        let x0 = Double(quad.topLeft.x), y0 = Double(quad.topLeft.y)
        let x1 = Double(quad.topRight.x), y1 = Double(quad.topRight.y)
        let x2 = Double(quad.bottomRight.x), y2 = Double(quad.bottomRight.y)
        let x3 = Double(quad.bottomLeft.x), y3 = Double(quad.bottomLeft.y)
        let sx = x0 - x1 + x2 - x3, sy = y0 - y1 + y2 - y3
        let dx1 = x1 - x2, dx2 = x3 - x2, dy1 = y1 - y2, dy2 = y3 - y2
        let den = dx1 * dy2 - dx2 * dy1
        if den == 0 || !den.isFinite { return nil }
        let g = (sx * dy2 - dx2 * sy) / den
        let h = (dx1 * sy - sx * dy1) / den
        let m = Homography(
            x1 - x0 + g * x1, x3 - x0 + h * x3, x0,
            y1 - y0 + g * y1, y3 - y0 + h * y3, y0,
            g, h, 1)
        let det = m.determinant
        return det == 0 || !det.isFinite ? nil : m
    }

    /// The map of the upright rectangle (0, 0)–(`width`, `height`) onto `quad`, corner to corner;
    /// nil for a degenerate quad or size.
    public static func rectToQuad(width: Double, height: Double, quad: Quad) -> Homography? {
        guard width > 0, height > 0, let s = squareToQuad(quad) else { return nil }
        return Homography(
            s.m00 / width, s.m01 / height, s.m02,
            s.m10 / width, s.m11 / height, s.m12,
            s.m20 / width, s.m21 / height, s.m22)
    }

    /// The map of `quad` onto the upright rectangle (0, 0)–(`width`, `height`).
    public static func quadToRect(_ quad: Quad, width: Double, height: Double) -> Homography? {
        rectToQuad(width: width, height: height, quad: quad)?.inverse()
    }

    /// The map that takes each of four points `from` to the matching point of `to`, by solving the
    /// eight equations (Gaussian elimination with partial pivoting), m22 = 1. nil when no such map
    /// exists (three points in line).
    public static func fromCorrespondences(_ from: [CGPoint], _ to: [CGPoint]) -> Homography? {
        precondition(from.count == 4 && to.count == 4, "Four points each.")
        // Row-major 8 × 9 augmented matrix.
        var a = [Double](repeating: 0, count: 8 * 9)
        for i in 0..<4 {
            let x = Double(from[i].x), y = Double(from[i].y), u = Double(to[i].x), v = Double(to[i].y)
            let r = 2 * i
            a[r * 9 + 0] = x; a[r * 9 + 1] = y; a[r * 9 + 2] = 1
            a[r * 9 + 3] = 0; a[r * 9 + 4] = 0; a[r * 9 + 5] = 0
            a[r * 9 + 6] = -u * x; a[r * 9 + 7] = -u * y; a[r * 9 + 8] = u
            a[(r + 1) * 9 + 0] = 0; a[(r + 1) * 9 + 1] = 0; a[(r + 1) * 9 + 2] = 0
            a[(r + 1) * 9 + 3] = x; a[(r + 1) * 9 + 4] = y; a[(r + 1) * 9 + 5] = 1
            a[(r + 1) * 9 + 6] = -v * x; a[(r + 1) * 9 + 7] = -v * y; a[(r + 1) * 9 + 8] = v
        }
        for col in 0..<8 {
            var pivot = col
            var best = abs(a[col * 9 + col])
            for r in (col + 1)..<8 {
                let value = abs(a[r * 9 + col])
                if value > best {
                    best = value
                    pivot = r
                }
            }
            if !(best > 1e-12) { return nil }
            if pivot != col {
                for k in 0..<9 { a.swapAt(col * 9 + k, pivot * 9 + k) }
            }
            for r in (col + 1)..<8 {
                let f = a[r * 9 + col] / a[col * 9 + col]
                if f == 0 { continue }
                for k in col..<9 { a[r * 9 + k] -= f * a[col * 9 + k] }
            }
        }
        var h = [Double](repeating: 0, count: 8)
        for r in stride(from: 7, through: 0, by: -1) {
            var sum = a[r * 9 + 8]
            for k in (r + 1)..<8 { sum -= a[r * 9 + k] * h[k] }
            h[r] = sum / a[r * 9 + r]
        }
        let m = Homography(h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7], 1)
        let det = m.determinant
        return det == 0 || !det.isFinite ? nil : m
    }
}

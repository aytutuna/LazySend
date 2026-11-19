import CoreGraphics
import Foundation

/// Four corners of a page seen in a photo, in image pixels (origin top-left, x right, y down,
/// continuous: pixel (i, j) covers [i, i + 1) × [j, j + 1), its center is (i + 0.5, j + 0.5)).
/// The corners run clockwise on screen. `fromCorners` names them: the top edge is the edge whose
/// midpoint is highest in the image (the smaller x on a tie), and `topLeft` is its first corner
/// going clockwise. The names say where the corners are in the image, not which way up the
/// page's text reads. Near the turn where two edges' midpoints are equally high (a W × H sheet turned
/// by atan(H / W)), a slight turn names the corners from the next edge: to tell whether two quads are
/// the same outline, compare them from every starting corner (`CaptureStability.movement`), not corner
/// by corner.
public struct Quad: Equatable, Codable, Sendable {
    public var topLeft: CGPoint
    public var topRight: CGPoint
    public var bottomRight: CGPoint
    public var bottomLeft: CGPoint

    public init(topLeft: CGPoint, topRight: CGPoint, bottomRight: CGPoint, bottomLeft: CGPoint) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }

    /// The corners clockwise from `topLeft`: 0 top-left, 1 top-right, 2 bottom-right, 3 bottom-left
    /// (taken modulo 4).
    public subscript(index: Int) -> CGPoint {
        switch index & 3 {
        case 0: return topLeft
        case 1: return topRight
        case 2: return bottomRight
        default: return bottomLeft
        }
    }

    /// The corners clockwise from `topLeft`.
    public var corners: [CGPoint] { [topLeft, topRight, bottomRight, bottomLeft] }

    /// The shoelace sum: positive when the corners run clockwise on screen (y down).
    public var signedArea: Double {
        var sum = 0.0
        for i in 0..<4 {
            let a = self[i], b = self[i + 1]
            sum += Double(a.x) * Double(b.y) - Double(b.x) * Double(a.y)
        }
        return sum / 2
    }

    /// The area enclosed, in square pixels.
    public var area: Double { abs(signedArea) }

    /// Every corner turns the same way (clockwise on screen) and no three corners are in line: a
    /// real outline of a flat sheet.
    public var isConvex: Bool {
        for i in 0..<4 {
            let a = self[i], b = self[i + 1], c = self[i + 2]
            let cross = (Double(b.x) - Double(a.x)) * (Double(c.y) - Double(b.y))
                - (Double(b.y) - Double(a.y)) * (Double(c.x) - Double(b.x))
            if !(cross > 0) { return false }
        }
        return true
    }

    /// The mean of the four corners.
    public var centroid: CGPoint {
        CGPoint(x: (Double(topLeft.x) + Double(topRight.x) + Double(bottomRight.x) + Double(bottomLeft.x)) / 4,
                y: (Double(topLeft.y) + Double(topRight.y) + Double(bottomRight.y) + Double(bottomLeft.y)) / 4)
    }

    /// The length of edge `index`: 0 top, 1 right, 2 bottom, 3 left.
    public func edgeLength(_ index: Int) -> Double {
        Quad.distance(self[index], self[index + 1])
    }

    /// Every coordinate multiplied: x by `sx`, y by `sy`.
    public func scaled(_ sx: Double, _ sy: Double) -> Quad {
        Quad(topLeft: CGPoint(x: Double(topLeft.x) * sx, y: Double(topLeft.y) * sy),
             topRight: CGPoint(x: Double(topRight.x) * sx, y: Double(topRight.y) * sy),
             bottomRight: CGPoint(x: Double(bottomRight.x) * sx, y: Double(bottomRight.y) * sy),
             bottomLeft: CGPoint(x: Double(bottomLeft.x) * sx, y: Double(bottomLeft.y) * sy))
    }

    /// The largest distance between corresponding corners.
    public func maxCornerDistance(_ other: Quad) -> Double {
        var worst = 0.0
        for i in 0..<4 { worst = max(worst, Quad.distance(self[i], other[i])) }
        return worst
    }

    /// Every corner lies within the image of `width` × `height`, at least `margin` pixels from its
    /// edges (a negative margin allows that much outside).
    public func isInside(width: Double, height: Double, margin: Double = 0) -> Bool {
        for i in 0..<4 {
            let p = self[i]
            let x = Double(p.x), y = Double(p.y)
            if x < margin || y < margin || x > width - margin || y > height - margin { return false }
        }
        return true
    }

    /// `point` lies inside the outline or within `tolerance` pixels outside it. The quad must be convex.
    public func contains(_ point: CGPoint, tolerance: Double = 0) -> Bool {
        let px = Double(point.x), py = Double(point.y)
        for i in 0..<4 {
            let a = self[i], b = self[i + 1]
            let len = Quad.distance(a, b)
            if len <= 0 { return false }
            // Distance of the point outside edge a→b (positive outside for a clockwise quad).
            let ax = Double(a.x), ay = Double(a.y), bx = Double(b.x), by = Double(b.y)
            let outside = ((bx - ax) * (ay - py) - (by - ay) * (ax - px)) / len
            if outside > tolerance { return false }
        }
        return true
    }

    /// Four corners in any order around the outline (either direction) as a quad: turned clockwise
    /// on screen when they run the other way, and started at the top-left corner (the first corner
    /// of the edge whose midpoint is highest; the smaller midpoint x on a tie).
    public static func fromCorners(_ corners: [CGPoint]) -> Quad {
        precondition(corners.count == 4, "A quad has four corners.")
        var p = corners
        var sum = 0.0
        for i in 0..<4 {
            let a = p[i], b = p[(i + 1) & 3]
            sum += Double(a.x) * Double(b.y) - Double(b.x) * Double(a.y)
        }
        if sum < 0 {
            p.swapAt(1, 3)
        }
        var start = 0
        var bestY = Double.greatestFiniteMagnitude, bestX = Double.greatestFiniteMagnitude
        for i in 0..<4 {
            let a = p[i], b = p[(i + 1) & 3]
            let my = (Double(a.y) + Double(b.y)) / 2, mx = (Double(a.x) + Double(b.x)) / 2
            if my < bestY || (my == bestY && mx < bestX) {
                bestY = my
                bestX = mx
                start = i
            }
        }
        return Quad(topLeft: p[start], topRight: p[(start + 1) & 3], bottomRight: p[(start + 2) & 3],
                    bottomLeft: p[(start + 3) & 3])
    }

    /// The distance between two points.
    static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = Double(a.x) - Double(b.x), dy = Double(a.y) - Double(b.y)
        return (dx * dx + dy * dy).squareRoot()
    }
}

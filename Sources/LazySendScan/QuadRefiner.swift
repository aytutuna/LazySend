import CoreGraphics
import Foundation

/// What `QuadRefiner.refine` made of an outline: the corners (refined, or the outline as given when no
/// refinement was taken), whether they were refined, and the outline's edge support: the share of its
/// weakest side backed by a clear edge (0...1).
public struct QuadRefinement: Equatable, Sendable {
    public var quad: Quad
    public var refined: Bool
    public var support: Double

    public init(quad: Quad, refined: Bool, support: Double) {
        self.quad = quad
        self.refined = refined
        self.support = support
    }
}

/// Moves each side of a page outline found roughly (Vision's, the page search's) onto the photo's edge.
/// Within `band` of the diagonal either side of a side, every straight line is scored by the points
/// along the side where it passes a ridge of the gradient across it (either sign, at least
/// `PageEdges.edgeThreshold`), so a faint edge along the whole side counts as much as a dark
/// one; of the lines scoring at least `outerShare` of the best, the outermost is the page's edge (a
/// header bar or a ruled line just inside it scores as well). That line is then fitted to a fraction of
/// a pixel at the points where its edge is clear. A side whose edge is clear at fewer than
/// `minSideSupport` of its points keeps its place. The corners are where the four lines cross; the
/// refinement is taken only when at least one side moved, the outline stays convex, no corner moved more
/// than twice the band and its sides lie on stronger gradient, all told, than the outline given. The photo is searched at most `PageEdges.analysisLongSide` px
/// long, as the page search sees it.
public enum QuadRefiner {
    /// How far either side of a side its edge is looked for: a share of the photo's diagonal.
    public static let band = 0.03
    /// Points along each side, from 10 % to 90 % of it (clear of the corners).
    public static let samples = 48
    /// A side's line is taken when its edge is clear at this share of its points.
    public static let minSideSupport = 0.5
    /// A point backs a side when the edge lies within this many analysis pixels of it.
    public static let supportReach = 1.5
    /// Of the lines scoring at least this share of the best, the outermost is the edge.
    public static let outerShare = 0.7
    /// How far outside the side as given, as a share of the band, a line may win for being outermost; one
    /// further out wins only as the best line.
    public static let outerReach = 1.0 / 3

    typealias Field = PageEdges.Field
    typealias Line = PageEdges.Line

    /// `quad` (the photo's pixels) moved onto the edges of `image`, with its support.
    public static func refine(_ image: RgbaImage, _ quad: Quad) -> QuadRefinement {
        guard let searched = analysis(image) else {
            return QuadRefinement(quad: quad, refined: false, support: 0)
        }
        let (field, toFullX, toFullY) = searched
        let q = quad.scaled(1 / toFullX, 1 / toFullY)
        let reach = band * field.diagonal
        let outward: Double = q.signedArea >= 0 ? 1 : -1
        var lines: [Line] = []
        var moved = 0
        for i in 0..<4 {
            if let line = fitSide(field, q[i], q[i + 1], reach, outward) {
                lines.append(line)
                moved += 1
            } else if Quad.distance(q[i], q[i + 1]) >= 1 {
                lines.append(Line.through(q[i], q[i + 1]))
            } else {
                return QuadRefinement(quad: quad, refined: false, support: 0)
            }
        }
        let given = backing(field, q)
        if moved > 0, let result = crossings(lines), result.isConvex, within(result, q, 2 * reach) {
            // Only an outline lying on its edges better than the one given: a page already on its edges is not
            // moved onto another edge near it.
            let found = backing(field, result)
            if found.fit > given.fit {
                return QuadRefinement(quad: result.scaled(toFullX, toFullY), refined: true, support: found.shares.min() ?? 0)
            }
        }
        return QuadRefinement(quad: quad, refined: false, support: given.shares.min() ?? 0)
    }

    /// The edge support of `quad` (the photo's pixels) in `image`, as `refine` reports it.
    static func supportOf(_ image: RgbaImage, _ quad: Quad) -> Double {
        guard let searched = analysis(image) else { return 0 }
        return backing(searched.0, quad.scaled(1 / searched.1, 1 / searched.2)).shares.min() ?? 0
    }

    private static func analysis(_ image: RgbaImage) -> (Field, Double, Double)? {
        let longSide = max(image.width, image.height)
        var small = image
        if longSide > PageEdges.analysisLongSide {
            let s = Double(PageEdges.analysisLongSide) / Double(longSide)
            let aw = max(1, Int((Double(image.width) * s).rounded()))
            let ah = max(1, Int((Double(image.height) * s).rounded()))
            small = image.resized(width: aw, height: ah)
        }
        if small.width < 16 || small.height < 16 { return nil }
        return (Field.build(small), Double(image.width) / Double(small.width), Double(image.height) / Double(small.height))
    }

    private static func crossings(_ lines: [Line]) -> Quad? {
        var corners: [CGPoint] = []
        for i in 0..<4 {
            guard let c = Line.intersect(lines[(i + 3) & 3], lines[i]) else { return nil }
            corners.append(c)
        }
        return Quad(topLeft: corners[0], topRight: corners[1], bottomRight: corners[2], bottomLeft: corners[3])
    }

    private static func within(_ a: Quad, _ b: Quad, _ limit: Double) -> Bool {
        for i in 0..<4 where !(Quad.distance(a[i], b[i]) <= limit) {
            return false
        }
        return true
    }

    /// The edge near the side from `p` to `q` (`outward`: 1 when the outline runs clockwise on screen, so
    /// the side's left normal points out), as the type's summary says: at each point the strongest response
    /// within 2 px of the line chosen, placed by a parabola, fitted by `PageEdges.fitLine`. nil
    /// when too few points are clear.
    private static func fitSide(_ f: Field, _ p: CGPoint, _ q: CGPoint, _ reach: Double, _ outward: Double) -> Line? {
        let px = Double(p.x), py = Double(p.y)
        let dx = Double(q.x) - px, dy = Double(q.y) - py
        let len = (dx * dx + dy * dy).squareRoot()
        if !(len >= 8) || len > 1e6 { return nil }
        let nx = dy / len, ny = -dx / len
        let r = max(2, Int(reach.rounded(.up)))
        let span = 2 * r + 1
        let n = samples
        var values = [Double](repeating: 0, count: n * span)
        var xs = [Double](repeating: 0, count: n)
        var ys = [Double](repeating: 0, count: n)
        var inside = [Bool](repeating: false, count: n)
        var used = 0
        for s in 0..<n {
            let t = 0.1 + 0.8 * (Double(s) + 0.5) / Double(n)
            let x = px + dx * t, y = py + dy * t
            xs[s] = x
            ys[s] = y
            if !inField(f, x, y) { continue }
            inside[s] = true
            used += 1
            for k in 0..<span {
                let ox = x + nx * Double(k - r), oy = y + ny * Double(k - r)
                if !inField(f, ox, oy) { continue }
                let g = f.gradientAt(ox, oy)
                values[s * span + k] = g.gx * nx + g.gy * ny
            }
        }
        if used * 4 < n { return nil }

        // Each ridge marked a pixel either way, so a line drawn through whole pixels still passes it.
        var hits = [Bool](repeating: false, count: 2 * n * span)
        for side in 0..<2 {
            let sign: Double = side == 0 ? -1 : 1
            for s in 0..<n where inside[s] {
                for k in 1..<(span - 1) {
                    let v = sign * values[s * span + k]
                    if v < PageEdges.edgeThreshold { continue }
                    if v < sign * values[s * span + k - 1] || v < sign * values[s * span + k + 1] { continue }
                    for d in (k - 1)...(k + 1) { hits[(side * n + s) * span + d] = true }
                }
            }
        }
        var counts = [Int](repeating: 0, count: 2 * span * span)
        var strengths = [Double](repeating: 0, count: 2 * span * span)
        var bestCount = 0, bestIndex = -1, bestNear = Int.max
        for side in 0..<2 {
            let sign: Double = side == 0 ? -1 : 1
            for a in 0..<span {
                for b in 0..<span {
                    var count = 0
                    var strength = 0.0
                    for s in 0..<n where inside[s] {
                        let k = Int((Double(a) + Double(b - a) * Double(s) / Double(n - 1)).rounded())
                        if !hits[(side * n + s) * span + k] { continue }
                        count += 1
                        strength += min(sign * values[s * span + k], PageEdges.voteCap)
                    }
                    let index = (side * span + a) * span + b
                    counts[index] = count
                    strengths[index] = strength
                    // The best line: the most points, the nearer to the side as given on a tie.
                    let near = abs(a - r) + abs(b - r)
                    if count > bestCount || (count == bestCount && near < bestNear) {
                        bestCount = count
                        bestIndex = index
                        bestNear = near
                    }
                }
            }
        }
        if Double(bestCount) < max(6, minSideSupport * Double(used)) { return nil }
        var bestSign = 1.0, bestOut = -Double.infinity, bestScore = 0, bestStrength = 0.0
        var bestStart = r, bestEnd = r
        let outReach = 2 * Double(r) * outerReach
        for side in 0..<2 {
            for a in 0..<span {
                for b in 0..<span {
                    let index = (side * span + a) * span + b
                    let count = counts[index]
                    if Double(count) < outerShare * Double(bestCount) { continue }
                    let outness = outward * Double(a + b - 2 * r)
                    if outness > outReach && index != bestIndex { continue }
                    if outness > bestOut
                        || (outness == bestOut && (count > bestScore || (count == bestScore && strengths[index] > bestStrength))) {
                        bestOut = outness
                        bestScore = count
                        bestStrength = strengths[index]
                        bestSign = side == 0 ? -1 : 1
                        bestStart = a
                        bestEnd = b
                    }
                }
            }
        }

        var points: [CGPoint] = []
        for s in 0..<n where inside[s] {
            let centre = Int((Double(bestStart) + Double(bestEnd - bestStart) * Double(s) / Double(n - 1)).rounded())
            var at = -1
            var top = 0.0
            for k in max(0, centre - 2)...min(span - 1, centre + 2) {
                let v = bestSign * values[s * span + k]
                if v >= PageEdges.edgeThreshold && v > top {
                    top = v
                    at = k
                }
            }
            if at < 0 { continue }
            var delta = 0.0
            if at > 0 && at < span - 1 {
                let before = bestSign * values[s * span + at - 1], after = bestSign * values[s * span + at + 1]
                let den = before - 2 * top + after
                if den < 0 { delta = min(max(0.5 * (before - after) / den, -0.5), 0.5) }
            }
            let off = Double(at - r) + delta
            points.append(CGPoint(x: xs[s] + nx * off, y: ys[s] + ny * off))
        }
        if Double(points.count) < max(6, minSideSupport * Double(used)) { return nil }
        return PageEdges.fitLine(points)
    }

    /// How well edges back `q` (analysis pixels). `shares`: the share of each side backed by an edge: at each
    /// of its points inside the frame, the gradient across it within `supportReach` px, of the sign that
    /// prevails along the side, at least `PageEdges.edgeThreshold`. `fit`: the sides' sum of that
    /// gradient right on the side (up to `PageEdges.voteCap`, as a share of it, the mean over the
    /// points). A side with fewer than a quarter of its points inside the frame backs nothing.
    private static func backing(_ f: Field, _ q: Quad) -> (shares: [Double], fit: Double) {
        var shares = [Double](repeating: 0, count: 4)
        var fit = 0.0
        for i in 0..<4 {
            let p = q[i], e = q[i + 1]
            let px = Double(p.x), py = Double(p.y)
            let dx = Double(e.x) - px, dy = Double(e.y) - py
            let len = (dx * dx + dy * dy).squareRoot()
            if !(len >= 1) { continue }
            let nx = dy / len, ny = -dx / len
            var pos = [Double](repeating: 0, count: samples)
            var neg = [Double](repeating: 0, count: samples)
            var onSide = [Double](repeating: 0, count: samples)
            var used = 0
            var sumPos = 0.0, sumNeg = 0.0
            for s in 0..<samples {
                let t = 0.1 + 0.8 * (Double(s) + 0.5) / Double(samples)
                let x = px + dx * t, y = py + dy * t
                if !inField(f, x, y) {
                    pos[s] = -1
                    neg[s] = -1
                    continue
                }
                used += 1
                var k = -supportReach
                while k <= supportReach {
                    let g = f.gradientAt(x + nx * k, y + ny * k)
                    let v = g.gx * nx + g.gy * ny
                    pos[s] = max(pos[s], v)
                    neg[s] = max(neg[s], -v)
                    if k == 0 { onSide[s] = v }
                    k += 0.5
                }
                sumPos += pos[s]
                sumNeg += neg[s]
            }
            if used * 4 < samples { continue }
            let sign: Double = sumPos >= sumNeg ? 1 : -1
            let side = sign > 0 ? pos : neg
            var backed = 0
            var on = 0.0
            for s in 0..<samples {
                if side[s] >= PageEdges.edgeThreshold { backed += 1 }
                if side[s] >= 0 { on += min(max(sign * onSide[s], 0), PageEdges.voteCap) }
            }
            shares[i] = Double(backed) / Double(used)
            fit += on / (PageEdges.voteCap * Double(used))
        }
        return (shares, fit)
    }

    /// Whether (x, y) lies where the gradient is measured (not the outermost pixels).
    private static func inField(_ f: Field, _ x: Double, _ y: Double) -> Bool {
        x >= 1.5 && y >= 1.5 && x <= Double(f.w) - 1.5 && y <= Double(f.h) - 1.5
    }
}

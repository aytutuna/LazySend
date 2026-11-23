package com.lazysend.lazysend.scan

import com.lazysend.lazysend.scan.PageEdges.Field
import com.lazysend.lazysend.scan.PageEdges.Line
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/**
 * What `QuadRefiner.refine` made of an outline: the corners (refined, or the outline as given when no
 * refinement was taken), whether they were refined, and the outline's edge support: the share of its
 * weakest side backed by a clear edge (0..1).
 */
data class QuadRefinement(val quad: Quad, val refined: Boolean, val support: Double)

/**
 * Moves each side of a page outline found roughly (the model's, the page search's) onto the photo's edge.
 * Within `BAND` of the diagonal either side of a side, every straight line is scored by the points along
 * the side where it passes a ridge of the gradient across it (either sign, at least
 * `PageEdges.EDGE_THRESHOLD`), so a faint edge along the whole side counts as much as a dark one; of the
 * lines scoring at least `OUTER_SHARE` of the best, the outermost is the page's edge (a header bar or a
 * ruled line just inside it scores as well). That line is then fitted to a fraction of a pixel at the
 * points where its edge is clear. A side whose edge is clear at fewer than `MIN_SIDE_SUPPORT` of its points
 * keeps its place. The corners are where the four lines cross; the refinement is taken only when at least
 * one side moved, the outline stays convex, no corner moved more than twice the band and its sides lie on
 * stronger gradient, all told, than the outline given. The photo is searched at most
 * `PageEdges.ANALYSIS_LONG_SIDE` px long, as the page search sees it.
 */
object QuadRefiner {
    /** How far either side of a side its edge is looked for: a share of the photo's diagonal. */
    const val BAND = 0.03

    /** Points along each side, from 10 % to 90 % of it (clear of the corners). */
    const val SAMPLES = 48

    /** A side's line is taken when its edge is clear at this share of its points. */
    const val MIN_SIDE_SUPPORT = 0.5

    /** A point backs a side when the edge lies within this many analysis pixels of it. */
    const val SUPPORT_REACH = 1.5

    /** Of the lines scoring at least this share of the best, the outermost is the edge. */
    const val OUTER_SHARE = 0.7

    /**
     * How far outside the side as given, as a share of the band, a line may win for being outermost; one
     * further out wins only as the best line.
     */
    const val OUTER_REACH = 1.0 / 3

    private class Searched(val field: Field, val toFullX: Double, val toFullY: Double)

    private class Backing(val shares: DoubleArray, val fit: Double)

    /** `quad` (the photo's pixels) moved onto the edges of `image`, with its support. */
    fun refine(image: RgbaImage, quad: Quad): QuadRefinement {
        val searched = analysis(image) ?: return QuadRefinement(quad, false, 0.0)
        val field = searched.field
        val q = quad.scaled(1 / searched.toFullX, 1 / searched.toFullY)
        val reach = BAND * field.diagonal
        val outward = if (q.signedArea >= 0) 1.0 else -1.0
        val lines = ArrayList<Line>(4)
        var moved = 0
        for (i in 0 until 4) {
            val line = fitSide(field, q[i], q[i + 1], reach, outward)
            if (line != null) {
                lines.add(line)
                moved++
            } else if (Quad.distance(q[i], q[i + 1]) >= 1) {
                lines.add(Line.through(q[i], q[i + 1]))
            } else {
                return QuadRefinement(quad, false, 0.0)
            }
        }
        val given = backing(field, q)
        val result = if (moved > 0) crossings(lines) else null
        if (result != null && result.isConvex && within(result, q, 2 * reach)) {
            // Only an outline lying on its edges better than the one given: a page already on its edges is not
            // moved onto another edge near it.
            val found = backing(field, result)
            if (found.fit > given.fit) {
                return QuadRefinement(result.scaled(searched.toFullX, searched.toFullY), true,
                    found.shares.minOrNull() ?: 0.0)
            }
        }
        return QuadRefinement(quad, false, given.shares.minOrNull() ?: 0.0)
    }

    /** The edge support of `quad` (the photo's pixels) in `image`, as `refine` reports it. */
    internal fun supportOf(image: RgbaImage, quad: Quad): Double {
        val searched = analysis(image) ?: return 0.0
        return backing(searched.field, quad.scaled(1 / searched.toFullX, 1 / searched.toFullY)).shares.minOrNull() ?: 0.0
    }

    private fun analysis(image: RgbaImage): Searched? {
        val longSide = max(image.width, image.height)
        var small = image
        if (longSide > PageEdges.ANALYSIS_LONG_SIDE) {
            val s = PageEdges.ANALYSIS_LONG_SIDE.toDouble() / longSide.toDouble()
            val aw = max(1, roundHalfAway(image.width.toDouble() * s).toInt())
            val ah = max(1, roundHalfAway(image.height.toDouble() * s).toInt())
            small = image.resized(aw, ah)
        }
        if (small.width < 16 || small.height < 16) return null
        return Searched(Field.build(small), image.width.toDouble() / small.width.toDouble(),
            image.height.toDouble() / small.height.toDouble())
    }

    private fun crossings(lines: List<Line>): Quad? {
        val corners = ArrayList<Pt>(4)
        for (i in 0 until 4) corners.add(Line.intersect(lines[(i + 3) and 3], lines[i]) ?: return null)
        return Quad(corners[0], corners[1], corners[2], corners[3])
    }

    private fun within(a: Quad, b: Quad, limit: Double): Boolean {
        for (i in 0 until 4) if (!(Quad.distance(a[i], b[i]) <= limit)) return false
        return true
    }

    /**
     * The edge near the side from `p` to `q` (`outward`: 1 when the outline runs clockwise on screen, so the
     * side's left normal points out), as the type's summary says: at each point the strongest response within
     * 2 px of the line chosen, placed by a parabola, fitted by `PageEdges.fitLine`. Null when too few points
     * are clear.
     */
    private fun fitSide(f: Field, p: Pt, q: Pt, reach: Double, outward: Double): Line? {
        val px = p.x
        val py = p.y
        val dx = q.x - px
        val dy = q.y - py
        val len = sqrt(dx * dx + dy * dy)
        if (!(len >= 8) || len > 1e6) return null
        val nx = dy / len
        val ny = -dx / len
        val r = max(2, ceil(reach).toInt())
        val span = 2 * r + 1
        val n = SAMPLES
        val values = DoubleArray(n * span)
        val xs = DoubleArray(n)
        val ys = DoubleArray(n)
        val inside = BooleanArray(n)
        var used = 0
        for (s in 0 until n) {
            val t = 0.1 + 0.8 * (s.toDouble() + 0.5) / n.toDouble()
            val x = px + dx * t
            val y = py + dy * t
            xs[s] = x
            ys[s] = y
            if (!inField(f, x, y)) continue
            inside[s] = true
            used++
            for (k in 0 until span) {
                val ox = x + nx * (k - r).toDouble()
                val oy = y + ny * (k - r).toDouble()
                if (!inField(f, ox, oy)) continue
                val g = f.gradientAt(ox, oy)
                values[s * span + k] = g.gx * nx + g.gy * ny
            }
        }
        if (used * 4 < n) return null

        // Each ridge marked a pixel either way, so a line drawn through whole pixels still passes it.
        val hits = BooleanArray(2 * n * span)
        for (side in 0 until 2) {
            val sign = if (side == 0) -1.0 else 1.0
            for (s in 0 until n) {
                if (!inside[s]) continue
                for (k in 1 until span - 1) {
                    val v = sign * values[s * span + k]
                    if (v < PageEdges.EDGE_THRESHOLD) continue
                    if (v < sign * values[s * span + k - 1] || v < sign * values[s * span + k + 1]) continue
                    for (d in k - 1..k + 1) hits[(side * n + s) * span + d] = true
                }
            }
        }
        val counts = IntArray(2 * span * span)
        val strengths = DoubleArray(2 * span * span)
        var bestCount = 0
        var bestIndex = -1
        var bestNear = Int.MAX_VALUE
        for (side in 0 until 2) {
            val sign = if (side == 0) -1.0 else 1.0
            for (a in 0 until span) {
                for (b in 0 until span) {
                    var count = 0
                    var strength = 0.0
                    for (s in 0 until n) {
                        if (!inside[s]) continue
                        val k = roundHalfAway(a.toDouble() + (b - a).toDouble() * s.toDouble() / (n - 1).toDouble()).toInt()
                        if (!hits[(side * n + s) * span + k]) continue
                        count++
                        strength += min(sign * values[s * span + k], PageEdges.VOTE_CAP)
                    }
                    val index = (side * span + a) * span + b
                    counts[index] = count
                    strengths[index] = strength
                    // The best line: the most points, the nearer to the side as given on a tie.
                    val near = abs(a - r) + abs(b - r)
                    if (count > bestCount || (count == bestCount && near < bestNear)) {
                        bestCount = count
                        bestIndex = index
                        bestNear = near
                    }
                }
            }
        }
        if (bestCount.toDouble() < max(6.0, MIN_SIDE_SUPPORT * used.toDouble())) return null
        var bestSign = 1.0
        var bestOut = Double.NEGATIVE_INFINITY
        var bestScore = 0
        var bestStrength = 0.0
        var bestStart = r
        var bestEnd = r
        val outReach = 2 * r.toDouble() * OUTER_REACH
        for (side in 0 until 2) {
            for (a in 0 until span) {
                for (b in 0 until span) {
                    val index = (side * span + a) * span + b
                    val count = counts[index]
                    if (count.toDouble() < OUTER_SHARE * bestCount.toDouble()) continue
                    val outness = outward * (a + b - 2 * r).toDouble()
                    if (outness > outReach && index != bestIndex) continue
                    if (outness > bestOut ||
                        (outness == bestOut && (count > bestScore || (count == bestScore && strengths[index] > bestStrength)))) {
                        bestOut = outness
                        bestScore = count
                        bestStrength = strengths[index]
                        bestSign = if (side == 0) -1.0 else 1.0
                        bestStart = a
                        bestEnd = b
                    }
                }
            }
        }

        val points = ArrayList<Pt>()
        for (s in 0 until n) {
            if (!inside[s]) continue
            val centre = roundHalfAway(bestStart.toDouble() + (bestEnd - bestStart).toDouble() * s.toDouble() / (n - 1).toDouble()).toInt()
            var at = -1
            var top = 0.0
            for (k in max(0, centre - 2)..min(span - 1, centre + 2)) {
                val v = bestSign * values[s * span + k]
                if (v >= PageEdges.EDGE_THRESHOLD && v > top) {
                    top = v
                    at = k
                }
            }
            if (at < 0) continue
            var delta = 0.0
            if (at > 0 && at < span - 1) {
                val before = bestSign * values[s * span + at - 1]
                val after = bestSign * values[s * span + at + 1]
                val den = before - 2 * top + after
                if (den < 0) delta = min(max(0.5 * (before - after) / den, -0.5), 0.5)
            }
            val off = (at - r).toDouble() + delta
            points.add(Pt(xs[s] + nx * off, ys[s] + ny * off))
        }
        if (points.size.toDouble() < max(6.0, MIN_SIDE_SUPPORT * used.toDouble())) return null
        return PageEdges.fitLine(points)
    }

    /**
     * How well edges back `q` (analysis pixels). `shares`: the share of each side backed by an edge: at each
     * of its points inside the frame, the gradient across it within `SUPPORT_REACH` px, of the sign that
     * prevails along the side, at least `PageEdges.EDGE_THRESHOLD`. `fit`: the sides' sum of that gradient
     * right on the side (up to `PageEdges.VOTE_CAP`, as a share of it, the mean over the points). A side
     * with fewer than a quarter of its points inside the frame backs nothing.
     */
    private fun backing(f: Field, q: Quad): Backing {
        val shares = DoubleArray(4)
        var fit = 0.0
        for (i in 0 until 4) {
            val p = q[i]
            val e = q[i + 1]
            val dx = e.x - p.x
            val dy = e.y - p.y
            val len = sqrt(dx * dx + dy * dy)
            if (!(len >= 1)) continue
            val nx = dy / len
            val ny = -dx / len
            val pos = DoubleArray(SAMPLES)
            val neg = DoubleArray(SAMPLES)
            val onSide = DoubleArray(SAMPLES)
            var used = 0
            var sumPos = 0.0
            var sumNeg = 0.0
            for (s in 0 until SAMPLES) {
                val t = 0.1 + 0.8 * (s.toDouble() + 0.5) / SAMPLES.toDouble()
                val x = p.x + dx * t
                val y = p.y + dy * t
                if (!inField(f, x, y)) {
                    pos[s] = -1.0
                    neg[s] = -1.0
                    continue
                }
                used++
                var k = -SUPPORT_REACH
                while (k <= SUPPORT_REACH) {
                    val g = f.gradientAt(x + nx * k, y + ny * k)
                    val v = g.gx * nx + g.gy * ny
                    pos[s] = max(pos[s], v)
                    neg[s] = max(neg[s], -v)
                    if (k == 0.0) onSide[s] = v
                    k += 0.5
                }
                sumPos += pos[s]
                sumNeg += neg[s]
            }
            if (used * 4 < SAMPLES) continue
            val sign = if (sumPos >= sumNeg) 1.0 else -1.0
            val side = if (sign > 0) pos else neg
            var backed = 0
            var on = 0.0
            for (s in 0 until SAMPLES) {
                if (side[s] >= PageEdges.EDGE_THRESHOLD) backed++
                if (side[s] >= 0) on += min(max(sign * onSide[s], 0.0), PageEdges.VOTE_CAP)
            }
            shares[i] = backed.toDouble() / used.toDouble()
            fit += on / (PageEdges.VOTE_CAP * used.toDouble())
        }
        return Backing(shares, fit)
    }

    /** Whether (x, y) lies where the gradient is measured (not the outermost pixels). */
    private fun inField(f: Field, x: Double, y: Double): Boolean =
        x >= 1.5 && y >= 1.5 && x <= f.w.toDouble() - 1.5 && y <= f.h.toDouble() - 1.5
}

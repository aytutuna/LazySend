package com.lazysend.lazysend.scan

import kotlinx.serialization.Serializable
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.sqrt

@Serializable
data class Pt(val x: Double, val y: Double)

/**
 * Four corners of a page seen in a photo, in continuous image pixels (origin top-left, y down; pixel
 * (i, j) covers [i, i + 1)). The corners run clockwise on screen. `fromCorners` names them: the top
 * edge is the one whose midpoint is highest, and `topLeft` is its first corner going clockwise. The
 * names say where the corners are in the image, not which way up the text reads, so to tell whether
 * two quads are the same outline compare them from every starting corner.
 */
@Serializable
data class Quad(val topLeft: Pt, val topRight: Pt, val bottomRight: Pt, val bottomLeft: Pt) {
    /** The corners clockwise from `topLeft`, index taken modulo 4. */
    operator fun get(index: Int): Pt = when (index and 3) {
        0 -> topLeft
        1 -> topRight
        2 -> bottomRight
        else -> bottomLeft
    }

    val corners: List<Pt> get() = listOf(topLeft, topRight, bottomRight, bottomLeft)

    /** Positive when the corners run clockwise on screen. */
    val signedArea: Double
        get() {
            var sum = 0.0
            for (i in 0 until 4) {
                val a = this[i]
                val b = this[i + 1]
                sum += a.x * b.y - b.x * a.y
            }
            return sum / 2
        }

    val area: Double get() = abs(signedArea)

    /** Every corner turns clockwise and no three are in line. */
    val isConvex: Boolean
        get() {
            for (i in 0 until 4) {
                val a = this[i]
                val b = this[i + 1]
                val c = this[i + 2]
                val cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
                if (!(cross > 0)) return false
            }
            return true
        }

    val centroid: Pt
        get() = Pt((topLeft.x + topRight.x + bottomRight.x + bottomLeft.x) / 4,
            (topLeft.y + topRight.y + bottomRight.y + bottomLeft.y) / 4)

    /** Edge 0 is the top, 1 the right, 2 the bottom, 3 the left. */
    fun edgeLength(index: Int): Double = distance(this[index], this[index + 1])

    fun scaled(sx: Double, sy: Double): Quad = Quad(
        Pt(topLeft.x * sx, topLeft.y * sy), Pt(topRight.x * sx, topRight.y * sy),
        Pt(bottomRight.x * sx, bottomRight.y * sy), Pt(bottomLeft.x * sx, bottomLeft.y * sy))

    fun maxCornerDistance(other: Quad): Double {
        var worst = 0.0
        for (i in 0 until 4) worst = max(worst, distance(this[i], other[i]))
        return worst
    }

    /** Every corner is at least `margin` pixels inside the image; a negative margin allows that much outside. */
    fun isInside(width: Double, height: Double, margin: Double = 0.0): Boolean {
        for (i in 0 until 4) {
            val p = this[i]
            if (p.x < margin || p.y < margin || p.x > width - margin || p.y > height - margin) return false
        }
        return true
    }

    /** Inside the outline or within `tolerance` pixels outside it; the quad must be convex. */
    fun contains(point: Pt, tolerance: Double = 0.0): Boolean {
        for (i in 0 until 4) {
            val a = this[i]
            val b = this[i + 1]
            val len = distance(a, b)
            if (len <= 0) return false
            val outside = ((b.x - a.x) * (a.y - point.y) - (b.y - a.y) * (a.x - point.x)) / len
            if (outside > tolerance) return false
        }
        return true
    }

    companion object {
        /** Four corners in any order around the outline, turned clockwise and started at the top-left. */
        fun fromCorners(corners: List<Pt>): Quad {
            require(corners.size == 4) { "A quad has four corners." }
            val p = corners.toMutableList()
            var sum = 0.0
            for (i in 0 until 4) {
                val a = p[i]
                val b = p[(i + 1) and 3]
                sum += a.x * b.y - b.x * a.y
            }
            if (sum < 0) {
                val t = p[1]
                p[1] = p[3]
                p[3] = t
            }
            var start = 0
            var bestY = Double.MAX_VALUE
            var bestX = Double.MAX_VALUE
            for (i in 0 until 4) {
                val a = p[i]
                val b = p[(i + 1) and 3]
                val my = (a.y + b.y) / 2
                val mx = (a.x + b.x) / 2
                if (my < bestY || (my == bestY && mx < bestX)) {
                    bestY = my
                    bestX = mx
                    start = i
                }
            }
            return Quad(p[start], p[(start + 1) and 3], p[(start + 2) and 3], p[(start + 3) and 3])
        }

        fun distance(a: Pt, b: Pt): Double {
            val dx = a.x - b.x
            val dy = a.y - b.y
            return sqrt(dx * dx + dy * dy)
        }
    }
}

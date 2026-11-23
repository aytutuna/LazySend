package com.lazysend.lazysend.scan

import kotlin.math.abs

/**
 * A plane-to-plane projective map (3 x 3, row-major): (x, y) goes to
 * ((m00 x + m01 y + m02) / w, (m10 x + m11 y + m12) / w) with w = m20 x + m21 y + m22.
 */
data class Homography(
    val m00: Double, val m01: Double, val m02: Double,
    val m10: Double, val m11: Double, val m12: Double,
    val m20: Double, val m21: Double, val m22: Double,
) {
    /** Infinite or NaN when `p` maps to the line at infinity. */
    fun map(p: Pt): Pt {
        val w = m20 * p.x + m21 * p.y + m22
        return Pt((m00 * p.x + m01 * p.y + m02) / w, (m10 * p.x + m11 * p.y + m12) / w)
    }

    /** Positive on the side of the plane that is seen. */
    fun weight(p: Pt): Double = m20 * p.x + m21 * p.y + m22

    val determinant: Double
        get() = m00 * (m11 * m22 - m12 * m21) - m01 * (m10 * m22 - m12 * m20) + m02 * (m10 * m21 - m11 * m20)

    /** Null when the matrix is singular. */
    fun inverse(): Homography? {
        val det = determinant
        if (det == 0.0 || !det.isFinite()) return null
        return Homography(
            (m11 * m22 - m12 * m21) / det, (m02 * m21 - m01 * m22) / det, (m01 * m12 - m02 * m11) / det,
            (m12 * m20 - m10 * m22) / det, (m00 * m22 - m02 * m20) / det, (m02 * m10 - m00 * m12) / det,
            (m10 * m21 - m11 * m20) / det, (m01 * m20 - m00 * m21) / det, (m00 * m11 - m01 * m10) / det)
    }

    companion object {
        val identity = Homography(1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0)

        /** `a` x `b`: applies `b` first, then `a`. */
        fun multiply(a: Homography, b: Homography) = Homography(
            a.m00 * b.m00 + a.m01 * b.m10 + a.m02 * b.m20,
            a.m00 * b.m01 + a.m01 * b.m11 + a.m02 * b.m21,
            a.m00 * b.m02 + a.m01 * b.m12 + a.m02 * b.m22,
            a.m10 * b.m00 + a.m11 * b.m10 + a.m12 * b.m20,
            a.m10 * b.m01 + a.m11 * b.m11 + a.m12 * b.m21,
            a.m10 * b.m02 + a.m11 * b.m12 + a.m12 * b.m22,
            a.m20 * b.m00 + a.m21 * b.m10 + a.m22 * b.m20,
            a.m20 * b.m01 + a.m21 * b.m11 + a.m22 * b.m21,
            a.m20 * b.m02 + a.m21 * b.m12 + a.m22 * b.m22)

        /** The unit square onto `quad` (Heckbert's closed form); null when three corners are in line. */
        fun squareToQuad(quad: Quad): Homography? {
            val x0 = quad.topLeft.x
            val y0 = quad.topLeft.y
            val x1 = quad.topRight.x
            val y1 = quad.topRight.y
            val x2 = quad.bottomRight.x
            val y2 = quad.bottomRight.y
            val x3 = quad.bottomLeft.x
            val y3 = quad.bottomLeft.y
            val sx = x0 - x1 + x2 - x3
            val sy = y0 - y1 + y2 - y3
            val dx1 = x1 - x2
            val dx2 = x3 - x2
            val dy1 = y1 - y2
            val dy2 = y3 - y2
            val den = dx1 * dy2 - dx2 * dy1
            if (den == 0.0 || !den.isFinite()) return null
            val g = (sx * dy2 - dx2 * sy) / den
            val h = (dx1 * sy - sx * dy1) / den
            val m = Homography(
                x1 - x0 + g * x1, x3 - x0 + h * x3, x0,
                y1 - y0 + g * y1, y3 - y0 + h * y3, y0,
                g, h, 1.0)
            val det = m.determinant
            return if (det == 0.0 || !det.isFinite()) null else m
        }

        /** The rectangle (0, 0)-(width, height) onto `quad`, corner to corner. */
        fun rectToQuad(width: Double, height: Double, quad: Quad): Homography? {
            if (!(width > 0 && height > 0)) return null
            val s = squareToQuad(quad) ?: return null
            return Homography(
                s.m00 / width, s.m01 / height, s.m02,
                s.m10 / width, s.m11 / height, s.m12,
                s.m20 / width, s.m21 / height, s.m22)
        }

        fun quadToRect(quad: Quad, width: Double, height: Double): Homography? =
            rectToQuad(width, height, quad)?.inverse()

        /**
         * The map taking each of four points `from` to the matching point of `to`, solved by Gaussian
         * elimination with partial pivoting and m22 = 1. Null when no such map exists.
         */
        fun fromCorrespondences(from: List<Pt>, to: List<Pt>): Homography? {
            require(from.size == 4 && to.size == 4) { "Four points each." }
            val a = DoubleArray(8 * 9)
            for (i in 0 until 4) {
                val x = from[i].x
                val y = from[i].y
                val u = to[i].x
                val v = to[i].y
                val r = 2 * i
                a[r * 9 + 0] = x; a[r * 9 + 1] = y; a[r * 9 + 2] = 1.0
                a[r * 9 + 6] = -u * x; a[r * 9 + 7] = -u * y; a[r * 9 + 8] = u
                a[(r + 1) * 9 + 3] = x; a[(r + 1) * 9 + 4] = y; a[(r + 1) * 9 + 5] = 1.0
                a[(r + 1) * 9 + 6] = -v * x; a[(r + 1) * 9 + 7] = -v * y; a[(r + 1) * 9 + 8] = v
            }
            for (col in 0 until 8) {
                var pivot = col
                var best = abs(a[col * 9 + col])
                for (r in col + 1 until 8) {
                    val value = abs(a[r * 9 + col])
                    if (value > best) {
                        best = value
                        pivot = r
                    }
                }
                if (!(best > 1e-12)) return null
                if (pivot != col) {
                    for (k in 0 until 9) {
                        val t = a[col * 9 + k]
                        a[col * 9 + k] = a[pivot * 9 + k]
                        a[pivot * 9 + k] = t
                    }
                }
                for (r in col + 1 until 8) {
                    val f = a[r * 9 + col] / a[col * 9 + col]
                    if (f == 0.0) continue
                    for (k in col until 9) a[r * 9 + k] -= f * a[col * 9 + k]
                }
            }
            val h = DoubleArray(8)
            for (r in 7 downTo 0) {
                var sum = a[r * 9 + 8]
                for (k in r + 1 until 8) sum -= a[r * 9 + k] * h[k]
                h[r] = sum / a[r * 9 + r]
            }
            val m = Homography(h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7], 1.0)
            val det = m.determinant
            return if (det == 0.0 || !det.isFinite()) null else m
        }
    }
}

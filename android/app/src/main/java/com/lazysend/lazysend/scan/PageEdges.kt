package com.lazysend.lazysend.scan

import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/** The edge field of a photo and the straight lines fitted to it, which `QuadRefiner` moves a page's outline onto. */
internal object PageEdges {
    /** The photo is searched with its long side at most this many pixels. */
    const val ANALYSIS_LONG_SIDE = 1000

    /** A pixel is an edge when its gradient is at least this many levels per pixel (after smoothing). */
    const val EDGE_THRESHOLD = 3.0

    /** An edge pixel's vote is its gradient, at most this. */
    const val VOTE_CAP = 20.0

    /** The gradient across a point, in levels per pixel. */
    class Gradient(val gx: Double, val gy: Double)

    /** The gradient of the analysis image: per pixel, of the strongest smoothed channel (0 on the outermost pixels). */
    class Field private constructor(val w: Int, val h: Int, private val gx: DoubleArray, private val gy: DoubleArray) {
        val diagonal: Double get() = sqrt(w.toDouble() * w.toDouble() + h.toDouble() * h.toDouble())

        /** The gradient at a continuous point, bilinear between pixel centers (clamped inside the gradient's area). */
        fun gradientAt(x: Double, y: Double): Gradient {
            val fx = x - 0.5
            val fy = y - 0.5
            val cx = min(max(fx, 1.0), w.toDouble() - 2.000001)
            val cy = min(max(fy, 1.0), h.toDouble() - 2.000001)
            val x0f = floor(cx)
            val y0f = floor(cy)
            val x0 = x0f.toInt()
            val y0 = y0f.toInt()
            val tx = cx - x0f
            val ty = cy - y0f
            val i = y0 * w + x0
            val gxTop = gx[i] * (1 - tx) + gx[i + 1] * tx
            val gxBottom = gx[i + w] * (1 - tx) + gx[i + w + 1] * tx
            val gyTop = gy[i] * (1 - tx) + gy[i + 1] * tx
            val gyBottom = gy[i + w] * (1 - tx) + gy[i + w + 1] * tx
            return Gradient(gxTop * (1 - ty) + gxBottom * ty, gyTop * (1 - ty) + gyBottom * ty)
        }

        companion object {
            fun build(image: RgbaImage): Field {
                val w = image.width
                val h = image.height
                val channels = arrayOf(smooth(image.pixels, w, h, 0), smooth(image.pixels, w, h, 1), smooth(image.pixels, w, h, 2))
                val gxs = DoubleArray(w * h)
                val gys = DoubleArray(w * h)
                if (h >= 3 && w >= 3) {
                    for (y in 1 until h - 1) {
                        for (x in 1 until w - 1) {
                            val i = y * w + x
                            var bestX = 0
                            var bestY = 0
                            var bestM = -1L
                            for (c in 0 until 3) {
                                val ch = channels[c]
                                val right = ch[i - w + 1] + 2 * ch[i + 1] + ch[i + w + 1]
                                val left = ch[i - w - 1] + 2 * ch[i - 1] + ch[i + w - 1]
                                val below = ch[i + w - 1] + 2 * ch[i + w] + ch[i + w + 1]
                                val above = ch[i - w - 1] + 2 * ch[i - w] + ch[i - w + 1]
                                val gx = right - left
                                val gy = below - above
                                val m = gx.toLong() * gx + gy.toLong() * gy
                                if (m > bestM) {
                                    bestM = m
                                    bestX = gx
                                    bestY = gy
                                }
                            }
                            gxs[i] = bestX.toDouble() / 2048.0
                            gys[i] = bestY.toDouble() / 2048.0
                        }
                    }
                }
                return Field(w, h, gxs, gys)
            }

            /** Channel `channel` smoothed by 1-4-6-4-1 across and down (edges repeated): 256 x the level. */
            private fun smooth(rgba: ByteArray, w: Int, h: Int, channel: Int): IntArray {
                // Each row smoothed across into rows 2..h+1 of a buffer padded by two repeated rows above and below.
                val row = IntArray(w + 4)
                val across = IntArray(w * (h + 4))
                for (y in 0 until h) {
                    val src = y * w
                    for (x in 0 until w) row[x + 2] = rgba[(src + x) * 4 + channel].toInt() and 0xFF
                    row[0] = row[2]
                    row[1] = row[2]
                    row[w + 2] = row[w + 1]
                    row[w + 3] = row[w + 1]
                    val dst = (y + 2) * w
                    for (x in 0 until w) {
                        across[dst + x] = row[x] + 4 * row[x + 1] + 6 * row[x + 2] + 4 * row[x + 3] + row[x + 4]
                    }
                }
                for (x in 0 until w) {
                    across[x] = across[2 * w + x]
                    across[w + x] = across[2 * w + x]
                    across[(h + 2) * w + x] = across[(h + 1) * w + x]
                    across[(h + 3) * w + x] = across[(h + 1) * w + x]
                }
                val output = IntArray(w * h)
                for (y in 0 until h) {
                    val a = y * w
                    val b = a + w
                    val c = b + w
                    val d = c + w
                    val e = d + w
                    for (x in 0 until w) {
                        output[a + x] = across[a + x] + 4 * across[b + x] + 6 * across[c + x] + 4 * across[d + x] + across[e + x]
                    }
                }
                return output
            }
        }
    }

    /** A straight line n . p = rho with a unit normal. */
    data class Line(val nx: Double, val ny: Double, val rho: Double) {
        fun distance(x: Double, y: Double): Double = nx * x + ny * y - rho

        companion object {
            fun through(p: Pt, q: Pt): Line {
                val dx = q.x - p.x
                val dy = q.y - p.y
                val len = sqrt(dx * dx + dy * dy)
                val nx = dy / len
                val ny = -dx / len
                return Line(nx, ny, nx * p.x + ny * p.y)
            }

            fun intersect(a: Line, b: Line): Pt? {
                val det = a.nx * b.ny - a.ny * b.nx
                if (abs(det) < 1e-9) return null
                return Pt((a.rho * b.ny - b.rho * a.ny) / det, (a.nx * b.rho - b.nx * a.rho) / det)
            }
        }
    }

    /**
     * The total-least-squares line through `points`, refitted twice without the points farther from it
     * than 2.5 times the median distance (and 0.75 px).
     */
    fun fitLine(points: List<Pt>): Line {
        var current = points
        var line = fit(current)
        for (round in 0 until 2) {
            val distances = DoubleArray(current.size) { abs(line.distance(current[it].x, current[it].y)) }
            val sorted = distances.sortedArray()
            val limit = max(0.75, 2.5 * sorted[sorted.size / 2])
            val kept = ArrayList<Pt>()
            for (i in current.indices) if (distances[i] <= limit) kept.add(current[i])
            if (kept.size < 4 || kept.size == current.size) break
            current = kept
            line = fit(current)
        }
        return line
    }

    private fun fit(points: List<Pt>): Line {
        var mx = 0.0
        var my = 0.0
        for (p in points) {
            mx += p.x
            my += p.y
        }
        mx /= points.size.toDouble()
        my /= points.size.toDouble()
        var sxx = 0.0
        var sxy = 0.0
        var syy = 0.0
        for (p in points) {
            val dx = p.x - mx
            val dy = p.y - my
            sxx += dx * dx
            sxy += dx * dy
            syy += dy * dy
        }
        // The direction of largest spread: the eigenvector of the larger eigenvalue.
        val half = (sxx - syy) / 2
        val lambda = (sxx + syy) / 2 + sqrt(half * half + sxy * sxy)
        val ax = lambda - syy
        val ay = sxy
        val bx = sxy
        val by = lambda - sxx
        var dirX: Double
        var dirY: Double
        if (abs(ax) + abs(ay) >= abs(bx) + abs(by)) {
            dirX = ax
            dirY = ay
        } else {
            dirX = bx
            dirY = by
        }
        var len = sqrt(dirX * dirX + dirY * dirY)
        if (len == 0.0) {
            dirX = 1.0
            dirY = 0.0
            len = 1.0
        }
        val nx = -dirY / len
        val ny = dirX / len
        return Line(nx, ny, nx * mx + ny * my)
    }
}

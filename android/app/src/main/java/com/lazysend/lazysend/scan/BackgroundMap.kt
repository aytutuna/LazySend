package com.lazysend.lazysend.scan

import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min

/**
 * How bright the paper is across an area of a page: the area is cut into tiles, each tile's background
 * is a high percentile of its pixels (the paper between the marks), and the background of any pixel is
 * interpolated between tile centers. `x`, `y`, `width` and `height` locate the area in the image;
 * `tiles` is row-major, `columns` x `rows`, one byte each.
 */
class BackgroundMap private constructor(
    val x: Int,
    val y: Int,
    val width: Int,
    val height: Int,
    val columns: Int,
    val rows: Int,
    val tiles: ByteArray,
) {
    // For each column (row) of the area: the two tiles whose centers surround it and the second one's weight.
    private val x0s = IntArray(width)
    private val x1s = IntArray(width)
    private val fxs = DoubleArray(width)
    private val y0s = IntArray(height)
    private val y1s = IntArray(height)
    private val fys = DoubleArray(height)

    init {
        interpolation(width, columns, x0s, x1s, fxs)
        interpolation(height, rows, y0s, y1s, fys)
    }

    private fun tile(i: Int): Int = tiles[i].toInt() and 0xFF

    private fun derived(tiles: ByteArray) = BackgroundMap(x, y, width, height, columns, rows, tiles)

    /** The middle tile background (the upper middle one for an even count). */
    fun medianTile(): Int {
        val sorted = IntArray(tiles.size) { tile(it) }
        sorted.sort()
        return sorted[sorted.size / 2]
    }

    /** Each tile replaced by the brightest of itself and its eight neighbors. */
    fun maxSmoothed(): BackgroundMap {
        val output = ByteArray(tiles.size)
        for (ty in 0 until rows) {
            for (tx in 0 until columns) {
                var best = 0
                for (ny in max(0, ty - 1)..min(rows - 1, ty + 1)) {
                    for (nx in max(0, tx - 1)..min(columns - 1, tx + 1)) best = max(best, tile(ny * columns + nx))
                }
                output[ty * columns + tx] = best.toByte()
            }
        }
        return derived(output)
    }

    /** Each tile replaced by the darkest of itself and its eight neighbors. */
    fun minSmoothed(): BackgroundMap {
        val output = ByteArray(tiles.size)
        for (ty in 0 until rows) {
            for (tx in 0 until columns) {
                var least = 255
                for (ny in max(0, ty - 1)..min(rows - 1, ty + 1)) {
                    for (nx in max(0, tx - 1)..min(columns - 1, tx + 1)) least = min(least, tile(ny * columns + nx))
                }
                output[ty * columns + tx] = least.toByte()
            }
        }
        return derived(output)
    }

    /**
     * Tiles much darker than the paper beside them filled in from it: a tile darker than `share` of the
     * brightest of its eight neighbors takes that neighbor's value, pass after pass (each pass reading the
     * one before), until nothing changes or there have been as many passes as the map is tiles across or
     * down. A soft shadow darkens from tile to tile by less than that and stays; a picture or a dark mark
     * larger than a tile is filled from the paper around it inwards. A filled region (changed tiles joined
     * through their eight neighbors) that reaches the map's outer tiles is lighting, not a picture: a
     * shadow cast across the sheet from beyond its edge. Its tiles keep their own values.
     */
    fun raisedDarkTiles(share: Double): BackgroundMap {
        val original = IntArray(tiles.size) { tile(it) }
        var current = original.copyOf()
        var next = IntArray(tiles.size)
        val passes = max(columns, rows)
        var pass = 0
        while (pass < passes) {
            var changed = false
            for (ty in 0 until rows) {
                for (tx in 0 until columns) {
                    var best = 0
                    for (ny in max(0, ty - 1)..min(rows - 1, ty + 1)) {
                        for (nx in max(0, tx - 1)..min(columns - 1, tx + 1)) {
                            if (nx == tx && ny == ty) continue
                            best = max(best, current[ny * columns + nx])
                        }
                    }
                    val value = current[ty * columns + tx]
                    if (value.toDouble() < share * best.toDouble()) {
                        next[ty * columns + tx] = best
                        changed = true
                    } else {
                        next[ty * columns + tx] = value
                    }
                }
            }
            val previous = current
            current = next
            next = previous
            pass++
            if (!changed) break
        }
        // Each filled region in turn, from its first tile in row-major order; one that reaches an outer tile
        // is lighting and takes its own values back.
        val visited = BooleanArray(current.size)
        val members = IntArray(current.size)
        var start = 0
        while (start < current.size) {
            if (visited[start] || current[start] == original[start]) {
                start++
                continue
            }
            visited[start] = true
            members[0] = start
            var count = 1
            var reachesEdge = false
            var k = 0
            while (k < count) {
                val tile = members[k]
                val tx = tile % columns
                val ty = tile / columns
                if (tx == 0 || ty == 0 || tx == columns - 1 || ty == rows - 1) reachesEdge = true
                for (ny in max(0, ty - 1)..min(rows - 1, ty + 1)) {
                    for (nx in max(0, tx - 1)..min(columns - 1, tx + 1)) {
                        val n = ny * columns + nx
                        if (visited[n] || current[n] == original[n]) continue
                        visited[n] = true
                        members[count++] = n
                    }
                }
                k++
            }
            if (reachesEdge) {
                for (m in 0 until count) current[members[m]] = original[members[m]]
            }
            start++
        }
        return derived(ByteArray(current.size) { current[it].toByte() })
    }

    /** Each tile raised to at least `floor`. */
    fun clampedBelow(floor: Int): BackgroundMap = derived(ByteArray(tiles.size) { max(tile(it), floor).toByte() })

    /**
     * The background at image pixel (px, py) inside the area: bilinear between the centers of the
     * surrounding tiles, the nearest tile's value beyond the outer centers.
     */
    fun valueAt(px: Int, py: Int): Double {
        val ax = min(max(px - x, 0), width - 1)
        val ay = min(max(py - y, 0), height - 1)
        val r0 = y0s[ay] * columns
        val r1 = y1s[ay] * columns
        val top = lerp(tile(r0 + x0s[ax]), tile(r0 + x1s[ax]), fxs[ax])
        val bottom = lerp(tile(r1 + x0s[ax]), tile(r1 + x1s[ax]), fxs[ax])
        return top + (bottom - top) * fys[ay]
    }

    /**
     * The ink of the area: 1 where a pixel is darker than (1 - `contrast`) of the background there, 0
     * elsewhere. One byte per pixel, width x height, row-major.
     */
    fun inkMask(gray: GrayImage, contrast: Double): ByteArray {
        val keep = 1 - contrast
        val mask = ByteArray(width * height)
        for (ay in 0 until height) {
            val row = (y + ay) * gray.width + x
            val t0 = y0s[ay] * columns
            val t1 = y1s[ay] * columns
            val fy = fys[ay]
            for (ax in 0 until width) {
                val top = lerp(tile(t0 + x0s[ax]), tile(t0 + x1s[ax]), fxs[ax])
                val bottom = lerp(tile(t1 + x0s[ax]), tile(t1 + x1s[ax]), fxs[ax])
                val background = top + (bottom - top) * fy
                if ((gray.pixels[row + ax].toInt() and 0xFF).toDouble() < background * keep) mask[ay * width + ax] = 1
            }
        }
        return mask
    }

    companion object {
        /**
         * The map of the area (x, y, width, height) of `gray`, clamped to the image: tiles of about
         * `tileSize` pixels (whole tiles only, so the last ones are a little larger), each one's
         * background the `percentile` (0..1) of its pixels. Null when the area is empty.
         */
        fun estimate(gray: GrayImage, x: Int, y: Int, width: Int, height: Int, tileSize: Int,
                     percentile: Double = 0.9): BackgroundMap? {
            val x0 = min(max(x, 0), gray.width)
            val y0 = min(max(y, 0), gray.height)
            val x1 = min(max(x + width, x0), gray.width)
            val y1 = min(max(y + height, y0), gray.height)
            val w = x1 - x0
            val h = y1 - y0
            if (w <= 0 || h <= 0) return null
            val size = max(1, tileSize)
            val columns = max(1, w / size)
            val rows = max(1, h / size)
            val tiles = ByteArray(columns * rows)
            val histogram = IntArray(256)
            for (ty in 0 until rows) {
                val top = y0 + ty * h / rows
                val bottom = y0 + (ty + 1) * h / rows
                for (tx in 0 until columns) {
                    val left = x0 + tx * w / columns
                    val right = x0 + (tx + 1) * w / columns
                    histogram.fill(0)
                    for (py in top until bottom) {
                        val row = py * gray.width
                        for (px in left until right) histogram[gray.pixels[row + px].toInt() and 0xFF]++
                    }
                    tiles[ty * columns + tx] =
                        percentile(histogram, (bottom - top) * (right - left), percentile).toByte()
                }
            }
            return BackgroundMap(x0, y0, w, h, columns, rows, tiles)
        }

        /** The smallest value with at least ceil(`fraction` x `count`) values at or below it, from a histogram of `count` values. */
        fun percentile(histogram: IntArray, count: Int, fraction: Double): Int {
            val rank = min(max(ceil(fraction * count.toDouble()).toInt(), 1), max(1, count))
            var seen = 0
            for (v in 0 until 256) {
                seen += histogram[v]
                if (seen >= rank) return v
            }
            return 255
        }

        private fun lerp(a: Int, b: Int, t: Double): Double = a.toDouble() + (b - a).toDouble() * t

        private fun interpolation(length: Int, tiles: Int, first: IntArray, second: IntArray, weight: DoubleArray) {
            val centers = DoubleArray(tiles) { t ->
                val start = t * length / tiles
                val end = (t + 1) * length / tiles
                (start + end).toDouble() / 2
            }
            var k = 0
            for (p in 0 until length) {
                val c = p.toDouble() + 0.5
                while (k < tiles - 1 && centers[k + 1] <= c) k++
                if (c <= centers[0]) {
                    first[p] = 0
                    second[p] = 0
                    weight[p] = 0.0
                } else if (k >= tiles - 1) {
                    first[p] = tiles - 1
                    second[p] = tiles - 1
                    weight[p] = 0.0
                } else {
                    first[p] = k
                    second[p] = k + 1
                    weight[p] = (c - centers[k]) / (centers[k + 1] - centers[k])
                }
            }
        }
    }
}

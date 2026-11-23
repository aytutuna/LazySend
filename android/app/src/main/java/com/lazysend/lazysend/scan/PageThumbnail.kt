package com.lazysend.lazysend.scan

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/**
 * A small grayscale look at a page in a live frame, to tell whether the automatic shutter is about to
 * take the page it took last: the frame's luma over the page's bounding box (`FrameQuality.area`) as
 * `SIDE` x `SIDE` cell means, without the outermost ring of cells, which the page's edges (found only to
 * a pixel or two) and the table beside them decide. Two looks match when their cells correlate
 * (`MIN_CORRELATION`), so another exposure or a slightly moved phone still matches while another page does
 * not; two looks that are both nearly flat (blank paper) match when their brightness against the frame's
 * part outside the page is close, however much of the frame the page fills.
 */
class PageThumbnail(frame: RgbaImage, page: Quad?) {
    private val cells: DoubleArray

    /** The mean luma of the frame outside the page, when there is enough of it, and light enough, to go by. */
    private val surround: Double?

    init {
        val gray = GrayImage.luma(frame)
        val box = FrameQuality.area(page, gray.width, gray.height)
        val outside = gray.width * gray.height - (box.x1 - box.x0) * (box.y1 - box.y0)
        var inside = 0L
        for (y in box.y0 until box.y1) {
            for (x in box.x0 until box.x1) inside += gray.pixels[y * gray.width + x].toInt() and 0xFF
        }
        var total = 0L
        for (v in gray.pixels) total += v.toInt() and 0xFF
        val around = (total - inside).toDouble() / max(outside, 1).toDouble()
        val enough = outside.toDouble() >= MIN_SURROUND * (gray.width * gray.height).toDouble()
        surround = if (enough && around >= MIN_SURROUND_LUMA) around else null

        val boxWidth = box.x1 - box.x0
        val boxHeight = box.y1 - box.y0
        val means = DoubleArray((SIDE - 2) * (SIDE - 2))
        var n = 0
        for (cy in 1 until SIDE - 1) {
            val y0 = box.y0 + cy * boxHeight / SIDE
            val y1 = min(max(y0 + 1, box.y0 + (cy + 1) * boxHeight / SIDE), box.y1)
            for (cx in 1 until SIDE - 1) {
                val x0 = box.x0 + cx * boxWidth / SIDE
                val x1 = min(max(x0 + 1, box.x0 + (cx + 1) * boxWidth / SIDE), box.x1)
                var sum = 0
                for (y in y0 until y1) {
                    for (x in x0 until x1) sum += gray.pixels[y * gray.width + x].toInt() and 0xFF
                }
                means[n++] = sum.toDouble() / max((y1 - y0) * (x1 - x0), 1).toDouble()
            }
        }
        cells = means
    }

    /** Whether `other` is a look at the same page. */
    fun matches(other: PageThumbnail): Boolean {
        val n = cells.size.toDouble()
        val meanA = cells.sum() / n
        val meanB = other.cells.sum() / n
        var dot = 0.0
        var spreadA = 0.0
        var spreadB = 0.0
        for (i in cells.indices) {
            val a = cells[i] - meanA
            val b = other.cells[i] - meanB
            dot += a * b
            spreadA += a * a
            spreadB += b * b
        }
        val flat = FLAT_SPREAD * FLAT_SPREAD * n
        if (spreadA < flat && spreadB < flat) {
            val a = surround
            val b = other.surround
            if (a != null && b != null && a > 0 && b > 0) {
                val ratioA = meanA / a
                val ratioB = meanB / b
                return abs(ratioA - ratioB) <= FLAT_RATIO * max(ratioA, ratioB)
            }
            return abs(meanA - meanB) <= FLAT_BRIGHTNESS
        }
        if (spreadA < flat || spreadB < flat) return false
        return dot / sqrt(spreadA * spreadB) >= MIN_CORRELATION
    }

    companion object {
        const val SIDE = 24
        const val MIN_CORRELATION = 0.9

        /** A look whose cells vary less than this (standard deviation, in luma levels) counts as flat. */
        const val FLAT_SPREAD = 4.0

        /** Flat looks match when their mean luma differs by at most this (when there is no frame around the page to compare against). */
        const val FLAT_BRIGHTNESS = 12.0

        /** Flat looks match when their brightness over the surround differs by at most this share. */
        const val FLAT_RATIO = 0.1

        /** The frame outside the page counts as a surround when it is at least this share of the frame... */
        const val MIN_SURROUND = 0.05

        /** ...and its mean luma is at least this. */
        const val MIN_SURROUND_LUMA = 16.0
    }
}

package com.lazysend.lazysend.scan

import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

/**
 * A live frame's readings: `sharpness` is the variance of the luma's 4-neighbour Laplacian over the area
 * (high for crisp edges and print, low when blurred), `brightness` the mean luma, 0..255.
 */
data class FrameQualityReading(val sharpness: Double, val brightness: Double)

/** The pixels a frame is measured over: [x0, x1) x [y0, y1). */
data class FrameQualityArea(val x0: Int, val y0: Int, val x1: Int, val y1: Int)

/**
 * How sharp and how bright a live camera frame is, for the automatic shutter: measured on the small frame
 * the page search reads, over the page's bounding box widened by `MARGIN` pixels and kept within the frame
 * (so the page's own edges are in it, and a blank page still has something to be sharp), or the whole frame
 * when no page is given. Sharpness is the variance of 4p - (up + down + left + right) over the area's
 * pixels that have all four neighbours in the frame; both readings come from integer sums, divided once.
 */
object FrameQuality {
    /** The page's bounding box is widened by this many pixels each way. */
    const val MARGIN = 2

    fun measure(frame: RgbaImage, region: Quad? = null): FrameQualityReading = measure(GrayImage.luma(frame), region)

    fun measure(gray: GrayImage, region: Quad? = null): FrameQualityReading {
        val w = gray.width
        val h = gray.height
        val pixels = gray.pixels
        val box = area(region, w, h)
        var sum = 0
        var count = 0
        for (y in box.y0 until box.y1) {
            val row = y * w
            for (x in box.x0 until box.x1) sum += pixels[row + x].toInt() and 0xFF
            count += box.x1 - box.x0
        }
        val brightness = if (count > 0) sum.toDouble() / count.toDouble() else 0.0

        var lapSum = 0
        var lapSquares = 0
        var n = 0
        for (y in max(box.y0, 1) until min(box.y1, h - 1)) {
            val row = y * w
            for (x in max(box.x0, 1) until min(box.x1, w - 1)) {
                val i = row + x
                val l = 4 * (pixels[i].toInt() and 0xFF) - (pixels[i - w].toInt() and 0xFF) -
                    (pixels[i + w].toInt() and 0xFF) - (pixels[i - 1].toInt() and 0xFF) - (pixels[i + 1].toInt() and 0xFF)
                lapSum += l
                lapSquares += l * l
                n++
            }
        }
        var sharpness = 0.0
        if (n > 0) {
            val mean = lapSum.toDouble() / n.toDouble()
            sharpness = max(0.0, lapSquares.toDouble() / n.toDouble() - mean * mean)
        }
        return FrameQualityReading(sharpness, brightness)
    }

    /**
     * The area measured: the quad's bounding box widened by `MARGIN` (its sides rounded outwards) and
     * kept within the frame; the whole frame without a quad, or with one that leaves nothing of it.
     */
    fun area(region: Quad?, width: Int, height: Int): FrameQualityArea {
        val whole = FrameQualityArea(0, 0, width, height)
        if (region == null) return whole
        var minX = Double.MAX_VALUE
        var minY = Double.MAX_VALUE
        var maxX = -Double.MAX_VALUE
        var maxY = -Double.MAX_VALUE
        for (corner in region.corners) {
            if (!corner.x.isFinite() || !corner.y.isFinite()) return whole
            minX = min(minX, corner.x)
            minY = min(minY, corner.y)
            maxX = max(maxX, corner.x)
            maxY = max(maxY, corner.y)
        }
        val edge = MARGIN.toDouble()
        val x0 = min(max(floor(minX) - edge, 0.0), width.toDouble()).toInt()
        val y0 = min(max(floor(minY) - edge, 0.0), height.toDouble()).toInt()
        val x1 = min(max(ceil(maxX) + edge, 0.0), width.toDouble()).toInt()
        val y1 = min(max(ceil(maxY) + edge, 0.0), height.toDouble()).toInt()
        if (x1 <= x0 || y1 <= y0) return whole
        return FrameQualityArea(x0, y0, x1, y1)
    }
}

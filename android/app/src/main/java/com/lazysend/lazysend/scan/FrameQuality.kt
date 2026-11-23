package com.lazysend.lazysend.scan

import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

/** The pixels a frame is measured over: [x0, x1) x [y0, y1). */
data class FrameQualityArea(val x0: Int, val y0: Int, val x1: Int, val y1: Int)

object FrameQuality {
    /** The page's bounding box is widened by this many pixels each way. */
    const val MARGIN = 2

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

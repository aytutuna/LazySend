package com.lazysend.lazysend.scan

import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

/**
 * The reference warp of camera pages: the page a `Quad` outlines in a photo, made into an upright
 * `width x height` rectangle. When the page is made more than `PREFILTER_ABOVE` times smaller than the
 * photo shows it, the photo is first averaged down in k x k blocks so no detail is skipped over, then
 * `PerspectiveCorrector.warp` samples it bicubically.
 */
object PerspectiveWarp {
    const val PREFILTER_ABOVE = 2.0

    /**
     * The whole part of how many times smaller the page is made (the longer of each pair of opposite
     * edges against `width` and `height`) when that is more than PREFILTER_ABOVE; 1 otherwise.
     */
    fun prefilterFactor(quad: Quad, width: Int, height: Int): Int {
        if (width < 1 || height < 1) return 1
        val w0 = max(quad.edgeLength(0), quad.edgeLength(2))
        val h0 = max(quad.edgeLength(1), quad.edgeLength(3))
        val shrink = max(w0 / width, h0 / height)
        if (!(shrink > PREFILTER_ABOVE) || !shrink.isFinite()) return 1
        return min(floor(shrink), PerspectiveCorrector.MAX_OUTPUT_SIDE.toDouble()).toInt()
    }

    /**
     * `image` averaged in `factor` x `factor` blocks from its top-left corner (the last row and column
     * may hold fewer pixels), rounded half up in integers. A factor of 1 or less gives the image itself.
     */
    fun boxReduced(image: RgbaImage, factor: Int): RgbaImage {
        if (factor <= 1) return image
        val w = image.width
        val h = image.height
        val rw = (w + factor - 1) / factor
        val rh = (h + factor - 1) / factor
        val output = ByteArray(rw * rh * 4)
        val pixels = image.pixels
        forRowBands(rh) { start, end ->
            for (oy in start until end) {
                val y0 = oy * factor
                val y1 = min(h, y0 + factor)
                for (ox in 0 until rw) {
                    val x0 = ox * factor
                    val x1 = min(w, x0 + factor)
                    var r = 0
                    var g = 0
                    var b = 0
                    var a = 0
                    for (y in y0 until y1) {
                        var si = (y * w + x0) * 4
                        for (x in x0 until x1) {
                            r += pixels[si].toInt() and 0xFF
                            g += pixels[si + 1].toInt() and 0xFF
                            b += pixels[si + 2].toInt() and 0xFF
                            a += pixels[si + 3].toInt() and 0xFF
                            si += 4
                        }
                    }
                    val count = (y1 - y0) * (x1 - x0)
                    val half = count / 2
                    val di = (oy * rw + ox) * 4
                    output[di] = ((r + half) / count).toByte()
                    output[di + 1] = ((g + half) / count).toByte()
                    output[di + 2] = ((b + half) / count).toByte()
                    output[di + 3] = ((a + half) / count).toByte()
                }
            }
        }
        return RgbaImage(rw, rh, output)
    }

    /**
     * The page `quad` outlines in `image` (corners in continuous pixels, clockwise from the top-left),
     * upright at `width` x `height`: averaged down first by `prefilterFactor`, then sampled as
     * `PerspectiveCorrector.warp` does with the supersampling and fill color of `options` (its size and
     * paper options do not apply). Null for a quad that is not convex or a size outside 1 to
     * MAX_OUTPUT_SIDE.
     */
    fun warp(image: RgbaImage, quad: Quad, width: Int, height: Int,
             options: PerspectiveOptions = PerspectiveOptions()): RgbaImage? {
        val limit = PerspectiveCorrector.MAX_OUTPUT_SIDE
        if (!quad.isConvex || width < 1 || height < 1 || width > limit || height > limit) return null
        val factor = prefilterFactor(quad, width, height)
        var source = image
        var sourceQuad = quad
        if (factor > 1) {
            source = boxReduced(image, factor)
            val scale = 1.0 / factor
            sourceQuad = quad.scaled(scale, scale)
        }
        val planOptions = options.copy(outputWidth = width, outputHeight = height, snapToPaper = false, maxLongSide = 0)
        val plan = PerspectiveCorrector.plan(sourceQuad, source.width, source.height, planOptions) ?: return null
        return PerspectiveCorrector.warp(source, plan, planOptions)
    }
}

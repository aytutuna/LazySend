package com.lazysend.lazysend.scan

import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/** The shape of the sheet a quad shows, worked out from the photo. */
data class AspectEstimate(
    /** The sheet's width (top edge) over its height (left edge), as it lies in the photo. */
    val widthOverHeight: Double,
    /** The camera focal length in pixels that explains the quad; null when the quad does not say. */
    val focalLength: Double?,
) {
    val longOverShort: Double get() = if (widthOverHeight >= 1) widthOverHeight else 1 / widthOverHeight
}

/** A known sheet whose shape matched. A4 stands for every sqrt(2) sheet. */
data class PaperMatch(val size: PaperSize, val longOverShort: Double)

enum class Supersampling {
    /** Four samples per pixel when the page is made smaller than the photo shows it (by more than 1.25). */
    Auto,
    Off,
    On,
}

data class PerspectiveOptions(
    /** The output size, when the caller knows it (both or neither); otherwise it comes from the quad. */
    var outputWidth: Int? = null,
    var outputHeight: Int? = null,
    /** The longest output side; 0 for no limit of the caller's own. */
    var maxLongSide: Int = 0,
    var paperAspectTolerance: Double = PerspectiveCorrector.PAPER_ASPECT_TOLERANCE,
    var snapToPaper: Boolean = true,
    var supersample: Supersampling = Supersampling.Auto,
    /** The color of what lies outside the photo (opaque). */
    var fillR: Int = 255,
    var fillG: Int = 255,
    var fillB: Int = 255,
)

data class PerspectivePlan(
    val width: Int,
    val height: Int,
    /** Maps an output point (continuous pixels) to the photo. */
    val outputToSource: Homography,
    val widthOverHeight: Double,
    /** The known size the shape snapped to, if any. */
    val paper: PaperMatch?,
    /** Output pixels per inch when `paper` is known; null otherwise (callers use `NOMINAL_DPI`). */
    val dpi: Double?,
    val supersampled: Boolean,
)

class PerspectiveCorrection(val image: RgbaImage, val plan: PerspectivePlan)

/**
 * Turns the page a quad outlines in a photo into an upright rectangle: the homography from the
 * output rectangle to the quad, the output size from the quad's longer edges and the sheet's shape
 * (a known paper size when it matches, else the camera's view of the quad, else the edge lengths),
 * then Catmull-Rom resampling with 2 x 2 supersampling when the page is made smaller.
 */
object PerspectiveCorrector {
    /** A shape matches a known size when the long-over-short ratios differ by at most this share. */
    const val PAPER_ASPECT_TOLERANCE = 0.03
    const val NOMINAL_DPI = 200.0
    const val MIN_FOCAL_DIAGONALS = 0.3
    const val MAX_FOCAL_DIAGONALS = 4.0
    const val SUPERSAMPLE_ABOVE = 1.25

    /** The output's long side is at most this many times the photo's diagonal. */
    const val MAX_PHOTO_DIAGONALS = 2.0

    /** 23170 squared times 4 is below an Int array limit and .NET's, so both platforms hold any output. */
    const val MAX_OUTPUT_SIDE = 23170

    /** Matched in this order, the nearest wins. */
    val documentSizes: List<PaperSize> = listOf(PaperSize.A4, PaperSize.Letter, PaperSize.Legal)

    /**
     * The shape of the flat rectangle seen as `quad` by a camera centered on the photo with square
     * pixels (Zhang and He, "Whiteboard scanning and image enhancement", 2007). When the quad is seen
     * straight on, or no focal length between MIN_FOCAL_DIAGONALS and MAX_FOCAL_DIAGONALS diagonals
     * explains it, the shape comes from the edge lengths.
     */
    fun estimateAspect(quad: Quad, imageWidth: Double, imageHeight: Double): AspectEstimate {
        val fallback = edgeAspect(quad)
        val r = rays(quad, imageWidth, imageHeight) ?: return AspectEstimate(fallback, null)
        val diagonal = sqrt(imageWidth * imageWidth + imageHeight * imageHeight)
        val zz = r.n2z * r.n3z
        // Seen straight on (opposite edges parallel), the camera's distance cannot be told.
        val scale = abs(r.n2x) + abs(r.n2y) + abs(r.n3x) + abs(r.n3y)
        if (abs(r.n2z) * diagonal > 1e-3 * scale || abs(r.n3z) * diagonal > 1e-3 * scale) {
            val f2 = -(r.n2x * r.n3x + r.n2y * r.n3y) / zz
            if (zz != 0.0 && f2 > 0 && f2.isFinite()) {
                val f = sqrt(f2)
                if (f >= MIN_FOCAL_DIAGONALS * diagonal && f <= MAX_FOCAL_DIAGONALS * diagonal) {
                    val num = r.n2x * r.n2x + r.n2y * r.n2y + f2 * r.n2z * r.n2z
                    val den = r.n3x * r.n3x + r.n3y * r.n3y + f2 * r.n3z * r.n3z
                    if (num > 0 && den > 0) return AspectEstimate(sqrt(num / den), f)
                }
            }
        }
        return AspectEstimate(fallback, null)
    }

    /**
     * The same with the camera's focal length (in pixels of this photo) given rather than worked out,
     * so a sheet tilted about an axis along one of its edges gets its shape as well. A focal length
     * that is not a positive number gives the estimate without it.
     */
    fun estimateAspect(quad: Quad, imageWidth: Double, imageHeight: Double, focalLength: Double): AspectEstimate {
        if (!(focalLength > 0) || !focalLength.isFinite()) return estimateAspect(quad, imageWidth, imageHeight)
        val fallback = edgeAspect(quad)
        val r = rays(quad, imageWidth, imageHeight) ?: return AspectEstimate(fallback, null)
        val f2 = focalLength * focalLength
        val num = r.n2x * r.n2x + r.n2y * r.n2y + f2 * r.n2z * r.n2z
        val den = r.n3x * r.n3x + r.n3y * r.n3y + f2 * r.n3z * r.n3z
        if (num > 0 && den > 0 && (num / den).isFinite()) return AspectEstimate(sqrt(num / den), focalLength)
        return AspectEstimate(fallback, null)
    }

    /** The size whose long-over-short ratio is nearest to `longOverShort`, when within `tolerance` of it as a share of the size's ratio. */
    fun matchPaper(longOverShort: Double, tolerance: Double = PAPER_ASPECT_TOLERANCE,
                   sizes: List<PaperSize> = documentSizes): PaperMatch? {
        var best: PaperMatch? = null
        var bestDiff = Double.MAX_VALUE
        for (size in sizes) {
            val w = size.inchesWidth
            val h = size.inchesHeight
            val ratio = max(w, h) / min(w, h)
            val diff = abs(longOverShort - ratio) / ratio
            if (diff <= tolerance && diff < bestDiff) {
                bestDiff = diff
                best = PaperMatch(size, ratio)
            }
        }
        return best
    }

    /**
     * The output size, the map and the resolution for the page `quad` outlines in a photo of
     * `imageWidth` x `imageHeight`. Null for a quad that is not convex, a photo without pixels, or an
     * output size given beyond MAX_OUTPUT_SIDE.
     */
    fun plan(quad: Quad, imageWidth: Int, imageHeight: Int, options: PerspectiveOptions = PerspectiveOptions()): PerspectivePlan? {
        val o = options
        if (!quad.isConvex || imageWidth <= 0 || imageHeight <= 0) return null
        val top = quad.edgeLength(0)
        val right = quad.edgeLength(1)
        val bottom = quad.edgeLength(2)
        val left = quad.edgeLength(3)
        val w0 = max(top, bottom)
        val h0 = max(left, right)
        val estimate = estimateAspect(quad, imageWidth.toDouble(), imageHeight.toDouble())
        var aspect = estimate.widthOverHeight
        val paper = if (o.snapToPaper) matchPaper(estimate.longOverShort, o.paperAspectTolerance, documentSizes) else null
        if (paper != null) aspect = if (aspect >= 1) paper.longOverShort else 1 / paper.longOverShort

        val width: Int
        val height: Int
        val fw = o.outputWidth
        val fh = o.outputHeight
        if (fw != null && fh != null && fw > 0 && fh > 0) {
            width = fw
            height = fh
        } else {
            var longSide = max(w0, h0)
            if (o.maxLongSide > 0) longSide = min(longSide, o.maxLongSide.toDouble())
            val iw = imageWidth.toDouble()
            val ih = imageHeight.toDouble()
            val photoDiagonal = sqrt(iw * iw + ih * ih)
            longSide = min(longSide, min(MAX_PHOTO_DIAGONALS * photoDiagonal, MAX_OUTPUT_SIDE.toDouble()))
            val wd: Double
            val hd: Double
            if (aspect >= 1) {
                wd = longSide
                hd = longSide / aspect
            } else {
                hd = longSide
                wd = longSide * aspect
            }
            if (!wd.isFinite() || !hd.isFinite()) return null
            width = max(1, floor(wd + 0.5).toInt())
            height = max(1, floor(hd + 0.5).toInt())
        }
        if (!fitsOutput(width, height)) return null
        val map = Homography.rectToQuad(width.toDouble(), height.toDouble(), quad) ?: return null

        var dpi: Double? = null
        if (paper != null) {
            dpi = max(width, height).toDouble() / max(paper.size.inchesWidth, paper.size.inchesHeight)
        }
        val supersample = when (o.supersample) {
            Supersampling.On -> true
            Supersampling.Off -> false
            Supersampling.Auto -> w0 > width * SUPERSAMPLE_ABOVE || h0 > height * SUPERSAMPLE_ABOVE
        }
        return PerspectivePlan(width, height, map, width.toDouble() / height, paper, dpi, supersample)
    }

    /** `image` resampled as `plan` says. */
    fun warp(image: RgbaImage, plan: PerspectivePlan, options: PerspectiveOptions = PerspectiveOptions()): RgbaImage {
        val w = plan.width
        val h = plan.height
        require(fitsOutput(w, h)) { "A $w x $h output is not possible." }
        val output = ByteArray(w * h * 4)
        val m = plan.outputToSource
        val pixels = image.pixels
        forRowBands(h) { start, end ->
            val acc = DoubleArray(4)
            val kx = DoubleArray(4)
            val ky = DoubleArray(4)
            for (oy in start until end) {
                for (ox in 0 until w) {
                    val di = (oy * w + ox) * 4
                    acc.fill(0.0)
                    if (plan.supersampled) {
                        for (s in 0 until 4) {
                            val px = ox + (if ((s and 1) == 0) 0.25 else 0.75)
                            val py = oy + (if ((s shr 1) == 0) 0.25 else 0.75)
                            accumulate(pixels, image.width, image.height, m, px, py, acc, kx, ky, options)
                        }
                        output[di] = clampedByte(acc[0] / 4).toByte()
                        output[di + 1] = clampedByte(acc[1] / 4).toByte()
                        output[di + 2] = clampedByte(acc[2] / 4).toByte()
                        output[di + 3] = clampedByte(acc[3] / 4).toByte()
                    } else {
                        accumulate(pixels, image.width, image.height, m, ox + 0.5, oy + 0.5, acc, kx, ky, options)
                        output[di] = clampedByte(acc[0]).toByte()
                        output[di + 1] = clampedByte(acc[1]).toByte()
                        output[di + 2] = clampedByte(acc[2]).toByte()
                        output[di + 3] = clampedByte(acc[3]).toByte()
                    }
                }
            }
        }
        return RgbaImage(w, h, output)
    }

    /** The page `quad` outlines, upright; null for a quad that is not convex. */
    fun correct(image: RgbaImage, quad: Quad, options: PerspectiveOptions = PerspectiveOptions()): PerspectiveCorrection? {
        val decided = plan(quad, image.width, image.height, options) ?: return null
        return PerspectiveCorrection(warp(image, decided, options), decided)
    }

    /**
     * Adds the Catmull-Rom sample (4 x 4 taps) of the photo at output point (px, py) to acc; outside
     * the photo it is the fill color. Near 1:1 a bilinear tap halfway between pixels would grey out
     * one-pixel strokes of fine print.
     */
    private fun accumulate(pixels: ByteArray, iw: Int, ih: Int, m: Homography, px: Double, py: Double,
                           acc: DoubleArray, kx: DoubleArray, ky: DoubleArray, o: PerspectiveOptions) {
        val w = m.m20 * px + m.m21 * py + m.m22
        val sx = (m.m00 * px + m.m01 * py + m.m02) / w - 0.5
        val sy = (m.m10 * px + m.m11 * py + m.m12) / w - 0.5
        if (!sx.isFinite() || !sy.isFinite() || sx < -2 || sy < -2 || sx > iw + 1 || sy > ih + 1) {
            acc[0] += o.fillR.toDouble()
            acc[1] += o.fillG.toDouble()
            acc[2] += o.fillB.toDouble()
            acc[3] += 255.0
            return
        }
        val fx0 = floor(sx)
        val fy0 = floor(sy)
        val x0 = fx0.toInt() - 1
        val y0 = fy0.toInt() - 1
        catmullRom(sx - fx0, kx)
        catmullRom(sy - fy0, ky)
        val inside = x0 >= 0 && y0 >= 0 && x0 + 3 < iw && y0 + 3 < ih
        for (j in 0 until 4) {
            val cy = y0 + j
            for (i in 0 until 4) {
                val cx = x0 + i
                val weight = kx[i] * ky[j]
                if (inside || (cx in 0 until iw && cy in 0 until ih)) {
                    val si = (cy * iw + cx) * 4
                    acc[0] += weight * (pixels[si].toInt() and 0xFF)
                    acc[1] += weight * (pixels[si + 1].toInt() and 0xFF)
                    acc[2] += weight * (pixels[si + 2].toInt() and 0xFF)
                    acc[3] += weight * (pixels[si + 3].toInt() and 0xFF)
                } else {
                    acc[0] += weight * o.fillR
                    acc[1] += weight * o.fillG
                    acc[2] += weight * o.fillB
                    acc[3] += weight * 255
                }
            }
        }
    }

    /**
     * Fills `out` with the Catmull-Rom weights of the taps at -1, 0, 1 and 2 from the pixel `t` (0 to 1)
     * before the point; at t = 0 they are exactly 0, 1, 0, 0.
     */
    internal fun catmullRom(t: Double, out: DoubleArray) {
        out[0] = ((-0.5 * t + 1) * t - 0.5) * t
        out[1] = (1.5 * t - 2.5) * t * t + 1
        out[2] = ((-1.5 * t + 2) * t + 0.5) * t
        out[3] = (0.5 * t - 0.5) * t * t
    }

    private fun fitsOutput(width: Int, height: Int): Boolean =
        width in 1..MAX_OUTPUT_SIDE && height in 1..MAX_OUTPUT_SIDE

    /** Zhang and He's n2 and n3: the directions of the rectangle's top and left edges in camera space. */
    private class PlaneRays(
        val n2x: Double, val n2y: Double, val n2z: Double,
        val n3x: Double, val n3y: Double, val n3z: Double,
    )

    /** The edge directions of the rectangle seen as `quad`, up to the focal length; null when the quad gives none. */
    private fun rays(quad: Quad, imageWidth: Double, imageHeight: Double): PlaneRays? {
        val cx = imageWidth / 2
        val cy = imageHeight / 2
        // m1 top-left, m2 top-right, m3 bottom-left, m4 bottom-right, centered, homogeneous.
        val m1x = quad.topLeft.x - cx
        val m1y = quad.topLeft.y - cy
        val m2x = quad.topRight.x - cx
        val m2y = quad.topRight.y - cy
        val m3x = quad.bottomLeft.x - cx
        val m3y = quad.bottomLeft.y - cy
        val m4x = quad.bottomRight.x - cx
        val m4y = quad.bottomRight.y - cy
        val c14 = cross(m1x, m1y, 1.0, m4x, m4y, 1.0)
        val c24 = cross(m2x, m2y, 1.0, m4x, m4y, 1.0)
        val c34 = cross(m3x, m3y, 1.0, m4x, m4y, 1.0)
        val k2den = dot(c24, m3x, m3y, 1.0)
        val k3den = dot(c34, m2x, m2y, 1.0)
        if (k2den == 0.0 || k3den == 0.0) return null
        val k2 = dot(c14, m3x, m3y, 1.0) / k2den
        val k3 = dot(c14, m2x, m2y, 1.0) / k3den
        return PlaneRays(k2 * m2x - m1x, k2 * m2y - m1y, k2 - 1, k3 * m3x - m1x, k3 * m3y - m1y, k3 - 1)
    }

    /** The mean of the top and bottom edges over the mean of the left and right edges (1 for a quad without height). */
    private fun edgeAspect(quad: Quad): Double {
        val top = quad.edgeLength(0)
        val right = quad.edgeLength(1)
        val bottom = quad.edgeLength(2)
        val left = quad.edgeLength(3)
        val sides = (left + right) / 2
        return if (sides > 0) (top + bottom) / 2 / sides else 1.0
    }

    private fun cross(ax: Double, ay: Double, az: Double, bx: Double, by: Double, bz: Double): DoubleArray =
        doubleArrayOf(ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx)

    private fun dot(a: DoubleArray, bx: Double, by: Double, bz: Double): Double =
        a[0] * bx + a[1] * by + a[2] * bz
}

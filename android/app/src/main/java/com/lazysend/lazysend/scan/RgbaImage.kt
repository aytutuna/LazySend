package com.lazysend.lazysend.scan

import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

data class Rect(val x: Double, val y: Double, val width: Double, val height: Double)

/** Rounds halves away from zero, as Swift's `rounded()`. */
internal fun roundHalfAway(value: Double): Double =
    if (value < 0) -floor(-value + 0.5) else floor(value + 0.5)

/** Rounded to the nearest byte value, halves to even, clamped to 0..255. */
internal fun clampedByte(value: Double): Int = min(255.0, max(0.0, Math.rint(value))).toInt()

/**
 * A plain RGBA8 bitmap: row-major, top-left origin, y down, 4 bytes per pixel (R, G, B, A). The
 * pixels are not copied on construction and `resized` or `rotatedQuarterTurns` may return the image
 * itself, so copy `pixels` before changing them.
 */
class RgbaImage(val width: Int, val height: Int, val pixels: ByteArray) {
    init {
        require(width > 0 && height > 0) { "Image dimensions must be positive." }
        require(pixels.size == width * height * 4) {
            "Pixel buffer must be ${width * height * 4} bytes, got ${pixels.size}."
        }
    }

    /** Minifying averages the covered pixels (rounded down); magnifying is bilinear with white outside. */
    fun resized(newWidth: Int, newHeight: Int): RgbaImage {
        require(newWidth > 0 && newHeight > 0) { "Target dimensions must be positive." }
        if (newWidth == width && newHeight == height) return this

        val output = ByteArray(newWidth * newHeight * 4)
        if (newWidth <= width && newHeight <= height) {
            val xRatio = width.toDouble() / newWidth
            val yRatio = height.toDouble() / newHeight
            for (dy in 0 until newHeight) {
                val sy0 = (dy * yRatio).toInt()
                val sy1 = max(sy0 + 1, min(height, ceil((dy + 1) * yRatio).toInt()))
                for (dx in 0 until newWidth) {
                    val sx0 = (dx * xRatio).toInt()
                    val sx1 = max(sx0 + 1, min(width, ceil((dx + 1) * xRatio).toInt()))
                    var r = 0
                    var g = 0
                    var b = 0
                    var a = 0
                    var count = 0
                    for (sy in sy0 until sy1) {
                        var row = (sy * width + sx0) * 4
                        for (sx in sx0 until sx1) {
                            r += pixels[row].toInt() and 0xFF
                            g += pixels[row + 1].toInt() and 0xFF
                            b += pixels[row + 2].toInt() and 0xFF
                            a += pixels[row + 3].toInt() and 0xFF
                            row += 4
                            count++
                        }
                    }
                    val di = (dy * newWidth + dx) * 4
                    output[di] = (r / count).toByte()
                    output[di + 1] = (g / count).toByte()
                    output[di + 2] = (b / count).toByte()
                    output[di + 3] = (a / count).toByte()
                }
            }
        } else {
            for (dy in 0 until newHeight) {
                val sy = (dy + 0.5) * height / newHeight - 0.5
                for (dx in 0 until newWidth) {
                    val sx = (dx + 0.5) * width / newWidth - 0.5
                    sampleBilinear(sx, sy, output, (dy * newWidth + dx) * 4)
                }
            }
        }
        return RgbaImage(newWidth, newHeight, output)
    }

    /** Axis-aligned crop, clamped to the image and rounded outward to whole pixels; null when empty. */
    fun cropped(rect: Rect): RgbaImage? {
        val left = floor(min(rect.x, rect.x + rect.width))
        val right = ceil(max(rect.x, rect.x + rect.width))
        val top = floor(min(rect.y, rect.y + rect.height))
        val bottom = ceil(max(rect.y, rect.y + rect.height))
        val x0 = max(0.0, left)
        val x1 = min(width.toDouble(), right)
        val y0 = max(0.0, top)
        val y1 = min(height.toDouble(), bottom)
        val x = x0.toInt()
        val y = y0.toInt()
        val w = (x1 - x0).toInt()
        val h = (y1 - y0).toInt()
        if (w < 1 || h < 1) return null
        val output = ByteArray(w * h * 4)
        for (row in 0 until h) {
            System.arraycopy(pixels, ((y + row) * width + x) * 4, output, row * w * 4, w * 4)
        }
        return RgbaImage(w, h, output)
    }

    /**
     * A rotated rectangle extracted upright: output pixel (u, v), measured from the output's center,
     * samples the source at (center.x + u cos a - v sin a, center.y + u sin a + v cos a), positive
     * angles clockwise on screen. Sampling is bicubic; outside the source is the fill color. Null
     * when the rounded size is empty.
     */
    fun extractRotated(center: Pt, width: Double, height: Double, angleDegrees: Double,
                       fillR: Int = 255, fillG: Int = 255, fillB: Int = 255): RgbaImage? {
        val outW = roundHalfAway(width).toInt()
        val outH = roundHalfAway(height).toInt()
        if (outW <= 0 || outH <= 0) return null

        val a = angleDegrees * Math.PI / 180
        val c = cos(a)
        val s = sin(a)
        val output = ByteArray(outW * outH * 4)
        val kx = DoubleArray(4)
        val ky = DoubleArray(4)
        for (oy in 0 until outH) {
            val v = oy - (outH - 1).toDouble() / 2
            for (ox in 0 until outW) {
                val u = ox - (outW - 1).toDouble() / 2
                val sx = center.x + u * c - v * s
                val sy = center.y + u * s + v * c
                // The samplers index pixel centers, hence the half-pixel shift.
                sampleCatmullRom(sx - 0.5, sy - 0.5, output, (oy * outW + ox) * 4, kx, ky, fillR, fillG, fillB)
            }
        }
        return RgbaImage(outW, outH, output)
    }

    /** Lossless 90 degree steps, clockwise on screen; taken modulo 4. */
    fun rotatedQuarterTurns(quarterTurns: Int): RgbaImage {
        val turns = ((quarterTurns % 4) + 4) % 4
        if (turns == 0) return this

        val w = width
        val h = height
        val swaps = turns % 2 == 1
        val nw = if (swaps) h else w
        val nh = if (swaps) w else h
        val output = ByteArray(nw * nh * 4)
        for (dy in 0 until nh) {
            for (dx in 0 until nw) {
                val sx: Int
                val sy: Int
                when (turns) {
                    1 -> { sx = dy; sy = h - 1 - dx }
                    2 -> { sx = w - 1 - dx; sy = h - 1 - dy }
                    else -> { sx = w - 1 - dy; sy = dx }
                }
                System.arraycopy(pixels, (sy * w + sx) * 4, output, (dy * nw + dx) * 4, 4)
            }
        }
        return RgbaImage(nw, nh, output)
    }

    private fun sampleBilinear(sx: Double, sy: Double, dest: ByteArray, destIndex: Int) {
        val x0 = floor(sx).toInt()
        val y0 = floor(sy).toInt()
        val fx = sx - x0
        val fy = sy - y0

        var acc0 = 0.0
        var acc1 = 0.0
        var acc2 = 0.0
        var acc3 = 0.0
        for (corner in 0 until 4) {
            val cx = x0 + (corner and 1)
            val cy = y0 + (corner shr 1)
            val weight = (if ((corner and 1) == 0) 1 - fx else fx) * (if ((corner shr 1) == 0) 1 - fy else fy)
            if (weight == 0.0) continue
            if (cx in 0 until width && cy in 0 until height) {
                val si = (cy * width + cx) * 4
                acc0 += weight * (pixels[si].toInt() and 0xFF)
                acc1 += weight * (pixels[si + 1].toInt() and 0xFF)
                acc2 += weight * (pixels[si + 2].toInt() and 0xFF)
                acc3 += weight * (pixels[si + 3].toInt() and 0xFF)
            } else {
                acc0 += weight * 255
                acc1 += weight * 255
                acc2 += weight * 255
                acc3 += weight * 255
            }
        }
        dest[destIndex] = clampedByte(acc0).toByte()
        dest[destIndex + 1] = clampedByte(acc1).toByte()
        dest[destIndex + 2] = clampedByte(acc2).toByte()
        dest[destIndex + 3] = clampedByte(acc3).toByte()
    }

    private fun sampleCatmullRom(sx: Double, sy: Double, dest: ByteArray, destIndex: Int, kx: DoubleArray, ky: DoubleArray,
                                 bgR: Int, bgG: Int, bgB: Int) {
        val fx0 = floor(sx)
        val fy0 = floor(sy)
        val x0 = fx0.toInt() - 1
        val y0 = fy0.toInt() - 1
        PerspectiveCorrector.catmullRom(sx - fx0, kx)
        PerspectiveCorrector.catmullRom(sy - fy0, ky)

        var acc0 = 0.0
        var acc1 = 0.0
        var acc2 = 0.0
        var acc3 = 0.0
        for (j in 0 until 4) {
            val cy = y0 + j
            for (i in 0 until 4) {
                val cx = x0 + i
                val weight = kx[i] * ky[j]
                if (cx in 0 until width && cy in 0 until height) {
                    val si = (cy * width + cx) * 4
                    acc0 += weight * (pixels[si].toInt() and 0xFF)
                    acc1 += weight * (pixels[si + 1].toInt() and 0xFF)
                    acc2 += weight * (pixels[si + 2].toInt() and 0xFF)
                    acc3 += weight * (pixels[si + 3].toInt() and 0xFF)
                } else {
                    acc0 += weight * bgR
                    acc1 += weight * bgG
                    acc2 += weight * bgB
                    acc3 += weight * 255
                }
            }
        }
        dest[destIndex] = clampedByte(acc0).toByte()
        dest[destIndex + 1] = clampedByte(acc1).toByte()
        dest[destIndex + 2] = clampedByte(acc2).toByte()
        dest[destIndex + 3] = clampedByte(acc3).toByte()
    }

    override fun equals(other: Any?): Boolean =
        other is RgbaImage && width == other.width && height == other.height && pixels.contentEquals(other.pixels)

    override fun hashCode(): Int = (width * 31 + height) * 31 + pixels.contentHashCode()

    companion object {
        /** A width x height image filled with an opaque color. */
        fun filled(width: Int, height: Int, r: Int, g: Int, b: Int): RgbaImage {
            val pixels = ByteArray(width * height * 4)
            var i = 0
            while (i < pixels.size) {
                pixels[i] = r.toByte()
                pixels[i + 1] = g.toByte()
                pixels[i + 2] = b.toByte()
                pixels[i + 3] = -1
                i += 4
            }
            return RgbaImage(width, height, pixels)
        }
    }
}

package com.lazysend.lazysend.scan

import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min

/**
 * An 8-bit luminance bitmap: row-major, top-left origin, one byte per pixel (0 = black). The page
 * analyses work on it at `ANALYSIS_DPI` so their pixel constants mean the same physical size on
 * every scan. `scale` is these pixels per pixel of the image they were made from.
 */
class GrayImage(
    val width: Int,
    val height: Int,
    val pixels: ByteArray,
    val dpi: Double = ANALYSIS_DPI.toDouble(),
    val scale: Double = 1.0,
) {
    init {
        require(width > 0 && height > 0) { "Image dimensions must be positive." }
        require(pixels.size == width * height) { "Pixel buffer must be ${width * height} bytes, got ${pixels.size}." }
    }

    operator fun get(x: Int, y: Int): Int = pixels[y * width + x].toInt() and 0xFF

    /** This image at `dpi` (box filter); itself when it is no finer. */
    fun atResolution(dpi: Int): GrayImage {
        if (dpi <= 0 || this.dpi <= dpi) return this
        val w = max(1, roundHalfAway(width * dpi.toDouble() / this.dpi).toInt())
        val h = max(1, roundHalfAway(height * dpi.toDouble() / this.dpi).toInt())
        val small = downsampled(w, h)
        return GrayImage(small.width, small.height, small.pixels, dpi.toDouble(), scale * w.toDouble() / width)
    }

    /** Each pixel is the mean (rounded down) of the source rectangle it covers; this image when not smaller on both axes. */
    fun downsampled(newWidthAsked: Int, newHeightAsked: Int): GrayImage {
        require(newWidthAsked > 0 && newHeightAsked > 0) { "Target dimensions must be positive." }
        if (newWidthAsked >= width && newHeightAsked >= height) return this
        val newWidth = min(newWidthAsked, width)
        val newHeight = min(newHeightAsked, height)

        val output = ByteArray(newWidth * newHeight)
        val xRatio = width.toDouble() / newWidth
        val yRatio = height.toDouble() / newHeight
        val x0s = IntArray(newWidth)
        val x1s = IntArray(newWidth)
        for (dx in 0 until newWidth) {
            x0s[dx] = (dx * xRatio).toInt()
            x1s[dx] = max(x0s[dx] + 1, min(width, ceil((dx + 1) * xRatio).toInt()))
        }
        for (dy in 0 until newHeight) {
            val sy0 = (dy * yRatio).toInt()
            val sy1 = max(sy0 + 1, min(height, ceil((dy + 1) * yRatio).toInt()))
            for (dx in 0 until newWidth) {
                val sx0 = x0s[dx]
                val sx1 = x1s[dx]
                var sum = 0
                for (sy in sy0 until sy1) {
                    val row = sy * width
                    for (sx in sx0 until sx1) sum += pixels[row + sx].toInt() and 0xFF
                }
                val count = (sy1 - sy0) * (sx1 - sx0)
                output[dy * newWidth + dx] = (sum / count).toByte()
            }
        }
        return GrayImage(newWidth, newHeight, output, dpi * newWidth / width, scale * newWidth / width)
    }

    /** Opaque RGBA with R = G = B = the gray value. */
    fun toRgba(): RgbaImage {
        val rgba = ByteArray(width * height * 4)
        for (p in pixels.indices) {
            val i = p * 4
            rgba[i] = pixels[p]
            rgba[i + 1] = pixels[p]
            rgba[i + 2] = pixels[p]
            rgba[i + 3] = -1
        }
        return RgbaImage(width, height, rgba)
    }

    override fun equals(other: Any?): Boolean =
        other is GrayImage && width == other.width && height == other.height && dpi == other.dpi &&
            scale == other.scale && pixels.contentEquals(other.pixels)

    override fun hashCode(): Int = (width * 31 + height) * 31 + pixels.contentHashCode()

    companion object {
        const val ANALYSIS_DPI = 100

        fun filled(width: Int, height: Int, value: Int, dpi: Double = ANALYSIS_DPI.toDouble()): GrayImage {
            val pixels = ByteArray(width * height)
            pixels.fill(value.toByte())
            return GrayImage(width, height, pixels, dpi)
        }

        /** Rec. 601 luma of `image`, rounded, at its own size. */
        fun luma(image: RgbaImage, dpi: Double = ANALYSIS_DPI.toDouble()): GrayImage =
            GrayImage(image.width, image.height, ColorAnalysis.grayPixels(image.pixels, image.width, image.height), dpi)

        /** `image`, scanned at `sourceDPI`, as luma at `analysisDPI` (box filter); kept as is when no finer. */
        fun from(image: RgbaImage, sourceDPI: Int, analysisDPI: Int = ANALYSIS_DPI): GrayImage =
            luma(image, max(1, sourceDPI).toDouble()).atResolution(analysisDPI)

        /** The chroma (max - min of R, G, B) of `image`, sized as `from` does. */
        fun chroma(image: RgbaImage, sourceDPI: Int, analysisDPI: Int = ANALYSIS_DPI): GrayImage {
            val pixels = ColorAnalysis.chromaPixels(image.pixels, image.width, image.height)
            return GrayImage(image.width, image.height, pixels, max(1, sourceDPI).toDouble()).atResolution(analysisDPI)
        }
    }
}

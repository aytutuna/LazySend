package com.lazysend.lazysend.scan

import kotlin.math.max

/**
 * Makes a camera frame (BGRA) small for the page search: the frame is split into blocks of `step` x `step`
 * pixels (`step` the smallest whole number that brings the long side to at most `maxLongSide`), and each
 * block gives one pixel, the mean of four of its pixels (at a quarter and three quarters of the block each
 * way), so the work is bounded by the small frame's size, not the camera's.
 */
object FrameScaler {
    fun downscaled(bgra: ByteArray, width: Int, height: Int, bytesPerRow: Int, maxLongSide: Int): RgbaImage? {
        if (width <= 0 || height <= 0 || maxLongSide <= 0 || bytesPerRow < width * 4) return null
        if (bgra.size < bytesPerRow * (height - 1) + width * 4) return null
        val longSide = max(width, height)
        val step = max((longSide + maxLongSide - 1) / maxLongSide, 1)
        val outWidth = max(width / step, 1)
        val outHeight = max(height / step, 1)
        val near = step / 4
        val far = (3 * step) / 4
        val pixels = ByteArray(outWidth * outHeight * 4)
        pixels.fill(-1)
        for (oy in 0 until outHeight) {
            val y0 = minOf(oy * step + near, height - 1)
            val y1 = minOf(oy * step + far, height - 1)
            for (ox in 0 until outWidth) {
                val x0 = minOf(ox * step + near, width - 1)
                val x1 = minOf(ox * step + far, width - 1)
                val a = y0 * bytesPerRow + x0 * 4
                val b = y0 * bytesPerRow + x1 * 4
                val c = y1 * bytesPerRow + x0 * 4
                val d = y1 * bytesPerRow + x1 * 4
                val o = (oy * outWidth + ox) * 4
                for (channel in 0 until 3) {
                    // BGRA in, RGBA out.
                    val from = 2 - channel
                    val sum = (bgra[a + from].toInt() and 0xFF) + (bgra[b + from].toInt() and 0xFF) +
                        (bgra[c + from].toInt() and 0xFF) + (bgra[d + from].toInt() and 0xFF)
                    pixels[o + channel] = ((sum + 2) / 4).toByte()
                }
            }
        }
        return RgbaImage(outWidth, outHeight, pixels)
    }
}

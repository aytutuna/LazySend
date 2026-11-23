package com.lazysend.lazysend.scan

import kotlin.math.max
import kotlin.math.min

/**
 * A photo as DocAligner's corner models take it: stretched to `SIDE` x `SIDE` (its shape not kept, as the
 * models were trained) and given as blue, green and red planes of values from 0 to 1, one row after
 * another. Sampled bilinearly with the pixel centres matched, as OpenCV's linear resize does: input pixel
 * (x, y) reads the photo at ((x + 0.5) * width / SIDE - 0.5, (y + 0.5) * height / SIDE - 0.5), clamped to
 * the photo, from the four pixels around it.
 */
object CornerModelInput {
    const val SIDE = 256

    /** `photo` (alpha left out) as the model's input: 3 x `SIDE` x `SIDE` values. */
    fun make(photo: RgbaImage): FloatArray {
        val plane = SIDE * SIDE
        val input = FloatArray(3 * plane)
        val scaleX = photo.width.toDouble() / SIDE.toDouble()
        val scaleY = photo.height.toDouble() / SIDE.toDouble()
        val px = photo.pixels
        for (y in 0 until SIDE) {
            val rowAt = source(y, scaleY)
            val rowLow = min(rowAt.toInt(), photo.height - 1)
            val rowHigh = min(rowLow + 1, photo.height - 1)
            val rowWeight = rowAt - rowLow.toDouble()
            val top = rowLow * photo.width
            val bottom = rowHigh * photo.width
            for (x in 0 until SIDE) {
                val colAt = source(x, scaleX)
                val colLow = min(colAt.toInt(), photo.width - 1)
                val colHigh = min(colLow + 1, photo.width - 1)
                val colWeight = colAt - colLow.toDouble()
                for (channel in 0 until 3) {
                    // Blue first: the models read OpenCV's BGR.
                    val offset = 2 - channel
                    val a = (px[(top + colLow) * 4 + offset].toInt() and 0xFF).toDouble()
                    val b = (px[(top + colHigh) * 4 + offset].toInt() and 0xFF).toDouble()
                    val c = (px[(bottom + colLow) * 4 + offset].toInt() and 0xFF).toDouble()
                    val d = (px[(bottom + colHigh) * 4 + offset].toInt() and 0xFF).toDouble()
                    val upper = a + (b - a) * colWeight
                    val lower = c + (d - c) * colWeight
                    input[channel * plane + y * SIDE + x] = ((upper + (lower - upper) * rowWeight) / 255).toFloat()
                }
            }
        }
        return input
    }

    private fun source(index: Int, scale: Double): Double = max((index.toDouble() + 0.5) * scale - 0.5, 0.0)
}

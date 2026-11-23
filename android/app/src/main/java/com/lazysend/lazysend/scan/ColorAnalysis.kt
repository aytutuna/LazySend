package com.lazysend.lazysend.scan

import kotlin.math.max
import kotlin.math.min

object ColorAnalysis {
    const val SAMPLE_STEP = 4

    /** A sample is colored when max(R, G, B) - min(R, G, B) is above this. */
    const val CHROMA_THRESHOLD = 32

    /** Low on purpose, so a stamp or a blue signature keeps the page in color. */
    const val MAX_COLORED_FRACTION = 0.001

    fun isEffectivelyGray(rgba: ByteArray, width: Int, height: Int): Boolean {
        var samples = 0
        var colored = 0
        for (y in 0 until height step SAMPLE_STEP) {
            val row = y * width * 4
            for (x in 0 until width step SAMPLE_STEP) {
                val i = row + x * 4
                val r = rgba[i].toInt() and 0xFF
                val g = rgba[i + 1].toInt() and 0xFF
                val b = rgba[i + 2].toInt() and 0xFF
                val chroma = max(r, max(g, b)) - min(r, min(g, b))
                samples++
                if (chroma > CHROMA_THRESHOLD) colored++
            }
        }
        return samples > 0 && colored.toDouble() < MAX_COLORED_FRACTION * samples.toDouble()
    }

    /** Rec. 601 luma in integers (weights x 1000), rounded half up. */
    fun grayPixels(rgba: ByteArray, width: Int, height: Int): ByteArray {
        val count = width * height
        val gray = ByteArray(count)
        for (p in 0 until count) {
            val i = p * 4
            val y = (299 * (rgba[i].toInt() and 0xFF) + 587 * (rgba[i + 1].toInt() and 0xFF) +
                114 * (rgba[i + 2].toInt() and 0xFF) + 500) / 1000
            gray[p] = min(255, y).toByte()
        }
        return gray
    }

    fun chromaPixels(rgba: ByteArray, width: Int, height: Int): ByteArray {
        val count = width * height
        val chroma = ByteArray(count)
        for (p in 0 until count) {
            val i = p * 4
            val r = rgba[i].toInt() and 0xFF
            val g = rgba[i + 1].toInt() and 0xFF
            val b = rgba[i + 2].toInt() and 0xFF
            chroma[p] = (max(r, max(g, b)) - min(r, min(g, b))).toByte()
        }
        return chroma
    }
}

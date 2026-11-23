package com.lazysend.lazysend.scan

/**
 * What the page fixtures are drawn with: integer arithmetic only and one xorshift32 generator, so a
 * fixture is the same pixels on every run (the checksums in the tests pin them).
 */
object TestPages {
    /** xorshift32 (13, 17, 5). */
    class Rng(seed: Long) {
        private var state: Int = if (seed.toInt() == 0) 1 else seed.toInt()

        fun next(): Int {
            state = state xor (state shl 13)
            state = state xor (state ushr 17)
            state = state xor (state shl 5)
            return state
        }

        /** 0 until n. */
        fun below(n: Int): Int = ((next().toLong() and 0xFFFFFFFFL) % n).toInt()

        /** Scanner noise: the sum of four uniform 0..6 values minus 12 (sigma = 4 levels). */
        fun noise(): Int {
            val a = below(7)
            val b = below(7)
            val c = below(7)
            val d = below(7)
            return a + b + c + d - 12
        }
    }

    fun clamp(value: Int): Int = minOf(255, maxOf(0, value))

    fun bytes(vararg values: Int): ByteArray = ByteArray(values.size) { values[it].toByte() }

    /** A gray page as an RGBA scan at `factor` times the resolution (each pixel repeated). */
    fun enlarged(page: GrayImage, factor: Int): RgbaImage {
        val w = page.width * factor
        val h = page.height * factor
        val rgba = ByteArray(w * h * 4)
        for (y in 0 until h) {
            for (x in 0 until w) {
                val v = page.pixels[(y / factor) * page.width + x / factor]
                val i = (y * w + x) * 4
                rgba[i] = v
                rgba[i + 1] = v
                rgba[i + 2] = v
                rgba[i + 3] = -1
            }
        }
        return RgbaImage(w, h, rgba)
    }
}

package com.lazysend.lazysend.scan

/**
 * Live frames as the page search reads them, 320 x 240: a wooden table and a sheet from (80, 40) to
 * (240, 200), with fine lines of print if asked (2 px lines every 4 px, words of 7 px every 10 px);
 * blurred by a box of (2 * blur + 1)^2 pixels (kept within the frame, rounded half up) and darkened to
 * dim/255 (rounded), if asked.
 */
object QualityFrames {
    const val width = 320
    const val height = 240

    val sheet = Quad(Pt(80.0, 40.0), Pt(240.0, 40.0), Pt(240.0, 200.0), Pt(80.0, 200.0))

    fun frame(printed: Boolean = true, blur: Int = 0, dim: Int = 255): RgbaImage {
        val count = width * height
        val r = IntArray(count)
        val g = IntArray(count)
        val b = IntArray(count)
        for (y in 0 until height) {
            for (x in 0 until width) {
                var c = FixtureColor(88, 80, 72)
                if (x in 80 until 240 && y in 40 until 200) {
                    var inked = printed && x in 96 until 224 && y in 56 until 184
                    if (inked) inked = (y - 56) % 4 < 2 && (x - 96) % 10 < 7
                    c = if (inked) FixtureColor(95, 92, 100) else FixtureColor(205, 200, 192)
                }
                val i = y * width + x
                r[i] = c.r
                g[i] = c.g
                b[i] = c.b
            }
        }
        val pixels = ByteArray(count * 4)
        for (y in 0 until height) {
            for (x in 0 until width) {
                var sr = 0
                var sg = 0
                var sb = 0
                var n = 0
                for (yy in maxOf(0, y - blur) until minOf(height, y + blur + 1)) {
                    for (xx in maxOf(0, x - blur) until minOf(width, x + blur + 1)) {
                        val i = yy * width + xx
                        sr += r[i]
                        sg += g[i]
                        sb += b[i]
                        n++
                    }
                }
                val o = (y * width + x) * 4
                pixels[o] = (((sr + n / 2) / n * dim + 127) / 255).toByte()
                pixels[o + 1] = (((sg + n / 2) / n * dim + 127) / 255).toByte()
                pixels[o + 2] = (((sb + n / 2) / n * dim + 127) / 255).toByte()
                pixels[o + 3] = -1
            }
        }
        return RgbaImage(width, height, pixels)
    }
}

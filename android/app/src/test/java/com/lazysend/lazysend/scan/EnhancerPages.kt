package com.lazysend.lazysend.scan

class FixtureColor(val r: Int, val g: Int, val b: Int)

/**
 * Pages a camera took, after the warp: a sheet of warm paper with lines of print, a red stamp and, if
 * asked, a large dark picture, under a shadow that darkens it from full light at the top left to about
 * 37 % at the bottom right (255 - 130 x / (W - 1) - 30 y / (H - 1), integer divisions).
 */
object EnhancerPages {
    val paper = FixtureColor(232, 226, 212)
    val ink = FixtureColor(40, 38, 44)
    val stamp = FixtureColor(196, 48, 44)
    val dark = FixtureColor(70, 74, 80)

    /** Where the hard shadow of `hardShadow` starts: everything right of it is in shadow. */
    const val shadowEdge = 130

    /** The light in the hard shadow, out of 255 (45 %). */
    const val shadowLight = 115

    enum class ShadowPrint { Lines, FewLines, Blank }

    fun isInk(x: Int, y: Int, width: Int, height: Int): Boolean {
        if (!(x >= 24 && x < width - 24 && y >= 70 && y < height - 30)) return false
        return (y - 70) % 12 < 3 && ((x - 24) / 18) % 5 != 4
    }

    fun isStamp(x: Int, y: Int): Boolean = x in 150 until 200 && y in 24 until 52

    fun isPicture(x: Int, y: Int): Boolean = x in 40 until 140 && y in 200 until 290

    /** The light at (x, y), out of 255. */
    fun light(x: Int, y: Int, width: Int, height: Int): Int = 255 - 130 * x / (width - 1) - 30 * y / (height - 1)

    /** What the pixel at (x, y) shows: 0 paper, 1 print, 2 the stamp, 3 the picture. */
    fun kind(x: Int, y: Int, width: Int, height: Int, stamp: Boolean, picture: Boolean): Int {
        var kind = 0
        if (isInk(x, y, width, height)) kind = 1
        if (stamp && isStamp(x, y)) kind = 2
        if (picture && isPicture(x, y)) kind = 3
        return kind
    }

    private fun put(pixels: ByteArray, o: Int, c: FixtureColor, s: Int) {
        pixels[o] = ((c.r * s + 127) / 255).toByte()
        pixels[o + 1] = ((c.g * s + 127) / 255).toByte()
        pixels[o + 2] = ((c.b * s + 127) / 255).toByte()
        pixels[o + 3] = -1
    }

    private fun gray(pixels: ByteArray, o: Int, v: Int) {
        pixels[o] = v.toByte()
        pixels[o + 1] = v.toByte()
        pixels[o + 2] = v.toByte()
        pixels[o + 3] = -1
    }

    fun shadowed(width: Int = 240, height: Int = 320, stamp: Boolean = true, picture: Boolean = false): RgbaImage {
        val pixels = ByteArray(width * height * 4)
        for (y in 0 until height) {
            for (x in 0 until width) {
                val c = when (kind(x, y, width, height, stamp, picture)) {
                    1 -> ink
                    2 -> EnhancerPages.stamp
                    3 -> dark
                    else -> paper
                }
                put(pixels, (y * width + x) * 4, c, light(x, y, width, height))
            }
        }
        return RgbaImage(width, height, pixels)
    }

    /** Where the light print of `darkGround` is: 1 px lines every 12 px, words of 18 px with every fifth left out. */
    fun isLightPrint(x: Int, y: Int, width: Int, height: Int): Boolean {
        if (!(x >= 24 && x < width - 24 && y >= 70 && y < height - 30)) return false
        return (y - 70) % 12 < 1 && ((x - 24) / 18) % 5 != 4
    }

    /** A dark ground (luma 55) with sparse light print (235) on it, as a chalkboard or a dark flyer. */
    fun darkGround(width: Int = 240, height: Int = 320): RgbaImage {
        val pixels = ByteArray(width * height * 4)
        for (y in 0 until height) {
            for (x in 0 until width) {
                gray(pixels, (y * width + x) * 4, if (isLightPrint(x, y, width, height)) 235 else 55)
            }
        }
        return RgbaImage(width, height, pixels)
    }

    /**
     * A gray page in even light: paper of luma `paper` with the lines of `isInk` (or the 1 px lines of
     * `isLightPrint` when `thin`) at luma `ink`, as pencil or faded thermal print.
     */
    fun faint(paper: Int, ink: Int, thin: Boolean, width: Int = 240, height: Int = 320): RgbaImage {
        val pixels = ByteArray(width * height * 4)
        for (y in 0 until height) {
            for (x in 0 until width) {
                val print = if (thin) isLightPrint(x, y, width, height) else isInk(x, y, width, height)
                gray(pixels, (y * width + x) * 4, if (print) ink else paper)
            }
        }
        return RgbaImage(width, height, pixels)
    }

    /** Where the print of a short note is: 2 px lines every 12 px from y = 70 to 130, words as `isInk`. */
    fun isFewLines(x: Int, y: Int, width: Int, height: Int): Boolean {
        if (!(x >= 24 && x < width - 24 && y >= 70 && y < 130)) return false
        return (y - 70) % 12 < 2 && ((x - 24) / 18) % 5 != 4
    }

    fun isPrint(x: Int, y: Int, width: Int, height: Int, print: ShadowPrint): Boolean = when (print) {
        ShadowPrint.Lines -> isInk(x, y, width, height)
        ShadowPrint.FewLines -> isFewLines(x, y, width, height)
        ShadowPrint.Blank -> false
    }

    /** The warm paper with `print` in full light, under a hard-edged shadow from `edge` to the right edge at `shadowLight`. */
    fun hardShadow(width: Int = 240, height: Int = 320, print: ShadowPrint = ShadowPrint.Lines,
                   edge: Int = shadowEdge): RgbaImage {
        val pixels = ByteArray(width * height * 4)
        for (y in 0 until height) {
            for (x in 0 until width) {
                val c = if (isPrint(x, y, width, height, print)) ink else paper
                put(pixels, (y * width + x) * 4, c, if (x < edge) 255 else shadowLight)
            }
        }
        return RgbaImage(width, height, pixels)
    }

    /** Where the picture of `pictureWithCaption` is (mid-tile on every side). */
    fun isBigPicture(x: Int, y: Int): Boolean = x in 30 until 210 && y in 50 until 230

    /** Where the caption of `pictureWithCaption` is: two 2 px lines under the picture. */
    fun isCaption(x: Int, y: Int): Boolean {
        if (!(x >= 40 && x < 200 && y >= 262 && y < 290)) return false
        return (y - 262) % 12 < 2 && ((x - 40) / 18) % 5 != 4
    }

    /** A 240 x 320 page in full light that is mostly a dark picture with a short caption under it on the warm paper. */
    fun pictureWithCaption(width: Int = 240, height: Int = 320): RgbaImage {
        val pixels = ByteArray(width * height * 4)
        for (y in 0 until height) {
            for (x in 0 until width) {
                val c = if (isBigPicture(x, y)) dark else if (isCaption(x, y)) ink else paper
                put(pixels, (y * width + x) * 4, c, 255)
            }
        }
        return RgbaImage(width, height, pixels)
    }
}

/**
 * Live frames as the page search reads them, 320 x 240: a wooden table and a blank sheet from (80, 40) to
 * (240, 200), blurred by a box of (2 * blur + 1)^2 pixels and darkened to dim/255, if asked.
 */
object LiveFrames {
    const val width = 320
    const val height = 240
    val sheet = Quad(Pt(80.0, 40.0), Pt(240.0, 40.0), Pt(240.0, 200.0), Pt(80.0, 200.0))

    fun frame(blur: Int = 0, dim: Int = 255): RgbaImage {
        val r = IntArray(width * height) { 88 }
        val g = IntArray(width * height) { 80 }
        val b = IntArray(width * height) { 72 }
        for (y in 40 until 200) {
            for (x in 80 until 240) {
                val i = y * width + x
                r[i] = 205
                g[i] = 200
                b[i] = 192
            }
        }
        val pixels = ByteArray(width * height * 4)
        pixels.fill(-1)
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
            }
        }
        return RgbaImage(width, height, pixels)
    }

    /** The sheet moved `dx` px to the right. */
    fun sheetMoved(dx: Double) = Quad(Pt(80 + dx, 40.0), Pt(240 + dx, 40.0), Pt(240 + dx, 200.0), Pt(80 + dx, 200.0))
}

/** `image` with a dark band across the sheet, as another page's text would make. */
fun barred(image: RgbaImage): RgbaImage {
    val pixels = image.pixels.copyOf()
    for (y in 90 until 150) {
        for (x in 80 until 240) {
            val o = (y * image.width + x) * 4
            pixels[o] = 40
            pixels[o + 1] = 40
            pixels[o + 2] = 40
        }
    }
    return RgbaImage(image.width, image.height, pixels)
}

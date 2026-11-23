package com.lazysend.lazysend.scan

/**
 * Synthetic phone photos of a page (360 x 480 RGBA): an A4-shaped sheet (210 x 297 page pixels, one
 * per millimetre, with a header bar, lines of glyphs and a picture) laid on a backdrop under a known
 * perspective, each photo pixel the mean of 2 x 2 samples, then lit: a gradient across the frame,
 * the phone's soft shadow and a glare spot.
 */
object PhotoScenes {
    const val width = 360
    const val height = 480
    const val pageWidth = 210
    const val pageHeight = 297

    /**
     * The page-to-photo map x = (a u + b v + c) / (g u + h v + i), y = (d u + e v + f) / (g u + h v + i),
     * page pixels (u, v) to photo pixels, in integers (Long, the products below overflow an Int).
     */
    class IntHomography(val a: Long, val b: Long, val c: Long, val d: Long, val e: Long, val f: Long,
                        val g: Long, val h: Long, val i: Long) {
        /** Where page point (u, v) lands in the photo. */
        fun map(u: Double, v: Double): Pt {
            val w = g.toDouble() * u + h.toDouble() * v + i.toDouble()
            val x = (a.toDouble() * u + b.toDouble() * v + c.toDouble()) / w
            val y = (d.toDouble() * u + e.toDouble() * v + f.toDouble()) / w
            return Pt(x, y)
        }

        /** The page's outline in the photo. */
        fun corners(pageWidth: Int, pageHeight: Int): Quad =
            Quad.fromCorners(listOf(map(0.0, 0.0), map(pageWidth.toDouble(), 0.0),
                map(pageWidth.toDouble(), pageHeight.toDouble()), map(0.0, pageHeight.toDouble())))
    }

    val woodMap = IntHomography(1155332, -122914, 81788928, 177335, 930372, 75497472, 485, -598, 1048576)
    val darkMap = IntHomography(739319, -271102, 110100480, -28187, 541359, 94371840, -96, -1455, 1048576)
    val lightMap = IntHomography(1121991, 12060, 62914560, -46867, 1041969, 62914560, 272, -332, 1048576)
    val similarMap = IntHomography(1095194, -44778, 73400320, -50732, 1055747, 83886080, -11, -267, 1048576)
    val cutOffMap = IntHomography(1228481, -108457, 157286400, 195764, 1313578, 41943040, -50, 298, 1048576)
    val underMap = IntHomography(806253, 18023, 31457280, -48774, 760787, 41943040, 39, -88, 1048576)
    val topMap = IntHomography(1053725, -86609, 125829120, 102517, 953472, 157286400, 16, -160, 1048576)
    val leftMap = IntHomography(741204, 21217, 20971520, -45071, 763036, 125829120, -46, 1, 1048576)
    val rightMap = IntHomography(748983, -21183, 199229440, 29959, 766131, 120586240, 0, 0, 1048576)
    val roundTripMap = IntHomography(1454408, -35269, 41943040, 82485, 1426885, 37748736, 50, 1, 1048576)

    /** An upright page 1.4 photo pixels per page pixel (294 x 415.8) whose bottom edge lies `gap` px above the frame's bottom (below it when negative: cut off). */
    fun bottomGapMap(gap: Int) = IntHomography(1468006, 0, 33L * 1048576, 0, 1468006,
        (height - gap).toLong() * 1048576 - 1468006L * pageHeight, 0, 0, 1048576)

    /** The same page with its right edge `gap` px from the frame's right side. */
    fun rightGapMap(gap: Int) = IntHomography(1468006, 0, (width - gap).toLong() * 1048576 - 1468006L * pageWidth, 0,
        1468006, 30L * 1048576, 0, 0, 1048576)

    enum class Backdrop { Wood, Dark, Light, Similar, Plain }

    /** A soft ellipse darkened by `depth` per mille, fading out to 2.5 x its size (in squared terms). */
    class Shadow(val cx: Int, val cy: Int, val rx: Int, val ry: Int, val depth: Int)

    /** A spot brightened toward white by up to `strength` per mille, fading quadratically to its radius. */
    class Glare(val cx: Int, val cy: Int, val r: Int, val strength: Int)

    /** The light: dimmed by up to `acrossX` per mille toward the right and `downY` per mille toward the bottom. */
    class Lighting(val acrossX: Int, val downY: Int, val shadow: Shadow?, val glare: Glare?)

    /** A sheet laid in the photo: its own pixels (RGB) and its map. */
    class Sheet(val rgb: ByteArray, val sheetWidth: Int, val sheetHeight: Int, val map: IntHomography)

    private val noLight = Lighting(0, 0, null, null)

    private fun page(seed: Long, map: IntHomography, r: Int = 246, g: Int = 244, b: Int = 238) =
        Sheet(pageRaster(seed, r, g, b), pageWidth, pageHeight, map)

    fun woodScene(): RgbaImage =
        scene(Backdrop.Wood, 0x3D00D001L, Lighting(180, 0, null, null), listOf(page(0x9A6E0001L, woodMap)))

    fun darkScene(): RgbaImage =
        scene(Backdrop.Dark, 0x3D00D002L, Lighting(0, 120, null, Glare(280, 120, 70, 900)), listOf(page(0x9A6E0002L, darkMap)))

    fun lightScene(): RgbaImage =
        scene(Backdrop.Light, 0x3D00D003L, Lighting(0, 0, Shadow(40, 470, 220, 260, 380), null),
            listOf(page(0x9A6E0003L, lightMap)))

    fun similarScene(): RgbaImage =
        scene(Backdrop.Similar, 0x3D00D004L, Lighting(100, 60, null, Glare(180, 250, 55, 800)),
            listOf(page(0x9A6E0004L, similarMap)))

    fun noPageScene(): RgbaImage =
        scene(Backdrop.Wood, 0x3D00D005L, Lighting(150, 0, Shadow(300, 100, 150, 120, 350), Glare(120, 300, 60, 900)),
            emptyList())

    fun plainScene(): RgbaImage = scene(Backdrop.Plain, 0x3D00D006L, noLight, emptyList())

    fun cutOffScene(): RgbaImage =
        scene(Backdrop.Dark, 0x3D00D007L, noLight, listOf(page(0x9A6E0007L, cutOffMap)))

    /** A smaller sheet of cream paper with a larger white one lying over its lower right part. */
    fun overlapScene(): RgbaImage =
        scene(Backdrop.Dark, 0x3D00D008L, noLight,
            listOf(page(0x9A6E0008L, underMap, 232, 226, 210), page(0x9A6E0009L, topMap)))

    /** Two sheets of the same size side by side. */
    fun twoPagesScene(): RgbaImage =
        scene(Backdrop.Light, 0x3D00D00AL, noLight, listOf(page(0x9A6E000AL, leftMap), page(0x9A6E000BL, rightMap)))

    /** The colored blocks of `blockRaster` filling most of the frame, for the round trip. */
    fun roundTripScene(): RgbaImage =
        scene(Backdrop.Dark, 0x3D00D00CL, noLight,
            listOf(Sheet(blockRaster(0x9A6E000CL), pageWidth, pageHeight, roundTripMap)))

    /** A page on wood filling the frame down to `gap` px from its bottom (`bottomGapMap`). */
    fun bottomGapScene(gap: Int): RgbaImage =
        scene(Backdrop.Wood, 0x3D00D00DL, Lighting(120, 0, null, null), listOf(page(0x9A6E000DL, bottomGapMap(gap))))

    /** A page on wood reaching to `gap` px from the frame's right side (`rightGapMap`). */
    fun rightGapScene(gap: Int): RgbaImage =
        scene(Backdrop.Wood, 0x3D00D00EL, Lighting(120, 0, null, null), listOf(page(0x9A6E000EL, rightGapMap(gap))))

    /**
     * A page: paper (white, 246, 244, 238, unless given) with noise, a dark blue-gray header bar,
     * 15 lines of glyphs every 14 px and a picture block.
     */
    fun pageRaster(seed: Long, paperR: Int = 246, paperG: Int = 244, paperB: Int = 238): ByteArray {
        val p = ByteArray(pageWidth * pageHeight * 3)
        val rng = TestPages.Rng(seed)
        for (i in 0 until pageWidth * pageHeight) {
            val n = rng.noise()
            p[i * 3] = TestPages.clamp(paperR + n).toByte()
            p[i * 3 + 1] = TestPages.clamp(paperG + n).toByte()
            p[i * 3 + 2] = TestPages.clamp(paperB + n).toByte()
        }
        fillRgb(p, 20, 18, 170, 14, 52, 64, 92)
        val text = TestPages.Rng(seed xor 0x5A5A5A5AL)
        val picks = intArrayOf(0b00111, 0b01011, 0b01101, 0b01110, 0b10011, 0b10101, 0b10110, 0b11001, 0b11010, 0b11100)
        for (line in 0 until 15) {
            val y = 46 + line * 14
            val maxWidth = if (line % 5 == 4) 90 else 170
            var cx = 20
            while (true) {
                val glyphs = 2 + text.below(7)
                if (cx + glyphs * 7 > 20 + maxWidth) break
                for (k in 0 until glyphs) {
                    val bits = picks[text.below(10)]
                    if (bits and 1 != 0) fillRgb(p, cx, y, 1, 9, 40, 40, 46)
                    if (bits and 2 != 0) fillRgb(p, cx + 4, y, 1, 9, 40, 40, 46)
                    if (bits and 4 != 0) fillRgb(p, cx, y, 5, 1, 40, 40, 46)
                    if (bits and 8 != 0) fillRgb(p, cx, y + 4, 5, 1, 40, 40, 46)
                    if (bits and 16 != 0) fillRgb(p, cx, y + 8, 5, 1, 40, 40, 46)
                    cx += 7
                }
                cx += 7
            }
        }
        for (y in 262 until 286) {
            for (x in 120 until 190) {
                val i = (y * pageWidth + x) * 3
                val v = 70 + (x * 7 + y * 13) % 120
                p[i] = v.toByte()
                p[i + 1] = (v * 9 / 10).toByte()
                p[i + 2] = (v * 7 / 10).toByte()
            }
        }
        return p
    }

    /** A sheet of 10 x 10 px blocks in random colors (each channel 40..239), for the round trip. */
    fun blockRaster(seed: Long): ByteArray {
        val p = ByteArray(pageWidth * pageHeight * 3)
        val rng = TestPages.Rng(seed)
        var by = 0
        while (by < pageHeight) {
            var bx = 0
            while (bx < pageWidth) {
                val r = 40 + rng.below(200)
                val g = 40 + rng.below(200)
                val b = 40 + rng.below(200)
                fillRgb(p, bx, by, 10, 10, r, g, b)
                bx += 10
            }
            by += 10
        }
        return p
    }

    /** The sheet's pixels as an RGBA image (to compare a corrected page with). */
    fun sheetImage(rgb: ByteArray): RgbaImage {
        val rgba = ByteArray(pageWidth * pageHeight * 4)
        for (i in 0 until pageWidth * pageHeight) {
            rgba[i * 4] = rgb[i * 3]
            rgba[i * 4 + 1] = rgb[i * 3 + 1]
            rgba[i * 4 + 2] = rgb[i * 3 + 2]
            rgba[i * 4 + 3] = -1
        }
        return RgbaImage(pageWidth, pageHeight, rgba)
    }

    private fun fillRgb(p: ByteArray, x: Int, y: Int, w: Int, h: Int, r: Int, g: Int, b: Int) {
        val y0 = maxOf(0, y)
        val y1 = minOf(pageHeight, y + h)
        val x0 = maxOf(0, x)
        val x1 = minOf(pageWidth, x + w)
        if (y0 >= y1 || x0 >= x1) return
        for (py in y0 until y1) {
            for (px in x0 until x1) {
                val i = (py * pageWidth + px) * 3
                p[i] = r.toByte()
                p[i + 1] = g.toByte()
                p[i + 2] = b.toByte()
            }
        }
    }

    /**
     * The photo: for every pixel the backdrop (with noise from `seed`, one draw per pixel), the
     * topmost sheet at each of its 2 x 2 sample points (quarter-pixel positions 1 and 3) or the
     * backdrop, averaged (rounding half up), then dimmed by the light and brightened by the glare.
     */
    fun scene(backdrop: Backdrop, seed: Long, light: Lighting, sheets: List<Sheet>): RgbaImage {
        val rng = TestPages.Rng(seed)
        val adj = LongArray(sheets.size * 9)
        for (s in sheets.indices) {
            val m = sheets[s].map
            adj[s * 9 + 0] = m.e * m.i - m.f * m.h
            adj[s * 9 + 1] = m.c * m.h - m.b * m.i
            adj[s * 9 + 2] = m.b * m.f - m.c * m.e
            adj[s * 9 + 3] = m.f * m.g - m.d * m.i
            adj[s * 9 + 4] = m.a * m.i - m.c * m.g
            adj[s * 9 + 5] = m.c * m.d - m.a * m.f
            adj[s * 9 + 6] = m.d * m.h - m.e * m.g
            adj[s * 9 + 7] = m.b * m.g - m.a * m.h
            adj[s * 9 + 8] = m.a * m.e - m.b * m.d
        }
        val pixels = ByteArray(width * height * 4)
        val back = IntArray(3)
        for (y in 0 until height) {
            for (x in 0 until width) {
                backdropColor(backdrop, x, y, rng, back)
                var sr = 0
                var sg = 0
                var sb = 0
                for (sample in 0 until 4) {
                    val qx = 4L * x + (if ((sample and 1) == 0) 1 else 3)
                    val qy = 4L * y + (if ((sample shr 1) == 0) 1 else 3)
                    var cr = back[0]
                    var cg = back[1]
                    var cb = back[2]
                    for (s in sheets.indices) {
                        val k = s * 9
                        var u = adj[k] * qx + adj[k + 1] * qy + adj[k + 2] * 4
                        var v = adj[k + 3] * qx + adj[k + 4] * qy + adj[k + 5] * 4
                        var w = adj[k + 6] * qx + adj[k + 7] * qy + adj[k + 8] * 4
                        if (w < 0) {
                            u = -u
                            v = -v
                            w = -w
                        }
                        val sheet = sheets[s]
                        if (w == 0L || u < 0 || v < 0 || u >= sheet.sheetWidth * w || v >= sheet.sheetHeight * w) continue
                        val i = (((v / w) * sheet.sheetWidth + u / w) * 3).toInt()
                        cr = sheet.rgb[i].toInt() and 0xFF
                        cg = sheet.rgb[i + 1].toInt() and 0xFF
                        cb = sheet.rgb[i + 2].toInt() and 0xFF
                    }
                    sr += cr
                    sg += cg
                    sb += cb
                }
                var r = (sr + 2) / 4
                var g = (sg + 2) / 4
                var b = (sb + 2) / 4
                var dim = 1000 - light.acrossX * x / width - light.downY * y / height
                val sh = light.shadow
                if (sh != null) {
                    val dx = (x - sh.cx).toLong()
                    val dy = (y - sh.cy).toLong()
                    val rx2 = sh.rx.toLong() * sh.rx
                    val ry2 = sh.ry.toLong() * sh.ry
                    val t = (dx * dx * ry2 + dy * dy * rx2) * 1000 / (rx2 * ry2)
                    if (t <= 1000) {
                        dim -= sh.depth
                    } else if (t < 2500) {
                        dim -= (sh.depth * (2500 - t) / 1500).toInt()
                    }
                }
                r = r * dim / 1000
                g = g * dim / 1000
                b = b * dim / 1000
                val gl = light.glare
                if (gl != null) {
                    val dx = x - gl.cx
                    val dy = y - gl.cy
                    val t = (dx * dx + dy * dy) * 1000 / (gl.r * gl.r)
                    if (t < 1000) {
                        val k = gl.strength * (1000 - t) / 1000
                        r += (255 - r) * k / 1000
                        g += (255 - g) * k / 1000
                        b += (255 - b) * k / 1000
                    }
                }
                val o = (y * width + x) * 4
                pixels[o] = TestPages.clamp(r).toByte()
                pixels[o + 1] = TestPages.clamp(g).toByte()
                pixels[o + 2] = TestPages.clamp(b).toByte()
                pixels[o + 3] = -1
            }
        }
        return RgbaImage(width, height, pixels)
    }

    /** The backdrop's color at (x, y), clamped to 0..255, into `out`; one noise draw. */
    private fun backdropColor(backdrop: Backdrop, x: Int, y: Int, rng: TestPages.Rng, out: IntArray) {
        val n = rng.noise()
        val r: Int
        val g: Int
        val b: Int
        when (backdrop) {
            Backdrop.Wood -> {
                // Grain bands warped across the frame, and the seams between planks every 150 px.
                val k = (x + 3 * y / 7) % 240
                val tri = if (k < 120) 120 - k else k - 120
                val phase = 2 * y + tri / 2
                val band = phase / 9 % 7
                var shade = when (band) { 0 -> -26; 1 -> -12; 3 -> -6; else -> 0 }
                if ((x + 75) % 150 < 2) shade -= 40
                r = 150 + shade + 2 * n
                g = 104 + shade * 3 / 4 + 2 * n
                b = 64 + shade / 2 + 2 * n
            }
            Backdrop.Dark -> { r = 38 + 2 * n; g = 40 + 2 * n; b = 46 + 2 * n }
            Backdrop.Light -> { r = 196 + n; g = 198 + n; b = 200 + n }
            Backdrop.Similar -> { r = 228 + n; g = 222 + n; b = 210 + n }
            Backdrop.Plain -> { r = 128 + n; g = 128 + n; b = 128 + n }
        }
        out[0] = TestPages.clamp(r)
        out[1] = TestPages.clamp(g)
        out[2] = TestPages.clamp(b)
    }

    /** FNV-1a of the RGBA bytes: one number per photo, as an unsigned 32-bit value. */
    fun checksum(image: RgbaImage): Long {
        var hash = -2128831035 // 2166136261
        for (b in image.pixels) {
            hash = hash xor (b.toInt() and 0xFF)
            hash *= 16777619
        }
        return hash.toLong() and 0xFFFFFFFFL
    }
}

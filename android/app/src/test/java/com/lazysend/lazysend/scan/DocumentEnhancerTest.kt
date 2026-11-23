package com.lazysend.lazysend.scan

import com.lazysend.lazysend.scan.DocumentEnhanceMode.Auto
import com.lazysend.lazysend.scan.DocumentEnhanceMode.BlackAndWhite
import com.lazysend.lazysend.scan.DocumentEnhanceMode.Color
import com.lazysend.lazysend.scan.DocumentEnhanceMode.Gray
import com.lazysend.lazysend.scan.DocumentEnhanceMode.Photo
import com.lazysend.lazysend.scan.DocumentEnhanceMode.Whiteboard
import com.lazysend.lazysend.scan.TestPages.bytes
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

class DocumentEnhancerTest {
    private fun px(image: RgbaImage, i: Int): Int = image.pixels[i].toInt() and 0xFF

    /** The luma of pixel (x, y), as `ColorAnalysis.grayPixels` computes it. */
    private fun lumaAt(image: RgbaImage, x: Int, y: Int): Int {
        val i = (y * image.width + x) * 4
        return (299 * px(image, i) + 587 * px(image, i + 1) + 114 * px(image, i + 2) + 500) / 1000
    }

    private class LumaRange(var min: Int = 255, var max: Int = 0, var mean: Double = 0.0)

    /** Min, max and mean luma of the pixels of one kind (`EnhancerPages.kind`). */
    private fun lumas(image: RgbaImage, kind: Int, stamp: Boolean = true, picture: Boolean = false): LumaRange {
        val range = LumaRange()
        var sum = 0
        var count = 0
        for (y in 0 until image.height) {
            for (x in 0 until image.width) {
                if (EnhancerPages.kind(x, y, image.width, image.height, stamp, picture) == kind) {
                    val v = lumaAt(image, x, y)
                    range.min = minOf(range.min, v)
                    range.max = maxOf(range.max, v)
                    sum += v
                    count++
                }
            }
        }
        range.mean = sum.toDouble() / maxOf(count, 1)
        return range
    }

    private fun checksum(image: RgbaImage) = PhotoScenes.checksum(image)

    private fun enhance(image: RgbaImage, mode: DocumentEnhanceMode, threshold: Double = DocumentEnhancer.DEFAULT_THRESHOLD) =
        DocumentEnhancer.enhance(image, mode, threshold)

    @Test
    fun theFixturesAreTheSharedPixels() {
        assertEquals(0x4329E79AL, checksum(EnhancerPages.shadowed()))
        assertEquals(0x8F960753L, checksum(EnhancerPages.shadowed(stamp = false)))
        assertEquals(0x2C86F2C0L, checksum(EnhancerPages.shadowed(stamp = false, picture = true)))
    }

    @Test
    fun aShadowedPageComesOutWithOneWhitePaper() {
        val page = EnhancerPages.shadowed()
        val before = lumas(page, 0)
        // The shadow: the paper from about 37 % to full light.
        assertTrue("paper ${before.min}..${before.max}", before.max - before.min >= 100)
        val result = enhance(page, Gray)
        assertEquals(Gray, result.mode)
        assertEquals(page.width, result.image.width)
        assertEquals(page.height, result.image.height)
        val paper = lumas(result.image, 0)
        assertTrue("paper ${paper.min}..${paper.max}", paper.min >= 250)
        // The print stays black everywhere, in the shadow too: the contrast is kept.
        val inked = lumas(result.image, 1)
        assertTrue("print ${inked.min}..${inked.max}", inked.max <= 10)
        val printBefore = lumas(page, 1)
        assertTrue("contrast kept", paper.mean - inked.mean >= (before.max - printBefore.min).toDouble())
        val out = result.image.pixels
        for (i in out.indices step 4) {
            assertEquals(out[i], out[i + 1])
            assertEquals(out[i], out[i + 2])
            assertEquals((-1).toByte(), out[i + 3])
        }
    }

    @Test
    fun colorTakesThePapersTintOutAndKeepsTheStampRed() {
        val result = enhance(EnhancerPages.shadowed(), Color)
        assertEquals(Color, result.mode)
        val image = result.image
        var stampR = 0
        var stampG = 0
        var stamps = 0
        for (y in 0 until image.height) {
            for (x in 0 until image.width) {
                val i = (y * image.width + x) * 4
                val kind = EnhancerPages.kind(x, y, image.width, image.height, stamp = true, picture = false)
                val r = px(image, i)
                val g = px(image, i + 1)
                val b = px(image, i + 2)
                if (kind == 0) {
                    // White and neutral: the warm paper's tint is gone.
                    assertTrue("paper at $x, $y", r >= 250 && g >= 250 && b >= 250)
                    assertTrue("tint at $x, $y", abs(r - b) <= 3)
                } else if (kind == 2) {
                    stampR += r
                    stampG += g
                    stamps++
                }
            }
        }
        assertTrue("the stamp stays red", (stampR - stampG).toDouble() / stamps >= 150)
        assertTrue(lumas(image, 1).max <= 10)
    }

    @Test
    fun autoKeepsColorOnlyWhereThePageHasColor() {
        val colored = EnhancerPages.shadowed()
        val auto = enhance(colored, Auto)
        assertEquals(Color, auto.mode)
        assertArrayEquals(enhance(colored, Color).image.pixels, auto.image.pixels)

        val plain = EnhancerPages.shadowed(stamp = false)
        val grayAuto = enhance(plain, Auto)
        assertEquals(Gray, grayAuto.mode)
        assertArrayEquals(enhance(plain, Gray).image.pixels, grayAuto.image.pixels)
    }

    @Test
    fun coloredPaperKeepsItsHueAndAWarmWhitePageStaysNeutral() {
        val width = 240
        val height = 320
        fun page(r: Int, g: Int, b: Int): RgbaImage {
            val pixels = ByteArray(width * height * 4)
            pixels.fill(-1)
            for (y in 0 until height) {
                for (x in 0 until width) {
                    val ink = EnhancerPages.isInk(x, y, width, height)
                    val o = (y * width + x) * 4
                    pixels[o] = (if (ink) 40 else r).toByte()
                    pixels[o + 1] = (if (ink) 38 else g).toByte()
                    pixels[o + 2] = (if (ink) 44 else b).toByte()
                }
            }
            return RgbaImage(width, height, pixels)
        }
        val o = (5 * width + 5) * 4

        val yellow = enhance(page(240, 220, 120), Auto)
        assertEquals(Color, yellow.mode)
        assertTrue("the yellow stays", px(yellow.image, o) - px(yellow.image, o + 2) >= 40)

        val warm = page(250, 232, 205)
        assertEquals(Gray, enhance(warm, Auto).mode)
        val warmColor = enhance(warm, Color)
        assertTrue(px(warmColor.image, o) >= 250)
        assertTrue(px(warmColor.image, o + 1) >= 250)
        assertTrue(px(warmColor.image, o + 2) >= 250)
    }

    @Test
    fun blackAndWhiteKeepsPencilAndFadedThermalPrint() {
        for ((paper, ink, thin) in listOf(Triple(226, 158, false), Triple(245, 176, true))) {
            val page = EnhancerPages.faint(paper, ink, thin)
            val bw = enhance(page, BlackAndWhite)
            assertEquals(BlackAndWhite, bw.mode)
            for (y in 0 until page.height) {
                for (x in 0 until page.width) {
                    val print = if (thin) EnhancerPages.isLightPrint(x, y, page.width, page.height)
                    else EnhancerPages.isInk(x, y, page.width, page.height)
                    val expected = if (print) 0 else 255
                    assertEquals("$ink: $x, $y", expected, px(bw.image, (y * page.width + x) * 4))
                }
            }
        }
    }

    @Test
    fun theBlackShareFollowsTheThreshold() {
        assertEquals(DocumentEnhancer.BILEVEL_SHARE, DocumentEnhancer.blackShare(0.5), 0.0)
        assertEquals(0.0, DocumentEnhancer.blackShare(0.0), 0.0)
        assertEquals(1.0, DocumentEnhancer.blackShare(1.0), 0.0)
        assertEquals(DocumentEnhancer.BILEVEL_SHARE / 2, DocumentEnhancer.blackShare(0.25), 1e-12)
        assertEquals(0.0, DocumentEnhancer.blackShare(-3.0), 0.0)
        assertEquals(1.0, DocumentEnhancer.blackShare(7.0), 0.0)
    }

    @Test
    fun blackAndWhiteCutsAtTheThreshold() {
        val page = EnhancerPages.faint(226, 158, false)
        fun blackPixels(image: RgbaImage): Int = (0 until image.pixels.size step 4).count { image.pixels[it].toInt() == 0 }
        fun black(threshold: Double) = blackPixels(enhance(page, BlackAndWhite, threshold).image)
        assertEquals(black(0.5), blackPixels(enhance(page, BlackAndWhite).image))
        assertTrue(black(0.5) > 0)
        assertEquals(0, black(0.0))
        assertTrue(black(1.0) >= black(0.5))
    }

    @Test
    fun blackAndWhiteIsPrintOnPaper() {
        val result = enhance(EnhancerPages.shadowed(), BlackAndWhite)
        assertEquals(BlackAndWhite, result.mode)
        val image = result.image
        for (y in 0 until image.height) {
            for (x in 0 until image.width) {
                val v = px(image, (y * image.width + x) * 4)
                assertTrue(v == 0 || v == 255)
                val kind = EnhancerPages.kind(x, y, image.width, image.height, stamp = true, picture = false)
                if (kind == 0) assertEquals(255, v)
                if (kind == 1) assertEquals(0, v)
            }
        }
    }

    @Test
    fun aLargeDarkPictureIsNotWashedOut() {
        val page = EnhancerPages.shadowed(stamp = false, picture = true)
        val result = enhance(page, Gray).image
        assertTrue(lumas(result, 0, stamp = false, picture = true).min >= 250)
        val picture = lumas(result, 3, stamp = false, picture = true)
        assertTrue("picture mean ${picture.mean}", picture.mean <= 70)
        // Its tiles were filled in from the paper around it.
        val gray = GrayImage.luma(page)
        val size = DocumentEnhancer.tileSize(page.width, page.height)
        val raw = BackgroundMap.estimate(gray, 0, 0, page.width, page.height, size)!!
        val paper = DocumentEnhancer.paperMap(gray)!!
        assertTrue(raw.valueAt(90, 245) < 80)
        assertTrue(paper.valueAt(90, 245) > 120)
    }

    @Test
    fun aPhotoIsStretchedAsAWholeNotEvenedOut() {
        val page = EnhancerPages.shadowed()
        val result = enhance(page, Photo)
        assertEquals(Photo, result.mode)
        val paper = lumas(result.image, 0)
        // The shadow stays (the light is the photo's), the ends of the range are stretched.
        assertTrue("paper ${paper.min}..${paper.max}", paper.max - paper.min >= 100)
        assertTrue(paper.max >= 250)
        assertTrue(lumas(result.image, 1).min <= 5)
        // A flat picture is left as it is.
        val flat = RgbaImage.filled(40, 30, 120, 110, 100)
        assertEquals(flat, enhance(flat, Photo).image)
    }

    @Test
    fun aPhotoIsStretchedByAtMostTheCappedGain() {
        // A faded print: levels 70 to 136, one of each.
        val faded = ramp(70, 136)
        val result = enhance(faded, Photo).image
        val first = px(result, 0)
        val last = px(result, (faded.width - 1) * 4)
        assertTrue("$first..$last", (last - first).toDouble() <= (136 - 70) * DocumentEnhancer.MAX_PHOTO_GAIN + 1)
        assertTrue(last - first > 136 - 70)
        assertTrue("$first", first in 55..75)
        assertTrue("$last", last in 130..150)
        assertEquals(0x9D70AB4AL, checksum(result))

        // A photo that already spans the range is stretched to the ends as before.
        val normal = ramp(10, 250)
        val stretched = enhance(normal, Photo).image
        assertEquals(0, px(stretched, 0))
        assertEquals(255, px(stretched, (normal.width - 1) * 4))
        assertEquals(0x7E1D5280L, checksum(stretched))
    }

    private fun ramp(from: Int, to: Int): RgbaImage {
        val width = to - from + 1
        val pixels = ByteArray(width * 4)
        pixels.fill(-1)
        for (x in 0 until width) {
            pixels[x * 4] = (from + x).toByte()
            pixels[x * 4 + 1] = (from + x).toByte()
            pixels[x * 4 + 2] = (from + x).toByte()
        }
        return RgbaImage(width, 1, pixels)
    }

    @Test
    fun aWhiteboardIsEvenedOutAndItsPrintIsNotStretchedToBlack() {
        val page = EnhancerPages.shadowed()
        val board = enhance(page, Whiteboard)
        assertEquals(Whiteboard, board.mode)
        assertEquals(page.width, board.image.width)
        assertEquals(page.height, board.image.height)
        assertTrue(lumas(board.image, 0).min >= 245)
        assertTrue(lumas(board.image, 1).min > 30)
        assertTrue(lumas(enhance(page, Color).image, 1).max <= 10)
    }

    @Test
    fun aWhiteboardPushesItsColorsAwayFromGray() {
        // A white board with a pale red mark: the mark's channels end up further apart than the flattened ones.
        val pixels = ByteArray(64 * 64 * 4)
        pixels.fill(-1)
        for (y in 0 until 64) {
            for (x in 0 until 64) {
                val mark = x in 22 until 42 && y in 22 until 42
                val i = (y * 64 + x) * 4
                pixels[i] = (if (mark) 150 else 230).toByte()
                pixels[i + 1] = (if (mark) 130 else 230).toByte()
                pixels[i + 2] = (if (mark) 130 else 230).toByte()
            }
        }
        val board = enhance(RgbaImage(64, 64, pixels), Whiteboard).image
        val mid = (32 * 64 + 32) * 4
        val chroma = px(board, mid) - px(board, mid + 1)
        assertTrue("chroma $chroma", chroma in 30..45)
        assertEquals(board.pixels[mid + 1], board.pixels[mid + 2])
        assertTrue(lumaAt(board, 4, 4) >= 250)
    }

    @Test
    fun theCleanedUpBytesDoNotChange() {
        val page = EnhancerPages.shadowed()
        assertEquals(0x70604295L, checksum(enhance(page, Auto).image))
        assertEquals(0x70604295L, checksum(enhance(page, Color).image))
        assertEquals(0xEC4526A3L, checksum(enhance(page, Gray).image))
        assertEquals(0x43422875L, checksum(enhance(page, BlackAndWhite).image))
        assertEquals(0xBCA2862CL, checksum(enhance(page, Photo).image))
        val plain = EnhancerPages.shadowed(stamp = false)
        assertEquals(0xF81468D6L, checksum(enhance(plain, Auto).image))
        val picture = EnhancerPages.shadowed(stamp = false, picture = true)
        assertEquals(0x13CF7A4CL, checksum(enhance(picture, Gray).image))
    }

    @Test
    fun darkTilesAreFilledFromThePaperBesideThem() {
        // A 4 x 4 map: paper at 200 with a gentle step (still paper) and a 2 x 2 dark block.
        val tiles = bytes(
            200, 200, 190, 180,
            200, 60, 50, 175,
            200, 55, 40, 170,
            200, 200, 180, 170,
        )
        val gray = ByteArray(16 * 16)
        for (y in 0 until 16) for (x in 0 until 16) gray[y * 16 + x] = tiles[(y / 4) * 4 + x / 4]
        val map = BackgroundMap.estimate(GrayImage(16, 16, gray), 0, 0, 16, 16, 4)!!
        assertArrayEquals(tiles, map.tiles)
        val raised = map.raisedDarkTiles(DocumentEnhancer.DARK_TILE_SHARE)
        // The block takes the paper beside it; the gentle step stays.
        val expected = bytes(
            200, 200, 190, 180,
            200, 200, 200, 175,
            200, 200, 200, 170,
            200, 200, 180, 170,
        )
        assertArrayEquals(expected, raised.tiles)
        assertEquals(map.width, raised.width)
        assertEquals(map.columns, raised.columns)
        // A block wider than a tile's neighbors is filled pass after pass, from the paper inwards.
        val wide = ByteArray(8 * 8)
        wide.fill(210.toByte())
        for (y in 1 until 7) for (x in 1 until 7) wide[y * 8 + x] = 50
        val widePixels = ByteArray(32 * 32)
        for (y in 0 until 32) for (x in 0 until 32) widePixels[y * 32 + x] = wide[(y / 4) * 8 + x / 4]
        val wideMap = BackgroundMap.estimate(GrayImage(32, 32, widePixels), 0, 0, 32, 32, 4)!!
        val filled = wideMap.raisedDarkTiles(0.7)
        val allPaper = ByteArray(64)
        allPaper.fill(210.toByte())
        assertArrayEquals(allPaper, filled.tiles)
        // A dark region that reaches the map's edge is a shadow cast from beyond the sheet: it keeps its own
        // tiles, the one inside it too, while a dark tile inside the paper is still filled.
        val mixed = bytes(
            200, 200, 200, 200, 200, 90,
            200, 50, 200, 200, 60, 80,
            200, 200, 200, 200, 200, 85,
            200, 200, 200, 200, 200, 200,
        )
        val mixedPixels = ByteArray(24 * 16)
        for (y in 0 until 16) for (x in 0 until 24) mixedPixels[y * 24 + x] = mixed[(y / 4) * 6 + x / 4]
        val mixedMap = BackgroundMap.estimate(GrayImage(24, 16, mixedPixels), 0, 0, 24, 16, 4)!!
        val kept = mixed.copyOf()
        kept[7] = 200.toByte()
        assertArrayEquals(kept, mixedMap.raisedDarkTiles(DocumentEnhancer.DARK_TILE_SHARE).tiles)
    }

    @Test
    fun aHardShadowFromTheEdgeIsEvenedOutNotFilledIn() {
        val page = EnhancerPages.hardShadow()
        assertEquals(0xA8CB3FCDL, checksum(page))
        val w = page.width
        val h = page.height
        val tile = DocumentEnhancer.tileSize(w, h)
        // The shadowed paper is at 45 % of the lit paper, so its tiles are much darker than their lit
        // neighbors; the shadow reaches the page's edge, so the paper map follows it instead of filling it in.
        val gray = GrayImage.luma(page)
        assertTrue((gray.pixels[20 * w + 200].toInt() and 0xFF) <= 105)
        val paper = DocumentEnhancer.paperMap(gray)!!
        assertTrue(paper.valueAt(200, 20) < 110)
        assertTrue(paper.valueAt(40, 20) > 220)
        // The paper one white on both sides (but within a tile of the shadow's edge, where the map steps
        // between tile centers), the print black on both; in black and white the print stays in the shadow too.
        val result = enhance(page, Gray)
        val bw = enhance(page, BlackAndWhite)
        assertEquals(BlackAndWhite, bw.mode)
        for (y in 0 until h) {
            for (x in 0 until w) {
                val ink = EnhancerPages.isInk(x, y, w, h)
                val nearEdge = x >= EnhancerPages.shadowEdge && x < EnhancerPages.shadowEdge + tile
                val v = lumaAt(result.image, x, y)
                val b = px(bw.image, (y * w + x) * 4)
                if (ink) {
                    assertTrue("print $v at $x, $y", v <= 30)
                    assertEquals(0, b)
                } else if (!nearEdge) {
                    assertTrue("paper $v at $x, $y", v >= 250)
                    assertEquals(255, b)
                }
            }
        }
        assertEquals(0x2E7FEF38L, checksum(result.image))
        assertEquals(0x74283C44L, checksum(bw.image))
        assertEquals(0x2C520A1DL, checksum(enhance(page, Color).image))
        val auto = enhance(page, Auto)
        assertEquals(Gray, auto.mode)
        assertArrayEquals(result.image.pixels, auto.image.pixels)
    }

    @Test
    fun lightPrintOnADarkGroundIsKeptNotWhitenedAway() {
        val page = EnhancerPages.darkGround()
        assertEquals(0xE4CFC2D5L, checksum(page))
        assertTrue(DocumentEnhancer.isLightOnDark(GrayImage.luma(page)))
        val w = page.width
        val h = page.height
        val modes = listOf(Gray to Gray, BlackAndWhite to BlackAndWhite, Auto to Gray, Color to Color)
        for ((mode, applied) in modes) {
            // Stretched as a whole: the ground black, the print white, never the whole page white.
            val result = enhance(page, mode)
            assertEquals(applied, result.mode)
            for (y in 0 until h) {
                for (x in 0 until w) {
                    val i = (y * w + x) * 4
                    val v = lumaAt(result.image, x, y)
                    if (EnhancerPages.isLightPrint(x, y, w, h)) {
                        assertTrue("$mode: print $v at $x, $y", v >= 250)
                    } else {
                        assertTrue("$mode: ground $v at $x, $y", v <= 5)
                    }
                    assertEquals(result.image.pixels[i], result.image.pixels[i + 2])
                    assertEquals((-1).toByte(), result.image.pixels[i + 3])
                }
            }
            assertEquals(0x6EDC8C95L, checksum(result.image))
        }
        // A page with paper is not light on dark: shadowed, with a dark picture, or under a hard shadow.
        assertFalse(DocumentEnhancer.isLightOnDark(GrayImage.luma(EnhancerPages.shadowed())))
        assertFalse(DocumentEnhancer.isLightOnDark(GrayImage.luma(EnhancerPages.shadowed(stamp = false, picture = true))))
        assertFalse(DocumentEnhancer.isLightOnDark(GrayImage.luma(EnhancerPages.hardShadow())))
        // Nor is a blank dark sheet: it has no light print.
        val blank = RgbaImage.filled(240, 320, 55, 55, 55)
        assertFalse(DocumentEnhancer.isLightOnDark(GrayImage.luma(blank)))
        // Nor a page with little or no print beside a hard step: the lit paper next to a shadow's edge or
        // around a big dark picture is the ground of the tile beside it, not light print, wherever in its
        // tile the edge falls.
        val edges = listOf(109, 127, EnhancerPages.shadowEdge, 148)
        val prints = listOf(EnhancerPages.ShadowPrint.FewLines, EnhancerPages.ShadowPrint.Blank)
        for (edge in edges) {
            for (print in prints) {
                val shadowed = EnhancerPages.hardShadow(print = print, edge = edge)
                assertFalse("$print, edge at $edge", DocumentEnhancer.isLightOnDark(GrayImage.luma(shadowed)))
            }
        }
        assertFalse(DocumentEnhancer.isLightOnDark(GrayImage.luma(EnhancerPages.pictureWithCaption())))
    }

    @Test
    fun aHardShadowOnAPageWithLittlePrintIsEvenedOutToo() {
        val fewLines = EnhancerPages.ShadowPrint.FewLines
        val blankPrint = EnhancerPages.ShadowPrint.Blank
        assertEquals(0x4B4A6495L, checksum(EnhancerPages.hardShadow(print = fewLines)))
        assertEquals(0x2EC994C5L, checksum(EnhancerPages.hardShadow(print = blankPrint)))
        assertEquals(0x263A9905L, checksum(EnhancerPages.hardShadow(print = fewLines, edge = 109)))
        assertEquals(0xA99E33C5L, checksum(EnhancerPages.hardShadow(print = blankPrint, edge = 148)))
        for (print in listOf(fewLines, blankPrint)) {
            val page = EnhancerPages.hardShadow(print = print)
            val w = page.width
            val h = page.height
            val tile = DocumentEnhancer.tileSize(w, h)
            // A short note or a blank sheet under a phone's shadow: the shadowed paper white like the lit
            // paper (not black), the print black in the shadow too, in gray and in black and white.
            val gray = enhance(page, Gray)
            val bw = enhance(page, BlackAndWhite)
            assertEquals(Gray, gray.mode)
            assertEquals(BlackAndWhite, bw.mode)
            for (y in 0 until h) {
                for (x in 0 until w) {
                    val nearEdge = x >= EnhancerPages.shadowEdge && x < EnhancerPages.shadowEdge + tile
                    val v = lumaAt(gray.image, x, y)
                    val b = px(bw.image, (y * w + x) * 4)
                    if (EnhancerPages.isPrint(x, y, w, h, print)) {
                        assertTrue("$print: print $v at $x, $y", v <= 30)
                        assertEquals(0, b)
                    } else if (!nearEdge) {
                        assertTrue("$print: paper $v at $x, $y", v >= 250)
                        assertEquals(255, b)
                    }
                }
            }
        }
        val note = EnhancerPages.hardShadow(print = fewLines)
        val noteGray = enhance(note, Gray).image
        assertEquals(0x7181A6C5L, checksum(noteGray))
        val noteAuto = enhance(note, Auto)
        assertEquals(Gray, noteAuto.mode)
        assertArrayEquals(noteGray.pixels, noteAuto.image.pixels)
        assertEquals(0x5BFD1FE5L, checksum(enhance(note, BlackAndWhite).image))
        val blank = EnhancerPages.hardShadow(print = blankPrint)
        assertEquals(0xF2CEFDC5L, checksum(enhance(blank, BlackAndWhite).image))
    }

    @Test
    fun aBigDarkPictureWithACaptionKeepsItsPaperAndItsPicture() {
        val page = EnhancerPages.pictureWithCaption()
        assertEquals(0x78DD9B25L, checksum(page))
        val gray = enhance(page, Gray)
        assertEquals(Gray, gray.mode)
        var paperMin = 255
        var captionMax = 0
        var pictureSum = 0
        var pictureCount = 0
        for (y in 0 until page.height) {
            for (x in 0 until page.width) {
                val v = lumaAt(gray.image, x, y)
                if (EnhancerPages.isBigPicture(x, y)) {
                    pictureSum += v
                    pictureCount++
                } else if (EnhancerPages.isCaption(x, y)) {
                    captionMax = maxOf(captionMax, v)
                } else {
                    paperMin = minOf(paperMin, v)
                }
            }
        }
        val pictureMean = pictureSum.toDouble() / pictureCount
        assertTrue("paper $paperMin", paperMin >= 250)
        assertTrue("caption $captionMax", captionMax <= 30)
        assertTrue("picture mean $pictureMean", pictureMean <= 70)
        assertEquals(0x895657F5L, checksum(gray.image))
        assertEquals(0x4ACCE6B5L, checksum(enhance(page, BlackAndWhite).image))
    }

    @Test
    fun captureFiltersKeepTheirStoredNamesAndModes() {
        assertEquals(listOf("original", "enhanced", "whiteboard", "grayscale", "blackAndWhite"),
            CaptureFilter.displayOrder.map { Json.encodeToString(it).trim('"') })
        assertEquals(CaptureFilter.BlackAndWhite, Json.decodeFromString<CaptureFilter>("\"blackAndWhite\""))
        assertEquals(Auto, CaptureFilter.Enhanced.mode)
        assertNull(CaptureFilter.Original.mode)
        assertEquals(CaptureFilter.Enhanced, CaptureFilter.fromMode(Color))
        assertEquals(CaptureFilter.Grayscale, CaptureFilter.fromMode(Gray))
        assertNull(CaptureFilter.fromMode(Photo))
    }
}

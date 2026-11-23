package com.lazysend.lazysend.scan

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PageThumbnailTest {
    @Test
    fun thePageSeenAgainMatchesEvenInAnotherExposure() {
        val sharp = PageThumbnail(LiveFrames.frame(), LiveFrames.sheet)
        val shifted = PageThumbnail(LiveFrames.frame(), LiveFrames.sheetMoved(2.0))
        val dimmed = PageThumbnail(LiveFrames.frame(dim = 150), LiveFrames.sheet)
        assertTrue(sharp.matches(sharp))
        assertTrue(sharp.matches(shifted))
        assertTrue(sharp.matches(dimmed))
    }

    @Test
    fun anotherPageDoesNotMatch() {
        val frame = LiveFrames.frame()
        val blank = PageThumbnail(frame, LiveFrames.sheet)
        val text = PageThumbnail(barred(frame), LiveFrames.sheet)
        assertFalse(blank.matches(text))
        assertFalse(text.matches(blank))
    }

    @Test
    fun twoSparsePagesWithTheirTextAtOtherHeightsDoNotMatch() {
        val high = PageThumbnail(textLine(70), LiveFrames.sheet)
        val low = PageThumbnail(textLine(150), LiveFrames.sheet)
        assertTrue(high.matches(PageThumbnail(textLine(70), LiveFrames.sheetMoved(2.0))))
        assertFalse(high.matches(low))
        assertFalse(low.matches(high))
    }

    @Test
    fun aBlankSheetSeenCloserUpStillMatches() {
        val far = PageThumbnail(sheetFrame(80, 40, 160, 160, 200, 80), quad(80.0, 40.0, 160.0, 160.0))
        val near = PageThumbnail(sheetFrame(50, 20, 220, 200, 200, 80), quad(50.0, 20.0, 220.0, 200.0))
        assertTrue(far.matches(near))
        assertTrue(near.matches(far))
    }

    @Test
    fun whiteAndKraftSheetsOnADarkTableDoNotMatch() {
        val white = PageThumbnail(sheetFrame(26, 20, 268, 200, 230, 40), quad(26.0, 20.0, 268.0, 200.0))
        val kraft = PageThumbnail(sheetFrame(26, 20, 268, 200, 150, 40), quad(26.0, 20.0, 268.0, 200.0))
        assertFalse(white.matches(kraft))
        assertFalse(kraft.matches(white))
    }

    @Test
    fun blankLooksMatchByBrightness() {
        val grey = PageThumbnail(RgbaImage.filled(64, 48, 90, 90, 90), null)
        val nearGrey = PageThumbnail(RgbaImage.filled(64, 48, 96, 96, 96), null)
        val white = PageThumbnail(RgbaImage.filled(64, 48, 230, 230, 230), null)
        assertTrue(grey.matches(nearGrey))
        assertFalse(grey.matches(white))
    }

    private fun quad(x: Double, y: Double, width: Double, height: Double) =
        Quad(Pt(x, y), Pt(x + width, y), Pt(x + width, y + height), Pt(x, y + height))

    /** A `LiveFrames`-sized frame of a plain `table` with a plain sheet of `paper` luma on it. */
    private fun sheetFrame(x: Int, y: Int, width: Int, height: Int, paper: Int, table: Int): RgbaImage {
        val pixels = ByteArray(LiveFrames.width * LiveFrames.height * 4)
        for (row in 0 until LiveFrames.height) {
            for (col in 0 until LiveFrames.width) {
                val onSheet = col in x until x + width && row in y until y + height
                val v = (if (onSheet) paper else table).toByte()
                val o = (row * LiveFrames.width + col) * 4
                pixels[o] = v
                pixels[o + 1] = v
                pixels[o + 2] = v
                pixels[o + 3] = -1
            }
        }
        return RgbaImage(LiveFrames.width, LiveFrames.height, pixels)
    }

    /** The plain sheet with one dark line of print, 4 px tall, across it at row `y`. */
    private fun textLine(y: Int): RgbaImage {
        val frame = LiveFrames.frame()
        val pixels = frame.pixels.copyOf()
        for (row in y until y + 4) {
            for (x in 100 until 220) {
                val o = (row * frame.width + x) * 4
                pixels[o] = 40
                pixels[o + 1] = 40
                pixels[o + 2] = 40
            }
        }
        return RgbaImage(frame.width, frame.height, pixels)
    }
}

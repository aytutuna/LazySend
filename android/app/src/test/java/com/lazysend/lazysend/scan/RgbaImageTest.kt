package com.lazysend.lazysend.scan

import com.lazysend.lazysend.scan.TestPages.bytes
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class RgbaImageTest {
    /** An image whose red channel holds the given values, green and blue 0, opaque. */
    private fun reds(width: Int, height: Int, vararg values: Int): RgbaImage {
        val pixels = ByteArray(width * height * 4)
        for ((i, value) in values.withIndex()) {
            pixels[i * 4] = value.toByte()
            pixels[i * 4 + 3] = -1
        }
        return RgbaImage(width, height, pixels)
    }

    private fun channel(image: RgbaImage, c: Int): ByteArray =
        ByteArray(image.width * image.height) { image.pixels[it * 4 + c] }

    private fun redsOf(image: RgbaImage) = channel(image, 0)

    @Test
    fun filledIsOpaqueAndOneColor() {
        val image = RgbaImage.filled(2, 1, 10, 20, 30)
        assertArrayEquals(bytes(10, 20, 30, 255, 10, 20, 30, 255), image.pixels)
    }

    @Test
    fun minifyingAveragesTheCoveredPixelsRoundingDown() {
        // 4 x 2 to 2 x 1: each output pixel is the mean of a 2 x 2 block.
        val image = reds(4, 2, 0, 10, 20, 31, 40, 50, 60, 70)
        assertArrayEquals(bytes(25, 45), redsOf(image.resized(2, 1)))
        // 3 x 1 to 2 x 1: the blocks overlap (columns 0-1 and 1-2).
        assertArrayEquals(bytes(15, 30), redsOf(reds(3, 1, 10, 20, 40).resized(2, 1)))
        assertEquals(255.toByte(), image.resized(2, 1).pixels[3])
    }

    @Test
    fun magnifyingIsBilinearWithWhiteOutsideAndRoundsHalfToEven() {
        // 2 x 1 to 4 x 1: samples at x = -0.25, 0.25, 0.75, 1.25.
        val image = RgbaImage(2, 1, bytes(0, 10, 0, 255, 2, 20, 0, 255)).resized(4, 1)
        assertArrayEquals(bytes(64, 0, 2, 65), redsOf(image))
        assertArrayEquals(bytes(71, 12, 18, 79), channel(image, 1))
        assertArrayEquals(bytes(64, 0, 0, 64), channel(image, 2))
    }

    @Test
    fun resizedToTheSameSizeIsTheSameImage() {
        val image = reds(2, 2, 1, 2, 3, 4)
        assertEquals(image, image.resized(2, 2))
    }

    @Test
    fun rotatedQuarterTurnsTurnsClockwise() {
        // 2 wide x 3 tall:  0 1 / 2 3 / 4 5
        val image = reds(2, 3, 0, 1, 2, 3, 4, 5)
        val once = image.rotatedQuarterTurns(1)
        assertEquals(3, once.width)
        assertEquals(2, once.height)
        assertArrayEquals(bytes(4, 2, 0, 5, 3, 1), redsOf(once))
        assertArrayEquals(bytes(5, 4, 3, 2, 1, 0), redsOf(image.rotatedQuarterTurns(2)))
        assertArrayEquals(bytes(1, 3, 5, 0, 2, 4), redsOf(image.rotatedQuarterTurns(3)))
        assertEquals(image.rotatedQuarterTurns(3), image.rotatedQuarterTurns(-1))
        assertEquals(image, image.rotatedQuarterTurns(4))
    }

    @Test
    fun croppedClampsToTheImageAndRoundsOutward() {
        val image = reds(3, 3, 0, 1, 2, 3, 4, 5, 6, 7, 8)
        assertArrayEquals(bytes(4, 5, 7, 8), redsOf(image.cropped(Rect(1.0, 1.0, 2.0, 2.0))!!))
        assertArrayEquals(bytes(0, 1, 3, 4), redsOf(image.cropped(Rect(0.5, 0.5, 1.0, 1.0))!!))
        assertArrayEquals(bytes(8), redsOf(image.cropped(Rect(2.0, 2.0, 5.0, 5.0))!!))
        assertNull(image.cropped(Rect(3.0, 0.0, 2.0, 2.0)))
    }

    @Test
    fun extractRotatedUprightRegionCopiesThePixels() {
        val image = reds(3, 3, 0, 1, 2, 3, 4, 5, 6, 7, 8)
        val same = image.extractRotated(Pt(1.5, 1.5), 3.0, 3.0, 0.0)!!
        assertArrayEquals(image.pixels, same.pixels)
        // A region a quarter turn clockwise comes out turned back: the image a quarter turn counterclockwise.
        val turned = image.extractRotated(Pt(1.5, 1.5), 3.0, 3.0, 90.0)!!
        assertArrayEquals(redsOf(image.rotatedQuarterTurns(3)), redsOf(turned))
        // Outside the image: the fill color.
        val outside = image.extractRotated(Pt(10.0, 10.0), 1.0, 1.0, 0.0, 7, 8, 9)!!
        assertArrayEquals(bytes(7, 8, 9, 255), outside.pixels)
        assertNull(image.extractRotated(Pt(1.0, 1.0), 0.4, 2.0, 0.0))
        // Halves round away from zero: 0.5 is one pixel.
        assertNotNull(image.extractRotated(Pt(1.0, 1.0), 0.5, 2.0, 0.0))
    }

    @Test
    fun extractRotatedOnePixelStripesKeepTheirContrast() {
        // Black and white columns one pixel wide, read a quarter pixel off: Catmull-Rom gives 40 and
        // 215; bilinear would give 64 and 191.
        val columns = IntArray(40) { if (it % 2 == 0) 0 else 255 }
        val image = reds(40, 3, *(columns + columns + columns))
        val shifted = image.extractRotated(Pt(20.25, 1.5), 40.0, 3.0, 0.0)!!
        val row = redsOf(shifted)
        for (x in 4 until 36) {
            assertEquals("column $x", (if (x % 2 == 0) 40 else 215).toByte(), row[40 + x])
        }
    }
}

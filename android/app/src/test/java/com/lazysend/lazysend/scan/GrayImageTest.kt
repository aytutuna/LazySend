package com.lazysend.lazysend.scan

import com.lazysend.lazysend.scan.TestPages.bytes
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

class GrayImageTest {
    @Test
    fun lumaUsesRoundedRec601Luma() {
        val rgba = bytes(255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255)
        val gray = GrayImage.luma(RgbaImage(4, 1, rgba))
        assertArrayEquals(bytes(76, 150, 29, 255), gray.pixels)
        assertEquals(100.0, gray.dpi, 0.0)
        assertEquals(1.0, gray.scale, 0.0)
    }

    @Test
    fun downsampledAveragesTheCoveredPixelsRoundingDown() {
        val gray = GrayImage(4, 2, bytes(0, 10, 20, 31, 40, 50, 60, 70), 200.0)
        val half = gray.downsampled(2, 1)
        assertArrayEquals(bytes(25, 45), half.pixels)
        assertEquals(100.0, half.dpi, 0.0)
        assertEquals(0.5, half.scale, 0.0)
        assertArrayEquals(bytes(15, 30), GrayImage(3, 1, bytes(10, 20, 40)).downsampled(2, 1).pixels)
        assertEquals(gray, gray.downsampled(4, 2))
        assertEquals(gray, gray.downsampled(9, 9))
    }

    @Test
    fun downsampledMatchesRgbaImageResized() {
        val rng = TestPages.Rng(77)
        val pixels = ByteArray(37 * 23) { rng.below(256).toByte() }
        val gray = GrayImage(37, 23, pixels)
        val rgba = gray.toRgba()
        for ((w, h) in listOf(10 to 7, 36 to 22, 1 to 1, 19 to 23)) {
            assertArrayEquals(GrayImage.luma(rgba.resized(w, h)).pixels, gray.downsampled(w, h).pixels)
        }
    }

    @Test
    fun aScanIsAtTheAnalysisResolution() {
        val scan = TestPages.enlarged(GrayImage(3, 2, bytes(0, 50, 100, 150, 200, 250)), 3)
        val gray = GrayImage.from(scan, 300)
        assertEquals(3, gray.width)
        assertEquals(2, gray.height)
        assertEquals(100.0, gray.dpi, 0.0)
        assertEquals(1.0 / 3, gray.scale, 1e-12)
        assertArrayEquals(bytes(0, 50, 100, 150, 200, 250), gray.pixels)
        // No finer than the analysis resolution: kept as it is.
        val coarse = GrayImage.from(scan, 75)
        assertEquals(9, coarse.width)
        assertEquals(6, coarse.height)
        assertEquals(75.0, coarse.dpi, 0.0)
        assertEquals(1.0, coarse.scale, 0.0)
        assertEquals(coarse, coarse.atResolution(100))
    }

    @Test
    fun chromaIsTheSpreadOfTheChannels() {
        val rgba = bytes(255, 0, 0, 255, 10, 20, 15, 255)
        assertArrayEquals(bytes(255, 10), GrayImage.chroma(RgbaImage(2, 1, rgba), 100).pixels)
    }

    @Test
    fun subscriptFilledAndToRgba() {
        assertArrayEquals(bytes(9, 9, 9, 9), GrayImage.filled(2, 2, 9).pixels)
        val image = GrayImage(2, 1, bytes(3, 4))
        assertEquals(4, image[1, 0])
        assertArrayEquals(bytes(3, 3, 3, 255, 4, 4, 4, 255), image.toRgba().pixels)
    }

    @Test
    fun grayDetectionIgnoresATintButNotAStamp() {
        val white = RgbaImage.filled(40, 40, 250, 246, 240)
        assertEquals(true, ColorAnalysis.isEffectivelyGray(white.pixels, 40, 40))
        val stamped = RgbaImage.filled(40, 40, 250, 246, 240)
        val i = (8 * 40 + 8) * 4
        stamped.pixels[i] = 0
        stamped.pixels[i + 1] = 0
        stamped.pixels[i + 2] = -1
        assertEquals(false, ColorAnalysis.isEffectivelyGray(stamped.pixels, 40, 40))
    }
}

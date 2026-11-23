package com.lazysend.lazysend.scan

import com.lazysend.lazysend.scan.TestPages.bytes
import com.lazysend.lazysend.scan.WarpFixtures.cameraView
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

class PerspectiveCorrectorTest {
    private val roundTripQuad: Quad
        get() = PhotoScenes.roundTripMap.corners(PhotoScenes.pageWidth, PhotoScenes.pageHeight)

    /** The mean absolute difference of R, G and B, leaving out `border` px all around. */
    private fun meanDifference(a: RgbaImage, b: RgbaImage, border: Int): Double {
        assertEquals(a.width, b.width)
        assertEquals(a.height, b.height)
        var sum = 0
        var count = 0
        for (y in border until a.height - border) {
            for (x in border until a.width - border) {
                val i = (y * a.width + x) * 4
                for (c in 0 until 3) sum += abs((a.pixels[i + c].toInt() and 0xFF) - (b.pixels[i + c].toInt() and 0xFF))
                count += 3
            }
        }
        return sum.toDouble() / count
    }

    private fun forcedOptions(supersample: Supersampling) = PerspectiveOptions(
        outputWidth = PhotoScenes.pageWidth, outputHeight = PhotoScenes.pageHeight, supersample = supersample)

    @Test
    fun correctingAWarpedSheetGivesItBack() {
        val sheet = PhotoScenes.sheetImage(PhotoScenes.blockRaster(0x9A6E000CL))
        val corrected = PerspectiveCorrector.correct(PhotoScenes.roundTripScene(), roundTripQuad, forcedOptions(Supersampling.On))!!
        assertEquals(PhotoScenes.pageWidth, corrected.image.width)
        assertEquals(PhotoScenes.pageHeight, corrected.image.height)
        val difference = meanDifference(sheet, corrected.image, 2)
        assertTrue("mean difference $difference", difference <= 6)
        // Every block's center is its own color.
        var by = 5
        while (by < PhotoScenes.pageHeight) {
            var bx = 5
            while (bx < PhotoScenes.pageWidth) {
                val i = (by * PhotoScenes.pageWidth + bx) * 4
                for (c in 0 until 3) {
                    val delta = (corrected.image.pixels[i + c].toInt() and 0xFF) - (sheet.pixels[i + c].toInt() and 0xFF)
                    assertTrue("block ($bx, $by) channel $c: $delta", delta in -6..6)
                }
                bx += 10
            }
            by += 10
        }
    }

    @Test
    fun correctedBytesAreTheSameAsOnTheOtherPlatforms() {
        val on = PerspectiveCorrector.correct(PhotoScenes.roundTripScene(), roundTripQuad, forcedOptions(Supersampling.On))!!
        assertEquals(0xF8DE2BA5L, PhotoScenes.checksum(on.image))
        val off = PerspectiveCorrector.correct(PhotoScenes.roundTripScene(), roundTripQuad, forcedOptions(Supersampling.Off))!!
        assertEquals(0x99509981L, PhotoScenes.checksum(off.image))
        val wood = PerspectiveCorrector.correct(PhotoScenes.woodScene(),
            PhotoScenes.woodMap.corners(PhotoScenes.pageWidth, PhotoScenes.pageHeight))!!
        assertEquals(235, wood.image.width)
        assertEquals(333, wood.image.height)
        assertEquals(PaperSize.A4, wood.plan.paper?.size)
        assertEquals(0x32B36A66L, PhotoScenes.checksum(wood.image))
    }

    @Test
    fun theOutputTakesTheLongerEdgesAndNeverMore() {
        val quad = Quad(Pt(100.0, 100.0), Pt(300.0, 120.0), Pt(320.0, 400.0), Pt(90.0, 380.0))
        val unsnapped = PerspectiveOptions(snapToPaper = false)
        val plan = PerspectiveCorrector.plan(quad, 1000, 1000, unsnapped)!!
        val longest = max(max(quad.edgeLength(0), quad.edgeLength(2)), max(quad.edgeLength(1), quad.edgeLength(3)))
        assertEquals(floor(longest + 0.5).toInt(), max(plan.width, plan.height))
        assertNull(plan.paper)
        assertNull(plan.dpi)
        val cappedOptions = unsnapped.copy(maxLongSide = 100)
        val capped = PerspectiveCorrector.plan(quad, 1000, 1000, cappedOptions)!!
        assertEquals(100, max(capped.width, capped.height))
        assertTrue(capped.supersampled)
        val single = PerspectiveCorrector.plan(quad, 1000, 1000, cappedOptions.copy(supersample = Supersampling.Off))!!
        assertFalse(single.supersampled)
    }

    @Test
    fun aKnownPaperSizeSetsTheShapeAndTheResolution() {
        // An A4 sheet tilted 25 degrees in a 3000 x 4000 photo: the output is sqrt(2) and about as large as the near edge.
        val view = cameraView(210.0, 297.0, 25.0, -10.0, 4.0, 420.0, 3100.0, 3000.0, 4000.0)
        val plan = PerspectiveCorrector.plan(view, 3000, 4000)!!
        assertEquals(PaperSize.A4, plan.paper?.size)
        val ratio = plan.height.toDouble() / plan.width
        assertTrue("$ratio", ratio in 1.410..1.418)
        val dpi = plan.dpi!!
        assertEquals(plan.height / 11.6929, dpi, 0.01)
    }

    @Test
    fun outsideThePhotoIsFilled() {
        val image = RgbaImage.filled(100, 100, 10, 20, 30)
        val quad = Quad(Pt(-50.0, 0.0), Pt(50.0, 0.0), Pt(50.0, 100.0), Pt(-50.0, 100.0))
        val options = PerspectiveOptions(fillR = 255, fillG = 0, fillB = 0, snapToPaper = false)
        val result = PerspectiveCorrector.correct(image, quad, options)!!
        assertEquals(100, result.image.width)
        val left = result.image.pixels.copyOfRange((10 * 100 + 10) * 4, (10 * 100 + 10) * 4 + 4)
        val right = result.image.pixels.copyOfRange((10 * 100 + 90) * 4, (10 * 100 + 90) * 4 + 4)
        assertArrayEquals(bytes(255, 0, 0, 255), left)
        assertArrayEquals(bytes(10, 20, 30, 255), right)
    }

    @Test
    fun onePixelStripesKeepTheirContrastAtOneToOne() {
        // Black and white columns one pixel wide, read a quarter pixel off at 1:1: Catmull-Rom gives
        // 40 and 215; bilinear would give 0.25 * 255 and 0.75 * 255, 64 and 191.
        val size = 40
        val p = ByteArray(size * size * 4) { -1 }
        for (y in 0 until size) {
            for (x in 0 until size step 2) {
                val i = (y * size + x) * 4
                p[i] = 0
                p[i + 1] = 0
                p[i + 2] = 0
            }
        }
        val stripes = RgbaImage(size, size, p)
        val side = size + 0.25
        val quad = Quad(Pt(0.25, 0.0), Pt(side, 0.0), Pt(side, size.toDouble()), Pt(0.25, size.toDouble()))
        val options = PerspectiveOptions(outputWidth = size, outputHeight = size, snapToPaper = false)
        val result = PerspectiveCorrector.correct(stripes, quad, options)!!
        assertFalse(result.plan.supersampled)
        var dark = 255
        var light = 0
        for (x in 4 until size - 4) {
            val value = result.image.pixels[(size / 2 * size + x) * 4].toInt() and 0xFF
            assertEquals("column $x", if (x % 2 == 0) 40 else 215, value)
            dark = min(dark, value)
            light = max(light, value)
        }
        assertTrue(light - dark > 191 - 64)
    }

    @Test
    fun aQuadFarOutsideThePhotoGivesABoundedOutput() {
        fun square(a: Double, b: Double) = Quad(Pt(a, a), Pt(b, a), Pt(b, b), Pt(a, b))
        val unsnapped = PerspectiveOptions(snapToPaper = false)
        // A corner editor's quad a million pixels across on a 4000 x 3000 photo: the long side is cut
        // to twice the photo's diagonal (10000 px), and the output can be made.
        val plan = PerspectiveCorrector.plan(square(0.0, 1e6), 4000, 3000, unsnapped)!!
        assertEquals(10000, plan.width)
        assertEquals(10000, plan.height)
        assertTrue(plan.supersampled)
        // Even larger photos stop at MAX_OUTPUT_SIDE, whose RGBA bytes still fit in one array.
        val capped = PerspectiveCorrector.plan(square(0.0, 1e19), 100000, 100000, unsnapped)!!
        assertEquals(PerspectiveCorrector.MAX_OUTPUT_SIDE, capped.width)
        assertTrue(capped.width.toLong() * capped.height * 4 <= 0x7FFFFFC7L)
        // A size the caller gives beyond the limit, or a photo without pixels, has no plan.
        val forced = PerspectiveOptions(outputWidth = 50000, outputHeight = 50000)
        assertNull(PerspectiveCorrector.plan(square(10.0, 90.0), 100, 100, forced))
        assertNull(PerspectiveCorrector.plan(square(10.0, 90.0), 0, 0))
        // A small photo with a quad dragged outside it: the output stays near the photo's size.
        val dragged = Quad(Pt(-500.0, -400.0), Pt(600.0, -300.0), Pt(700.0, 900.0), Pt(-450.0, 800.0))
        val near = PerspectiveCorrector.plan(dragged, 100, 100, unsnapped)!!
        assertTrue("${near.width} x ${near.height}", max(near.width, near.height) <= 283)
    }

    @Test
    fun aNonConvexQuadIsRefused() {
        val bowtie = Quad(Pt(0.0, 0.0), Pt(10.0, 10.0), Pt(10.0, 0.0), Pt(0.0, 10.0))
        assertNull(PerspectiveCorrector.correct(RgbaImage.filled(20, 20, 0, 0, 0), bowtie))
        assertNotNull(PerspectiveCorrector.correct(RgbaImage.filled(20, 20, 0, 0, 0),
            Quad(Pt(0.0, 0.0), Pt(10.0, 0.0), Pt(10.0, 10.0), Pt(0.0, 10.0))))
    }
}

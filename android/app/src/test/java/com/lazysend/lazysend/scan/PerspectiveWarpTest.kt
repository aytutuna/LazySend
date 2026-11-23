package com.lazysend.lazysend.scan

import com.lazysend.lazysend.scan.TestPages.bytes
import com.lazysend.lazysend.scan.WarpFixtures.psnr
import com.lazysend.lazysend.scan.WarpFixtures.quad
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.atomic.AtomicIntegerArray

class PerspectiveWarpTest {
    private fun pixel(image: RgbaImage, x: Int, y: Int): ByteArray {
        val i = (y * image.width + x) * 4
        return image.pixels.copyOfRange(i, i + 4)
    }

    /** The dots of `dottedPage`: 7 x 7 black squares centered 24.5 px in from each corner. */
    private val dotCenters = listOf(Pt(24.5, 24.5), Pt(275.5, 24.5), Pt(275.5, 375.5), Pt(24.5, 375.5))

    /** A 300 x 400 page: soft color ramps, a checkerboard of 15 px squares in blue and the four dots. */
    private fun dottedPage(): RgbaImage {
        val w = 300
        val h = 400
        val p = ByteArray(w * h * 4)
        for (y in 0 until h) {
            for (x in 0 until w) {
                val i = (y * w + x) * 4
                p[i] = (230 - x * 60 / w).toByte()
                p[i + 1] = (220 - y * 80 / h).toByte()
                p[i + 2] = (120 + (x / 15 + y / 15) % 2 * 80).toByte()
                p[i + 3] = -1
            }
        }
        for (center in dotCenters) {
            val cx = center.x.toInt()
            val cy = center.y.toInt()
            for (y in cy - 3..cy + 3) {
                for (x in cx - 3..cx + 3) {
                    val i = (y * w + x) * 4
                    p[i] = 0
                    p[i + 1] = 0
                    p[i + 2] = 0
                }
            }
        }
        return RgbaImage(w, h, p)
    }

    /** The page's place in the 640 x 480 photo of the round trip. */
    private val photoQuad = quad(130.5, 60.25, 470.0, 95.5, 500.75, 430.0, 95.0, 400.5)

    /** The centroid of the pixels darker than 60 (by their darkness) within `radius` px of (cx, cy); null when there are none. */
    private fun darkCentroid(image: RgbaImage, cx: Double, cy: Double, radius: Int): Pt? {
        var sx = 0.0
        var sy = 0.0
        var sw = 0.0
        val x0 = maxOf(0, cx.toInt() - radius)
        val x1 = minOf(image.width - 1, cx.toInt() + radius)
        val y0 = maxOf(0, cy.toInt() - radius)
        val y1 = minOf(image.height - 1, cy.toInt() + radius)
        if (x0 > x1 || y0 > y1) return null
        for (y in y0..y1) {
            for (x in x0..x1) {
                val i = (y * image.width + x) * 4
                val luma = ((image.pixels[i].toInt() and 0xFF) * 299 + (image.pixels[i + 1].toInt() and 0xFF) * 587 +
                    (image.pixels[i + 2].toInt() and 0xFF) * 114) / 1000
                if (luma >= 60) continue
                val weight = (60 - luma).toDouble()
                sx += weight * (x + 0.5)
                sy += weight * (y + 0.5)
                sw += weight
            }
        }
        if (sw <= 0) return null
        return Pt(sx / sw, sy / sw)
    }

    @Test
    fun warpedBytesAreTheSameAsOnTheOtherPlatforms() {
        val supersampled = PerspectiveWarp.warp(WarpFixtures.photo(96, 72),
            quad(10.25, 6.5, 85.75, 12.0, 80.5, 66.25, 6.0, 60.75), 40, 30)!!
        assertEquals(0xA255D919L, PhotoScenes.checksum(supersampled))
        assertArrayEquals(bytes(209, 163, 155, 255), pixel(supersampled, 0, 0))
        assertArrayEquals(bytes(55, 130, 69, 255), pixel(supersampled, 7, 5))
        assertArrayEquals(bytes(227, 174, 62, 255), pixel(supersampled, 19, 13))

        val prefiltered = PerspectiveWarp.warp(WarpFixtures.photo(240, 180),
            quad(20.5, 15.25, 220.0, 30.75, 205.25, 170.5, 12.0, 150.0), 48, 36)!!
        assertEquals(0xB7EA788DL, PhotoScenes.checksum(prefiltered))
        assertArrayEquals(bytes(161, 131, 90, 255), pixel(prefiltered, 0, 0))
        assertArrayEquals(bytes(154, 162, 139, 255), pixel(prefiltered, 7, 5))
        assertArrayEquals(bytes(142, 201, 145, 255), pixel(prefiltered, 19, 13))

        val enlarged = PerspectiveWarp.warp(WarpFixtures.photo(32, 24),
            quad(-4.0, -3.0, 30.0, 1.0, 36.0, 26.0, 2.0, 22.0), 50, 40)!!
        assertEquals(0x685B8D2EL, PhotoScenes.checksum(enlarged))
        assertArrayEquals(bytes(255, 255, 255, 255), pixel(enlarged, 0, 0))
        assertArrayEquals(bytes(46, 32, 0, 255), pixel(enlarged, 7, 5))
        assertArrayEquals(bytes(223, 202, 148, 255), pixel(enlarged, 19, 13))
    }

    @Test
    fun thePrefilterStartsAboveTwiceSmallerAndTakesTheWholePart() {
        val quad = quad(20.5, 15.25, 220.0, 30.75, 205.25, 170.5, 12.0, 150.0)
        assertEquals(4, PerspectiveWarp.prefilterFactor(quad, 48, 36))
        assertEquals(1, PerspectiveWarp.prefilterFactor(quad, 120, 90))
        assertEquals(2, PerspectiveWarp.prefilterFactor(quad, 90, 60))
        assertEquals(1, PerspectiveWarp.prefilterFactor(quad, 400, 300))
        assertEquals(1, PerspectiveWarp.prefilterFactor(quad, 0, 36))
        // Exactly twice smaller is not more than twice.
        val square = quad(0.0, 0.0, 100.0, 0.0, 100.0, 100.0, 0.0, 100.0)
        assertEquals(1, PerspectiveWarp.prefilterFactor(square, 50, 50))
        assertEquals(2, PerspectiveWarp.prefilterFactor(square, 49, 49))
        assertEquals(3, PerspectiveWarp.prefilterFactor(square, 33, 50))
    }

    @Test
    fun boxReducedAveragesWholeAndEdgeBlocksRoundingHalfUp() {
        // 5 x 3, blocks of 2: a 3 x 2 result whose last column and row hold fewer pixels.
        val p = ByteArray(5 * 3 * 4)
        for (i in 0 until 15) {
            p[i * 4] = (i * 10).toByte()
            p[i * 4 + 1] = (i % 2).toByte()
            p[i * 4 + 2] = -1
            p[i * 4 + 3] = if (i == 0) 0 else -1
        }
        val reduced = PerspectiveWarp.boxReduced(RgbaImage(5, 3, p), 2)
        assertEquals(3, reduced.width)
        assertEquals(2, reduced.height)
        // Block (0, 0): pixels 0, 1, 5, 6 give R 30, G 0.5 to 1, A 191.25 to 191.
        assertArrayEquals(bytes(30, 1, 255, 191), pixel(reduced, 0, 0))
        assertArrayEquals(bytes(65, 1, 255, 255), pixel(reduced, 2, 0))
        assertArrayEquals(bytes(125, 1, 255, 255), pixel(reduced, 1, 1))
        assertArrayEquals(bytes(140, 0, 255, 255), pixel(reduced, 2, 1))
        val image = WarpFixtures.photo(7, 5)
        assertEquals(image, PerspectiveWarp.boxReduced(image, 1))
    }

    @Test
    fun withoutPrefilterTheWarpIsTheCorrectorsOwn() {
        val photo = WarpFixtures.photo(96, 72)
        val quad = quad(10.25, 6.5, 85.75, 12.0, 80.5, 66.25, 6.0, 60.75)
        val options = PerspectiveOptions(outputWidth = 40, outputHeight = 30, snapToPaper = false)
        val plan = PerspectiveCorrector.plan(quad, 96, 72, options)!!
        val warped = PerspectiveWarp.warp(photo, quad, 40, 30)!!
        assertArrayEquals(PerspectiveCorrector.warp(photo, plan, options).pixels, warped.pixels)
        val dark = PerspectiveOptions(fillR = 10, fillG = 20, fillB = 30)
        val filled = PerspectiveWarp.warp(WarpFixtures.photo(32, 24),
            quad(-4.0, -3.0, 30.0, 1.0, 36.0, 26.0, 2.0, 22.0), 50, 40, dark)!!
        assertArrayEquals(bytes(10, 20, 30, 255), pixel(filled, 0, 0))
    }

    @Test
    fun noWarpForAnOutlineThatIsNotConvexOrASizeOutOfRange() {
        val photo = WarpFixtures.photo(32, 24)
        assertNull(PerspectiveWarp.warp(photo, quad(0.0, 0.0, 30.0, 0.0, 10.0, 5.0, 0.0, 20.0), 10, 10))
        assertNull(PerspectiveWarp.warp(photo, quad(0.0, 20.0, 30.0, 20.0, 30.0, 0.0, 0.0, 0.0), 10, 10))
        assertNull(PerspectiveWarp.warp(photo, quad(0.0, 0.0, 30.0, 0.0, 30.0, 20.0, 0.0, 20.0), 0, 10))
        assertNull(PerspectiveWarp.warp(photo, quad(0.0, 0.0, 30.0, 0.0, 30.0, 20.0, 0.0, 20.0), 10,
            PerspectiveCorrector.MAX_OUTPUT_SIDE + 1))
    }

    @Test
    fun aPagePhotographedAndWarpedBackKeepsItsCornersAndLooks() {
        val page = dottedPage()
        val toPhoto = Homography.rectToQuad(300.0, 400.0, photoQuad)!!
        val back = toPhoto.inverse()!!
        // The photo: every photo pixel looks up the page through the inverse map (dark table around it).
        val photoCorners = Quad.fromCorners(listOf(back.map(Pt(0.0, 0.0)), back.map(Pt(640.0, 0.0)),
            back.map(Pt(640.0, 480.0)), back.map(Pt(0.0, 480.0))))
        assertTrue(photoCorners.isConvex)
        val table = PerspectiveOptions(fillR = 40, fillG = 40, fillB = 40)
        val photo = PerspectiveWarp.warp(page, photoCorners, 640, 480, table)!!

        // The page's corners land where the map says, within 1 px.
        for (center in dotCenters) {
            val expected = toPhoto.map(center)
            val found = darkCentroid(photo, expected.x, expected.y, 8)!!
            assertTrue("photo dot at $found, expected $expected", Quad.distance(found, expected) <= 1)
        }

        // Warped back along the page's corners, it is the page again.
        val recovered = PerspectiveWarp.warp(photo, photoQuad, 300, 400)!!
        val psnr = psnr(page, recovered, 3)
        assertTrue("PSNR $psnr dB", psnr >= 30)
        for (center in dotCenters) {
            val found = darkCentroid(recovered, center.x, center.y, 8)!!
            assertTrue("page dot at $found, expected $center", Quad.distance(found, center) <= 1)
        }
    }

    @Test
    fun aPageMadeMuchSmallerIsAveragedNotAliased() {
        // A fine 2 px checkerboard seen 4 times larger than the output: averaged it is an even gray.
        val w = 400
        val h = 300
        val p = ByteArray(w * h * 4)
        for (y in 0 until h) {
            for (x in 0 until w) {
                val i = (y * w + x) * 4
                val v = if ((x / 2 + y / 2) % 2 == 0) 30 else 230
                p[i] = v.toByte()
                p[i + 1] = v.toByte()
                p[i + 2] = v.toByte()
                p[i + 3] = -1
            }
        }
        val photo = RgbaImage(w, h, p)
        val quad = quad(10.0, 10.0, 390.0, 18.0, 385.0, 290.0, 14.0, 284.0)
        val warped = PerspectiveWarp.warp(photo, quad, 90, 66)!!
        assertEquals(4, PerspectiveWarp.prefilterFactor(quad, 90, 66))
        val options = PerspectiveOptions(outputWidth = 90, outputHeight = 66, snapToPaper = false)
        val plan = PerspectiveCorrector.plan(quad, w, h, options)!!
        val plain = PerspectiveCorrector.warp(photo, plan)
        val gray = RgbaImage.filled(90, 66, 130, 130, 130)
        val prefilteredPsnr = psnr(gray, warped, 2)
        val plainPsnr = psnr(gray, plain, 2)
        assertTrue("prefiltered PSNR $prefilteredPsnr dB", prefilteredPsnr >= 30)
        assertTrue("prefiltered $prefilteredPsnr dB, plain $plainPsnr dB", prefilteredPsnr > plainPsnr + 6)
    }

    @Test
    fun rowBandsCoverEveryRowOnce() {
        for (rows in listOf(0, 1, 2, 7, 64, 1000)) {
            val visits = AtomicIntegerArray(rows)
            forRowBands(rows) { start, end ->
                for (row in start until end) visits.incrementAndGet(row)
            }
            for (row in 0 until rows) assertEquals("$rows rows, row $row", 1, visits.get(row))
        }
    }
}

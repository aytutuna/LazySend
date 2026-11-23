package com.lazysend.lazysend.scan

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

class QuadRefinerTest {
    private val diagonal = sqrt((PhotoScenes.width * PhotoScenes.width + PhotoScenes.height * PhotoScenes.height).toDouble())

    private fun truth(map: PhotoScenes.IntHomography): Quad = map.corners(PhotoScenes.pageWidth, PhotoScenes.pageHeight)

    private fun quadOf(c: List<Pt>) = Quad(c[0], c[1], c[2], c[3])

    /** `quad` with every corner moved 1 % of the diagonal, each its own way (four patterns). */
    private fun off(quad: Quad, pattern: Int): Quad = quadOf(quad.corners.mapIndexed { i, p ->
        val angle = i * 1.7 + pattern * 2.3
        Pt(p.x + 0.01 * diagonal * cos(angle), p.y + 0.01 * diagonal * sin(angle))
    })

    /** `quad` with every corner moved 2 % of the diagonal away from its middle. */
    private fun grown(quad: Quad): Quad {
        val c = quad.centroid
        return quadOf(quad.corners.map { p ->
            val dx = p.x - c.x
            val dy = p.y - c.y
            val len = sqrt(dx * dx + dy * dy)
            Pt(p.x + 0.02 * diagonal * dx / len, p.y + 0.02 * diagonal * dy / len)
        })
    }

    /** An upright page (231 x 327 px) at (60, 50). */
    private val upright = PhotoScenes.IntHomography(1100000, 0, 60L * 1048576, 0, 1100000, 50L * 1048576, 0, 0, 1048576)

    /**
     * The upright page on a plain sheet of one color reaching 9 to 18 px beyond it on every side (within the
     * band, beyond its outward reach), on a dark desk.
     */
    private fun onASheet(r: Int, g: Int, b: Int): RgbaImage {
        val folder = PhotoScenes.IntHomography(1205862, 0, 48L * 1048576, 0, 1205862, 38L * 1048576, 0, 0, 1048576)
        val plain = ByteArray(PhotoScenes.pageWidth * PhotoScenes.pageHeight * 3)
        var i = 0
        while (i < plain.size) {
            plain[i] = r.toByte()
            plain[i + 1] = g.toByte()
            plain[i + 2] = b.toByte()
            i += 3
        }
        return PhotoScenes.scene(PhotoScenes.Backdrop.Dark, 0x3D00D010L, PhotoScenes.Lighting(0, 0, null, null), listOf(
            PhotoScenes.Sheet(plain, PhotoScenes.pageWidth, PhotoScenes.pageHeight, folder),
            PhotoScenes.Sheet(PhotoScenes.pageRaster(0x9A6E0010L), PhotoScenes.pageWidth, PhotoScenes.pageHeight, upright),
        ))
    }

    @Test
    fun anOutlineOffThePageIsMovedBackOntoItsEdges() {
        val scenes = listOf(
            Triple("wood", PhotoScenes.woodScene(), truth(PhotoScenes.woodMap)),
            Triple("dark", PhotoScenes.darkScene(), truth(PhotoScenes.darkMap)),
            Triple("light", PhotoScenes.lightScene(), truth(PhotoScenes.lightMap)),
            Triple("similar", PhotoScenes.similarScene(), truth(PhotoScenes.similarMap)),
            Triple("roundTrip", PhotoScenes.roundTripScene(), truth(PhotoScenes.roundTripMap)),
            Triple("bottomGap", PhotoScenes.bottomGapScene(8), truth(PhotoScenes.bottomGapMap(8))),
            Triple("rightGap", PhotoScenes.rightGapScene(4), truth(PhotoScenes.rightGapMap(4))),
        )
        for ((name, photo, page) in scenes) {
            // The page's own outline is backed by its edges all round; one 2 % too large is not. Inward the
            // whole band is searched, outward a third of it.
            assertTrue(name, QuadRefiner.supportOf(photo, page) >= 0.95)
            val large = grown(page)
            assertTrue(name, QuadRefiner.supportOf(photo, large) < 0.7)
            val starts = ArrayList<Quad>()
            // Not where growing it crosses the frame's edge (the pages near the frame's border).
            if (large.isInside(photo.width.toDouble(), photo.height.toDouble())) starts.add(large)
            for (pattern in 0 until 4) starts.add(off(page, pattern))
            for ((pattern, start) in starts.withIndex()) {
                val result = QuadRefiner.refine(photo, start)
                assertTrue("$name $pattern", result.refined)
                assertTrue("$name $pattern: refined to ${result.quad}", result.quad.maxCornerDistance(page) <= 0.003 * diagonal)
                assertTrue("$name $pattern", result.support >= 0.95)
            }
        }
    }

    @Test
    fun aHeaderBarJustInsideThePageDoesNotPullItsTopEdge() {
        // Moved straight down 1 %: the header bar's top edge lies nearer than the page's top edge.
        val photo = PhotoScenes.darkScene()
        val page = truth(PhotoScenes.darkMap)
        val start = page.copy(
            topLeft = Pt(page.topLeft.x, page.topLeft.y + 0.01 * diagonal),
            topRight = Pt(page.topRight.x, page.topRight.y + 0.01 * diagonal))
        val result = QuadRefiner.refine(photo, start)
        assertTrue("${result.quad}", result.quad.maxCornerDistance(page) <= 0.003 * diagonal)
    }

    @Test
    fun aPageAlreadyOnItsEdgesIsNotPushedOntoAFolderUnderIt() {
        val photo = onASheet(200, 170, 110)
        val page = truth(upright)
        val result = QuadRefiner.refine(photo, page)
        assertTrue("${result.quad}", result.quad.maxCornerDistance(page) <= 0.5)
        assertTrue(result.support >= 0.95)
    }

    @Test
    fun anEquallySharpEdgeJustOutsideDoesNotTakeTheSide() {
        // A gray card under the page: its edges are as sharp as the page's. An outline 2 px inside the page
        // moves onto the page's edges, not the card's.
        val photo = onASheet(128, 128, 128)
        val page = truth(upright)
        val inside = Quad(Pt(page.topLeft.x + 2, page.topLeft.y + 2), Pt(page.topRight.x - 2, page.topRight.y + 2),
            Pt(page.bottomRight.x - 2, page.bottomRight.y - 2), Pt(page.bottomLeft.x + 2, page.bottomLeft.y - 2))
        val result = QuadRefiner.refine(photo, inside)
        assertTrue(result.refined)
        assertTrue("${result.quad}", result.quad.maxCornerDistance(page) <= 1)
        assertTrue(result.support >= 0.95)
    }

    @Test
    fun aTableWithNoPageLeavesTheOutlineAlone() {
        val photo = PhotoScenes.plainScene()
        val start = off(truth(PhotoScenes.woodMap), 0)
        val result = QuadRefiner.refine(photo, start)
        assertFalse(result.refined)
        assertEquals(start, result.quad)
        assertTrue(result.support < 0.2)
    }

    @Test
    fun aLargePhotoIsSearchedSmallAndTheCornersComeBackInItsPixels() {
        // The wood scene three times as large (1080 x 1440): searched at 1000 px long, answered in its own pixels.
        val small = PhotoScenes.woodScene()
        val photo = small.resized(small.width * 3, small.height * 3)
        val page = truth(PhotoScenes.woodMap).scaled(3.0, 3.0)
        val result = QuadRefiner.refine(photo, off(page, 1))
        assertTrue(result.refined)
        assertTrue("${result.quad}", result.quad.maxCornerDistance(page) <= 0.003 * 3 * diagonal)
    }
}

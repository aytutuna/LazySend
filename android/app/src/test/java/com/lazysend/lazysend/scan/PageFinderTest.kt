package com.lazysend.lazysend.scan

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.sqrt

/** A corner model that answers with four spots on the corners it is given (shares of the photo). */
private class SpotModel(private val corners: List<Pt>, private val peak: Double) : CornerModel {
    override fun heatmaps(input: FloatArray): CornerHeatmaps {
        val heat = DrawnHeatmap(SIZE)
        corners.forEachIndexed { channel, corner -> heat.spot(channel, corner.x * SIZE, corner.y * SIZE, peak) }
        return CornerHeatmaps(heat.values, SIZE, SIZE)
    }

    companion object {
        const val SIZE = 64
    }
}

class PageFinderTest {
    private val truth = PhotoScenes.woodMap.corners(PhotoScenes.pageWidth, PhotoScenes.pageHeight)

    private fun shares(quad: Quad) =
        quad.corners.map { Pt(it.x / PhotoScenes.width, it.y / PhotoScenes.height) }

    @Test
    fun aPageTheModelIsSureOfIsMovedOntoThePhotosEdges() {
        val photo = PhotoScenes.woodScene()
        val found = PageFinder.find(photo, SpotModel(shares(truth), 0.9))
        val diagonal = sqrt((PhotoScenes.width * PhotoScenes.width + PhotoScenes.height * PhotoScenes.height).toDouble())
        val named = Quad.fromCorners(found.corners.corners)
        for (corner in 0 until 4) {
            val dx = named[corner].x - truth[corner].x
            val dy = named[corner].y - truth[corner].y
            assertTrue("corner $corner", sqrt(dx * dx + dy * dy) / diagonal < 0.02)
        }
        assertTrue(PageFinder.canUseCorners(found.corners))
    }

    @Test
    fun withoutAModelOrANoticedPageTheEditorStartsFromAnInsetRectangle() {
        val photo = PhotoScenes.woodScene()
        val start = PageFinder.startCorners(photo.width, photo.height)
        assertEquals(PageFound(start, false), PageFinder.find(photo, null))
        assertEquals(PageFound(start, false), PageFinder.find(photo, CornerModel { null }))
        assertEquals(PageFound(start, false), PageFinder.find(photo, SpotModel(shares(truth), 0.4)))
        assertEquals(Pt(36.0, 48.0), start.topLeft)
        assertEquals(Pt(324.0, 432.0), start.bottomRight)
    }

    @Test
    fun aLivePageIsAcceptedOnlyWhenSureLargeAndShapedLikeAPage() {
        val page = Quad(Pt(80.0, 40.0), Pt(240.0, 40.0), Pt(240.0, 200.0), Pt(80.0, 200.0))
        assertEquals(page, PageFinder.accepted(QuadCandidate(page, 0.9), 320, 240))
        assertNull(PageFinder.accepted(QuadCandidate(page, 0.4), 320, 240))
        val sliver = Quad(Pt(10.0, 20.0), Pt(300.0, 20.0), Pt(300.0, 30.0), Pt(10.0, 30.0))
        assertNull(PageFinder.accepted(QuadCandidate(sliver, 0.9), 320, 240))
        val small = Quad(Pt(100.0, 80.0), Pt(150.0, 80.0), Pt(150.0, 130.0), Pt(100.0, 130.0))
        assertNull(PageFinder.accepted(QuadCandidate(small, 0.9), 320, 240))
        // A bow tie is no page.
        val twisted = Quad(Pt(80.0, 40.0), Pt(240.0, 200.0), Pt(240.0, 40.0), Pt(80.0, 200.0))
        assertNull(PageFinder.accepted(QuadCandidate(twisted, 0.9), 320, 240))
    }

    @Test
    fun aCornerMovedOutsideThePhotoStaysInsideAndOneThatBreaksThePageStays() {
        val start = PageFinder.startCorners(400, 300)
        val pulled = PageFinder.movedCorner(start, 0, Pt(-50.0, -20.0), 400, 300)
        assertEquals(Pt(0.0, 0.0), pulled.topLeft)
        assertEquals(start.topRight, pulled.topRight)
        // Dragged across the opposite corner: the outline would fold, so the corner stays.
        assertEquals(start, PageFinder.movedCorner(start, 0, Pt(380.0, 280.0), 400, 300))
        // Dragged onto its neighbour: an edge under the least length, so it stays.
        assertEquals(start, PageFinder.movedCorner(start, 0, Pt(355.0, 31.0), 400, 300))
    }

    @Test
    fun outlinesOutsideThePhotoAreClampedAndTheWholePhotoIsItsFourCorners() {
        val outside = Quad(Pt(-20.0, -10.0), Pt(420.0, -10.0), Pt(420.0, 320.0), Pt(-20.0, 320.0))
        assertEquals(PageFinder.wholePhoto(400, 300), PageFinder.clamped(outside, 400, 300))
        val point = Pt(10.0, 10.0)
        val line = Quad(point, point, point, point)
        assertEquals(PageFinder.startCorners(400, 300), PageFinder.clamped(line, 400, 300))
        assertFalse(PageFinder.canUseCorners(line))
    }

    @Test
    fun theFrameCandidateIsTurnedBackOntoTheSensorsPixels() {
        // The model sees the upright frame; the page it finds is returned in the frame as the sensor gave it.
        val frame = RgbaImage.filled(64, 48, 120, 120, 120)
        // In the frame turned a quarter (48 x 64) the page spans x 0.2..0.8, y 0.1..0.9.
        val upright = listOf(Pt(0.2, 0.1), Pt(0.8, 0.1), Pt(0.8, 0.9), Pt(0.2, 0.9))
        val candidate = PageFinder.frameCandidate(frame, 90, SpotModel(upright, 0.9))
        assertNotNull(candidate)
        val sensor = candidate!!.quad
        // A quarter back: x' = y, y' = 1 - x, as shares, then scaled to the 64 x 48 frame.
        assertEquals(0.1 * 64, sensor.topLeft.x, 2.0)
        assertEquals(0.2 * 48, sensor.topLeft.y, 2.0)
        assertEquals(0.9 * 64, sensor.bottomRight.x, 2.0)
        assertEquals(0.8 * 48, sensor.bottomRight.y, 2.0)
        assertEquals(0.9, candidate.confidence, 0.05)
    }
}

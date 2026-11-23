package com.lazysend.lazysend.scan

import com.lazysend.lazysend.scan.WarpFixtures.cameraView
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HomographyTest {
    private val tilted = Quad(Pt(105.0, 90.0), Pt(258.0, 86.0), Pt(310.0, 418.0), Pt(48.0, 414.0))

    private fun assertNear(expected: Pt, actual: Pt, tolerance: Double) {
        assertTrue("expected $expected, got $actual", Quad.distance(expected, actual) <= tolerance)
    }

    @Test
    fun squareToQuadMapsTheUnitSquareOntoTheCorners() {
        val m = Homography.squareToQuad(tilted)!!
        assertNear(tilted.topLeft, m.map(Pt(0.0, 0.0)), 1e-9)
        assertNear(tilted.topRight, m.map(Pt(1.0, 0.0)), 1e-9)
        assertNear(tilted.bottomRight, m.map(Pt(1.0, 1.0)), 1e-9)
        assertNear(tilted.bottomLeft, m.map(Pt(0.0, 1.0)), 1e-9)
    }

    @Test
    fun rectToQuadAndQuadToRectUndoEachOther() {
        val forward = Homography.rectToQuad(210.0, 297.0, tilted)!!
        val back = Homography.quadToRect(tilted, 210.0, 297.0)!!
        assertNear(tilted.bottomRight, forward.map(Pt(210.0, 297.0)), 1e-9)
        val rng = TestPages.Rng(0x40A0A001L)
        repeat(50) {
            val p = Pt(rng.below(2100) / 10.0, rng.below(2970) / 10.0)
            assertNear(p, back.map(forward.map(p)), 1e-9)
        }
    }

    @Test
    fun solvingTheEquationsGivesTheClosedForm() {
        val closed = Homography.rectToQuad(210.0, 297.0, tilted)!!
        val solved = Homography.fromCorrespondences(
            listOf(Pt(0.0, 0.0), Pt(210.0, 0.0), Pt(210.0, 297.0), Pt(0.0, 297.0)), tilted.corners)!!
        val rng = TestPages.Rng(0x40A0A002L)
        repeat(50) {
            val p = Pt(rng.below(2100) / 10.0, rng.below(2970) / 10.0)
            assertNear(closed.map(p), solved.map(p), 1e-7)
        }
    }

    @Test
    fun inverseAndProductCompose() {
        val a = Homography.rectToQuad(100.0, 100.0, tilted)!!
        val b = Homography(1.5, 0.2, 10.0, -0.1, 0.9, 5.0, 0.0004, -0.0002, 1.0)
        val ab = Homography.multiply(a, b)
        val inverse = ab.inverse()!!
        val p = Pt(37.5, 61.25)
        assertNear(a.map(b.map(p)), ab.map(p), 1e-9)
        assertNear(p, inverse.map(ab.map(p)), 1e-9)
        assertNear(p, Homography.multiply(ab, inverse).map(p), 1e-9)
        assertNear(p, Homography.identity.map(p), 0.0)
    }

    @Test
    fun threeCornersInLineHaveNoMap() {
        val flat = Quad(Pt(0.0, 0.0), Pt(10.0, 0.0), Pt(20.0, 0.0), Pt(5.0, 10.0))
        assertNull(Homography.fromCorrespondences(flat.corners, tilted.corners))
        assertNull(Homography(1.0, 2.0, 3.0, 2.0, 4.0, 6.0, 0.0, 0.0, 1.0).inverse())
        assertNull(Homography.rectToQuad(0.0, 10.0, tilted))
    }

    @Test
    fun cornersAreNamedClockwiseFromTheTopLeft() {
        // Counterclockwise, starting at the bottom-right corner.
        val q = Quad.fromCorners(listOf(tilted.bottomRight, tilted.topRight, tilted.topLeft, tilted.bottomLeft))
        assertEquals(tilted, q)
        assertTrue(q.isConvex)
        assertTrue(q.signedArea > 0)
        // A diamond: the top edge is the higher of the two upper edges, the left one on a tie.
        val diamond = Quad.fromCorners(listOf(Pt(50.0, 0.0), Pt(100.0, 50.0), Pt(50.0, 100.0), Pt(0.0, 50.0)))
        assertEquals(Pt(0.0, 50.0), diamond.topLeft)
        assertEquals(Pt(50.0, 0.0), diamond.topRight)
    }

    @Test
    fun quadMeasures() {
        val square = Quad(Pt(0.0, 0.0), Pt(10.0, 0.0), Pt(10.0, 10.0), Pt(0.0, 10.0))
        assertEquals(100.0, square.area, 0.0)
        assertEquals(Pt(5.0, 5.0), square.centroid)
        assertTrue(square.contains(Pt(5.0, 5.0)))
        assertFalse(square.contains(Pt(11.0, 5.0)))
        assertTrue(square.contains(Pt(11.0, 5.0), 1.5))
        assertTrue(square.isInside(10.0, 10.0))
        assertFalse(square.isInside(9.0, 10.0))
        val bowtie = Quad(Pt(0.0, 0.0), Pt(10.0, 10.0), Pt(10.0, 0.0), Pt(0.0, 10.0))
        assertFalse(bowtie.isConvex)
        assertEquals(5.0, square.maxCornerDistance(square.scaled(1.5, 1.0)), 1e-9)
    }

    @Test
    fun theShapeOfTheSheetIsRecoveredFromATiltedView() {
        // An A4 sheet tilted 30 and 15 degrees, turned 10, by a camera with a 900 px focal length.
        val view = cameraView(210.0, 297.0, 30.0, 15.0, 10.0, 520.0, 900.0, 1200.0, 1600.0)
        val estimate = PerspectiveCorrector.estimateAspect(view, 1200.0, 1600.0)
        val focal = estimate.focalLength
        assertNotNull(focal)
        assertTrue("focal $focal", focal!! in 891.0..909.0)
        assertTrue("${estimate.longOverShort}", estimate.longOverShort in 1.414 * 0.995..1.414 * 1.005)
        assertEquals(PaperSize.A4, PerspectiveCorrector.matchPaper(estimate.longOverShort)?.size)

        // An ID card tilted 35 degrees.
        val card = cameraView(85.6, 53.98, 35.0, 0.0, 5.0, 160.0, 1000.0, 1500.0, 2000.0)
        val cardEstimate = PerspectiveCorrector.estimateAspect(card, 1500.0, 2000.0)
        assertTrue("${cardEstimate.longOverShort}", cardEstimate.longOverShort in 1.586 * 0.99..1.586 * 1.01)
    }

    @Test
    fun aSheetSeenStraightOnTakesItsEdgeLengths() {
        val straight = Quad(Pt(100.0, 100.0), Pt(400.0, 100.0), Pt(400.0, 300.0), Pt(100.0, 300.0))
        val estimate = PerspectiveCorrector.estimateAspect(straight, 800.0, 600.0)
        assertNull(estimate.focalLength)
        assertEquals(1.5, estimate.widthOverHeight, 1e-9)
    }

    @Test
    fun paperSizesMatchWithinThreePercent() {
        assertEquals(PaperSize.A4, PerspectiveCorrector.matchPaper(1.40)?.size)
        assertEquals(PaperSize.Letter, PerspectiveCorrector.matchPaper(1.30)?.size)
        assertEquals(PaperSize.Legal, PerspectiveCorrector.matchPaper(1.64)?.size)
        assertNull(PerspectiveCorrector.matchPaper(1.59))
        assertNull(PerspectiveCorrector.matchPaper(1.50))
        assertNull(PerspectiveCorrector.matchPaper(2.5))
        assertNull(PerspectiveCorrector.matchPaper(1.0))
    }
}

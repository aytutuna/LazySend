package com.lazysend.lazysend.ui

import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ZoomControlTest {
    private val wide = 0.5f..10f

    @Test
    fun aTelephotoLensGetsItsOwnButtonBeyondTwice() {
        assertEquals(listOf(0.5f, 1f, 2f, 5f), lensStops(0.5f, 20f, 5f))
        assertEquals(listOf(1f, 2f, 3f), lensStops(1f, 10f, 3f))
        assertEquals(listOf(1f, 2f), lensStops(1f, 10f, 2f))
        assertEquals(listOf(1f), lensStops(1f, 1.5f, 5f))
    }

    @Test
    fun theTelephotoIsTheLongestLensOverTheMainOneToTheNearestHalf() {
        assertEquals(5f, telephotoRatio(24f, listOf(13f, 24f, 119f))!!, 0.001f)
        assertEquals(3f, telephotoRatio(24f, listOf(13f, 24f, 71f))!!, 0.001f)
        assertNull(telephotoRatio(24f, listOf(13f, 24f)))
        assertNull(telephotoRatio(24f, emptyList()))
    }

    @Test
    fun theWheelEndsAtTheCameraTopTenTimesOrFiveTimesTheLongestLens() {
        assertEquals(0.5f..10f, dialRange(listOf(0.5f, 1f, 5f), 30f))
        assertEquals(1f..10f, dialRange(listOf(1f, 2f), 30f))
        assertEquals(1f..3f, dialRange(listOf(1f), 3f))
        assertEquals(1f..5f, dialRange(listOf(1f), 30f))
    }

    @Test
    fun equalDragsDoubleTheZoomSoHalfToOneTravelsAsFarAsOneToTwo() {
        assertEquals(1f, zoomAfterDrag(0.5f, -POINTS_PER_DOUBLING, POINTS_PER_DOUBLING, wide), 0.0001f)
        assertEquals(2f, zoomAfterDrag(1f, -POINTS_PER_DOUBLING, POINTS_PER_DOUBLING, wide), 0.0001f)
        assertEquals(1f, zoomAfterDrag(2f, POINTS_PER_DOUBLING, POINTS_PER_DOUBLING, wide), 0.0001f)
    }

    @Test
    fun theDragStopsAtTheEndsOfTheWheel() {
        assertEquals(0.5f, zoomAfterDrag(1f, 1000f, POINTS_PER_DOUBLING, wide), 0f)
        assertEquals(10f, zoomAfterDrag(1f, -1000f, POINTS_PER_DOUBLING, wide), 0f)
    }

    @Test
    fun theOffsetOnTheWheelIsTheInverseOfTheDrag() {
        assertEquals(POINTS_PER_DOUBLING, wheelOffset(2f, 1f, POINTS_PER_DOUBLING), 0.001f)
        assertEquals(-POINTS_PER_DOUBLING, wheelOffset(0.5f, 1f, POINTS_PER_DOUBLING), 0.001f)
        assertEquals(0f, wheelOffset(1.4f, 1.4f, POINTS_PER_DOUBLING), 0f)
    }

    @Test
    fun aStopIsCrossedInEitherDirectionAndAlsoReached() {
        val stops = listOf(0.5f, 1f, 2f)
        assertTrue(crossesStop(0.9f, 1.1f, stops))
        assertTrue(crossesStop(2.1f, 1.9f, stops))
        assertTrue(crossesStop(1.5f, 2f, stops))
        assertFalse(crossesStop(1.2f, 1.8f, stops))
        assertFalse(crossesStop(1f, 1.2f, stops))
    }

    @Test
    fun accessibilityStepsFromStopToStop() {
        val stops = listOf(0.5f, 1f, 2f, 5f)
        assertEquals(2f, stepStop(1f, stops, true))
        assertEquals(2f, stepStop(1.4f, stops, true))
        assertEquals(1f, stepStop(1.4f, stops, false))
        assertNull(stepStop(5f, stops, true))
        assertNull(stepStop(0.5f, stops, false))
    }

    @Test
    fun theActiveLabelHasTheTimesSignAndOneDecimalBetweenStops() {
        Locale.setDefault(Locale.US)
        assertEquals("1×", zoomLabel(1f))
        assertEquals("1.4×", zoomLabel(1.4f))
        assertEquals("0.5×", zoomLabel(0.5f))
    }

    @Test
    fun anInactiveLabelIsTheBareNumberWithoutALeadingZero() {
        Locale.setDefault(Locale.US)
        assertEquals(".5", stopLabel(0.5f))
        assertEquals("2", stopLabel(2f))
        assertEquals("5", stopLabel(5f))
        Locale.setDefault(Locale.forLanguageTag("tr-TR"))
        assertEquals(",5", stopLabel(0.5f))
        Locale.setDefault(Locale.US)
    }

    @Test
    fun theWheelHasMarksEveryTenthThenHalvesThenWholesAndEveryStop() {
        val marks = wheelTicks(0.5f..10f, listOf(0.5f, 1f, 2f, 3f))
        assertEquals(0.5f, marks.first(), 0f)
        assertEquals(10f, marks.last(), 0f)
        assertTrue(marks.any { Math.abs(it - 1.3f) < 0.001f })
        assertTrue(marks.any { Math.abs(it - 2.5f) < 0.001f })
        assertFalse(marks.any { Math.abs(it - 2.3f) < 0.001f })
        assertEquals(marks, marks.sorted())
        assertEquals(1, marks.count { Math.abs(it - 3f) < 0.001f })
    }
}

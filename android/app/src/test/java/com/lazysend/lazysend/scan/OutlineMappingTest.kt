package com.lazysend.lazysend.scan

import org.junit.Assert.assertEquals
import org.junit.Test

class OutlineMappingTest {
    // A sensor frame of 400 x 300 and a page in it, as shares of the frame.
    private val outline = Quad(Pt(0.1, 0.2), Pt(0.5, 0.2), Pt(0.5, 0.6), Pt(0.1, 0.6))
    private val frameWidth = 400
    private val frameHeight = 300

    private fun assertPoints(expected: List<Pt>, actual: List<Pt>) {
        assertEquals(expected.size, actual.size)
        for (i in expected.indices) {
            assertEquals("x of $i", expected[i].x, actual[i].x, 1e-6)
            assertEquals("y of $i", expected[i].y, actual[i].y, 1e-6)
        }
    }

    /** The corner as a pixel of the sensor frame turned clockwise by [degrees], worked out on pixels and not on shares. */
    private fun turned(corner: Pt, degrees: Int): Pt {
        val x = corner.x * frameWidth
        val y = corner.y * frameHeight
        return when (degrees) {
            90 -> Pt(frameHeight - y, x)
            180 -> Pt(frameWidth - x, frameHeight - y)
            270 -> Pt(y, frameWidth - x)
            else -> Pt(x, y)
        }
    }

    private fun expected(degrees: Int, viewWidth: Double, viewHeight: Double, scale: PreviewScale): List<Pt> {
        val sideways = degrees % 180 == 90
        val width = (if (sideways) frameHeight else frameWidth).toDouble()
        val height = (if (sideways) frameWidth else frameHeight).toDouble()
        val factor = when (scale) {
            PreviewScale.Fill -> maxOf(viewWidth / width, viewHeight / height)
            PreviewScale.Fit -> minOf(viewWidth / width, viewHeight / height)
        }
        return outline.corners.map { corner ->
            val p = turned(corner, degrees)
            Pt((viewWidth - width * factor) / 2 + p.x * factor, (viewHeight - height * factor) / 2 + p.y * factor)
        }
    }

    @Test
    fun everyTurnAndScaleSitsWhereTheTurnedPixelsAre() {
        for (degrees in listOf(0, 90, 180, 270)) {
            for (scale in PreviewScale.values()) {
                for ((viewWidth, viewHeight) in listOf(600.0 to 400.0, 360.0 to 800.0, 500.0 to 500.0)) {
                    val got = OutlineMapping.toView(outline, degrees, frameWidth, frameHeight, viewWidth, viewHeight, scale)
                    assertPoints(expected(degrees, viewWidth, viewHeight, scale), got)
                }
            }
        }
    }

    @Test
    fun aFrameTurnedAQuarterIsLetterboxedWithFitAndCroppedWithFill() {
        val whole = Quad(Pt(0.0, 0.0), Pt(1.0, 0.0), Pt(1.0, 1.0), Pt(0.0, 1.0))
        // 400 x 300 turned a quarter is 300 x 400; in 600 x 400 it is 300 wide between two bars with Fit...
        val fit = OutlineMapping.toView(whole, 90, 400, 300, 600.0, 400.0, PreviewScale.Fit)
        assertPoints(listOf(Pt(450.0, 0.0), Pt(450.0, 400.0), Pt(150.0, 400.0), Pt(150.0, 0.0)), fit)
        // ...and 600 wide and 800 tall, the top and bottom cut off, with Fill.
        val fill = OutlineMapping.toView(whole, 90, 400, 300, 600.0, 400.0, PreviewScale.Fill)
        assertPoints(listOf(Pt(600.0, -200.0), Pt(600.0, 600.0), Pt(0.0, 600.0), Pt(0.0, -200.0)), fill)
    }

    @Test
    fun anUprightFrameOfTheViewsShapeIsOnlyScaled() {
        val got = OutlineMapping.toView(outline, 0, 400, 300, 800.0, 600.0, PreviewScale.Fill)
        assertPoints(listOf(Pt(80.0, 120.0), Pt(400.0, 120.0), Pt(400.0, 360.0), Pt(80.0, 360.0)), got)
    }

    @Test
    fun aTurnPastAFullCircleOrANegativeOneIsTheSameTurn() {
        val a = OutlineMapping.toView(outline, 90, frameWidth, frameHeight, 600.0, 400.0, PreviewScale.Fit)
        assertPoints(a, OutlineMapping.toView(outline, 450, frameWidth, frameHeight, 600.0, 400.0, PreviewScale.Fit))
        assertPoints(a, OutlineMapping.toView(outline, -270, frameWidth, frameHeight, 600.0, 400.0, PreviewScale.Fit))
    }
}

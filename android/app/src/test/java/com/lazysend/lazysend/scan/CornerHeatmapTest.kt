package com.lazysend.lazysend.scan

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min

/** Four channels of `size` x `size` values, all 0 until spots are added. */
class DrawnHeatmap(val size: Int) {
    val values = FloatArray(size * size * 4)

    /** A Gaussian spot of `peak` and `sigma` (in values) centred on (`x`, `y`), in the values' own units, added to `channel`. */
    fun spot(channel: Int, x: Double, y: Double, peak: Double = 0.9, sigma: Double = 2.0) {
        for (row in 0 until size) {
            for (column in 0 until size) {
                val dx = column + 0.5 - x
                val dy = row + 0.5 - y
                val value = peak * exp(-(dx * dx + dy * dy) / (2 * sigma * sigma))
                val index = channel * size * size + row * size + column
                values[index] = max(values[index], value.toFloat())
            }
        }
    }

    /** The highest value drawn in `channel`. */
    fun peak(channel: Int): Double {
        var best = 0f
        for (i in channel * size * size until (channel + 1) * size * size) best = max(best, values[i])
        return best.toDouble()
    }

    val weakestPeak: Double get() = min(min(peak(0), peak(1)), min(peak(2), peak(3)))
}

class CornerHeatmapTest {
    private val size = 64

    /** A page a little turned, its corners in the values' units. */
    private val page = listOf(Pt(12.0, 10.0), Pt(50.0, 14.0), Pt(48.0, 56.0), Pt(9.0, 52.0))

    private fun drawnPage(peaks: List<Double> = listOf(0.9, 0.9, 0.9, 0.9)): DrawnHeatmap {
        val heat = DrawnHeatmap(size)
        for (channel in 0 until 4) heat.spot(channel, page[channel].x, page[channel].y, peaks[channel])
        return heat
    }

    private fun decode(heat: DrawnHeatmap): QuadCandidate? = CornerHeatmap.decode(heat.values, size, size)

    @Test
    fun fourSpotsGiveTheCornersInOrderAsSharesOfTheImage() {
        val heat = drawnPage()
        val found = decode(heat)!!
        found.quad.corners.forEachIndexed { index, corner ->
            assertEquals("corner $index", page[index].x, corner.x * size, 0.01)
            assertEquals("corner $index", page[index].y, corner.y * size, 0.01)
        }
        assertEquals(heat.weakestPeak, found.confidence, 1e-6)
    }

    @Test
    fun theConfidenceIsTheWeakestChannelsPeak() {
        val heat = drawnPage(listOf(0.95, 0.6, 0.8, 0.9))
        assertEquals(heat.peak(1), decode(heat)!!.confidence, 1e-6)
    }

    @Test
    fun theLargestBlobWinsOverASmallerBrighterOne() {
        val heat = drawnPage()
        // A small bright spot far from the top-left corner's wide one.
        heat.spot(0, 40.5, 40.5, peak = 1.0, sigma = 0.8)
        val found = decode(heat)!!
        assertEquals(12.0, found.quad.topLeft.x * size, 0.01)
        assertEquals(10.0, found.quad.topLeft.y * size, 0.01)
        assertEquals(heat.weakestPeak, found.confidence, 1e-6)
    }

    @Test
    fun anEmptyChannelGivesNothing() {
        val heat = DrawnHeatmap(size)
        heat.spot(0, 12.0, 10.0)
        heat.spot(1, 50.0, 14.0)
        heat.spot(3, 9.0, 52.0)
        assertNull(decode(heat))
        // A channel whose values all stay under the threshold is as empty.
        heat.spot(2, 48.0, 56.0, peak = 0.25)
        assertNull(decode(heat))
    }

    @Test
    fun cornersOutOfOrderGiveNothing() {
        val heat = DrawnHeatmap(size)
        heat.spot(0, 12.0, 10.0)
        heat.spot(1, 48.0, 56.0)
        heat.spot(2, 50.0, 14.0)
        heat.spot(3, 9.0, 52.0)
        assertNull(decode(heat))
    }

    @Test
    fun aSpotBetweenValuesIsFoundToAFractionOfAValue() {
        val heat = DrawnHeatmap(size)
        heat.spot(0, 20.25, 10.75)
        heat.spot(1, 50.6, 14.3)
        heat.spot(2, 48.0, 56.0)
        heat.spot(3, 9.0, 52.0)
        val found = decode(heat)!!
        assertEquals(20.25, found.quad.topLeft.x * size, 0.1)
        assertEquals(10.75, found.quad.topLeft.y * size, 0.1)
        assertEquals(50.6, found.quad.topRight.x * size, 0.1)
        assertEquals(14.3, found.quad.topRight.y * size, 0.1)
    }

    @Test
    fun aNonSquareHeatmapIsReadAsSharesOfEachSide() {
        val width = 32
        val height = 16
        val values = FloatArray(width * height * 4)
        val spots = listOf(4 to 3, 27 to 3, 27 to 12, 4 to 12)
        for (channel in 0 until 4) values[channel * width * height + spots[channel].second * width + spots[channel].first] = 0.8f
        val found = CornerHeatmap.decode(values, width, height)
        assertNotNull(found)
        assertEquals(4.5 / 32, found!!.quad.topLeft.x, 1e-9)
        assertEquals(3.5 / 16, found.quad.topLeft.y, 1e-9)
        assertEquals(27.5 / 32, found.quad.bottomRight.x, 1e-9)
        assertEquals(12.5 / 16, found.quad.bottomRight.y, 1e-9)
        assertNull(CornerHeatmap.decode(values.copyOf(10), width, height))
    }
}

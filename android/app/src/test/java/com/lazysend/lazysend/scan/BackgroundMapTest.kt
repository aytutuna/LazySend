package com.lazysend.lazysend.scan

import com.lazysend.lazysend.scan.TestPages.bytes
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class BackgroundMapTest {
    private fun estimate(gray: GrayImage, x: Int, y: Int, width: Int, height: Int, tileSize: Int): BackgroundMap =
        BackgroundMap.estimate(gray, x, y, width, height, tileSize)!!

    @Test
    fun percentileIsTheSmallestValueWithEnoughBelowIt() {
        val histogram = IntArray(256)
        for (v in 0 until 10) histogram[v] = 1
        assertEquals(8, BackgroundMap.percentile(histogram, 10, 0.9))
        assertEquals(4, BackgroundMap.percentile(histogram, 10, 0.5))
        assertEquals(9, BackgroundMap.percentile(histogram, 10, 1.0))
        assertEquals(0, BackgroundMap.percentile(histogram, 10, 0.0))
    }

    /** 100 x 50: left half 200, right half 100. */
    private fun halves(withSpecks: Boolean): GrayImage {
        val pixels = ByteArray(100 * 50)
        for (y in 0 until 50) {
            for (x in 0 until 100) pixels[y * 100 + x] = (if (x < 50) 200 else 100).toByte()
        }
        if (withSpecks) {
            pixels[10 * 100 + 10] = 0
            pixels[10 * 100 + 60] = 0
        }
        return GrayImage(100, 50, pixels)
    }

    @Test
    fun estimateTilesTheAreaWithWholeTiles() {
        val gray = halves(true)
        val map = estimate(gray, 0, 0, 100, 50, 50)
        assertEquals(2, map.columns)
        assertEquals(1, map.rows)
        assertArrayEquals(bytes(200, 100), map.tiles)
        // Tiles of 30 over 100 x 50: three of 33-34 across, one down.
        val odd = estimate(gray, 0, 0, 100, 50, 30)
        assertEquals(3, odd.columns)
        assertEquals(1, odd.rows)
        assertArrayEquals(bytes(200, 200, 100), odd.tiles)
        // The area is clamped to the image; an empty one has no map.
        val clamped = estimate(gray, 50, -5, 80, 80, 25)
        assertEquals(listOf(50, 0, 50, 50, 2, 2),
            listOf(clamped.x, clamped.y, clamped.width, clamped.height, clamped.columns, clamped.rows))
        assertNull(BackgroundMap.estimate(gray, 100, 0, 10, 10, 5))
    }

    @Test
    fun valueAtInterpolatesBetweenTileCenters() {
        val map = estimate(halves(false), 0, 0, 100, 50, 50)
        assertEquals(200.0, map.valueAt(0, 0), 0.0)
        assertEquals(200.0, map.valueAt(24, 49), 0.0)
        assertEquals(199.0, map.valueAt(25, 0), 1e-9) // center 25.5 is 0.5 px past the first tile's center (25)
        assertEquals(151.0, map.valueAt(49, 0), 1e-9)
        assertEquals(149.0, map.valueAt(50, 0), 1e-9)
        assertEquals(100.0, map.valueAt(75, 0), 0.0)
        assertEquals(100.0, map.valueAt(99, 49), 0.0)
        assertEquals(100.0, map.valueAt(500, 500), 0.0) // outside: the nearest edge of the area
    }

    @Test
    fun maxSmoothedTakesTheBrightestNeighborClampedBelowRaisesTheFloor() {
        // 3 x 3 tiles of 10 px with values 10, 20, ... 90 row by row.
        val pixels = ByteArray(30 * 30)
        for (y in 0 until 30) {
            for (x in 0 until 30) pixels[y * 30 + x] = (10 * (1 + (y / 10) * 3 + x / 10)).toByte()
        }
        val map = estimate(GrayImage(30, 30, pixels), 0, 0, 30, 30, 10)
        assertArrayEquals(bytes(10, 20, 30, 40, 50, 60, 70, 80, 90), map.tiles)
        assertEquals(50, map.medianTile())
        assertArrayEquals(bytes(50, 60, 60, 80, 90, 90, 80, 90, 90), map.maxSmoothed().tiles)
        assertArrayEquals(bytes(10, 10, 20, 10, 10, 20, 40, 40, 50), map.minSmoothed().tiles)
        assertArrayEquals(bytes(45, 45, 45, 45, 50, 60, 70, 80, 90), map.clampedBelow(45).tiles)
        assertArrayEquals(bytes(10, 20, 30, 40, 50, 60, 70, 80, 90), map.tiles) // unchanged
    }

    @Test
    fun inkMaskMarksPixelsClearlyDarkerThanThePaper() {
        // Paper 200: 141 is 70.5 % of it (not ink), 139 is 69.5 % (ink).
        val pixels = ByteArray(40 * 40)
        pixels.fill(200.toByte())
        pixels[5 * 40 + 5] = 141.toByte()
        pixels[5 * 40 + 6] = 139.toByte()
        pixels[30 * 40 + 30] = 0
        val gray = GrayImage(40, 40, pixels)
        val map = estimate(gray, 0, 0, 40, 40, 20)
        val mask = map.inkMask(gray, 0.30)
        assertEquals(2, mask.count { it.toInt() == 1 })
        assertEquals(1, mask[5 * 40 + 6].toInt())
        assertEquals(1, mask[30 * 40 + 30].toInt())
        assertEquals(0, mask[5 * 40 + 5].toInt())
        // A map of part of the image: the mask covers that part only.
        val part = estimate(gray, 20, 20, 20, 20, 10)
        val partMask = part.inkMask(gray, 0.30)
        assertEquals(400, partMask.size)
        assertEquals(1, partMask[10 * 20 + 10].toInt())
        assertEquals(1, partMask.count { it.toInt() == 1 })
    }
}

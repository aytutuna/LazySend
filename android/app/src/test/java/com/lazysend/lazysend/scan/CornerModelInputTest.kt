package com.lazysend.lazysend.scan

import org.junit.Assert.assertEquals
import org.junit.Test

private const val PLANE = CornerModelInput.SIDE * CornerModelInput.SIDE

/** A `width` x `height` photo whose pixel (x, y) is `color(x, y)` (red, green, blue), opaque. */
private fun photo(width: Int, height: Int, color: (Int, Int) -> Triple<Int, Int, Int>): RgbaImage {
    val pixels = ByteArray(width * height * 4)
    pixels.fill(-1)
    for (y in 0 until height) {
        for (x in 0 until width) {
            val (r, g, b) = color(x, y)
            val i = (y * width + x) * 4
            pixels[i] = r.toByte()
            pixels[i + 1] = g.toByte()
            pixels[i + 2] = b.toByte()
        }
    }
    return RgbaImage(width, height, pixels)
}

/** The input's value in `channel` (0 blue, 1 green, 2 red) at (x, y). */
private fun inputValue(input: FloatArray, channel: Int, x: Int, y: Int): Float =
    input[channel * PLANE + y * CornerModelInput.SIDE + x]

private fun assertValue(expected: Float, actual: Float) = assertEquals(expected, actual, 0f)

class CornerModelInputTest {
    @Test
    fun theInputIsBlueGreenAndRedPlanesFromZeroToOne() {
        val input = CornerModelInput.make(RgbaImage.filled(300, 200, 255, 128, 0))
        assertEquals(3 * 256 * 256, input.size)
        for ((x, y) in listOf(0 to 0, 255 to 0, 17 to 93, 255 to 255)) {
            assertValue(0f, inputValue(input, 0, x, y))
            assertValue((128.0 / 255).toFloat(), inputValue(input, 1, x, y))
            assertValue(1f, inputValue(input, 2, x, y))
        }
    }

    @Test
    fun halvingTakesTheMeanOfEachPairOfPixels() {
        // 512 wide: input column x reads photo columns 2x and 2x + 1 half and half; 256 high: rows 1 to 1.
        val input = CornerModelInput.make(photo(512, 256) { x, y -> Triple(x and 255, y, 0) })
        assertValue((20.5 / 255).toFloat(), inputValue(input, 2, 10, 7))
        assertValue((254.5 / 255).toFloat(), inputValue(input, 2, 127, 7))
        assertValue((0.5 / 255).toFloat(), inputValue(input, 2, 128, 7))
        assertValue((144.5 / 255).toFloat(), inputValue(input, 2, 200, 7))
        assertValue((7.0 / 255).toFloat(), inputValue(input, 1, 10, 7))
        assertValue(1f, inputValue(input, 1, 10, 255))
    }

    @Test
    fun enlargingBlendsTheNearestPixelsAndClampsAtTheEdges() {
        // 2 x 2: red 0 on the left and 255 on the right, green 0 at the top and 255 at the bottom.
        val input = CornerModelInput.make(photo(2, 2) { x, y -> Triple(255 * x, 255 * y, 0) })
        assertValue(0f, inputValue(input, 2, 0, 0))
        assertValue(0f, inputValue(input, 2, 63, 0))
        assertValue((0.99609375 / 255).toFloat(), inputValue(input, 2, 64, 0))
        assertValue((128.49609375 / 255).toFloat(), inputValue(input, 2, 128, 0))
        assertValue(1f, inputValue(input, 2, 255, 0))
        assertValue((128.49609375 / 255).toFloat(), inputValue(input, 1, 0, 128))
        assertValue(1f, inputValue(input, 1, 0, 255))
    }

    @Test
    fun anOddSizedPhotoGivesTheSameNumbersOnBothPlatforms() {
        val input = CornerModelInput.make(photo(300, 200) { x, y ->
            Triple((x * 7 + y * 3) and 255, (x * y) and 255, (x + 2 * y) and 255)
        })
        assertValue(0.00033700981293804944f, input[0])
        assertValue(0.00493259821087122f, input[1])
        assertValue(0.16829043626785278f, input[255])
        assertValue(0.7822610139846802f, input[25637])
        assertValue(0.4466605484485626f, input[131071])
        assertValue(0.30775123834609985f, input[163969])
        var sum = 0.0
        for (v in input) sum += v.toDouble()
        assertEquals(96996.50867031487, sum, 0.0)
    }
}

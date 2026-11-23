package com.lazysend.lazysend.scan

import android.graphics.Matrix
import android.graphics.PixelFormat
import android.graphics.Rect
import android.media.Image
import androidx.camera.core.ImageInfo
import androidx.camera.core.ImageProxy
import androidx.camera.core.impl.TagBundle
import androidx.camera.core.impl.utils.ExifData
import java.nio.ByteBuffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [36], application = android.app.Application::class)
class ScanFrameFeedTest {
    private class FakeImage(
        private val bytes: ByteArray,
        private val w: Int,
        private val h: Int,
        private val stride: Int,
        private val turn: Int,
        private val nanos: Long,
        private val pixelFormat: Int = PixelFormat.RGBA_8888,
    ) : ImageProxy {
        var closed = false

        override fun close() {
            closed = true
        }

        override fun getCropRect() = Rect(0, 0, w, h)

        override fun setCropRect(rect: Rect?) {}

        override fun getFormat() = pixelFormat

        override fun getHeight() = h

        override fun getWidth() = w

        override fun getPlanes(): Array<ImageProxy.PlaneProxy> = arrayOf(
            object : ImageProxy.PlaneProxy {
                override fun getRowStride() = stride

                override fun getPixelStride() = 4

                override fun getBuffer(): ByteBuffer = ByteBuffer.wrap(bytes)
            },
        )

        override fun getImageInfo(): ImageInfo = object : ImageInfo {
            override fun getTagBundle(): TagBundle = TagBundle.emptyBundle()

            override fun getTimestamp() = nanos

            override fun getRotationDegrees() = turn

            override fun populateExifData(exifBuilder: ExifData.Builder) {}

            override fun getSensorToBufferTransformMatrix() = Matrix()
        }

        @androidx.camera.core.ExperimentalGetImage
        override fun getImage(): Image? = null
    }

    /** A [w] x [h] frame whose pixel (x, y) is (x * 10, y * 10, 7) with [stride] bytes a row, the padding 99. */
    private fun frame(w: Int, h: Int, stride: Int): ByteArray {
        val bytes = ByteArray(stride * h) { 99 }
        for (y in 0 until h) {
            for (x in 0 until w) {
                val o = y * stride + x * 4
                bytes[o] = (x * 10).toByte()
                bytes[o + 1] = (y * 10).toByte()
                bytes[o + 2] = 7
                bytes[o + 3] = -1
            }
        }
        return bytes
    }

    @Test
    fun aFrameWithPaddedRowsKeepsItsPixelsAndChannelOrder() {
        val feed = ScanFrameFeed(null)
        var got: ScanFrame? = null
        feed.start { got = it }
        feed.handle(frame(8, 4, 48), 8, 4, 48, 90, 1234.0)
        val image = got!!.image
        assertEquals(8, image.width)
        assertEquals(4, image.height)
        assertEquals(1234.0, got!!.timestampMs, 0.0)
        assertNull(got!!.page)
        for (y in 0 until 4) {
            for (x in 0 until 8) {
                val o = (y * 8 + x) * 4
                assertEquals(x * 10, image.pixels[o].toInt() and 0xFF)
                assertEquals(y * 10, image.pixels[o + 1].toInt() and 0xFF)
                assertEquals(7, image.pixels[o + 2].toInt() and 0xFF)
            }
        }
    }

    @Test
    fun aBigFrameIsMadeSmallBeforeAnythingElse() {
        val feed = ScanFrameFeed(null)
        var got: ScanFrame? = null
        feed.start { got = it }
        feed.handle(ByteArray(1280 * 720 * 4), 1280, 720, 1280 * 4, 0, 0.0)
        assertTrue(maxOf(got!!.image.width, got!!.image.height) <= LiveQuadTracker.ANALYSIS_LONG_SIDE)
        assertEquals(1280.0 / 720, got!!.image.width.toDouble() / got!!.image.height, 0.05)
    }

    @Test
    fun theModelSeesTheFrameUprightAndItsPageComesBackInTheSensorsFrame() {
        // The demo's frame as a sensor gives it with the phone upright: turned a quarter counterclockwise, 480 x 360.
        val sensor = ScanDemo.frame.rotatedQuarterTurns(3)
        assertEquals(480, sensor.width)
        val feed = ScanFrameFeed(ScanDemo.finder())
        var got: ScanFrame? = null
        feed.start { got = it }
        feed.handle(sensor.pixels, sensor.width, sensor.height, sensor.width * 4, 90, 0.0)
        val page = got!!.page!!
        // An upright pixel (x, y) is the sensor's (y, width - x), the frame being 480 x 360 here and 360 x 480 upright.
        val expected = ScanDemo.outline.corners.map { Pt(it.y, ScanDemo.WIDTH - it.x) }
        for (corner in page.quad.corners) {
            assertTrue("$corner", expected.any { Math.hypot(it.x - corner.x, it.y - corner.y) < 8 })
        }
    }

    @Test
    fun framesComeOnlyWhileStartedAndNotSoonerThanTheTrackerWantsThem() {
        val feed = ScanFrameFeed(null)
        val bytes = frame(8, 4, 32)
        var count = 0
        feed.analyze(FakeImage(bytes, 8, 4, 32, 0, 1_000_000_000))
        assertEquals(0, count)
        feed.start { count++ }
        val first = FakeImage(bytes, 8, 4, 32, 0, 1_000_000_000)
        feed.analyze(first)
        assertEquals(1, count)
        assertTrue(first.closed)
        feed.analyze(FakeImage(bytes, 8, 4, 32, 0, 1_050_000_000))
        assertEquals(1, count)
        feed.analyze(FakeImage(bytes, 8, 4, 32, 0, 1_100_000_000))
        assertEquals(2, count)
        // A clock that started over is not too soon.
        feed.analyze(FakeImage(bytes, 8, 4, 32, 0, 500_000_000))
        assertEquals(3, count)
        feed.stop()
        feed.analyze(FakeImage(bytes, 8, 4, 32, 0, 5_000_000_000))
        assertEquals(3, count)
    }

    @Test
    fun aWarmPhoneAsksForFewerFrames() {
        var warm = true
        val feed = ScanFrameFeed(null) { warm }
        val bytes = frame(8, 4, 32)
        var count = 0
        feed.start { count++ }
        feed.analyze(FakeImage(bytes, 8, 4, 32, 0, 1_000_000_000))
        feed.analyze(FakeImage(bytes, 8, 4, 32, 0, 1_100_000_000))
        assertEquals(1, count)
        warm = false
        feed.analyze(FakeImage(bytes, 8, 4, 32, 0, 1_200_000_000))
        assertEquals(2, count)
    }

    @Test
    fun aFrameInAnotherFormatIsClosedAndPassedOver() {
        val feed = ScanFrameFeed(null)
        var count = 0
        feed.start { count++ }
        val yuv = FakeImage(ByteArray(64), 8, 4, 32, 0, 1_000_000_000, pixelFormat = 35)
        feed.analyze(yuv)
        assertEquals(0, count)
        assertTrue(yuv.closed)
    }
}

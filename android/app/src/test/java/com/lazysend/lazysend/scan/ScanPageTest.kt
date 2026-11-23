package com.lazysend.lazysend.scan

import android.graphics.BitmapFactory
import android.media.ExifInterface
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36], application = android.app.Application::class)
class ScanPageTest {
    private val truth = PhotoScenes.woodMap.corners(PhotoScenes.pageWidth, PhotoScenes.pageHeight)

    private fun size(jpeg: ByteArray): Pair<Int, Int> {
        assertEquals(0xFF.toByte(), jpeg[0])
        assertEquals(0xD8.toByte(), jpeg[1])
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size, bounds)
        return bounds.outWidth to bounds.outHeight
    }

    @Test
    fun aPhotoIsCutOutAlongItsCornersAndKeepsThemForALaterCut() {
        val photo = PhotoScenes.woodScene()
        val page = PagePipeline.page(photo, truth, CaptureFilter.Enhanced)!!
        assertEquals(truth, page.corners)
        assertEquals(page.width to page.height, size(page.jpeg))
        // An A4 sheet: 1.414 times as long as wide.
        assertEquals(1.4142, page.height.toDouble() / page.width, 0.06)
        assertTrue(page.dpi in PagePipeline.MIN_DPI..PagePipeline.MAX_DPI)
    }

    @Test
    fun grayAndBlackAndWhiteFiltersMakeGrayPagesAndOriginalKeepsColour() {
        val photo = PhotoScenes.woodScene()
        for (filter in listOf(CaptureFilter.Grayscale, CaptureFilter.BlackAndWhite)) {
            val page = PagePipeline.page(photo, truth, filter)!!
            assertTrue("$filter", page.gray)
            assertEquals("$filter", 3, ScanPdf.jpegComponents(page.jpeg))
        }
        val original = PagePipeline.page(photo, truth, CaptureFilter.Original)!!
        assertFalse(original.gray)
        val options = PerspectiveOptions(maxLongSide = PagePipeline.MAX_LONG_SIDE)
        val cut = PerspectiveCorrector.correct(photo, Quad.fromCorners(truth.corners), options)!!
        assertEquals(cut.image.width, original.width)
        assertEquals(cut.image.height, original.height)
    }

    @Test
    fun theWholePhotoIsOnlyFiltered() {
        val photo = PhotoScenes.woodScene()
        val page = PagePipeline.wholePage(photo, CaptureFilter.Original)!!
        assertEquals(photo.width, page.width)
        assertEquals(photo.height, page.height)
        assertEquals(PageFinder.wholePhoto(photo.width, photo.height), page.corners)
    }

    @Test
    fun cornersThatOutlineNoPageMakeNoPage() {
        val point = Pt(10.0, 10.0)
        val line = Quad(point, point, point, point)
        assertNull(PagePipeline.page(PhotoScenes.woodScene(), line, CaptureFilter.Enhanced))
    }

    @Test
    fun thePageDpiIsKeptWithinItsLimits() {
        assertEquals(50, PagePipeline.pageDpi(12.0, 1000))
        assertEquals(1200, PagePipeline.pageDpi(5000.0, 1000))
        assertEquals(200, PagePipeline.pageDpi(199.6, 1000))
    }

    @Test
    fun aPageThatMatchedNoPaperTakesTheUsualSheetsLongSide() {
        // 2339 px on A4's 11.69 in is 200 dpi, where Letter's 11 in makes it 213: never a made-up 15 in page.
        assertEquals(200, PagePipeline.pageDpi(null, 2339, "DE"))
        assertEquals(200, PagePipeline.pageDpi(Double.NaN, 2339, "DE"))
        assertEquals(213, PagePipeline.pageDpi(null, 2339, "us"))
        assertEquals(257, PagePipeline.pageDpi(null, 3000, null))
        assertEquals(50, PagePipeline.pageDpi(null, 100, "CA"))
    }

    @Test
    fun aPhotoFromTheCameraIsReadUprightByItsOrientationTag() {
        val temp = File.createTempFile("photo", ".jpg")
        try {
            // A 40 x 20 picture, red on the left half, tagged "turned a quarter": read as 20 x 40.
            val pixels = RgbaImage.filled(40, 20, 40, 40, 200).pixels
            for (y in 0 until 20) for (x in 0 until 20) {
                val i = (y * 40 + x) * 4
                pixels[i] = 220.toByte(); pixels[i + 1] = 30; pixels[i + 2] = 30
            }
            temp.writeBytes(JpegEncoder.encode(RgbaImage(40, 20, pixels), false)!!)
            ExifInterface(temp.absolutePath).apply {
                setAttribute(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_ROTATE_90.toString())
                saveAttributes()
            }
            val read = PhotoReader.decode(temp.readBytes())!!
            assertEquals(20, read.width)
            assertEquals(40, read.height)
            // A quarter turn clockwise puts the left half at the top.
            assertTrue((read.pixels[(5 * 20 + 10) * 4].toInt() and 0xFF) > 150)
            assertTrue((read.pixels[(35 * 20 + 10) * 4].toInt() and 0xFF) < 100)
        } finally {
            temp.delete()
        }
        assertNull(PhotoReader.decode(byteArrayOf(0, 1, 2, 3)))
    }

    @Test
    fun aPhotoWithNoTagIsReadAsItIs() {
        val read = PhotoReader.decode(JpegEncoder.encode(RgbaImage.filled(40, 20, 90, 90, 90), false)!!)!!
        assertEquals(40, read.width)
        assertEquals(20, read.height)
    }

    @Test
    fun aThumbnailIsNoLargerThanAskedForByMoreThanTheSampling() {
        val jpeg = JpegEncoder.encode(RgbaImage.filled(400, 300, 90, 90, 90), false)!!
        val thumb = jpeg.toThumbnail(100)!!
        assertEquals(100, thumb.width)
        assertEquals(75, thumb.height)
        assertNotNull(jpeg.toThumbnail(1000))
        assertNull(byteArrayOf(1, 2, 3).toThumbnail(100))
    }
}

package com.lazysend.lazysend.scan

import java.nio.charset.StandardCharsets
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36], application = android.app.Application::class)
class ScanPdfTest {
    private fun page(width: Int, height: Int, dpi: Int, gray: Boolean, shade: Int): ScanPage {
        val jpeg = JpegEncoder.encode(RgbaImage.filled(width, height, shade, shade, shade), gray)!!
        return ScanPage(corners = PageFinder.wholePhoto(width, height), filter = CaptureFilter.Original, jpeg = jpeg,
            width = width, height = height, dpi = dpi, gray = gray)
    }

    private val pages = listOf(
        page(600, 800, 100, false, 200),
        page(800, 600, 200, true, 90),
        page(64, 64, 72, false, 30),
    )

    private fun text(data: ByteArray) = String(data, StandardCharsets.ISO_8859_1)

    private fun indexOf(data: ByteArray, needle: ByteArray, from: Int = 0): Int {
        outer@ for (i in from..data.size - needle.size) {
            for (j in needle.indices) if (data[i + j] != needle[j]) continue@outer
            return i
        }
        return -1
    }

    @Test
    fun aLongScanIsWrittenPageByPageToAFileAndIsTheSameAsTheOneBuiltInMemory() {
        val sample = pages[0]
        val asked = mutableListOf<Int>()
        val file = java.io.File.createTempFile("scan", ".pdf")
        try {
            // Each page is made when it is asked for and dropped after: 150 pages of 400 KB never exist together.
            file.outputStream().buffered().use { out ->
                ScanPdf.write(out, 150) { i ->
                    asked += i
                    sample.copy(jpeg = ByteArray(400_000) { b -> (b + i).toByte() })
                }
            }

            assertEquals((0 until 150).toList(), asked)
            val s = text(file.readBytes())
            assertTrue(s.contains("/Count 150 /Kids [3 0 R 6 0 R"))
            assertTrue(s.contains("452 0 obj"))
            assertTrue(s.endsWith("%%EOF\n"))
            val startxref = s.substringAfterLast("startxref\n").substringBefore("\n").toInt()
            assertTrue(s.substring(startxref).startsWith("xref\n0 453\n"))
        } finally {
            file.delete()
        }
        val streamed = java.io.ByteArrayOutputStream().also { out -> ScanPdf.write(out, pages.size) { pages[it] } }.toByteArray()
        assertEquals(text(ScanPdf.make(pages)), text(streamed))
    }

    @Test
    fun everyPageIsOnePdfPageTheSizeItPrintsAt() {
        val data = ScanPdf.make(pages)
        val s = text(data)
        assertTrue(s.startsWith("%PDF-1.4\n%"))
        assertTrue(s.endsWith("%%EOF\n"))
        assertTrue(s.contains("/Count 3 /Kids [3 0 R 6 0 R 9 0 R]"))
        assertTrue(s.contains("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 432.00 576.00]"))
        assertTrue(s.contains("6 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 288.00 216.00]"))
        assertTrue(s.contains("9 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 64.00 64.00]"))
    }

    @Test
    fun theJpegsAreEmbeddedAsTheyAreWithTheColorSpaceTheyHave() {
        val data = ScanPdf.make(pages)
        val s = text(data)
        var from = 0
        for ((i, page) in pages.withIndex()) {
            val number = 5 + 3 * i
            val head = "$number 0 obj\n<< /Type /XObject /Subtype /Image /Width ${page.width} /Height ${page.height} " +
                "/ColorSpace ${"/DeviceRGB"} /BitsPerComponent 8 /Filter /DCTDecode /Length ${page.jpeg.size} >>\nstream\n"
            val start = s.indexOf("$number 0 obj\n", from)
            assertTrue(start >= 0)
            val actual = s.substring(start, start + head.length)
            val space = if (ScanPdf.jpegComponents(page.jpeg) == 1) "/DeviceGray" else "/DeviceRGB"
            assertEquals(head.replace("/DeviceRGB", space), actual)
            val streamAt = start + head.length
            assertEquals(page.jpeg.toList(), data.copyOfRange(streamAt, streamAt + page.jpeg.size).toList())
            assertEquals("\nendstream\nendobj\n", s.substring(streamAt + page.jpeg.size, streamAt + page.jpeg.size + 18))
            from = streamAt
        }
        assertEquals(3, "/DCTDecode".toRegex().findAll(s).count())
    }

    @Test
    fun aGrayPageStaysAJpegTheViewerReadsAsDeviceRgbWhenThePlatformWritesThreeComponents() {
        val gray = pages[1]
        val expected = if (ScanPdf.jpegComponents(gray.jpeg) == 1) "/DeviceGray" else "/DeviceRGB"
        assertTrue(text(ScanPdf.make(listOf(gray))).contains("/ColorSpace $expected"))
        assertEquals(3, ScanPdf.jpegComponents(pages[0].jpeg))
    }

    @Test
    fun theComponentCountComesFromTheFrameHeader() {
        val one = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte(), 0xE0.toByte(), 0, 4, 0, 0,
            0xFF.toByte(), 0xC0.toByte(), 0, 11, 8, 0, 4, 0, 4, 1, 1, 0x11, 0)
        assertEquals(1, ScanPdf.jpegComponents(one))
        assertEquals(null, ScanPdf.jpegComponents(byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 1, 2, 3, 4)))
    }

    @Test
    fun theCrossReferenceTablePointsAtItsObjects() {
        val data = ScanPdf.make(pages)
        val s = text(data)
        val start = s.substringAfterLast("startxref\n").substringBefore("\n").toInt()
        assertEquals("xref\n", s.substring(start, start + 5))
        val lines = s.substring(start).split("\n")
        assertEquals("0 12", lines[1])
        assertEquals("0000000000 65535 f ", lines[2])
        for (n in 1..11) {
            val entry = lines[2 + n]
            assertEquals(20, entry.length + 1)
            val offset = entry.substring(0, 10).toInt()
            assertTrue(entry.endsWith(" 00000 n "))
            val marker = "$n 0 obj\n".toByteArray()
            assertEquals(offset, indexOf(data, marker, offset))
        }
        assertTrue(s.contains("trailer\n<< /Size 12 /Root 1 0 R >>"))
    }
}

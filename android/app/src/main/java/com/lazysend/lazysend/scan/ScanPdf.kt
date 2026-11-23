package com.lazysend.lazysend.scan

import java.io.ByteArrayOutputStream
import java.util.Locale

/** Writes a scan's pages as one PDF: each page's JPEG is embedded as it is, on a page the size it prints at (`ScanPage.dpi`). */
object ScanPdf {
    fun make(pages: List<ScanPage>): ByteArray {
        val out = ByteArrayOutputStream()
        val offsets = ArrayList<Int>()

        fun add(text: String) = out.write(text.toByteArray(Charsets.ISO_8859_1))
        fun begin(number: Int) {
            offsets.add(out.size())
            add("$number 0 obj\n")
        }

        // The second line is four high bytes, which tells file transfer tools that the file is binary.
        add("%PDF-1.4\n%")
        out.write(byteArrayOf(0xE2.toByte(), 0xE3.toByte(), 0xCF.toByte(), 0xD3.toByte(), 0x0A))
        // Object 1 is the catalog and 2 the page tree; page i is object 3 + 3i, followed by its content and its image.
        begin(1)
        add("<< /Type /Catalog /Pages 2 0 R >>\nendobj\n")
        begin(2)
        val kids = pages.indices.joinToString(" ") { "${3 + 3 * it} 0 R" }
        add("<< /Type /Pages /Count ${pages.size} /Kids [$kids] >>\nendobj\n")
        for ((i, page) in pages.withIndex()) {
            val first = 3 + 3 * i
            val w = page.width.toDouble() * 72 / page.dpi
            val h = page.height.toDouble() * 72 / page.dpi
            val size = "${points(w)} ${points(h)}"
            begin(first)
            add("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 $size] /Resources << /XObject << /Im0 ${first + 2} 0 R >> >> /Contents ${first + 1} 0 R >>\nendobj\n")
            val content = "q ${points(w)} 0 0 ${points(h)} 0 0 cm /Im0 Do Q\n"
            begin(first + 1)
            add("<< /Length ${content.length} >>\nstream\n${content}endstream\nendobj\n")
            begin(first + 2)
            // The encoder writes three components even for a gray page, so the color space comes from the JPEG itself.
            val space = if (jpegComponents(page.jpeg) == 1) "/DeviceGray" else "/DeviceRGB"
            add("<< /Type /XObject /Subtype /Image /Width ${page.width} /Height ${page.height} /ColorSpace $space /BitsPerComponent 8 /Filter /DCTDecode /Length ${page.jpeg.size} >>\nstream\n")
            out.write(page.jpeg)
            add("\nendstream\nendobj\n")
        }
        val table = out.size()
        add("xref\n0 ${offsets.size + 1}\n0000000000 65535 f \n")
        for (offset in offsets) add(String.format(Locale.US, "%010d 00000 n \n", offset))
        add("trailer\n<< /Size ${offsets.size + 1} /Root 1 0 R >>\nstartxref\n$table\n%%EOF\n")
        return out.toByteArray()
    }

    private fun points(value: Double): String = String.format(Locale.US, "%.2f", value)

    /** The component count in the frame header of a JPEG; null when no frame header comes before the scan. */
    internal fun jpegComponents(jpeg: ByteArray): Int? {
        var i = 2
        while (i + 3 < jpeg.size) {
            if (jpeg[i] != 0xFF.toByte()) return null
            val marker = jpeg[i + 1].toInt() and 0xFF
            if (marker == 0xFF) { i++; continue }
            if (marker == 0xDA) return null
            if (marker == 0x01 || marker in 0xD0..0xD8) { i += 2; continue }
            if (marker in 0xC0..0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC) {
                return if (i + 9 < jpeg.size) jpeg[i + 9].toInt() and 0xFF else null
            }
            i += 2 + (((jpeg[i + 2].toInt() and 0xFF) shl 8) or (jpeg[i + 3].toInt() and 0xFF))
        }
        return null
    }
}

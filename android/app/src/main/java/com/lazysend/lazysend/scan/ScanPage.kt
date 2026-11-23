package com.lazysend.lazysend.scan

import java.util.Locale
import java.util.UUID
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

/**
 * A page of a scan: the corners it was cut out along in the photo (so the page can be cut again from
 * the photo, which `ScanPageStore` keeps), the filter it was cleaned up with, and the page as a JPEG.
 */
data class ScanPage(
    val id: UUID = UUID.randomUUID(),
    /** The corners in the upright photo's pixels. */
    val corners: Quad,
    val filter: CaptureFilter,
    val jpeg: ByteArray,
    val width: Int,
    val height: Int,
    /** The resolution the page is printed at in a PDF. */
    val dpi: Int,
    /** The page has no colour (gray or black and white). */
    val gray: Boolean,
) {
    override fun equals(other: Any?): Boolean =
        other is ScanPage && id == other.id && corners == other.corners && filter == other.filter &&
            jpeg.contentEquals(other.jpeg) && width == other.width && height == other.height &&
            dpi == other.dpi && gray == other.gray

    override fun hashCode(): Int = id.hashCode() * 31 + jpeg.contentHashCode()
}

/** Makes the page of a photo: cut out along the corners with its perspective corrected, then cleaned up as the filter says. */
object PagePipeline {
    const val NOMINAL_DPI = 200
    const val MIN_DPI = 50
    const val MAX_DPI = 1200

    /** A cut page is at most this many pixels long (A4 at 300 dpi), however close the camera was. */
    const val MAX_LONG_SIDE = 3508

    /** Where Letter is the usual paper; A4 everywhere else. */
    private val letterRegions = setOf("US", "CA", "MX", "PH", "CL", "CO", "CR", "DO", "GT", "NI", "PA", "PR", "SV", "VE")

    private class Made(val jpeg: ByteArray, val width: Int, val height: Int, val gray: Boolean)

    /** The page of `photo` (upright) cut along `corners`. Null when the corners outline no page or it cannot be encoded. */
    fun page(photo: RgbaImage, corners: Quad, filter: CaptureFilter, id: UUID = UUID.randomUUID()): ScanPage? {
        val named = Quad.fromCorners(corners.corners)
        val options = PerspectiveOptions(maxLongSide = MAX_LONG_SIDE)
        val cut = PerspectiveCorrector.correct(photo, named, options) ?: return null
        val made = cleaned(cut.image, filter) ?: return null
        return ScanPage(id, corners, filter, made.jpeg, made.width, made.height,
            pageDpi(cut.plan.dpi, max(made.width, made.height)), made.gray)
    }

    /** The whole photo as the page, as with Use whole photo in the corner editor: only the filter is applied. */
    fun wholePage(photo: RgbaImage, filter: CaptureFilter, id: UUID = UUID.randomUUID()): ScanPage? {
        val made = cleaned(photo, filter) ?: return null
        val dpi = pageDpi(null, max(made.width, made.height))
        return ScanPage(id, PageFinder.wholePhoto(photo.width, photo.height), filter, made.jpeg, made.width,
            made.height, dpi, made.gray)
    }

    private fun cleaned(image: RgbaImage, filter: CaptureFilter): Made? {
        var result = image
        var gray = false
        filter.mode?.let { mode ->
            val enhanced = DocumentEnhancer.enhance(image, mode)
            result = enhanced.image
            gray = enhanced.mode == DocumentEnhanceMode.Gray || enhanced.mode == DocumentEnhanceMode.BlackAndWhite
        }
        val jpeg = JpegEncoder.encode(result, gray) ?: return null
        return Made(jpeg, result.width, result.height, gray)
    }

    /**
     * `dpi` rounded and kept within `MIN_DPI` to `MAX_DPI`. A page that matched no paper size gets the resolution that
     * makes its long side the long side of the usual paper where the user lives (Letter or A4), so it is not printed at
     * a made-up size.
     */
    internal fun pageDpi(dpi: Double?, longSide: Int, region: String? = Locale.getDefault().country): Int {
        var d = dpi ?: 0.0
        if (!(d.isFinite() && d > 0)) {
            val inches = if ((region ?: "").uppercase(Locale.ROOT) in letterRegions) 11.0 else 11.69
            d = if (longSide > 0) longSide / inches else NOMINAL_DPI.toDouble()
        }
        return min(max(floor(d + 0.5).toInt(), MIN_DPI), MAX_DPI)
    }
}

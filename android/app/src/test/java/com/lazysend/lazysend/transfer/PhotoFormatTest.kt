package com.lazysend.lazysend.transfer

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PhotoFormatTest {
    @Test
    fun picturesInAnotherFormatAreConverted() {
        for (mime in listOf("image/heic", "image/heif", "image/webp")) assertTrue(mime, converts(PhotoFormat.Jpeg, mime))
        for (mime in listOf("image/heic", "image/webp", "image/jpeg", "image/bmp")) assertTrue(mime, converts(PhotoFormat.Png, mime))
    }

    @Test
    fun aPngOrAnotherStillPictureIsNotMadeIntoAJpeg() {
        for (mime in listOf("image/png", "image/bmp", "image/x-ms-bmp", "image/jpeg")) assertFalse(mime, converts(PhotoFormat.Jpeg, mime))
    }

    @Test
    fun aWebpWithTransparencyIsLeftAloneUnderJpeg() {
        val plain = "RIFF\u0000\u0000\u0000\u0000WEBPVP8X\u000a\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000".toByteArray(Charsets.ISO_8859_1)
        val extended = plain.copyOf().also { it[20] = 0x10 }
        val lossless = "RIFF\u0000\u0000\u0000\u0000WEBPVP8L\u0000\u0000\u0000\u0000\u002f\u0000\u0000\u0000\u0000".toByteArray(Charsets.ISO_8859_1)
        val losslessAlpha = lossless.copyOf().also { it[24] = 0x10 }
        assertFalse(hasAlpha("image/webp", plain))
        assertTrue(hasAlpha("image/webp", extended))
        assertFalse(hasAlpha("image/webp", lossless))
        assertTrue(hasAlpha("image/webp", losslessAlpha))
        assertFalse(hasAlpha("image/png", extended))
    }

    @Test
    fun aPictureAlreadyInTheFormatIsLeftAlone() {
        assertFalse(converts(PhotoFormat.Jpeg, "image/jpeg"))
        assertFalse(converts(PhotoFormat.Png, "image/png"))
    }

    @Test
    fun originalGifsVideosAndOtherFilesAreNeverConverted() {
        for (mime in listOf("image/jpeg", "image/heic", "video/mp4", "application/pdf", null)) assertFalse(mime, converts(PhotoFormat.Original, mime))
        for (format in listOf(PhotoFormat.Jpeg, PhotoFormat.Png)) {
            for (mime in listOf("image/gif", "image/svg+xml", "video/mp4", "application/pdf", "text/plain", null)) assertFalse("$format $mime", converts(format, mime))
        }
    }

    @Test
    fun theExtensionFollowsTheFormat() {
        assertEquals("IMG_1.jpg", convertedName("IMG_1.heic", PhotoFormat.Jpeg))
        assertEquals("holiday.2026.png", convertedName("holiday.2026.webp", PhotoFormat.Png))
        assertEquals("shot.jpg", convertedName("shot", PhotoFormat.Jpeg))
        assertEquals("IMG_1.heic", convertedName("IMG_1.heic", PhotoFormat.Original))
    }

    @Test
    fun rawFilesAvifAndAnimatedTypesAreLeftAlone() {
        for (format in listOf(PhotoFormat.Jpeg, PhotoFormat.Png)) {
            for (mime in listOf("image/x-adobe-dng", "image/x-canon-cr2", "image/x-sony-arw", "image/avif", "image/apng")) assertFalse("$format $mime", converts(format, mime))
        }
        assertTrue(converts(PhotoFormat.Png, "image/x-ms-bmp"))
    }

    @Test
    fun animatedWebpAndPngAreRecognisedFromTheirStart() {
        val still = "RIFF\u0000\u0000\u0000\u0000WEBPVP8X\u000a\u0000\u0000\u0000\u0000\u0000\u0000\u0000".toByteArray(Charsets.ISO_8859_1)
        val moving = still.copyOf().also { it[20] = 0x12 }
        assertFalse(isAnimated("image/webp", still))
        assertTrue(isAnimated("image/webp", moving))
        assertFalse(isAnimated("image/png", "\u0089PNG....IHDR....IDAT....".toByteArray(Charsets.ISO_8859_1)))
        assertTrue(isAnimated("image/png", "\u0089PNG....IHDR....acTL....IDAT....".toByteArray(Charsets.ISO_8859_1)))
        assertFalse(isAnimated("image/jpeg", moving))
    }

    @Test
    fun aHugePictureIsDecodedAtNoMoreThanAboutFortyMegapixels() {
        assertEquals(1, sampleSizeFor(8000, 5000))
        assertEquals(1, sampleSizeFor(6000, 6666))
        val big = sampleSizeFor(12000, 9000)
        assertTrue(big >= 2)
        assertTrue((12000L / big) * (9000L / big) <= 40_000_000L)
    }
}
